use std::sync::atomic::{AtomicU32, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};

use anyhow::Result;
use bytes::Bytes;
use futures::{SinkExt, StreamExt};
use tokio::sync::mpsc;
use tokio::task::JoinHandle;
use valence_protocol::uuid::Uuid;

use crate::config::ClientConfig;
use crate::mc::packets::{
    CustomPayloadC2s, CustomPayloadS2c, DisconnectS2c, Ident, KeepAliveC2s, KeepAliveS2c, Packet,
    RawBytes,
};
use crate::mc::{configuration, handshake, login, play};
use crate::net::framed::{self, McFramed};
use crate::net::tcp;

/// The plugin-channel identifier the Play-state byte transport rides on.
/// This is also a wire-visible fingerprint; isolated here so it's a
/// one-line change to disguise later.
const TUNNEL_CHANNEL: &str = "mcvpn:tunnel";

/// Bukkit's `Messenger.MAX_MESSAGE_SIZE` is 32766 bytes; stay comfortably
/// under it in both directions so neither side ever has to reject a frame.
const MAX_FRAME_LEN: usize = 32000;

const CHANNEL_CAPACITY: usize = 64;

static USERNAME_COUNTER: AtomicU32 = AtomicU32::new(0);

/// The reusable Minecraft transport. `connect()` drives the connection
/// through Handshake, Login, Configuration, and Play, and announces the
/// tunnel plugin channel. `spawn()` then hands the connection off to a
/// background actor task and returns a `Tunnel` for moving frame payloads
/// in and out — this is what `send_frame()`/`receive_frame()` from the
/// original design become once there's a concurrent caller (the proxy
/// layer) that needs to read and write at the same time.
///
/// There's no explicit `disconnect()`: every `Session` gets `spawn()`ed
/// into a `Tunnel` immediately, and the connection closes when the actor
/// task ends (`Tunnel::join.abort()`, or the socket erroring out) and its
/// `McFramed` is dropped — a TCP close either way, no farewell packet
/// needed to look like a real client quitting.
pub struct Session {
    framed: McFramed,
    pub uuid: Uuid,
    pub username: String,
    pub entity_id: i32,
}

impl Session {
    /// Connects to `server_host:server_port` under a freshly generated
    /// unique username and drives the connection all the way to Play.
    pub async fn connect(config: &ClientConfig) -> Result<Self> {
        let stream = tcp::connect((config.server_host.as_str(), config.server_port)).await?;
        let mut framed = framed::new(stream);

        handshake::send(&mut framed, &config.server_host, config.server_port).await?;
        let username = unique_username(&config.username_prefix);
        let login = login::perform(&mut framed, &username).await?;
        configuration::run().await;
        let play_info = play::await_join(&mut framed).await?;
        play::register_channel(&mut framed, TUNNEL_CHANNEL).await?;

        Ok(Self {
            framed,
            uuid: login.uuid,
            username: login.username,
            entity_id: play_info.entity_id,
        })
    }

    /// Hands the connection off to a background actor task and returns a
    /// pair of channels for moving frame payloads in and out. The actor
    /// owns the connection exclusively, so it can answer `KeepAlive` on its
    /// own without any locking, while the two directions of a proxied
    /// stream run as fully independent tasks against `Tunnel`.
    pub fn spawn(self) -> Tunnel {
        let (outbound_tx, outbound_rx) = mpsc::channel(CHANNEL_CAPACITY);
        let (inbound_tx, inbound_rx) = mpsc::channel(CHANNEL_CAPACITY);

        let join = tokio::spawn(run_actor(self.framed, outbound_rx, inbound_tx));

        Tunnel {
            sender: FrameSender(outbound_tx),
            receiver: FrameReceiver(inbound_rx),
            join,
        }
    }
}

async fn run_actor(
    mut framed: McFramed,
    mut outbound_rx: mpsc::Receiver<Bytes>,
    inbound_tx: mpsc::Sender<Bytes>,
) {
    loop {
        tokio::select! {
            payload = outbound_rx.recv() => {
                let Some(payload) = payload else {
                    // The caller dropped its sender: nothing left to relay
                    // outward. `Tunnel::join.abort()` (or this same
                    // channel-closed check on the inbound side) tears the
                    // rest down.
                    break;
                };
                if payload.len() > MAX_FRAME_LEN {
                    break;
                }
                let Ok(channel) = Ident::new(TUNNEL_CHANNEL) else { break };
                let packet = CustomPayloadC2s { channel, data: RawBytes(&payload) };
                if framed.send(&packet).await.is_err() {
                    break;
                }
            }
            frame = framed.next() => {
                let Some(Ok(frame)) = frame else { break };
                match frame.id {
                    CustomPayloadS2c::ID => {
                        let Ok(pkt) = frame.decode::<CustomPayloadS2c>() else { break };
                        if pkt.channel.as_str() == TUNNEL_CHANNEL
                            && inbound_tx.send(Bytes::copy_from_slice(pkt.data.0)).await.is_err()
                        {
                            break;
                        }
                    }
                    KeepAliveS2c::ID => {
                        let Ok(pkt) = frame.decode::<KeepAliveS2c>() else { break };
                        if framed.send(&KeepAliveC2s { id: pkt.id }).await.is_err() {
                            break;
                        }
                    }
                    DisconnectS2c::ID => break,
                    _ => {}
                }
            }
        }
    }
}

/// Generates a fresh, valid (`[a-zA-Z0-9_]`, <=16 chars) offline-mode
/// username so concurrent tunnels never collide on a duplicate login.
fn unique_username(prefix: &str) -> String {
    let n = USERNAME_COUNTER.fetch_add(1, Ordering::Relaxed);
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.subsec_nanos())
        .unwrap_or(0);
    let mut name = format!("{prefix}{:04x}{:04x}", nanos & 0xffff, n & 0xffff);
    name.truncate(16);
    name
}

/// A live tunnel handed off to a background actor: send payloads in via
/// `sender`, read whatever comes back via `receiver`. Once both ends are
/// dropped (or `join.abort()` is called directly) the underlying Minecraft
/// connection is torn down.
pub struct Tunnel {
    pub sender: FrameSender,
    pub receiver: FrameReceiver,
    pub join: JoinHandle<()>,
}

pub struct FrameSender(mpsc::Sender<Bytes>);

impl FrameSender {
    pub async fn send(&self, payload: Bytes) -> Result<()> {
        self.0
            .send(payload)
            .await
            .map_err(|_| anyhow::anyhow!("tunnel closed"))
    }
}

pub struct FrameReceiver(mpsc::Receiver<Bytes>);

impl FrameReceiver {
    pub async fn recv(&mut self) -> Option<Bytes> {
        self.0.recv().await
    }
}

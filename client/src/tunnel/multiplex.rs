//! The multiplexer: turns one persistent Minecraft connection
//! (`mc::session::Tunnel`) into many independent logical streams, each
//! looking to its caller like a simple bidirectional byte pipe.
//!
//! `Multiplexer::spawn` first runs the authenticated key-exchange
//! handshake (see `crypto::cipher`), then starts a background task that
//! owns the connection, the derived session keys, and all stream
//! bookkeeping; callers only ever touch `StreamSender`/`StreamReceiver`
//! handles. This is the piece that replaces "one Minecraft login per
//! browser CONNECT" with "one login, many logical streams" -- a page load
//! that opens a dozen CONNECT tunnels now looks like one player standing
//! still, not a dozen players rapidly joining and leaving.

use std::collections::HashMap;
use std::sync::Arc;
use std::sync::atomic::{AtomicU32, Ordering};
use std::time::Duration;

use anyhow::{Result, anyhow, ensure};
use bytes::Bytes;
use rand::Rng;
use tokio::sync::{Semaphore, mpsc, oneshot};
use tokio::task::JoinHandle;

use crate::crypto::cipher::{self, ConnectionId, SessionCrypto};
use crate::mc::session::{FrameReceiver, FrameSender, Tunnel};

use super::frame::{CONTROL_STREAM, Frame, FrameType};
use super::stream::{StreamReceiver, StreamSender, StreamShared};

/// Wire-sized chunk cap: `mc::session::MAX_FRAME_LEN` (32000) minus the
/// frame header (10 bytes) and the AEAD envelope overhead (8-byte counter
/// + 16-byte tag), with headroom to spare.
pub const MAX_STREAM_CHUNK: usize = 31000;

/// Bytes of unacknowledged data a stream may have in flight before its
/// sender must wait for a `WindowUpdate`.
const INITIAL_WINDOW: u32 = 256 * 1024;

/// Bound on pending requests to open a new stream / frames queued for the
/// wire. Just backpressure on local task scheduling, not a protocol limit.
const QUEUE_CAPACITY: usize = 64;

/// How long to wait for the plugin's handshake reply before giving up.
/// A wrong key_id/secret means the plugin never replies at all (see
/// `crypto::cipher`), so this is also what turns "bad credential" from an
/// indefinite hang into a clear, timely error.
const HANDSHAKE_TIMEOUT: Duration = Duration::from_secs(10);

/// Session-key rotation target interval and jitter range -- see
/// `crypto::cipher`'s "Key rotation" docs for why this happens at all.
/// Picking a fresh random delay every time (instead of a fixed 10-minute
/// tick) means the interval between rotations isn't a constant that would
/// itself stand out in traffic timing analysis.
const ROTATION_INTERVAL: Duration = Duration::from_secs(600);
const ROTATION_JITTER: Duration = Duration::from_secs(90);

fn next_rotation_delay() -> Duration {
    let jitter_secs = rand::thread_rng().gen_range(0..=(2 * ROTATION_JITTER.as_secs()));
    (ROTATION_INTERVAL - ROTATION_JITTER) + Duration::from_secs(jitter_secs)
}

pub struct Multiplexer {
    open_tx: mpsc::Sender<OpenRequest>,
}

struct OpenRequest {
    target: String,
    reply: oneshot::Sender<Result<(StreamSender, StreamReceiver)>>,
}

struct StreamEntry {
    inbound_tx: mpsc::Sender<Bytes>,
    send_credit: Arc<Semaphore>,
}

impl Multiplexer {
    /// Takes ownership of an already-connected `Tunnel`, runs the
    /// authenticated ephemeral-key handshake over it, and starts the
    /// background actor once that succeeds.
    ///
    /// Fails if the plugin doesn't reply within `HANDSHAKE_TIMEOUT` or its
    /// reply doesn't authenticate -- both symptoms of a key_id/secret
    /// mismatch, since a plugin that doesn't recognize our handshake stays
    /// completely silent rather than sending back an error (see
    /// `crypto::cipher`'s module docs for why).
    pub async fn spawn(tunnel: Tunnel, key_id: cipher::KeyId, secret: Vec<u8>) -> Result<Self> {
        let Tunnel { sender, mut receiver, join } = tunnel;

        let crypto = perform_handshake(&sender, &mut receiver, &key_id, &secret).await?;

        let (open_tx, open_rx) = mpsc::channel(QUEUE_CAPACITY);
        tokio::spawn(run(sender, receiver, join, crypto, secret, open_rx));

        Ok(Self { open_tx })
    }

    /// Opens a new logical stream to `target` (`"host:port"`).
    ///
    /// This does not wait for the plugin to actually reach the target: if
    /// that fails, the plugin sends back a `Close` for this stream, and the
    /// returned `StreamReceiver::recv()` will simply return `None` shortly
    /// after -- indistinguishable from any other early close.
    pub async fn open_stream(&self, target: &str) -> Result<(StreamSender, StreamReceiver)> {
        let (reply_tx, reply_rx) = oneshot::channel();
        self.open_tx
            .send(OpenRequest { target: target.to_owned(), reply: reply_tx })
            .await
            .map_err(|_| anyhow!("tunnel actor is gone"))?;
        reply_rx.await.map_err(|_| anyhow!("tunnel actor is gone"))?
    }
}

/// Runs the client side of the handshake described in `crypto::cipher`'s
/// module docs: send `connection_id || key_id || epk_c || mac1`, wait for
/// `epk_s || mac2`, verify it, derive session keys from the X25519 shared
/// point.
async fn perform_handshake(
    sender: &FrameSender,
    receiver: &mut FrameReceiver,
    key_id: &cipher::KeyId,
    secret: &[u8],
) -> Result<SessionCrypto> {
    let connection_id: ConnectionId = cipher::random_connection_id();
    let keypair = cipher::EphemeralKeypair::generate();
    let epk_c = keypair.public;

    let mac1 = cipher::handshake_mac1(secret, &connection_id, key_id, &epk_c);
    let mut message1 = Vec::with_capacity(
        cipher::CONNECTION_ID_LEN + cipher::KEY_ID_LEN + cipher::PUBLIC_KEY_LEN + cipher::MAC_LEN,
    );
    message1.extend_from_slice(&connection_id);
    message1.extend_from_slice(key_id);
    message1.extend_from_slice(&epk_c);
    message1.extend_from_slice(&mac1);

    sender
        .send(Bytes::from(message1))
        .await
        .map_err(|_| anyhow!("tunnel closed before the handshake could start"))?;

    let reply = tokio::time::timeout(HANDSHAKE_TIMEOUT, receiver.recv())
        .await
        .map_err(|_| {
            anyhow!(
                "handshake timed out waiting for the plugin's reply -- most likely the key_id/secret \
                 doesn't match on both ends (a wrong credential means the plugin stays \
                 silent rather than erroring)"
            )
        })?
        .ok_or_else(|| anyhow!("tunnel closed during the handshake"))?;

    let expected_len = cipher::PUBLIC_KEY_LEN + cipher::MAC_LEN;
    ensure!(reply.len() == expected_len, "malformed handshake reply from the plugin");

    let epk_s: [u8; 32] = reply[..cipher::PUBLIC_KEY_LEN].try_into().expect("checked length");
    let mac2: [u8; 32] = reply[cipher::PUBLIC_KEY_LEN..].try_into().expect("checked length");

    let expected_mac2 = cipher::handshake_mac2(secret, &connection_id, key_id, &epk_c, &epk_s);
    ensure!(
        cipher::constant_time_eq(&mac2, &expected_mac2),
        "handshake authentication failed -- the credential does not match the plugin's"
    );

    let dh_output = keypair.diffie_hellman(&epk_s);
    Ok(SessionCrypto::derive(secret, &connection_id, &epk_c, &epk_s, &dh_output, true))
}

async fn run(
    sender: FrameSender,
    mut receiver: FrameReceiver,
    join: JoinHandle<()>,
    mut crypto: SessionCrypto,
    secret: Vec<u8>,
    mut open_rx: mpsc::Receiver<OpenRequest>,
) {
    let mut streams: HashMap<u32, StreamEntry> = HashMap::new();
    let (frame_tx, mut frame_rx) = mpsc::channel::<Frame>(QUEUE_CAPACITY);
    let next_stream_id = AtomicU32::new(1);

    // `None` = no rotation currently in flight; `Some(keypair)` = we sent a
    // rotation request and are holding onto our ephemeral secret while we
    // wait for the peer's reply.
    let mut pending_rotation: Option<cipher::EphemeralKeypair> = None;
    let rotation_timer = tokio::time::sleep(next_rotation_delay());
    tokio::pin!(rotation_timer);

    loop {
        tokio::select! {
            // Time to rotate session keys. Skipped if a rotation we
            // initiated is already awaiting a reply -- the timer still
            // gets rescheduled either way so a stuck rotation can't wedge
            // rotation forever.
            () = &mut rotation_timer => {
                if pending_rotation.is_none() {
                    let keypair = cipher::EphemeralKeypair::generate();
                    let request = Frame::key_update(&keypair.public);
                    let envelope = crypto.seal(&request.encode());
                    if sender.send(Bytes::from(envelope)).await.is_err() {
                        break;
                    }
                    pending_rotation = Some(keypair);
                }
                rotation_timer.as_mut().reset(tokio::time::Instant::now() + next_rotation_delay());
            }

            // A caller wants a new logical stream.
            req = open_rx.recv() => {
                let Some(req) = req else { break };
                let id = next_stream_id.fetch_add(1, Ordering::Relaxed);

                let send_credit = Arc::new(Semaphore::new(INITIAL_WINDOW as usize));
                let (inbound_tx, inbound_rx) = mpsc::channel(32);
                streams.insert(id, StreamEntry { inbound_tx, send_credit: Arc::clone(&send_credit) });

                let shared = Arc::new(StreamShared { id, send_credit, outbound: frame_tx.clone() });
                let handles = (StreamSender { shared }, StreamReceiver { inbound: inbound_rx });

                let envelope = crypto.seal(&Frame::open(id, &req.target).encode());
                if sender.send(Bytes::from(envelope)).await.is_err() {
                    let _ = req.reply.send(Err(anyhow!("tunnel closed")));
                    break;
                }
                let _ = req.reply.send(Ok(handles));
            }

            // A stream wants to send a frame (data, close, or a
            // window-update we generated while handling incoming data).
            frame = frame_rx.recv() => {
                let Some(frame) = frame else { continue };
                let is_close = frame.frame_type == FrameType::Close;
                let stream_id = frame.stream_id;

                let envelope = crypto.seal(&frame.encode());
                if sender.send(Bytes::from(envelope)).await.is_err() {
                    break;
                }
                if is_close {
                    streams.remove(&stream_id);
                }
            }

            // Something arrived from the Minecraft connection.
            envelope = receiver.recv() => {
                let Some(envelope) = envelope else { break };
                let Ok(plaintext) = crypto.open(&envelope) else {
                    // Not from an authenticated peer, or corrupted. Drop it
                    // silently and keep going: one bad message shouldn't
                    // tear down every other stream on this connection.
                    continue;
                };
                let Ok(incoming) = Frame::decode(&plaintext) else { continue };

                if incoming.frame_type == FrameType::KeyUpdate {
                    if !handle_key_update(incoming, &mut crypto, &mut pending_rotation, &sender, &secret).await {
                        break;
                    }
                    continue;
                }

                handle_incoming(incoming, &mut streams, &frame_tx).await;
            }
        }
    }

    join.abort();
}

/// Handles an incoming `KeyUpdate` frame, either as the reply to a
/// rotation we initiated or as a request from the peer to reply to -- see
/// `crypto::cipher`'s "Key rotation" docs for the full protocol. Returns
/// `false` if the underlying connection died while sending a reply.
async fn handle_key_update(
    incoming: Frame,
    crypto: &mut SessionCrypto,
    pending_rotation: &mut Option<cipher::EphemeralKeypair>,
    sender: &FrameSender,
    secret: &[u8],
) -> bool {
    let Ok(their_epk): Result<[u8; 32], _> = incoming.payload.as_ref().try_into() else {
        return true; // malformed; ignore and keep the connection alive
    };

    match pending_rotation.take() {
        Some(my_keypair) => {
            // We initiated; this is their reply. We're "a", they're "b".
            let my_epk = my_keypair.public;
            let dh_output = my_keypair.diffie_hellman(&their_epk);
            crypto.complete_rotation(secret, &my_epk, &their_epk, &dh_output);
            true
        }
        None => {
            // They initiated; we reply. They're "a", we're "b".
            let my_keypair = cipher::EphemeralKeypair::generate();
            let my_epk = my_keypair.public;
            let dh_output = my_keypair.diffie_hellman(&their_epk);
            let reply = Frame::key_update(&my_epk).encode();
            let sealed_reply = crypto.reply_to_rotation(secret, &their_epk, &my_epk, &dh_output, &reply);
            sender.send(Bytes::from(sealed_reply)).await.is_ok()
        }
    }
}

async fn handle_incoming(
    frame: Frame,
    streams: &mut HashMap<u32, StreamEntry>,
    frame_tx: &mpsc::Sender<Frame>,
) {
    match frame.frame_type {
        FrameType::Data => {
            // Clone the sender out (cheap: mpsc::Sender is just a shared
            // handle) rather than holding a borrow of `streams` across the
            // `.await` below.
            let Some(inbound_tx) = streams.get(&frame.stream_id).map(|e| e.inbound_tx.clone()) else {
                return;
            };
            let len = frame.payload.len() as u32;
            if inbound_tx.send(frame.payload).await.is_ok() {
                // Credit back what we just buffered so the peer's sender
                // keeps going -- see the WindowUpdate frame docs.
                let _ = frame_tx.send(Frame::window_update(frame.stream_id, len)).await;
            } else {
                streams.remove(&frame.stream_id);
            }
        }
        FrameType::WindowUpdate => {
            if frame.payload.len() == 4 {
                let bytes: [u8; 4] = frame.payload[..4].try_into().expect("checked length");
                let credit = u32::from_be_bytes(bytes);
                if let Some(entry) = streams.get(&frame.stream_id) {
                    entry.send_credit.add_permits(credit as usize);
                }
            }
        }
        FrameType::Close => {
            streams.remove(&frame.stream_id);
        }
        FrameType::Ping => {
            let pong = Frame { stream_id: CONTROL_STREAM, frame_type: FrameType::Pong, payload: frame.payload };
            let _ = frame_tx.send(pong).await;
        }
        FrameType::Pong | FrameType::Open => {
            // We never receive Open (only the client opens streams in this
            // design) and a Pong needs no action beyond having arrived.
        }
        FrameType::KeyUpdate => {
            // Unreachable in practice: `run()` intercepts and handles
            // KeyUpdate frames via `handle_key_update` before ever calling
            // this function. Matched here only so this stays exhaustive.
        }
    }
}

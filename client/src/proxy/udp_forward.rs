//! Static UDP port forwarding through the tunnel: every datagram arriving
//! on a local UDP socket is sent to one fixed `target` via a plugin-side
//! UDP association, and replies come back to whichever local peer sent it.
//!
//! This is what lets a packet tunnel ride on mcvpn: point a WireGuard
//! peer's `Endpoint` at `listen`, and its UDP datagrams travel inside the
//! Minecraft TCP connection to `target` -- so the WireGuard interface
//! carries any IP traffic (TCP, UDP, ICMP), not just proxied TCP streams.

use std::collections::HashMap;
use std::net::SocketAddr;
use std::sync::Arc;

use anyhow::{Context, Result, anyhow};
use tokio::net::UdpSocket;
use tokio::sync::mpsc;

use crate::tunnel::multiplex::Multiplexer;
use crate::tunnel::udp::UdpSender;

/// Largest datagram accepted locally; must fit one tunnel frame
/// (`multiplex::MAX_STREAM_CHUNK`) together with its address prefix.
const MAX_DATAGRAM: usize = 30000;

/// Splits `"host:port"` / `"[v6]:port"` into its parts.
pub fn split_target(target: &str) -> Result<(String, u16)> {
    let (host, port) = target
        .rsplit_once(':')
        .ok_or_else(|| anyhow!("udp_forward target {target:?} must be host:port"))?;
    let host = host.trim_start_matches('[').trim_end_matches(']');
    let port = port.parse().with_context(|| format!("invalid port in udp_forward target {target:?}"))?;
    Ok((host.to_owned(), port))
}

pub async fn serve(listen: &str, target: &str, multiplexer: Arc<Multiplexer>) -> Result<()> {
    let (host, port) = split_target(target)?;
    let socket = Arc::new(
        UdpSocket::bind(listen).await.with_context(|| format!("failed to bind UDP forward on {listen}"))?,
    );
    println!("[udp-forward] {listen} -> {host}:{port}");

    // One association per local peer, so replies go back to the right one.
    let mut peers: HashMap<SocketAddr, UdpSender> = HashMap::new();
    let (ended_tx, mut ended_rx) = mpsc::unbounded_channel::<SocketAddr>();
    let mut buf = vec![0u8; MAX_DATAGRAM];

    loop {
        tokio::select! {
            ended = ended_rx.recv() => {
                // The association's connection was lost; the next datagram
                // from this peer opens a fresh one after the reconnect.
                if let Some(peer) = ended {
                    peers.remove(&peer);
                }
            }
            received = socket.recv_from(&mut buf) => {
                let (n, from) = received.context("UDP forward socket failed")?;
                if !peers.contains_key(&from) {
                    let (sender, mut receiver) = match multiplexer.open_udp().await {
                        Ok(handles) => handles,
                        Err(e) => {
                            // Dropping the datagram is fine: the sender (e.g.
                            // WireGuard) retransmits on its own schedule.
                            eprintln!("[udp-forward] cannot open association: {e:#}");
                            continue;
                        }
                    };
                    let reply_socket = Arc::clone(&socket);
                    let ended_tx = ended_tx.clone();
                    tokio::spawn(async move {
                        while let Some((_, _, data)) = receiver.recv().await {
                            if reply_socket.send_to(&data, from).await.is_err() {
                                break;
                            }
                        }
                        let _ = ended_tx.send(from);
                    });
                    peers.insert(from, sender);
                }
                let sender = peers.get(&from).expect("inserted above");
                if sender.send(&host, port, &buf[..n]).await.is_err() {
                    peers.remove(&from);
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::split_target;

    #[test]
    fn splits_ipv4_and_bracketed_ipv6_targets() {
        assert_eq!(split_target("203.0.113.5:53000").unwrap(), ("203.0.113.5".to_owned(), 53000));
        assert_eq!(split_target("[2001:db8::1]:53000").unwrap(), ("2001:db8::1".to_owned(), 53000));
        assert!(split_target("no-port").is_err());
    }
}

//! A UDP association, multiplexed alongside streams over the same
//! Minecraft connection. Obtained from `Multiplexer::open_udp`. Mirrors the
//! plugin's `UdpAssociationState`: no fixed target, every datagram names
//! its own destination, and replies come back tagged with their source.

use anyhow::{Result, anyhow};
use bytes::Bytes;
use tokio::sync::mpsc;

use super::frame::Frame;

/// One datagram received on an association: `(source host, source port, data)`.
pub type Datagram = (String, u16, Bytes);

pub struct UdpSender {
    pub(super) id: u32,
    pub(super) outbound: mpsc::Sender<Frame>,
}

impl UdpSender {
    /// Sends one datagram to `host:port` through the plugin. Datagrams are
    /// never chunked and have no flow control -- like UDP itself, the
    /// caller gets no delivery guarantee.
    pub async fn send(&self, host: &str, port: u16, data: &[u8]) -> Result<()> {
        let frame = Frame::datagram(self.id, host, port, data)?;
        self.outbound.send(frame).await.map_err(|_| anyhow!("tunnel closed"))
    }
}

pub struct UdpReceiver {
    pub(super) inbound: mpsc::Receiver<Datagram>,
}

impl UdpReceiver {
    /// Returns `None` once the association is closed or its connection lost.
    pub async fn recv(&mut self) -> Option<Datagram> {
        self.inbound.recv().await
    }
}

//! A single logical stream, multiplexed alongside others over one shared
//! Minecraft connection. Obtained in pieces from `Multiplexer::open_stream`.

use std::sync::Arc;

use anyhow::{Result, anyhow};
use bytes::Bytes;
use tokio::sync::{Semaphore, mpsc};

use super::frame::Frame;
use super::multiplex::MAX_STREAM_CHUNK;

pub(super) struct StreamShared {
    pub(super) id: u32,
    pub(super) send_credit: Arc<Semaphore>,
    pub(super) outbound: mpsc::Sender<Frame>,
}

/// The send half of a stream. Cheap to hold onto; internally just an
/// `Arc`-shared handle back to the multiplexer actor.
pub struct StreamSender {
    pub(super) shared: Arc<StreamShared>,
}

impl StreamSender {
    pub fn id(&self) -> u32 {
        self.shared.id
    }

    /// Sends `data`, splitting it into wire-sized chunks and waiting for
    /// flow-control credit as needed. Waiting here only ever blocks the
    /// caller of *this* stream -- it never blocks any other stream sharing
    /// the underlying connection, since credit is tracked per stream.
    pub async fn send(&self, data: Bytes) -> Result<()> {
        for chunk in data.chunks(MAX_STREAM_CHUNK) {
            let chunk = Bytes::copy_from_slice(chunk);

            let permit = Arc::clone(&self.shared.send_credit)
                .acquire_many_owned(chunk.len() as u32)
                .await
                .map_err(|_| anyhow!("tunnel closed"))?;
            // Credit is spent until a WindowUpdate from the peer replenishes
            // it -- don't let the permit auto-return on drop.
            permit.forget();

            self.shared
                .outbound
                .send(Frame::data(self.shared.id, chunk))
                .await
                .map_err(|_| anyhow!("tunnel closed"))?;
        }
        Ok(())
    }

    /// Tells the peer this stream is done, so it can release whatever
    /// local resource (target socket) it was holding for it.
    pub async fn close(&self) {
        let _ = self.shared.outbound.send(Frame::close(self.shared.id)).await;
    }
}

/// The receive half of a stream.
pub struct StreamReceiver {
    pub(super) inbound: mpsc::Receiver<Bytes>,
}

impl StreamReceiver {
    /// Returns `None` once the stream is closed, from either end.
    pub async fn recv(&mut self) -> Option<Bytes> {
        self.inbound.recv().await
    }
}

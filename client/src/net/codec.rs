//! `tokio_util` codec adapter around `valence_protocol`'s packet framing.
//!
//! This type only understands the Minecraft *wire format*: a VarInt length
//! prefix, an optional zlib compression envelope, and (later) an optional
//! stream cipher. It has no notion of connection state (Handshaking / Login /
//! Play) or of any specific packet type — those belong to the `mc` layer.

use anyhow::Error;
use bytes::{Buf, BytesMut};
use tokio_util::codec::{Decoder, Encoder};
use valence_protocol::{CompressionThreshold, Encode, Packet, PacketDecoder, PacketEncoder};

pub use valence_protocol::decode::PacketFrame;

#[derive(Default)]
pub struct MinecraftCodec {
    encoder: PacketEncoder,
    decoder: PacketDecoder,
}

impl MinecraftCodec {
    pub fn new() -> Self {
        Self::default()
    }

    /// Applies the compression threshold announced by the server (via
    /// `SetCompression` in Login, or the Play-state equivalent). `None`
    /// disables compression.
    pub fn set_compression(&mut self, threshold: CompressionThreshold) {
        self.encoder.set_compression(threshold);
        self.decoder.set_compression(threshold);
    }
}

impl Decoder for MinecraftCodec {
    type Item = PacketFrame;
    type Error = Error;

    fn decode(&mut self, src: &mut BytesMut) -> Result<Option<Self::Item>, Self::Error> {
        // Hand everything newly read over to the decoder's own buffer; it
        // already knows how to hold onto a partial frame across calls.
        if src.has_remaining() {
            self.decoder.queue_bytes(src.split());
        }
        self.decoder.try_next_packet()
    }
}

impl<'a, P> Encoder<&'a P> for MinecraftCodec
where
    P: Packet + Encode,
{
    type Error = Error;

    fn encode(&mut self, item: &'a P, dst: &mut BytesMut) -> Result<(), Self::Error> {
        self.encoder.append_packet(item)?;
        dst.unsplit(self.encoder.take());
        Ok(())
    }
}

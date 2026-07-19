//! The multiplexed frame format carried inside each encrypted envelope
//! (see `crypto::cipher`). Lets many logical streams share one persistent
//! Minecraft connection, the same way HTTP/2 multiplexes many requests
//! over one TCP connection.
//!
//! Wire format -- this is the *plaintext* that gets AEAD-sealed, never
//! sent as-is:
//!
//! ```text
//! stream_id:   u32 BE
//! frame_type:  u8
//! flags:       u8   (reserved, always 0 for now)
//! payload_len: u32 BE
//! payload:     payload_len bytes
//! ```
//!
//! `stream_id` 0 is reserved for connection-level control frames (Ping /
//! Pong) that aren't associated with any one proxied connection.

use anyhow::{Result, bail};
use bytes::{Buf, BufMut, Bytes, BytesMut};

pub const HEADER_LEN: usize = 4 + 1 + 1 + 4;
pub const CONTROL_STREAM: u32 = 0;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FrameType {
    /// Opens a new logical stream. Payload: UTF-8 `"host:port"` of the
    /// target to connect to.
    Open,
    /// Payload bytes for an existing stream, in either direction.
    Data,
    /// Either side is done with this stream. Payload is an optional short
    /// UTF-8 reason and may be empty.
    Close,
    /// Connection-level liveness probe. Payload is an opaque 8-byte token
    /// the peer must echo back verbatim in a `Pong`.
    Ping,
    /// Reply to a `Ping`, echoing its payload.
    Pong,
    /// Grants the peer `payload` (4-byte BE `u32`) more bytes of send
    /// credit for `stream_id`. Part of per-stream flow control: a slow
    /// consumer on one stream only throttles that stream's sender, never
    /// the others sharing this connection.
    WindowUpdate,
    /// Connection-level (`CONTROL_STREAM`) session-key rotation. Payload:
    /// a fresh 32-byte X25519 ephemeral public key. Whichever side has no
    /// rotation already in flight when it receives one of these treats it
    /// as a request and replies in kind with its own; whichever side sent
    /// the first one treats the reply as completing the exchange. Both
    /// sides then derive fresh session keys from the DH output -- see
    /// `crypto::cipher` for the full key-rollover protocol.
    KeyUpdate,
}

impl FrameType {
    fn to_byte(self) -> u8 {
        match self {
            FrameType::Open => 1,
            FrameType::Data => 2,
            FrameType::Close => 3,
            FrameType::Ping => 4,
            FrameType::Pong => 5,
            FrameType::WindowUpdate => 6,
            FrameType::KeyUpdate => 7,
        }
    }

    fn from_byte(b: u8) -> Result<Self> {
        Ok(match b {
            1 => FrameType::Open,
            2 => FrameType::Data,
            3 => FrameType::Close,
            4 => FrameType::Ping,
            5 => FrameType::Pong,
            6 => FrameType::WindowUpdate,
            7 => FrameType::KeyUpdate,
            other => bail!("unknown frame type {other}"),
        })
    }
}

#[derive(Debug, Clone)]
pub struct Frame {
    pub stream_id: u32,
    pub frame_type: FrameType,
    pub payload: Bytes,
}

impl Frame {
    pub fn encode(&self) -> Vec<u8> {
        let mut buf = BytesMut::with_capacity(HEADER_LEN + self.payload.len());
        buf.put_u32(self.stream_id);
        buf.put_u8(self.frame_type.to_byte());
        buf.put_u8(0); // flags, reserved
        buf.put_u32(self.payload.len() as u32);
        buf.extend_from_slice(&self.payload);
        buf.to_vec()
    }

    pub fn decode(mut buf: &[u8]) -> Result<Self> {
        if buf.len() < HEADER_LEN {
            bail!("frame shorter than its header");
        }
        let stream_id = buf.get_u32();
        let frame_type = FrameType::from_byte(buf.get_u8())?;
        let _flags = buf.get_u8();
        let payload_len = buf.get_u32() as usize;
        if buf.len() != payload_len {
            bail!(
                "frame payload length mismatch: header says {payload_len}, got {}",
                buf.len()
            );
        }
        Ok(Frame {
            stream_id,
            frame_type,
            payload: Bytes::copy_from_slice(buf),
        })
    }

    pub fn open(stream_id: u32, target: &str) -> Self {
        Frame {
            stream_id,
            frame_type: FrameType::Open,
            payload: Bytes::copy_from_slice(target.as_bytes()),
        }
    }

    pub fn data(stream_id: u32, payload: Bytes) -> Self {
        Frame { stream_id, frame_type: FrameType::Data, payload }
    }

    pub fn close(stream_id: u32) -> Self {
        Frame { stream_id, frame_type: FrameType::Close, payload: Bytes::new() }
    }

    pub fn window_update(stream_id: u32, additional_bytes: u32) -> Self {
        Frame {
            stream_id,
            frame_type: FrameType::WindowUpdate,
            payload: Bytes::copy_from_slice(&additional_bytes.to_be_bytes()),
        }
    }

    pub fn key_update(ephemeral_public_key: &[u8; 32]) -> Self {
        Frame {
            stream_id: CONTROL_STREAM,
            frame_type: FrameType::KeyUpdate,
            payload: Bytes::copy_from_slice(ephemeral_public_key),
        }
    }
}

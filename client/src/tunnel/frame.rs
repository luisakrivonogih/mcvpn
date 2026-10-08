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
    /// Opens a UDP association. Empty payload: unlike a stream there is no
    /// fixed target, every `Datagram` names its own (SOCKS5 UDP ASSOCIATE
    /// semantics). Matches the plugin's `Frame.Type.OPEN_UDP`.
    OpenUdp,
    /// One whole UDP datagram on an association, never chunked. Payload:
    /// `host_len: u8 || host_utf8 || port: u16 BE || data` -- byte-for-byte
    /// the plugin's `Frame.datagram`. Toward the plugin it names the
    /// destination; from the plugin, the address the reply came from.
    Datagram,
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
            FrameType::OpenUdp => 8,
            FrameType::Datagram => 9,
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
            8 => FrameType::OpenUdp,
            9 => FrameType::Datagram,
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

    pub fn open_udp(stream_id: u32) -> Self {
        Frame { stream_id, frame_type: FrameType::OpenUdp, payload: Bytes::new() }
    }

    pub fn datagram(stream_id: u32, host: &str, port: u16, data: &[u8]) -> Result<Self> {
        let host = host.as_bytes();
        if host.len() > u8::MAX as usize {
            bail!("datagram host is longer than 255 bytes");
        }
        let mut buf = BytesMut::with_capacity(1 + host.len() + 2 + data.len());
        buf.put_u8(host.len() as u8);
        buf.extend_from_slice(host);
        buf.put_u16(port);
        buf.extend_from_slice(data);
        Ok(Frame { stream_id, frame_type: FrameType::Datagram, payload: buf.freeze() })
    }

    /// Splits a `Datagram` payload into `(host, port, data)`.
    pub fn decode_datagram(&self) -> Result<(String, u16, Bytes)> {
        let payload = &self.payload;
        let Some(&host_len) = payload.first() else { bail!("empty datagram payload") };
        let host_end = 1 + host_len as usize;
        if payload.len() < host_end + 2 {
            bail!("datagram payload shorter than its address");
        }
        let host = std::str::from_utf8(&payload[1..host_end])?.to_owned();
        let port = u16::from_be_bytes([payload[host_end], payload[host_end + 1]]);
        Ok((host, port, payload.slice(host_end + 2..)))
    }

    pub fn key_update(ephemeral_public_key: &[u8; 32]) -> Self {
        Frame {
            stream_id: CONTROL_STREAM,
            frame_type: FrameType::KeyUpdate,
            payload: Bytes::copy_from_slice(ephemeral_public_key),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn datagram_round_trips_in_the_plugin_wire_format() {
        let frame = Frame::datagram(7, "203.0.113.5", 53000, b"wg").unwrap();
        // host_len || host || port BE || data
        let mut expected = vec![11u8];
        expected.extend_from_slice(b"203.0.113.5");
        expected.extend_from_slice(&53000u16.to_be_bytes());
        expected.extend_from_slice(b"wg");
        assert_eq!(frame.payload.as_ref(), expected.as_slice());

        let decoded = Frame::decode(&frame.encode()).unwrap();
        assert_eq!(decoded.frame_type, FrameType::Datagram);
        let (host, port, data) = decoded.decode_datagram().unwrap();
        assert_eq!((host.as_str(), port, data.as_ref()), ("203.0.113.5", 53000, b"wg".as_ref()));
    }

    #[test]
    fn udp_frame_type_bytes_match_the_plugin() {
        assert_eq!(Frame::open_udp(1).encode()[4], 8);
        assert_eq!(Frame::datagram(1, "h", 1, b"").unwrap().encode()[4], 9);
    }

    #[test]
    fn malformed_datagram_is_rejected() {
        let frame = Frame { stream_id: 1, frame_type: FrameType::Datagram, payload: Bytes::from_static(&[5, b'a']) };
        assert!(frame.decode_datagram().is_err());
    }
}

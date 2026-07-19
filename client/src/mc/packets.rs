//! The single manifest of `valence_protocol` packet types this project uses.
//!
//! `handshake.rs`, `login.rs`, and `play.rs` import packet types from here
//! rather than reaching into `valence_protocol::packets::...` directly, so a
//! future protocol version bump only requires editing this file.

pub use valence_protocol::packets::handshaking::HandshakeC2s;
pub use valence_protocol::packets::handshaking::handshake_c2s::HandshakeNextState;
pub use valence_protocol::packets::login::{
    LoginCompressionS2c, LoginDisconnectS2c, LoginHelloC2s, LoginHelloS2c, LoginQueryRequestS2c,
    LoginQueryResponseC2s, LoginSuccessS2c,
};
pub use valence_protocol::packets::play::{
    CustomPayloadC2s, CustomPayloadS2c, DisconnectS2c, GameJoinS2c, KeepAliveC2s, KeepAliveS2c,
};
pub use valence_protocol::{Ident, Packet, PROTOCOL_VERSION, RawBytes};

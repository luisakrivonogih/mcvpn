use anyhow::Result;
use futures::SinkExt;
use valence_protocol::VarInt;

use crate::mc::packets::{HandshakeC2s, HandshakeNextState, PROTOCOL_VERSION};
use crate::net::framed::McFramed;

/// Sends the initial Handshake packet and declares our intent to log in.
///
/// This is always the first packet on a fresh connection; there is no
/// response to wait for; the server simply starts expecting Login-state
/// packets afterwards.
pub async fn send(framed: &mut McFramed, server_address: &str, server_port: u16) -> Result<()> {
    let packet = HandshakeC2s {
        protocol_version: VarInt(PROTOCOL_VERSION),
        server_address,
        server_port,
        next_state: HandshakeNextState::Login,
    };

    framed.send(&packet).await
}

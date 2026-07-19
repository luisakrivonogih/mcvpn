use anyhow::{Result, anyhow, bail};
use futures::{SinkExt, StreamExt};
use valence_protocol::uuid::Uuid;

use crate::mc::packets::{
    LoginCompressionS2c, LoginDisconnectS2c, LoginHelloC2s, LoginHelloS2c, LoginQueryRequestS2c,
    LoginQueryResponseC2s, LoginSuccessS2c, Packet,
};
use crate::net::framed::McFramed;

/// The identity the server assigned us once login succeeds.
pub struct LoginOutcome {
    pub uuid: Uuid,
    pub username: String,
}

/// Drives the Login state to completion: sends `LoginStart`, answers
/// whatever the server asks in between, and returns once `LoginSuccess`
/// arrives.
///
/// Only offline-mode servers are supported: an `EncryptionRequest`
/// (`LoginHelloS2c`) means the server is running in online mode, which
/// requires a Mojang session-server round trip we haven't implemented, so we
/// fail loudly instead of hanging.
pub async fn perform(framed: &mut McFramed, username: &str) -> Result<LoginOutcome> {
    framed
        .send(&LoginHelloC2s {
            username,
            profile_id: None,
        })
        .await?;

    loop {
        let frame = framed
            .next()
            .await
            .ok_or_else(|| anyhow!("connection closed during login"))??;

        match frame.id {
            LoginDisconnectS2c::ID => {
                let pkt: LoginDisconnectS2c = frame.decode()?;
                bail!("server rejected login: {}", pkt.reason);
            }
            LoginHelloS2c::ID => {
                bail!(
                    "server requested encryption (online-mode) but only offline-mode is \
                     supported in this transport"
                );
            }
            LoginCompressionS2c::ID => {
                let pkt: LoginCompressionS2c = frame.decode()?;
                let threshold = (pkt.threshold.0 >= 0).then_some(pkt.threshold.0 as u32);
                framed.codec_mut().set_compression(threshold);
            }
            LoginQueryRequestS2c::ID => {
                let pkt: LoginQueryRequestS2c = frame.decode()?;
                // We don't implement any login plugin channels; `data: None`
                // tells the server "not understood", which is the correct,
                // expected response from a vanilla client that doesn't
                // recognize the channel.
                framed
                    .send(&LoginQueryResponseC2s {
                        message_id: pkt.message_id,
                        data: None,
                    })
                    .await?;
            }
            LoginSuccessS2c::ID => {
                let pkt: LoginSuccessS2c = frame.decode()?;
                return Ok(LoginOutcome {
                    uuid: pkt.uuid,
                    username: pkt.username.to_owned(),
                });
            }
            other => bail!("unexpected packet ID {other} during login"),
        }
    }
}

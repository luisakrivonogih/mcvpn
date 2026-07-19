use anyhow::{Result, anyhow, bail};
use futures::{SinkExt, StreamExt};

use crate::mc::packets::{CustomPayloadC2s, DisconnectS2c, GameJoinS2c, Ident, Packet, RawBytes};
use crate::net::framed::McFramed;

/// The handful of `GameJoin` fields we actually need for Phase 1.
pub struct PlayInfo {
    pub entity_id: i32,
}

/// Waits for the server's first Play-state packet, which per protocol 763 is
/// always `GameJoin` (`GameJoinS2c`), confirming we're fully in the Play
/// state.
pub async fn await_join(framed: &mut McFramed) -> Result<PlayInfo> {
    let frame = framed
        .next()
        .await
        .ok_or_else(|| anyhow!("connection closed before entering play"))??;

    match frame.id {
        GameJoinS2c::ID => {
            let pkt: GameJoinS2c = frame.decode()?;
            Ok(PlayInfo {
                entity_id: pkt.entity_id,
            })
        }
        DisconnectS2c::ID => {
            let pkt: DisconnectS2c = frame.decode()?;
            bail!("server disconnected us on entering play: {}", pkt.reason);
        }
        other => bail!("expected GameJoin as the first play packet, got ID {other}"),
    }
}

/// Announces a plugin channel via the vanilla `minecraft:register` custom
/// payload, the way a real modded client advertises the channels it
/// understands. Not required for delivery (Bukkit dispatches incoming plugin
/// messages to registered listeners regardless of whether the client
/// announced them), but sending it matches real client behavior.
pub async fn register_channel(framed: &mut McFramed, channel: &str) -> Result<()> {
    let register = Ident::new("minecraft:register")?;
    framed
        .send(&CustomPayloadC2s {
            channel: register,
            data: RawBytes(channel.as_bytes()),
        })
        .await
}

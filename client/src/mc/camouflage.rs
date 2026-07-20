//! Client-initiated Play-state traffic a real Minecraft client produces
//! just by sitting connected in the world: `ClientSettings` once on join,
//! then a steady trickle of looking around, occasional arm swings, and
//! sneak toggles for as long as the connection lasts.
//!
//! Without this, the connection's *entire* outbound Play-state traffic is
//! Handshake, Login, one plugin-channel registration, and `KeepAlive`
//! replies -- and since this transport runs over an offline-mode session
//! (see `mc/login.rs`), none of that is wrapped in Minecraft's own
//! encryption, so it's all inspectable as real protocol traffic. A client
//! that never once looks around or swings its arm for the lifetime of a
//! connection is itself a distinguishing pattern; this module exists to
//! remove that gap cheaply.
//!
//! Deliberately does not simulate walking: this client has no chunk/terrain
//! data, so it has no way to know what ground (if any) is under a reported
//! position, and vanilla's server-side movement sanity checks (speed/
//! distance) exist specifically to catch clients whose position reports
//! don't add up. Looking around and swinging an arm cost nothing to fake
//! convincingly because neither carries position information for the
//! server to validate -- they're free realism, not a gamble.

use std::time::Duration;

use rand::Rng;

use crate::mc::packets::{
    ChatMode, ClientCommand, ClientCommandC2s, ClientSettingsC2s, DisplayedSkinParts, Hand,
    HandSwingC2s, LookAndOnGroundC2s, MainArm, VarInt,
};

/// Idle-tick interval range. Not an attempt to match a real client's ~20/s
/// input-polling rate -- that would mean reproducing full clientside input
/// simulation for no benefit, since nothing here carries state a server (or
/// an observer) could cross-check against a specific tick count. What
/// matters for blending in is producing *some* ordinary-looking Play
/// traffic on an ordinary human cadence, which this is.
const IDLE_MIN: Duration = Duration::from_secs(2);
const IDLE_MAX: Duration = Duration::from_secs(6);

/// The `ClientSettings` a real client sends once, right after entering
/// Play and before anything else -- its total absence is itself a
/// fingerprint, so this is sent unconditionally regardless of whether the
/// rest of the idle simulation below is ever exercised.
pub fn client_settings() -> ClientSettingsC2s<'static> {
    ClientSettingsC2s {
        locale: "en_us",
        view_distance: 10,
        chat_mode: ChatMode::Enabled,
        chat_colors: true,
        displayed_skin_parts: DisplayedSkinParts::new()
            .with_cape(true)
            .with_jacket(true)
            .with_left_sleeve(true)
            .with_right_sleeve(true)
            .with_left_pants_leg(true)
            .with_right_pants_leg(true)
            .with_hat(true),
        main_arm: MainArm::Right,
        enable_text_filtering: false,
        allow_server_listings: true,
    }
}

pub enum Action {
    Look(LookAndOnGroundC2s),
    Swing(HandSwingC2s),
    Sneak(ClientCommandC2s),
}

/// Tracks just enough local state (current facing, current sneak toggle,
/// our entity id) to keep successive idle actions self-consistent --
/// e.g. never emitting `StartSneaking` twice in a row.
pub struct IdleSimulator {
    entity_id: i32,
    yaw: f32,
    pitch: f32,
    sneaking: bool,
}

impl IdleSimulator {
    pub fn new(entity_id: i32, yaw: f32, pitch: f32) -> Self {
        Self { entity_id, yaw, pitch, sneaking: false }
    }

    /// Resyncs to an orientation the server just told us authoritatively
    /// (the spawn teleport, or any later one) so the next look-wobble
    /// starts from where the server actually thinks we're facing instead
    /// of drifting from a stale local guess.
    pub fn resync(&mut self, yaw: f32, pitch: f32) {
        self.yaw = yaw;
        self.pitch = pitch;
    }

    pub fn next_delay(&self) -> Duration {
        let range_ms = (IDLE_MAX - IDLE_MIN).as_millis() as u64;
        IDLE_MIN + Duration::from_millis(rand::thread_rng().gen_range(0..=range_ms))
    }

    /// Picks the next bit of idle Play-state traffic. Weighted heavily
    /// toward looking around, since that's what an idle real player
    /// produces most; arm swings and sneak toggles are rarer punctuation
    /// on top of that baseline.
    pub fn next_action(&mut self) -> Action {
        let mut rng = rand::thread_rng();
        match rng.gen_range(0..10) {
            0..=6 => {
                self.yaw = wrap_yaw(self.yaw + rng.gen_range(-25.0..25.0));
                self.pitch = (self.pitch + rng.gen_range(-15.0..15.0)).clamp(-89.0, 89.0);
                Action::Look(LookAndOnGroundC2s { yaw: self.yaw, pitch: self.pitch, on_ground: true })
            }
            7..=8 => Action::Swing(HandSwingC2s { hand: Hand::Main }),
            _ => {
                self.sneaking = !self.sneaking;
                let action = if self.sneaking {
                    ClientCommand::StartSneaking
                } else {
                    ClientCommand::StopSneaking
                };
                Action::Sneak(ClientCommandC2s {
                    entity_id: VarInt(self.entity_id),
                    action,
                    jump_boost: VarInt(0),
                })
            }
        }
    }
}

fn wrap_yaw(deg: f32) -> f32 {
    let mut d = deg % 360.0;
    if d > 180.0 {
        d -= 360.0;
    } else if d < -180.0 {
        d += 360.0;
    }
    d
}

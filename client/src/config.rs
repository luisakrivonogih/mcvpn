use std::fs;

use serde::Deserialize;

/// Runtime configuration, loaded from a TOML config file (with sensible
/// local-testing defaults for everything except credentials). The client is
/// a long-running proxy process, so a config file fits better than
/// positional CLI args or a pile of env vars: it's the path to the file
/// (given as the first CLI argument, defaulting to `./config.toml`) that's
/// passed on the command line, not the settings themselves.
#[derive(Clone)]
pub struct ClientConfig {
    /// The Minecraft (Paper) server this transport tunnels through.
    pub server_host: String,
    pub server_port: u16,
    /// Prefix for the per-connection offline-mode username. Each new tunnel
    /// gets a unique generated suffix appended (see `session::connect`) so
    /// concurrent CONNECTs don't collide on a duplicate login.
    pub username_prefix: String,
    /// Local address the HTTP CONNECT proxy listens on.
    pub proxy_listen: String,
    /// Local address the SOCKS5 proxy listens on -- the front door for
    /// traffic that doesn't speak HTTP CONNECT at all (see `proxy::socks5`).
    pub socks_listen: String,
    /// Identifies which per-user credential this client presents on every
    /// new tunnel's handshake. The plugin looks this up in its DB-backed
    /// user store to find the matching `key_secret`. Must match a `key_id`
    /// issued by the admin panel.
    pub key_id: [u8; 16],
    /// The per-user secret paired with `key_id`, used to key the handshake
    /// MACs. Without this, anyone who can reach the Minecraft port could
    /// use it as an anonymous open TCP relay. Must match the secret the
    /// admin panel issued alongside `key_id`.
    pub key_secret: Vec<u8>,
}

/// Raw TOML shape. Non-credential fields fall back to the same local-testing
/// defaults the old env-var loader used; credentials never do (see below).
#[derive(Deserialize)]
struct RawConfig {
    #[serde(default = "default_server_host")]
    server_host: String,
    #[serde(default = "default_server_port")]
    server_port: u16,
    #[serde(default = "default_username_prefix")]
    username_prefix: String,
    #[serde(default = "default_proxy_listen")]
    proxy_listen: String,
    #[serde(default = "default_socks_listen")]
    socks_listen: String,
    key_id: Option<String>,
    key_secret: Option<String>,
}

fn default_server_host() -> String {
    "127.0.0.1".to_owned()
}

fn default_server_port() -> u16 {
    25565
}

fn default_username_prefix() -> String {
    "mcvpn_".to_owned()
}

fn default_proxy_listen() -> String {
    "127.0.0.1:8080".to_owned()
}

fn default_socks_listen() -> String {
    "127.0.0.1:1080".to_owned()
}

impl ClientConfig {
    pub fn load() -> Self {
        let path = std::env::args()
            .nth(1)
            .unwrap_or_else(|| "config.toml".to_owned());

        let raw_toml = fs::read_to_string(&path)
            .unwrap_or_else(|e| panic!("failed to read config file {path:?}: {e}"));

        let raw: RawConfig = toml::from_str(&raw_toml)
            .unwrap_or_else(|e| panic!("failed to parse config file {path:?} as TOML: {e}"));

        Self {
            server_host: raw.server_host,
            server_port: raw.server_port,
            username_prefix: raw.username_prefix,
            proxy_listen: raw.proxy_listen,
            socks_listen: raw.socks_listen,
            key_id: required_hex_field("key_id", raw.key_id, 16)
                .try_into()
                .expect("length checked above"),
            key_secret: required_hex_field("key_secret", raw.key_secret, 32),
        }
    }
}

/// Reads a required hex-encoded credential field, hex-decodes it, and
/// hard-fails with a clear message if it's missing, malformed, or the wrong
/// length. A missing or malformed credential must not silently fall back to
/// a default: that would just produce a client that hangs at the handshake
/// timeout with a confusing error instead of failing fast at startup.
fn required_hex_field(key: &str, value: Option<String>, expected_bytes: usize) -> Vec<u8> {
    let value = value.unwrap_or_else(|| {
        panic!(
            "{key} is required in the config file (expected {} bytes as {} hex chars)",
            expected_bytes,
            expected_bytes * 2
        )
    });
    let decoded = hex::decode(&value).unwrap_or_else(|e| {
        panic!(
            "{key} is not valid hex (expected {} hex chars): {e}",
            expected_bytes * 2
        )
    });
    if decoded.len() != expected_bytes {
        panic!(
            "{key} decoded to {} bytes, expected exactly {expected_bytes} (i.e. {} hex chars)",
            decoded.len(),
            expected_bytes * 2
        );
    }
    decoded
}

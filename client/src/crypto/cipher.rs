//! ChaCha20-Poly1305 AEAD tunnel encryption, keyed by a forward-secret
//! per-connection session key derived from an authenticated X25519
//! ephemeral Diffie-Hellman handshake -- not directly from the user's
//! secret. This means that even if a user's secret is later compromised,
//! packet captures of past sessions cannot be decrypted retroactively:
//! doing so would require the ephemeral private keys, which are generated
//! fresh per connection, never transmitted, and dropped the moment the
//! session keys are derived.
//!
//! Handshake -- two plaintext messages, before any AEAD traffic flows:
//!
//! ```text
//! Client -> Server: connection_id (16B) || key_id (16B) || epk_c (32B) || mac1 (32B)
//!   mac1 = HMAC-SHA256(secret, connection_id || key_id || epk_c)
//!
//! Server -> Client: epk_s (32B) || mac2 (32B)
//!   mac2 = HMAC-SHA256(secret, connection_id || key_id || epk_c || epk_s)
//! ```
//!
//! `key_id` identifies which per-user credential the client is presenting;
//! the plugin looks up the matching `secret` in its user store and uses it
//! to key both MACs, rather than every connection sharing one global
//! secret. Both MACs are keyed by that looked-up secret, so completing the
//! handshake at all requires knowing it. An active man-in-the-middle who
//! doesn't know the secret can't forge either MAC, so they can't
//! substitute their own ephemeral key on either leg and establish a
//! working session with either side -- the best they can do is relay
//! message 1 unmodified (any tampering invalidates its MAC) and then have
//! nothing valid to send back, since they can't compute mac2 either. A
//! party that sends a bogus message 1 gets no reply at all: the same
//! silence as every other unauthenticated message on this channel.
//!
//! Once both sides have `epk_c`, `epk_s`, and their own ephemeral private
//! key, they compute the X25519 shared point and derive two directional
//! AEAD keys via HKDF-SHA256, mixing in the user's secret as well (belt
//! and suspenders: even if the MAC-based handshake authentication turned
//! out to have a flaw, session keys still wouldn't be derivable without
//! the secret).
//!
//! Post-handshake, every AEAD-sealed message is:
//!
//! ```text
//! counter (8B BE, plaintext) || AEAD(plaintext) + 16B tag
//! ```
//!
//! `counter` is a strictly increasing per-direction sequence number,
//! doubling as replay protection: this transport is a single ordered
//! TCP-backed byte stream, so a counter that isn't strictly greater than
//! the last one accepted can only mean a replayed or corrupted message.
//!
//! ## Key rotation
//!
//! A connection that stays open for a long time (this tunnel's whole point
//! is that it *doesn't* reconnect constantly) would otherwise encrypt an
//! unbounded amount of traffic under one key pair. Periodically -- see
//! `tunnel::multiplex`'s jittered timer -- either side can send a
//! `KeyUpdate` frame carrying a fresh ephemeral X25519 public key. No new
//! MAC dance is needed to authenticate this: the `KeyUpdate` frame is
//! itself sent as an ordinary AEAD-sealed message under the *current*
//! session key, so only someone who already holds that key could have
//! produced it. Whichever side receives one while it has no rotation of
//! its own in flight treats it as a request and replies with its own
//! ephemeral key (sealed under the *old* key, since the requester can't
//! derive the new one until it sees this reply); both sides then compute
//! the new X25519 shared point and derive a fresh key pair exactly like
//! the initial handshake, mixing in the user's secret again.
//!
//! Handling the cutover without dropping or misreading a message in
//! flight: the side that sends the reply keeps the *old* inbound key
//! alongside the new one for a little while (`SessionCrypto::open` tries
//! current first, falls back to the previous key, and drops the fallback
//! the moment something decrypts under the new key) -- because messages
//! it already sent under the old key before requesting a rotation may
//! still be in flight when the peer processes the exchange. The requester
//! doesn't have this problem: it only starts using new keys after
//! processing the one reply message that gave it the peer's ephemeral
//! key, and by construction every message after that point was sent by
//! the peer after *its* switch too. Both sides implement the same
//! current-plus-fallback logic anyway, for symmetry and because it costs
//! nothing to be defensive here.

use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};

use anyhow::{Result, bail};
use chacha20poly1305::aead::{Aead, KeyInit};
use chacha20poly1305::{ChaCha20Poly1305, Key, Nonce};
use hkdf::Hkdf;
use hmac::{Hmac, Mac};
use rand::RngCore;
use rand::rngs::OsRng;
use sha2::Sha256;

pub const CONNECTION_ID_LEN: usize = 16;
pub const KEY_ID_LEN: usize = 16;
pub const PUBLIC_KEY_LEN: usize = 32;
pub const MAC_LEN: usize = 32;

pub type ConnectionId = [u8; CONNECTION_ID_LEN];
pub type KeyId = [u8; KEY_ID_LEN];

const COUNTER_LEN: usize = 8;
const KEY_LEN: usize = 32;

/// RFC 7748's X25519 base point: 9, followed by 31 zero bytes.
const X25519_BASEPOINT: [u8; 32] = {
    let mut b = [0u8; 32];
    b[0] = 9;
    b
};

pub fn random_connection_id() -> ConnectionId {
    let mut id = [0u8; CONNECTION_ID_LEN];
    OsRng.fill_bytes(&mut id);
    id
}

/// A fresh, single-use X25519 keypair. `diffie_hellman` consumes it by
/// value, so the same ephemeral secret can't accidentally be reused across
/// connections -- reuse is exactly what would undermine forward secrecy.
pub struct EphemeralKeypair {
    private: [u8; 32],
    pub public: [u8; 32],
}

impl EphemeralKeypair {
    pub fn generate() -> Self {
        let mut private = [0u8; 32];
        OsRng.fill_bytes(&mut private);
        let public = x25519_dalek::x25519(private, X25519_BASEPOINT);
        Self { private, public }
    }

    pub fn diffie_hellman(self, their_public: &[u8; 32]) -> [u8; 32] {
        x25519_dalek::x25519(self.private, *their_public)
    }
}

/// Constant-time byte comparison for MAC verification. A naive `==` on
/// `[u8; N]` can short-circuit on the first differing byte, which in
/// principle leaks timing information an attacker could use to forge a
/// valid MAC one byte at a time; this always compares every byte.
pub fn constant_time_eq(a: &[u8], b: &[u8]) -> bool {
    if a.len() != b.len() {
        return false;
    }
    let mut diff = 0u8;
    for (x, y) in a.iter().zip(b.iter()) {
        diff |= x ^ y;
    }
    diff == 0
}

fn hmac_sha256(key: &[u8], data: &[u8]) -> [u8; 32] {
    // Both `KeyInit` (used above for ChaCha20Poly1305::new) and `hmac::Mac`
    // declare `new_from_slice`; disambiguate explicitly rather than rely on
    // which import order the compiler happens to prefer.
    let mut mac = <Hmac<Sha256> as Mac>::new_from_slice(key).expect("HMAC-SHA256 accepts any key length");
    mac.update(data);
    mac.finalize().into_bytes().into()
}

/// Computes `mac1` for handshake message 1.
pub fn handshake_mac1(
    secret: &[u8],
    connection_id: &ConnectionId,
    key_id: &KeyId,
    epk_c: &[u8; PUBLIC_KEY_LEN],
) -> [u8; MAC_LEN] {
    let mut data = Vec::with_capacity(CONNECTION_ID_LEN + KEY_ID_LEN + PUBLIC_KEY_LEN);
    data.extend_from_slice(connection_id);
    data.extend_from_slice(key_id);
    data.extend_from_slice(epk_c);
    hmac_sha256(secret, &data)
}

/// Computes `mac2` for handshake message 2.
pub fn handshake_mac2(
    secret: &[u8],
    connection_id: &ConnectionId,
    key_id: &KeyId,
    epk_c: &[u8; PUBLIC_KEY_LEN],
    epk_s: &[u8; PUBLIC_KEY_LEN],
) -> [u8; MAC_LEN] {
    let mut data = Vec::with_capacity(CONNECTION_ID_LEN + KEY_ID_LEN + PUBLIC_KEY_LEN * 2);
    data.extend_from_slice(connection_id);
    data.extend_from_slice(key_id);
    data.extend_from_slice(epk_c);
    data.extend_from_slice(epk_s);
    hmac_sha256(secret, &data)
}

/// AEAD state for one direction of post-handshake traffic.
struct DirectionalCipher {
    cipher: ChaCha20Poly1305,
    next_send_counter: AtomicU64,
    last_accepted_counter: AtomicU64,
    have_accepted_any: AtomicBool,
}

impl DirectionalCipher {
    fn new(key_bytes: [u8; KEY_LEN]) -> Self {
        Self {
            cipher: ChaCha20Poly1305::new(Key::from_slice(&key_bytes)),
            next_send_counter: AtomicU64::new(0),
            last_accepted_counter: AtomicU64::new(0),
            have_accepted_any: AtomicBool::new(false),
        }
    }

    fn seal(&self, plaintext: &[u8]) -> Vec<u8> {
        let counter = self.next_send_counter.fetch_add(1, Ordering::SeqCst);
        let nonce = nonce_from_counter(counter);
        // Only fails if plaintext exceeds ChaCha20-Poly1305's ~256 GiB
        // limit, which our per-message size cap never comes close to.
        let ciphertext = self
            .cipher
            .encrypt(Nonce::from_slice(&nonce), plaintext)
            .expect("chacha20poly1305 encryption cannot fail for frame-sized input");

        let mut out = Vec::with_capacity(COUNTER_LEN + ciphertext.len());
        out.extend_from_slice(&counter.to_be_bytes());
        out.extend_from_slice(&ciphertext);
        out
    }

    fn open(&self, sealed: &[u8]) -> Result<Vec<u8>> {
        if sealed.len() < COUNTER_LEN {
            bail!("sealed frame shorter than the counter prefix");
        }
        let (counter_bytes, ciphertext) = sealed.split_at(COUNTER_LEN);
        let counter = u64::from_be_bytes(counter_bytes.try_into().expect("exactly 8 bytes"));

        if self.have_accepted_any.load(Ordering::SeqCst)
            && counter <= self.last_accepted_counter.load(Ordering::SeqCst)
        {
            bail!("non-increasing nonce counter (replay or corruption)");
        }

        let nonce = nonce_from_counter(counter);
        let plaintext = self
            .cipher
            .decrypt(Nonce::from_slice(&nonce), ciphertext)
            .map_err(|_| anyhow::anyhow!("AEAD authentication failed"))?;

        self.last_accepted_counter.store(counter, Ordering::SeqCst);
        self.have_accepted_any.store(true, Ordering::SeqCst);
        Ok(plaintext)
    }
}

fn nonce_from_counter(counter: u64) -> [u8; 12] {
    let mut nonce = [0u8; 12];
    nonce[4..].copy_from_slice(&counter.to_be_bytes());
    nonce
}

/// Both directions' AEAD state for one Minecraft connection. `previous_inbound`
/// is only `Some` for a brief window right after a key rotation -- see the
/// module docs' "Key rotation" section for why it's needed and when it's
/// discarded.
pub struct SessionCrypto {
    current_outbound: DirectionalCipher,
    current_inbound: DirectionalCipher,
    previous_inbound: Option<DirectionalCipher>,
}

impl SessionCrypto {
    /// Derives session keys from the completed handshake's transcript and
    /// DH output. `we_are_client` picks which HKDF label is "outbound" for
    /// this side, so the client's outbound key is always the server's
    /// inbound key and vice versa.
    pub fn derive(
        secret: &[u8],
        connection_id: &ConnectionId,
        epk_c: &[u8; PUBLIC_KEY_LEN],
        epk_s: &[u8; PUBLIC_KEY_LEN],
        dh_output: &[u8; 32],
        we_are_client: bool,
    ) -> Self {
        let mut salt = Vec::with_capacity(CONNECTION_ID_LEN + PUBLIC_KEY_LEN * 2);
        salt.extend_from_slice(connection_id);
        salt.extend_from_slice(epk_c);
        salt.extend_from_slice(epk_s);

        let mut ikm = Vec::with_capacity(32 + secret.len());
        ikm.extend_from_slice(dh_output);
        ikm.extend_from_slice(secret);

        let hk = Hkdf::<Sha256>::new(Some(&salt), &ikm);
        let mut client_to_server = [0u8; KEY_LEN];
        let mut server_to_client = [0u8; KEY_LEN];
        hk.expand(b"mcvpn tunnel c2s", &mut client_to_server)
            .expect("32 bytes is a valid HKDF-SHA256 output length");
        hk.expand(b"mcvpn tunnel s2c", &mut server_to_client)
            .expect("32 bytes is a valid HKDF-SHA256 output length");

        let (outbound_key, inbound_key) = if we_are_client {
            (client_to_server, server_to_client)
        } else {
            (server_to_client, client_to_server)
        };

        Self {
            current_outbound: DirectionalCipher::new(outbound_key),
            current_inbound: DirectionalCipher::new(inbound_key),
            previous_inbound: None,
        }
    }

    pub fn seal(&self, plaintext: &[u8]) -> Vec<u8> {
        self.current_outbound.seal(plaintext)
    }

    /// Tries the current inbound key first; if that fails, falls back to
    /// the previous key (only present right after a rotation). Dropping
    /// `previous_inbound` the moment `current_inbound` succeeds is exactly
    /// what confirms the peer has switched over too -- see the module docs.
    pub fn open(&mut self, sealed: &[u8]) -> Result<Vec<u8>> {
        if let Ok(plaintext) = self.current_inbound.open(sealed) {
            self.previous_inbound = None;
            return Ok(plaintext);
        }
        if let Some(previous) = &self.previous_inbound {
            if let Ok(plaintext) = previous.open(sealed) {
                return Ok(plaintext);
            }
        }
        bail!("AEAD open failed under both the current and previous session key")
    }

    /// Called by whichever side is *replying* to a peer-initiated
    /// `KeyUpdate`: seals `reply_plaintext` under the outgoing (soon to be
    /// replaced) key, then atomically swaps in the new key pair derived
    /// from this rotation's DH output. `epk_a`/`epk_b` follow the
    /// initiator-then-responder convention used throughout this rotation
    /// (`epk_a` = the key that arrived in the request, `epk_b` = the key
    /// we're generating for the reply) -- independent of, and reset fresh
    /// for, each individual rotation, regardless of which side is
    /// permanently the client vs. server.
    pub fn reply_to_rotation(
        &mut self,
        secret: &[u8],
        epk_a: &[u8; PUBLIC_KEY_LEN],
        epk_b: &[u8; PUBLIC_KEY_LEN],
        dh_output: &[u8; 32],
        reply_plaintext: &[u8],
    ) -> Vec<u8> {
        let sealed_reply = self.current_outbound.seal(reply_plaintext);
        self.rotate_keys(secret, epk_a, epk_b, dh_output, false);
        sealed_reply
    }

    /// Called by the rotation *initiator* upon receiving and decrypting
    /// the peer's reply: derives and swaps in the new key pair. No
    /// separate "old key" send needed here, since our request was already
    /// sent under the (still current, at that point) key by the ordinary
    /// `seal` path.
    pub fn complete_rotation(
        &mut self,
        secret: &[u8],
        epk_a: &[u8; PUBLIC_KEY_LEN],
        epk_b: &[u8; PUBLIC_KEY_LEN],
        dh_output: &[u8; 32],
    ) {
        self.rotate_keys(secret, epk_a, epk_b, dh_output, true);
    }

    fn rotate_keys(
        &mut self,
        secret: &[u8],
        epk_a: &[u8; PUBLIC_KEY_LEN],
        epk_b: &[u8; PUBLIC_KEY_LEN],
        dh_output: &[u8; 32],
        we_are_a: bool,
    ) {
        let mut salt = Vec::with_capacity(PUBLIC_KEY_LEN * 2);
        salt.extend_from_slice(epk_a);
        salt.extend_from_slice(epk_b);

        let mut ikm = Vec::with_capacity(32 + secret.len());
        ikm.extend_from_slice(dh_output);
        ikm.extend_from_slice(secret);

        let hk = Hkdf::<Sha256>::new(Some(&salt), &ikm);
        let mut a_to_b = [0u8; KEY_LEN];
        let mut b_to_a = [0u8; KEY_LEN];
        hk.expand(b"mcvpn rotate a2b", &mut a_to_b)
            .expect("32 bytes is a valid HKDF-SHA256 output length");
        hk.expand(b"mcvpn rotate b2a", &mut b_to_a)
            .expect("32 bytes is a valid HKDF-SHA256 output length");

        let (rotation_outbound, rotation_inbound) = if we_are_a { (a_to_b, b_to_a) } else { (b_to_a, a_to_b) };

        let new_outbound = DirectionalCipher::new(rotation_outbound);
        let new_inbound = DirectionalCipher::new(rotation_inbound);

        self.previous_inbound = Some(std::mem::replace(&mut self.current_inbound, new_inbound));
        self.current_outbound = new_outbound;
    }
}

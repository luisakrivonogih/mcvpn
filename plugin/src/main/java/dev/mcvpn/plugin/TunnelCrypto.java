package dev.mcvpn.plugin;

import java.math.BigInteger;
import java.nio.charset.StandardCharsets;
import java.security.GeneralSecurityException;
import java.security.KeyFactory;
import java.security.KeyPair;
import java.security.KeyPairGenerator;
import java.security.PrivateKey;
import java.security.interfaces.XECPublicKey;
import java.security.spec.NamedParameterSpec;
import java.security.spec.XECPublicKeySpec;
import java.util.Arrays;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicLong;

import javax.crypto.Cipher;
import javax.crypto.KeyAgreement;
import javax.crypto.Mac;
import javax.crypto.spec.IvParameterSpec;
import javax.crypto.spec.SecretKeySpec;

/**
 * ChaCha20-Poly1305 AEAD tunnel encryption, keyed by a forward-secret
 * per-connection session key derived from an authenticated X25519
 * ephemeral Diffie-Hellman handshake -- mirrors the Rust client's {@code
 * crypto::cipher} byte-for-byte. See that module's docs for the full
 * rationale; the short version: session keys depend on ephemeral private
 * keys that are generated fresh per connection, never transmitted, and
 * discarded once the session keys are derived, so a shared-secret leak
 * later can't be used to retroactively decrypt a recorded past session.
 *
 * <pre>
 * Client -&gt; Server: connection_id (16B) || key_id (16B) || epk_c (32B) || mac1 (32B)
 *   mac1 = HMAC-SHA256(secret, connection_id || key_id || epk_c)
 *
 * Server -&gt; Client: epk_s (32B) || mac2 (32B)
 *   mac2 = HMAC-SHA256(secret, connection_id || key_id || epk_c || epk_s)
 * </pre>
 *
 * {@code key_id} names which per-user secret authenticates this connection
 * (see the plugin's {@code store.UserStore}); {@code secret} is that user's
 * raw secret bytes, not a passphrase string, and is folded into the
 * handshake MACs and the session-key HKDF but not into {@code key_id}
 * itself -- {@code key_id} is a lookup key, not a MAC input beyond the
 * handshake messages that need to bind it to a particular exchange.
 *
 * Post-handshake: {@code counter (8B BE) || AEAD(plaintext) + 16B tag}.
 *
 * HKDF is hand-implemented per RFC 5869 on top of {@code HmacSHA256} (the
 * JDK has no HKDF API); X25519 uses the JDK's built-in XEC support
 * (available since Java 11). Note: JCA represents X25519 public keys as a
 * {@code BigInteger} u-coordinate, while the wire format (and the Rust
 * side) uses RFC 7748's raw 32-byte little-endian encoding directly --
 * {@link #encodePublicKey} / {@link #decodePublicKey} do that conversion.
 * This is the one piece of this codebase most likely to need a fix if the
 * two sides don't interoperate on the first try.
 */
final class TunnelCrypto {

    static final int CONNECTION_ID_LEN = 16;
    static final int KEY_ID_LEN = 16;
    static final int PUBLIC_KEY_LEN = 32;
    static final int MAC_LEN = 32;

    private static final int COUNTER_LEN = 8;
    private static final int KEY_LEN = 32;
    private static final int HASH_LEN = 32;
    private static final NamedParameterSpec X25519_PARAMS = new NamedParameterSpec("X25519");

    // Not final: key rotation (see replyToRotation/completeRotation below)
    // swaps these out at runtime. Unlike the Rust client's actor (which is
    // single-threaded by construction), this plugin calls seal() from each
    // stream's own background reader thread while rotation runs on the
    // main thread handling plugin messages -- genuinely concurrent, so
    // every accessor below is `synchronized` on this instance.
    private Direction currentOutbound;
    private Direction currentInbound;
    private Direction previousInbound;

    private TunnelCrypto(byte[] outboundKey, byte[] inboundKey) {
        this.currentOutbound = new Direction(outboundKey);
        this.currentInbound = new Direction(inboundKey);
    }

    // --- Handshake ---

    /** A fresh, single-use X25519 keypair for one connection's handshake. */
    static final class Keypair {
        private final PrivateKey privateKey;
        final byte[] publicKeyBytes;

        private Keypair(PrivateKey privateKey, byte[] publicKeyBytes) {
            this.privateKey = privateKey;
            this.publicKeyBytes = publicKeyBytes;
        }

        static Keypair generate() throws GeneralSecurityException {
            KeyPairGenerator kpg = KeyPairGenerator.getInstance("X25519");
            KeyPair kp = kpg.generateKeyPair();
            return new Keypair(kp.getPrivate(), encodePublicKey((XECPublicKey) kp.getPublic()));
        }

        /** Raw 32-byte X25519 shared secret (already in wire format, no BigInteger round trip needed). */
        byte[] diffieHellman(byte[] theirPublicKeyBytes) throws GeneralSecurityException {
            XECPublicKey theirKey = decodePublicKey(theirPublicKeyBytes);
            KeyAgreement ka = KeyAgreement.getInstance("X25519");
            ka.init(privateKey);
            ka.doPhase(theirKey, true);
            return ka.generateSecret();
        }
    }

    private static byte[] encodePublicKey(XECPublicKey key) {
        return beToLe32(key.getU().toByteArray());
    }

    private static XECPublicKey decodePublicKey(byte[] rawLe32) throws GeneralSecurityException {
        BigInteger u = new BigInteger(1, le32ToBe(rawLe32));
        KeyFactory kf = KeyFactory.getInstance("X25519");
        return (XECPublicKey) kf.generatePublic(new XECPublicKeySpec(X25519_PARAMS, u));
    }

    /** Converts a possibly short/sign-padded big-endian BigInteger encoding to a fixed 32-byte little-endian array. */
    private static byte[] beToLe32(byte[] be) {
        byte[] result = new byte[32];
        int copyLen = Math.min(be.length, 32);
        System.arraycopy(be, be.length - copyLen, result, 32 - copyLen, copyLen);
        reverseInPlace(result);
        return result;
    }

    private static byte[] le32ToBe(byte[] le) {
        byte[] be = le.clone();
        reverseInPlace(be);
        return be;
    }

    private static void reverseInPlace(byte[] a) {
        for (int i = 0, j = a.length - 1; i < j; i++, j--) {
            byte tmp = a[i];
            a[i] = a[j];
            a[j] = tmp;
        }
    }

    static byte[] handshakeMac1(byte[] secret, byte[] connectionId, byte[] keyId, byte[] epkC)
            throws GeneralSecurityException {
        return hmacSha256(secret, concat(connectionId, keyId, epkC));
    }

    static byte[] handshakeMac2(byte[] secret, byte[] connectionId, byte[] keyId, byte[] epkC, byte[] epkS)
            throws GeneralSecurityException {
        return hmacSha256(secret, concat(connectionId, keyId, epkC, epkS));
    }

    /** Constant-time MAC comparison -- see the Rust client's `constant_time_eq` for why this matters. */
    static boolean constantTimeEquals(byte[] a, byte[] b) {
        return java.security.MessageDigest.isEqual(a, b);
    }

    static TunnelCrypto derive(byte[] secret, byte[] connectionId, byte[] epkC, byte[] epkS,
            byte[] dhOutput, boolean weAreClient) throws GeneralSecurityException {
        byte[] salt = concat(connectionId, epkC, epkS);
        byte[] ikm = concat(dhOutput, secret);

        byte[] prk = hkdfExtract(salt, ikm);
        byte[] clientToServer = hkdfExpand(prk, "mcvpn tunnel c2s".getBytes(StandardCharsets.UTF_8), KEY_LEN);
        byte[] serverToClient = hkdfExpand(prk, "mcvpn tunnel s2c".getBytes(StandardCharsets.UTF_8), KEY_LEN);

        return weAreClient
                ? new TunnelCrypto(clientToServer, serverToClient)
                : new TunnelCrypto(serverToClient, clientToServer);
    }

    // --- Post-handshake AEAD ---

    synchronized byte[] seal(byte[] plaintext) throws GeneralSecurityException {
        return currentOutbound.seal(plaintext);
    }

    /**
     * Tries the current inbound key first; if that fails, falls back to
     * the previous key (only present right after a rotation). Dropping
     * {@code previousInbound} the moment {@code currentInbound} succeeds
     * is exactly what confirms the peer has switched over too -- see the
     * Rust client's {@code crypto::cipher} "Key rotation" docs for the
     * full reasoning, which applies identically here.
     */
    synchronized byte[] open(byte[] sealed) throws GeneralSecurityException {
        try {
            byte[] plaintext = currentInbound.open(sealed);
            previousInbound = null;
            return plaintext;
        } catch (GeneralSecurityException e) {
            if (previousInbound != null) {
                return previousInbound.open(sealed);
            }
            throw e;
        }
    }

    // --- Key rotation ---

    /**
     * Called by whichever side is *replying* to a peer-initiated
     * KEY_UPDATE: seals {@code replyPlaintext} under the outgoing (soon to
     * be replaced) key, then atomically swaps in the new key pair derived
     * from this rotation's DH output. {@code epkA}/{@code epkB} follow the
     * initiator-then-responder convention (epkA = the key that arrived in
     * the request, epkB = the key we're generating for the reply) --
     * independent of, and reset fresh for, each individual rotation.
     */
    synchronized byte[] replyToRotation(byte[] secret, byte[] epkA, byte[] epkB, byte[] dhOutput,
            byte[] replyPlaintext) throws GeneralSecurityException {
        byte[] sealedReply = currentOutbound.seal(replyPlaintext);
        rotateKeys(secret, epkA, epkB, dhOutput, false);
        return sealedReply;
    }

    /**
     * Called by the rotation *initiator* upon receiving and decrypting the
     * peer's reply: derives and swaps in the new key pair. No separate
     * "old key" send needed here, since our request was already sent
     * under the (still current, at that point) key by the ordinary
     * {@link #seal} path.
     */
    synchronized void completeRotation(byte[] secret, byte[] epkA, byte[] epkB, byte[] dhOutput)
            throws GeneralSecurityException {
        rotateKeys(secret, epkA, epkB, dhOutput, true);
    }

    private void rotateKeys(byte[] secret, byte[] epkA, byte[] epkB, byte[] dhOutput, boolean weAreA)
            throws GeneralSecurityException {
        byte[] salt = concat(epkA, epkB);
        byte[] ikm = concat(dhOutput, secret);

        byte[] prk = hkdfExtract(salt, ikm);
        byte[] aToB = hkdfExpand(prk, "mcvpn rotate a2b".getBytes(StandardCharsets.UTF_8), KEY_LEN);
        byte[] bToA = hkdfExpand(prk, "mcvpn rotate b2a".getBytes(StandardCharsets.UTF_8), KEY_LEN);

        byte[] outboundKey = weAreA ? aToB : bToA;
        byte[] inboundKey = weAreA ? bToA : aToB;

        previousInbound = currentInbound;
        currentInbound = new Direction(inboundKey);
        currentOutbound = new Direction(outboundKey);
    }

    private static final class Direction {
        private final SecretKeySpec key;
        private final AtomicLong nextSendCounter = new AtomicLong(0);
        private final AtomicLong lastAcceptedCounter = new AtomicLong(0);
        private final AtomicBoolean haveAcceptedAny = new AtomicBoolean(false);

        Direction(byte[] keyBytes) {
            this.key = new SecretKeySpec(keyBytes, "ChaCha20");
        }

        byte[] seal(byte[] plaintext) throws GeneralSecurityException {
            long counter = nextSendCounter.getAndIncrement();
            Cipher cipher = Cipher.getInstance("ChaCha20-Poly1305");
            cipher.init(Cipher.ENCRYPT_MODE, key, new IvParameterSpec(nonceFromCounter(counter)));
            byte[] ciphertext = cipher.doFinal(plaintext);

            byte[] out = new byte[COUNTER_LEN + ciphertext.length];
            writeBeLong(out, 0, counter);
            System.arraycopy(ciphertext, 0, out, COUNTER_LEN, ciphertext.length);
            return out;
        }

        byte[] open(byte[] sealed) throws GeneralSecurityException {
            if (sealed.length < COUNTER_LEN) {
                throw new GeneralSecurityException("sealed frame shorter than the counter prefix");
            }
            long counter = readBeLong(sealed, 0);
            if (haveAcceptedAny.get() && counter <= lastAcceptedCounter.get()) {
                throw new GeneralSecurityException("non-increasing nonce counter (replay or corruption)");
            }

            byte[] ciphertext = Arrays.copyOfRange(sealed, COUNTER_LEN, sealed.length);
            Cipher cipher = Cipher.getInstance("ChaCha20-Poly1305");
            cipher.init(Cipher.DECRYPT_MODE, key, new IvParameterSpec(nonceFromCounter(counter)));
            // Throws AEADBadTagException (a GeneralSecurityException) if the
            // tag doesn't verify -- wrong key or tampered ciphertext.
            byte[] plaintext = cipher.doFinal(ciphertext);

            lastAcceptedCounter.set(counter);
            haveAcceptedAny.set(true);
            return plaintext;
        }
    }

    private static byte[] nonceFromCounter(long counter) {
        byte[] nonce = new byte[12];
        writeBeLong(nonce, 4, counter);
        return nonce;
    }

    private static void writeBeLong(byte[] dst, int offset, long value) {
        for (int i = 0; i < 8; i++) {
            dst[offset + i] = (byte) (value >>> (8 * (7 - i)));
        }
    }

    private static long readBeLong(byte[] src, int offset) {
        long value = 0;
        for (int i = 0; i < 8; i++) {
            value = (value << 8) | (src[offset + i] & 0xFFL);
        }
        return value;
    }

    private static byte[] concat(byte[]... parts) {
        int total = 0;
        for (byte[] p : parts) {
            total += p.length;
        }
        byte[] out = new byte[total];
        int pos = 0;
        for (byte[] p : parts) {
            System.arraycopy(p, 0, out, pos, p.length);
            pos += p.length;
        }
        return out;
    }

    // --- HKDF (RFC 5869) on top of HmacSHA256; the JDK has no HKDF API. ---

    private static byte[] hkdfExtract(byte[] salt, byte[] ikm) throws GeneralSecurityException {
        return hmacSha256(salt, ikm);
    }

    private static byte[] hkdfExpand(byte[] prk, byte[] info, int length) throws GeneralSecurityException {
        int n = (length + HASH_LEN - 1) / HASH_LEN;
        byte[] okm = new byte[length];
        byte[] t = new byte[0];
        int pos = 0;
        for (int i = 1; i <= n; i++) {
            byte[] input = concat(t, info, new byte[] { (byte) i });
            t = hmacSha256(prk, input);
            int copyLen = Math.min(HASH_LEN, length - pos);
            System.arraycopy(t, 0, okm, pos, copyLen);
            pos += copyLen;
        }
        return okm;
    }

    private static byte[] hmacSha256(byte[] key, byte[] data) throws GeneralSecurityException {
        Mac mac = Mac.getInstance("HmacSHA256");
        mac.init(new SecretKeySpec(key.length == 0 ? new byte[HASH_LEN] : key, "HmacSHA256"));
        return mac.doFinal(data);
    }
}

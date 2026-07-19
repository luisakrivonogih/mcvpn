package dev.mcvpn.plugin.http;

import java.security.GeneralSecurityException;
import java.security.SecureRandom;
import java.util.Base64;

import javax.crypto.SecretKeyFactory;
import javax.crypto.spec.PBEKeySpec;

/**
 * PBKDF2WithHmacSHA256 password hashing shared by the admin HTTP API
 * ({@link AdminHttpServer}) and the bootstrap console command
 * ({@code McvpnCommand}) -- the only two places an admin password is ever
 * turned into a stored hash.
 *
 * Encoded form: {@code iterations:base64(salt):base64(hash)}, so the
 * iteration count and salt travel with the hash and nothing else needs to
 * be configured to verify it later even if the iteration count changes.
 */
public final class PasswordHashing {

    private static final int ITERATIONS = 210_000;
    private static final int SALT_LEN = 16;
    private static final int KEY_LEN_BITS = 256;
    private static final SecureRandom RANDOM = new SecureRandom();

    private PasswordHashing() {
    }

    public static String hash(char[] password) {
        byte[] salt = new byte[SALT_LEN];
        RANDOM.nextBytes(salt);
        byte[] hash = pbkdf2(password, salt, ITERATIONS);
        return ITERATIONS + ":" + b64(salt) + ":" + b64(hash);
    }

    public static String hash(String password) {
        return hash(password.toCharArray());
    }

    public static boolean verify(char[] password, String encoded) {
        try {
            String[] parts = encoded.split(":", 3);
            if (parts.length != 3) {
                return false;
            }
            int iterations = Integer.parseInt(parts[0]);
            byte[] salt = Base64.getDecoder().decode(parts[1]);
            byte[] expected = Base64.getDecoder().decode(parts[2]);
            byte[] actual = pbkdf2(password, salt, iterations);
            return java.security.MessageDigest.isEqual(expected, actual);
        } catch (RuntimeException e) {
            return false; // malformed stored hash; treat as a verification failure, not a crash
        }
    }

    public static boolean verify(String password, String encoded) {
        return verify(password.toCharArray(), encoded);
    }

    private static byte[] pbkdf2(char[] password, byte[] salt, int iterations) {
        try {
            SecretKeyFactory factory = SecretKeyFactory.getInstance("PBKDF2WithHmacSHA256");
            PBEKeySpec spec = new PBEKeySpec(password, salt, iterations, KEY_LEN_BITS);
            return factory.generateSecret(spec).getEncoded();
        } catch (GeneralSecurityException e) {
            throw new IllegalStateException("PBKDF2WithHmacSHA256 not available", e);
        }
    }

    private static String b64(byte[] b) {
        return Base64.getEncoder().encodeToString(b);
    }
}

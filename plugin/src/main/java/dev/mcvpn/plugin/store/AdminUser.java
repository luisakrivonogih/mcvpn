package dev.mcvpn.plugin.store;

import java.time.Instant;

/**
 * One admin-panel account. {@code passwordHash} is a self-describing
 * PBKDF2 encoding ({@code iterations:base64(salt):base64(hash)}) -- see
 * {@code dev.mcvpn.plugin.http.PasswordHashing} -- never a plaintext
 * password.
 */
public record AdminUser(String id, String username, String passwordHash, Instant createdAt) {
}

package dev.mcvpn.plugin.store;

import java.time.Instant;

/**
 * One tunnel user: the {@code keyId}/{@code secret} pair a client
 * presents in handshake message 1 (see {@code TunnelCrypto}), plus
 * bookkeeping for the admin panel. {@code lastSeenAt} is {@code null}
 * until the first successful handshake.
 */
public record VpnUser(
        String id,
        byte[] keyId,
        byte[] secret,
        String label,
        boolean enabled,
        Instant createdAt,
        Instant lastSeenAt) {
}

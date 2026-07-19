package dev.mcvpn.plugin.store;

import java.security.SecureRandom;
import java.time.Instant;
import java.util.ArrayList;
import java.util.HexFormat;
import java.util.List;
import java.util.NoSuchElementException;
import java.util.Optional;
import java.util.UUID;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.ConcurrentHashMap;

/**
 * Non-persistent, zero-config default: everything lives in memory and is
 * lost on restart. Fine for local testing; a real deployment should
 * configure a {@code database:} backend instead (see {@link UserStoreFactory}).
 */
public final class MemoryUserStore implements UserStore {

    private final SecureRandom random = new SecureRandom();

    // Keyed by hex-encoded keyId.
    private final ConcurrentHashMap<String, VpnUser> vpnUsersByKeyId = new ConcurrentHashMap<>();
    private final ConcurrentHashMap<String, VpnUser> vpnUsersById = new ConcurrentHashMap<>();

    // Keyed by username.
    private final ConcurrentHashMap<String, AdminUser> adminsByUsername = new ConcurrentHashMap<>();
    private final ConcurrentHashMap<String, AdminUser> adminsById = new ConcurrentHashMap<>();

    @Override
    public CompletableFuture<Optional<VpnUser>> findVpnUserByKeyId(byte[] keyId) {
        return CompletableFuture.completedFuture(Optional.ofNullable(vpnUsersByKeyId.get(hex(keyId))));
    }

    @Override
    public CompletableFuture<List<VpnUser>> listVpnUsers() {
        return CompletableFuture.completedFuture(new ArrayList<>(vpnUsersById.values()));
    }

    @Override
    public synchronized CompletableFuture<VpnUser> createVpnUser(String label) {
        for (int attempt = 0; attempt < 3; attempt++) {
            byte[] keyId = randomBytes(16);
            String keyIdHex = hex(keyId);
            if (vpnUsersByKeyId.containsKey(keyIdHex)) {
                continue; // astronomically rare collision; retry with a fresh keyId
            }
            byte[] secret = randomBytes(32);
            VpnUser user = new VpnUser(UUID.randomUUID().toString(), keyId, secret, label, true, Instant.now(), null);
            vpnUsersByKeyId.put(keyIdHex, user);
            vpnUsersById.put(user.id(), user);
            return CompletableFuture.completedFuture(user);
        }
        CompletableFuture<VpnUser> failed = new CompletableFuture<>();
        failed.completeExceptionally(new IllegalStateException("failed to generate a unique keyId after 3 attempts"));
        return failed;
    }

    @Override
    public CompletableFuture<Void> setVpnUserEnabled(String id, boolean enabled) {
        VpnUser existing = vpnUsersById.get(id);
        if (existing == null) {
            CompletableFuture<Void> failed = new CompletableFuture<>();
            failed.completeExceptionally(new NoSuchElementException("no such vpn user: " + id));
            return failed;
        }
        VpnUser updated = new VpnUser(existing.id(), existing.keyId(), existing.secret(), existing.label(),
                enabled, existing.createdAt(), existing.lastSeenAt());
        replace(existing, updated);
        return CompletableFuture.completedFuture(null);
    }

    @Override
    public CompletableFuture<VpnUser> rotateVpnUserSecret(String id) {
        VpnUser existing = vpnUsersById.get(id);
        if (existing == null) {
            CompletableFuture<VpnUser> failed = new CompletableFuture<>();
            failed.completeExceptionally(new NoSuchElementException("no such vpn user: " + id));
            return failed;
        }
        VpnUser updated = new VpnUser(existing.id(), existing.keyId(), randomBytes(32), existing.label(),
                existing.enabled(), existing.createdAt(), existing.lastSeenAt());
        replace(existing, updated);
        return CompletableFuture.completedFuture(updated);
    }

    @Override
    public CompletableFuture<Void> deleteVpnUser(String id) {
        VpnUser existing = vpnUsersById.remove(id);
        if (existing != null) {
            vpnUsersByKeyId.remove(hex(existing.keyId()));
        }
        return CompletableFuture.completedFuture(null);
    }

    @Override
    public CompletableFuture<Void> touchLastSeen(String id) {
        VpnUser existing = vpnUsersById.get(id);
        if (existing == null) {
            return CompletableFuture.completedFuture(null);
        }
        VpnUser updated = new VpnUser(existing.id(), existing.keyId(), existing.secret(), existing.label(),
                existing.enabled(), existing.createdAt(), Instant.now());
        replace(existing, updated);
        return CompletableFuture.completedFuture(null);
    }

    @Override
    public CompletableFuture<Optional<AdminUser>> findAdminByUsername(String username) {
        return CompletableFuture.completedFuture(Optional.ofNullable(adminsByUsername.get(username)));
    }

    @Override
    public CompletableFuture<Optional<AdminUser>> findAdminById(String id) {
        return CompletableFuture.completedFuture(Optional.ofNullable(adminsById.get(id)));
    }

    @Override
    public CompletableFuture<List<AdminUser>> listAdmins() {
        return CompletableFuture.completedFuture(new ArrayList<>(adminsById.values()));
    }

    @Override
    public CompletableFuture<AdminUser> createAdmin(String username, String passwordHash) {
        if (adminsByUsername.containsKey(username)) {
            CompletableFuture<AdminUser> failed = new CompletableFuture<>();
            failed.completeExceptionally(new IllegalStateException("admin username already exists: " + username));
            return failed;
        }
        AdminUser admin = new AdminUser(UUID.randomUUID().toString(), username, passwordHash, Instant.now());
        adminsByUsername.put(username, admin);
        adminsById.put(admin.id(), admin);
        return CompletableFuture.completedFuture(admin);
    }

    @Override
    public CompletableFuture<Void> updateAdminPassword(String id, String newPasswordHash) {
        AdminUser existing = adminsById.get(id);
        if (existing == null) {
            CompletableFuture<Void> failed = new CompletableFuture<>();
            failed.completeExceptionally(new NoSuchElementException("no such admin: " + id));
            return failed;
        }
        AdminUser updated = new AdminUser(existing.id(), existing.username(), newPasswordHash, existing.createdAt());
        adminsById.put(updated.id(), updated);
        adminsByUsername.put(updated.username(), updated);
        return CompletableFuture.completedFuture(null);
    }

    @Override
    public void close() {
        // Nothing to release; state simply evaporates with the JVM.
    }

    private void replace(VpnUser existing, VpnUser updated) {
        vpnUsersById.put(updated.id(), updated);
        vpnUsersByKeyId.put(hex(updated.keyId()), updated);
    }

    private byte[] randomBytes(int len) {
        byte[] b = new byte[len];
        random.nextBytes(b);
        return b;
    }

    private static String hex(byte[] b) {
        return HexFormat.of().formatHex(b);
    }
}

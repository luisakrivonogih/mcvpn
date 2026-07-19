package dev.mcvpn.plugin.store;

import java.util.List;
import java.util.Optional;
import java.util.concurrent.CompletableFuture;

/**
 * Pluggable per-user credential store backing both the tunnel handshake
 * (VPN users) and the embedded admin HTTP API (admin users). Every method
 * is asynchronous -- implementations backed by a real database run their
 * blocking calls on a shared executor -- so nothing here may ever block
 * the calling thread, including the hot connection-handshake path in
 * {@code PlayerMultiplex}.
 */
public interface UserStore {

    CompletableFuture<Optional<VpnUser>> findVpnUserByKeyId(byte[] keyId);

    CompletableFuture<List<VpnUser>> listVpnUsers();

    /**
     * Generates a fresh random 16-byte {@code keyId} and 32-byte
     * {@code secret}, inserts a new user labeled {@code label}, and
     * returns it. Implementations should retry with a freshly generated
     * {@code keyId} (up to a small bounded number of attempts) if a
     * unique-constraint collision occurs.
     */
    CompletableFuture<VpnUser> createVpnUser(String label);

    CompletableFuture<Void> setVpnUserEnabled(String id, boolean enabled);

    /** Generates and persists a fresh 32-byte secret for the user, returning the updated record. */
    CompletableFuture<VpnUser> rotateVpnUserSecret(String id);

    CompletableFuture<Void> deleteVpnUser(String id);

    CompletableFuture<Void> touchLastSeen(String id);

    CompletableFuture<Optional<AdminUser>> findAdminByUsername(String username);

    CompletableFuture<Optional<AdminUser>> findAdminById(String id);

    CompletableFuture<List<AdminUser>> listAdmins();

    CompletableFuture<AdminUser> createAdmin(String username, String passwordHash);

    CompletableFuture<Void> updateAdminPassword(String id, String newPasswordHash);

    void close();
}

package dev.mcvpn.plugin.store;

import java.util.List;
import java.util.Locale;
import java.util.Optional;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.ThreadFactory;
import java.util.concurrent.atomic.AtomicInteger;

import org.bukkit.configuration.file.FileConfiguration;

/**
 * Reads the {@code database:} config section and constructs the matching
 * {@link UserStore} implementation. DB-backed stores share one small
 * fixed-size executor for their blocking calls; {@link MemoryUserStore}
 * doesn't need it. The returned store's {@link UserStore#close()} also
 * shuts that executor down, so callers only ever need to close the store
 * itself.
 */
public final class UserStoreFactory {

    private UserStoreFactory() {
    }

    public static UserStore create(FileConfiguration config) {
        String type = config.getString("database.type", "memory").toLowerCase(Locale.ROOT);

        if ("memory".equals(type)) {
            return new MemoryUserStore();
        }

        ExecutorService dbExecutor = newDbExecutor();
        String host = config.getString("database.host", "127.0.0.1");
        int port = config.getInt("database.port", defaultPortFor(type));
        String name = config.getString("database.name", "mcvpn");
        String user = config.getString("database.user", "mcvpn");
        String password = config.getString("database.password", "");

        UserStore delegate = switch (type) {
            case "postgres" -> new PostgresUserStore(host, port, name, user, password, dbExecutor);
            case "mariadb" -> new MariaUserStore(host, port, name, user, password, dbExecutor);
            case "mongodb" -> {
                String connectionString = buildMongoConnectionString(host, port, user, password);
                yield new MongoUserStore(connectionString, name, dbExecutor);
            }
            default -> throw new IllegalArgumentException(
                    "unknown database.type '" + type + "' (expected: memory, postgres, mariadb, mongodb)");
        };

        return new ClosingUserStore(delegate, dbExecutor);
    }

    private static int defaultPortFor(String type) {
        return switch (type) {
            case "postgres" -> 5432;
            case "mariadb" -> 3306;
            case "mongodb" -> 27017;
            default -> 0;
        };
    }

    private static String buildMongoConnectionString(String host, int port, String user, String password) {
        if (user == null || user.isEmpty()) {
            return "mongodb://" + host + ":" + port;
        }
        return "mongodb://" + user + ":" + password + "@" + host + ":" + port;
    }

    private static ExecutorService newDbExecutor() {
        AtomicInteger counter = new AtomicInteger(1);
        ThreadFactory threadFactory = runnable -> {
            Thread t = new Thread(runnable, "mcvpn-db-" + counter.getAndIncrement());
            t.setDaemon(true);
            return t;
        };
        return Executors.newFixedThreadPool(4, threadFactory);
    }

    /** Wraps a DB-backed store so closing it also shuts down the shared executor it was built with. */
    private static final class ClosingUserStore implements UserStore {
        private final UserStore delegate;
        private final ExecutorService dbExecutor;

        ClosingUserStore(UserStore delegate, ExecutorService dbExecutor) {
            this.delegate = delegate;
            this.dbExecutor = dbExecutor;
        }

        @Override
        public CompletableFuture<Optional<VpnUser>> findVpnUserByKeyId(byte[] keyId) {
            return delegate.findVpnUserByKeyId(keyId);
        }

        @Override
        public CompletableFuture<List<VpnUser>> listVpnUsers() {
            return delegate.listVpnUsers();
        }

        @Override
        public CompletableFuture<VpnUser> createVpnUser(String label) {
            return delegate.createVpnUser(label);
        }

        @Override
        public CompletableFuture<Void> setVpnUserEnabled(String id, boolean enabled) {
            return delegate.setVpnUserEnabled(id, enabled);
        }

        @Override
        public CompletableFuture<VpnUser> rotateVpnUserSecret(String id) {
            return delegate.rotateVpnUserSecret(id);
        }

        @Override
        public CompletableFuture<Void> deleteVpnUser(String id) {
            return delegate.deleteVpnUser(id);
        }

        @Override
        public CompletableFuture<Void> touchLastSeen(String id) {
            return delegate.touchLastSeen(id);
        }

        @Override
        public CompletableFuture<Optional<AdminUser>> findAdminByUsername(String username) {
            return delegate.findAdminByUsername(username);
        }

        @Override
        public CompletableFuture<Optional<AdminUser>> findAdminById(String id) {
            return delegate.findAdminById(id);
        }

        @Override
        public CompletableFuture<List<AdminUser>> listAdmins() {
            return delegate.listAdmins();
        }

        @Override
        public CompletableFuture<AdminUser> createAdmin(String username, String passwordHash) {
            return delegate.createAdmin(username, passwordHash);
        }

        @Override
        public CompletableFuture<Void> updateAdminPassword(String id, String newPasswordHash) {
            return delegate.updateAdminPassword(id, newPasswordHash);
        }

        @Override
        public void close() {
            delegate.close();
            dbExecutor.shutdown();
        }
    }
}

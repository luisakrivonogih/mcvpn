package dev.mcvpn.plugin.store;

import java.sql.Connection;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.sql.Statement;
import java.sql.Timestamp;
import java.security.SecureRandom;
import java.time.Instant;
import java.util.ArrayList;
import java.util.List;
import java.util.Optional;
import java.util.UUID;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.ExecutorService;

import com.zaxxer.hikari.HikariConfig;
import com.zaxxer.hikari.HikariDataSource;

/**
 * Shared JDBC implementation of {@link UserStore}. Subclasses only supply
 * the dialect-specific DDL column types and a {@link HikariConfig}; every
 * query is otherwise identical across Postgres/MariaDB.
 *
 * All blocking JDBC calls run on {@code dbExecutor} (see
 * {@link UserStoreFactory}), never on the caller's thread. The two tables
 * are created with {@code CREATE TABLE IF NOT EXISTS} synchronously in the
 * constructor so a misconfigured database fails loudly during
 * {@code onEnable} rather than on the first handshake.
 */
public abstract class AbstractJdbcUserStore implements UserStore {

    private final HikariDataSource dataSource;
    private final ExecutorService dbExecutor;
    private final SecureRandom random = new SecureRandom();

    protected AbstractJdbcUserStore(HikariConfig hikariConfig, ExecutorService dbExecutor) {
        this.dataSource = new HikariDataSource(hikariConfig);
        this.dbExecutor = dbExecutor;
        try (Connection c = dataSource.getConnection(); Statement st = c.createStatement()) {
            st.executeUpdate("CREATE TABLE IF NOT EXISTS vpn_users ("
                    + "id " + idColumnType() + " PRIMARY KEY, "
                    + "key_id " + binaryColumnType(16) + " NOT NULL UNIQUE, "
                    + "secret " + binaryColumnType(32) + " NOT NULL, "
                    + "label VARCHAR(255) NOT NULL, "
                    + "enabled BOOLEAN NOT NULL, "
                    + "created_at TIMESTAMP NOT NULL, "
                    + "last_seen_at TIMESTAMP NULL)");
            st.executeUpdate("CREATE TABLE IF NOT EXISTS admin_users ("
                    + "id " + idColumnType() + " PRIMARY KEY, "
                    + "username VARCHAR(255) NOT NULL UNIQUE, "
                    + "password_hash VARCHAR(255) NOT NULL, "
                    + "created_at TIMESTAMP NOT NULL)");
        } catch (SQLException e) {
            throw new IllegalStateException("failed to initialize mcvpn database schema", e);
        }
    }

    /** SQL column type for a fixed-length binary column of {@code lengthBytes} bytes (e.g. {@code BYTEA}, {@code VARBINARY(16)}). */
    protected abstract String binaryColumnType(int lengthBytes);

    /** SQL column type for the generated {@code UUID.randomUUID().toString()} id columns (e.g. {@code UUID}, {@code CHAR(36)}). */
    protected abstract String idColumnType();

    private <T> CompletableFuture<T> supply(SqlSupplier<T> supplier) {
        return CompletableFuture.supplyAsync(() -> {
            try (Connection c = dataSource.getConnection()) {
                return supplier.get(c);
            } catch (SQLException e) {
                throw new RuntimeException(e);
            }
        }, dbExecutor);
    }

    @FunctionalInterface
    private interface SqlSupplier<T> {
        T get(Connection c) throws SQLException;
    }

    @Override
    public CompletableFuture<Optional<VpnUser>> findVpnUserByKeyId(byte[] keyId) {
        return supply(c -> {
            try (PreparedStatement ps = c.prepareStatement(
                    "SELECT id, key_id, secret, label, enabled, created_at, last_seen_at FROM vpn_users WHERE key_id = ?")) {
                ps.setBytes(1, keyId);
                try (ResultSet rs = ps.executeQuery()) {
                    return rs.next() ? Optional.of(readVpnUser(rs)) : Optional.empty();
                }
            }
        });
    }

    @Override
    public CompletableFuture<List<VpnUser>> listVpnUsers() {
        return supply(c -> {
            List<VpnUser> result = new ArrayList<>();
            try (PreparedStatement ps = c.prepareStatement(
                    "SELECT id, key_id, secret, label, enabled, created_at, last_seen_at FROM vpn_users");
                    ResultSet rs = ps.executeQuery()) {
                while (rs.next()) {
                    result.add(readVpnUser(rs));
                }
            }
            return result;
        });
    }

    @Override
    public CompletableFuture<VpnUser> createVpnUser(String label) {
        return CompletableFuture.supplyAsync(() -> {
            SQLException lastFailure = null;
            for (int attempt = 0; attempt < 3; attempt++) {
                byte[] keyId = randomBytes(16);
                byte[] secret = randomBytes(32);
                String id = UUID.randomUUID().toString();
                Instant createdAt = Instant.now();
                try (Connection c = dataSource.getConnection();
                        PreparedStatement ps = c.prepareStatement(
                                "INSERT INTO vpn_users (id, key_id, secret, label, enabled, created_at, last_seen_at) "
                                        + "VALUES (?, ?, ?, ?, ?, ?, NULL)")) {
                    ps.setString(1, id);
                    ps.setBytes(2, keyId);
                    ps.setBytes(3, secret);
                    ps.setString(4, label);
                    ps.setBoolean(5, true);
                    ps.setTimestamp(6, Timestamp.from(createdAt));
                    ps.executeUpdate();
                    return new VpnUser(id, keyId, secret, label, true, createdAt, null);
                } catch (SQLException e) {
                    lastFailure = e;
                    // Astronomically rare unique-constraint collision on
                    // key_id; retry with a fresh random keyId.
                }
            }
            throw new RuntimeException("failed to create vpn user after 3 attempts", lastFailure);
        }, dbExecutor);
    }

    @Override
    public CompletableFuture<Void> setVpnUserEnabled(String id, boolean enabled) {
        return supply(c -> {
            try (PreparedStatement ps = c.prepareStatement("UPDATE vpn_users SET enabled = ? WHERE id = ?")) {
                ps.setBoolean(1, enabled);
                ps.setString(2, id);
                ps.executeUpdate();
            }
            return null;
        });
    }

    @Override
    public CompletableFuture<VpnUser> rotateVpnUserSecret(String id) {
        return supply(c -> {
            byte[] secret = randomBytes(32);
            try (PreparedStatement ps = c.prepareStatement("UPDATE vpn_users SET secret = ? WHERE id = ?")) {
                ps.setBytes(1, secret);
                ps.setString(2, id);
                ps.executeUpdate();
            }
            try (PreparedStatement ps = c.prepareStatement(
                    "SELECT id, key_id, secret, label, enabled, created_at, last_seen_at FROM vpn_users WHERE id = ?")) {
                ps.setString(1, id);
                try (ResultSet rs = ps.executeQuery()) {
                    if (!rs.next()) {
                        throw new SQLException("no such vpn user: " + id);
                    }
                    return readVpnUser(rs);
                }
            }
        });
    }

    @Override
    public CompletableFuture<Void> deleteVpnUser(String id) {
        return supply(c -> {
            try (PreparedStatement ps = c.prepareStatement("DELETE FROM vpn_users WHERE id = ?")) {
                ps.setString(1, id);
                ps.executeUpdate();
            }
            return null;
        });
    }

    @Override
    public CompletableFuture<Void> touchLastSeen(String id) {
        return supply(c -> {
            try (PreparedStatement ps = c.prepareStatement("UPDATE vpn_users SET last_seen_at = ? WHERE id = ?")) {
                ps.setTimestamp(1, Timestamp.from(Instant.now()));
                ps.setString(2, id);
                ps.executeUpdate();
            }
            return null;
        });
    }

    @Override
    public CompletableFuture<Optional<AdminUser>> findAdminByUsername(String username) {
        return supply(c -> {
            try (PreparedStatement ps = c.prepareStatement(
                    "SELECT id, username, password_hash, created_at FROM admin_users WHERE username = ?")) {
                ps.setString(1, username);
                try (ResultSet rs = ps.executeQuery()) {
                    return rs.next() ? Optional.of(readAdminUser(rs)) : Optional.empty();
                }
            }
        });
    }

    @Override
    public CompletableFuture<Optional<AdminUser>> findAdminById(String id) {
        return supply(c -> {
            try (PreparedStatement ps = c.prepareStatement(
                    "SELECT id, username, password_hash, created_at FROM admin_users WHERE id = ?")) {
                ps.setString(1, id);
                try (ResultSet rs = ps.executeQuery()) {
                    return rs.next() ? Optional.of(readAdminUser(rs)) : Optional.empty();
                }
            }
        });
    }

    @Override
    public CompletableFuture<List<AdminUser>> listAdmins() {
        return supply(c -> {
            List<AdminUser> result = new ArrayList<>();
            try (PreparedStatement ps = c.prepareStatement("SELECT id, username, password_hash, created_at FROM admin_users");
                    ResultSet rs = ps.executeQuery()) {
                while (rs.next()) {
                    result.add(readAdminUser(rs));
                }
            }
            return result;
        });
    }

    @Override
    public CompletableFuture<AdminUser> createAdmin(String username, String passwordHash) {
        return supply(c -> {
            String id = UUID.randomUUID().toString();
            Instant createdAt = Instant.now();
            try (PreparedStatement ps = c.prepareStatement(
                    "INSERT INTO admin_users (id, username, password_hash, created_at) VALUES (?, ?, ?, ?)")) {
                ps.setString(1, id);
                ps.setString(2, username);
                ps.setString(3, passwordHash);
                ps.setTimestamp(4, Timestamp.from(createdAt));
                ps.executeUpdate();
            }
            return new AdminUser(id, username, passwordHash, createdAt);
        });
    }

    @Override
    public CompletableFuture<Void> updateAdminPassword(String id, String newPasswordHash) {
        return supply(c -> {
            try (PreparedStatement ps = c.prepareStatement("UPDATE admin_users SET password_hash = ? WHERE id = ?")) {
                ps.setString(1, newPasswordHash);
                ps.setString(2, id);
                ps.executeUpdate();
            }
            return null;
        });
    }

    @Override
    public void close() {
        dataSource.close();
    }

    private static VpnUser readVpnUser(ResultSet rs) throws SQLException {
        Timestamp lastSeen = rs.getTimestamp("last_seen_at");
        return new VpnUser(
                rs.getString("id"),
                rs.getBytes("key_id"),
                rs.getBytes("secret"),
                rs.getString("label"),
                rs.getBoolean("enabled"),
                rs.getTimestamp("created_at").toInstant(),
                lastSeen == null ? null : lastSeen.toInstant());
    }

    private static AdminUser readAdminUser(ResultSet rs) throws SQLException {
        return new AdminUser(
                rs.getString("id"),
                rs.getString("username"),
                rs.getString("password_hash"),
                rs.getTimestamp("created_at").toInstant());
    }

    private byte[] randomBytes(int len) {
        byte[] b = new byte[len];
        random.nextBytes(b);
        return b;
    }
}

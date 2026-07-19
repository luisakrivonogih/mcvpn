package dev.mcvpn.plugin.store;

import java.security.SecureRandom;
import java.time.Instant;
import java.util.ArrayList;
import java.util.List;
import java.util.Optional;
import java.util.UUID;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.ExecutorService;

import org.bson.Document;
import org.bson.types.Binary;

import com.mongodb.MongoWriteException;
import com.mongodb.client.MongoClient;
import com.mongodb.client.MongoClients;
import com.mongodb.client.MongoCollection;
import com.mongodb.client.MongoDatabase;
import com.mongodb.client.model.IndexOptions;
import com.mongodb.client.model.Indexes;
import com.mongodb.client.model.Updates;

/**
 * MongoDB-backed {@link UserStore} using the synchronous driver. All driver
 * calls are blocking, so every method is wrapped in
 * {@link CompletableFuture#supplyAsync(java.util.function.Supplier, java.util.concurrent.Executor)}
 * on the shared {@code dbExecutor}. Unique indexes on {@code keyId} and
 * {@code username} are ensured once, synchronously, at construction.
 */
public final class MongoUserStore implements UserStore {

    private static final String VPN_USERS = "vpn_users";
    private static final String ADMIN_USERS = "admin_users";

    private final MongoClient client;
    private final MongoDatabase db;
    private final ExecutorService dbExecutor;
    private final SecureRandom random = new SecureRandom();

    public MongoUserStore(String connectionString, String databaseName, ExecutorService dbExecutor) {
        this.client = MongoClients.create(connectionString);
        this.db = client.getDatabase(databaseName);
        this.dbExecutor = dbExecutor;

        db.getCollection(VPN_USERS).createIndex(Indexes.ascending("keyId"), new IndexOptions().unique(true));
        db.getCollection(ADMIN_USERS).createIndex(Indexes.ascending("username"), new IndexOptions().unique(true));
    }

    private MongoCollection<Document> vpnUsers() {
        return db.getCollection(VPN_USERS);
    }

    private MongoCollection<Document> adminUsers() {
        return db.getCollection(ADMIN_USERS);
    }

    private <T> CompletableFuture<T> async(java.util.function.Supplier<T> supplier) {
        return CompletableFuture.supplyAsync(supplier, dbExecutor);
    }

    @Override
    public CompletableFuture<Optional<VpnUser>> findVpnUserByKeyId(byte[] keyId) {
        return async(() -> {
            Document doc = vpnUsers().find(new Document("keyId", new Binary(keyId))).first();
            return Optional.ofNullable(doc).map(MongoUserStore::readVpnUser);
        });
    }

    @Override
    public CompletableFuture<List<VpnUser>> listVpnUsers() {
        return async(() -> {
            List<VpnUser> result = new ArrayList<>();
            for (Document doc : vpnUsers().find()) {
                result.add(readVpnUser(doc));
            }
            return result;
        });
    }

    @Override
    public CompletableFuture<VpnUser> createVpnUser(String label) {
        return async(() -> {
            RuntimeException lastFailure = null;
            for (int attempt = 0; attempt < 3; attempt++) {
                byte[] keyId = randomBytes(16);
                byte[] secret = randomBytes(32);
                String id = UUID.randomUUID().toString();
                Instant createdAt = Instant.now();
                Document doc = new Document("_id", id)
                        .append("keyId", new Binary(keyId))
                        .append("secret", new Binary(secret))
                        .append("label", label)
                        .append("enabled", true)
                        .append("createdAt", createdAt.toString())
                        .append("lastSeenAt", null);
                try {
                    vpnUsers().insertOne(doc);
                    return new VpnUser(id, keyId, secret, label, true, createdAt, null);
                } catch (MongoWriteException e) {
                    lastFailure = e; // unique-constraint collision on keyId; retry
                }
            }
            throw new IllegalStateException("failed to create vpn user after 3 attempts", lastFailure);
        });
    }

    @Override
    public CompletableFuture<Void> setVpnUserEnabled(String id, boolean enabled) {
        return async(() -> {
            vpnUsers().updateOne(new Document("_id", id), Updates.set("enabled", enabled));
            return null;
        });
    }

    @Override
    public CompletableFuture<VpnUser> rotateVpnUserSecret(String id) {
        return async(() -> {
            byte[] secret = randomBytes(32);
            vpnUsers().updateOne(new Document("_id", id), Updates.set("secret", new Binary(secret)));
            Document doc = vpnUsers().find(new Document("_id", id)).first();
            if (doc == null) {
                throw new java.util.NoSuchElementException("no such vpn user: " + id);
            }
            return readVpnUser(doc);
        });
    }

    @Override
    public CompletableFuture<Void> deleteVpnUser(String id) {
        return async(() -> {
            vpnUsers().deleteOne(new Document("_id", id));
            return null;
        });
    }

    @Override
    public CompletableFuture<Void> touchLastSeen(String id) {
        return async(() -> {
            vpnUsers().updateOne(new Document("_id", id), Updates.set("lastSeenAt", Instant.now().toString()));
            return null;
        });
    }

    @Override
    public CompletableFuture<Optional<AdminUser>> findAdminByUsername(String username) {
        return async(() -> {
            Document doc = adminUsers().find(new Document("username", username)).first();
            return Optional.ofNullable(doc).map(MongoUserStore::readAdminUser);
        });
    }

    @Override
    public CompletableFuture<Optional<AdminUser>> findAdminById(String id) {
        return async(() -> {
            Document doc = adminUsers().find(new Document("_id", id)).first();
            return Optional.ofNullable(doc).map(MongoUserStore::readAdminUser);
        });
    }

    @Override
    public CompletableFuture<List<AdminUser>> listAdmins() {
        return async(() -> {
            List<AdminUser> result = new ArrayList<>();
            for (Document doc : adminUsers().find()) {
                result.add(readAdminUser(doc));
            }
            return result;
        });
    }

    @Override
    public CompletableFuture<AdminUser> createAdmin(String username, String passwordHash) {
        return async(() -> {
            String id = UUID.randomUUID().toString();
            Instant createdAt = Instant.now();
            Document doc = new Document("_id", id)
                    .append("username", username)
                    .append("passwordHash", passwordHash)
                    .append("createdAt", createdAt.toString());
            adminUsers().insertOne(doc);
            return new AdminUser(id, username, passwordHash, createdAt);
        });
    }

    @Override
    public CompletableFuture<Void> updateAdminPassword(String id, String newPasswordHash) {
        return async(() -> {
            adminUsers().updateOne(new Document("_id", id), Updates.set("passwordHash", newPasswordHash));
            return null;
        });
    }

    @Override
    public void close() {
        client.close();
    }

    private static VpnUser readVpnUser(Document doc) {
        String lastSeenAt = doc.getString("lastSeenAt");
        return new VpnUser(
                doc.getString("_id"),
                doc.get("keyId", Binary.class).getData(),
                doc.get("secret", Binary.class).getData(),
                doc.getString("label"),
                doc.getBoolean("enabled"),
                Instant.parse(doc.getString("createdAt")),
                lastSeenAt == null ? null : Instant.parse(lastSeenAt));
    }

    private static AdminUser readAdminUser(Document doc) {
        return new AdminUser(
                doc.getString("_id"),
                doc.getString("username"),
                doc.getString("passwordHash"),
                Instant.parse(doc.getString("createdAt")));
    }

    private byte[] randomBytes(int len) {
        byte[] b = new byte[len];
        random.nextBytes(b);
        return b;
    }
}

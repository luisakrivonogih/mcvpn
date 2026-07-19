package dev.mcvpn.plugin.http;

import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.InetSocketAddress;
import java.nio.charset.StandardCharsets;
import java.security.SecureRandom;
import java.time.Duration;
import java.time.Instant;
import java.util.ArrayList;
import java.util.Base64;
import java.util.HexFormat;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.CompletionException;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.ThreadFactory;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.logging.Logger;

import com.google.gson.Gson;
import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpServer;

import dev.mcvpn.plugin.store.AdminUser;
import dev.mcvpn.plugin.store.UserStore;
import dev.mcvpn.plugin.store.VpnUser;

/**
 * Embedded admin HTTP API, called server-to-server by the (separately
 * built) SvelteKit admin panel's backend -- never directly by a browser,
 * so there are deliberately no CORS headers anywhere here. Meant to be
 * bound to loopback only; see the {@code admin-api:} section of
 * {@code config.yml} for the trust-model rationale.
 *
 * Built on the JDK's built-in {@link HttpServer} (no extra dependency for
 * the transport) with {@link Gson} for request/response JSON bodies.
 * Sessions are opaque bearer tokens kept in memory only ({@link #sessions});
 * they don't survive a restart, which is fine since the panel just prompts
 * for login again.
 */
public final class AdminHttpServer {

    private static final Duration SESSION_TTL = Duration.ofHours(12);
    private static final HexFormat HEX = HexFormat.of();

    private final Logger logger;
    private final UserStore userStore;
    private final OnlineStatus onlineStatus;
    private final Gson gson = new Gson();
    private final SecureRandom random = new SecureRandom();
    private final Map<String, Session> sessions = new ConcurrentHashMap<>();

    private HttpServer server;
    private ExecutorService httpExecutor;

    public AdminHttpServer(Logger logger, UserStore userStore, OnlineStatus onlineStatus) {
        this.logger = logger;
        this.userStore = userStore;
        this.onlineStatus = onlineStatus;
    }

    /** Reports whether a vpn user (by store id) currently has an authenticated tunnel connection. */
    @FunctionalInterface
    public interface OnlineStatus {
        boolean isOnline(String vpnUserId);
    }

    public void start(String bind, int port) throws IOException {
        server = HttpServer.create(new InetSocketAddress(bind, port), 0);
        server.createContext("/api/login", guard(this::handleLogin, false));
        server.createContext("/api/logout", guard(this::handleLogout, true));
        server.createContext("/api/vpn-users", guard(this::handleVpnUsers, true));
        server.createContext("/api/admins", guard(this::handleAdmins, true));

        AtomicInteger counter = new AtomicInteger(1);
        ThreadFactory threadFactory = r -> {
            Thread t = new Thread(r, "mcvpn-http-" + counter.getAndIncrement());
            t.setDaemon(true);
            return t;
        };
        httpExecutor = Executors.newFixedThreadPool(4, threadFactory);
        server.setExecutor(httpExecutor);
        server.start();
    }

    public void stop() {
        if (server != null) {
            server.stop(0);
        }
        if (httpExecutor != null) {
            httpExecutor.shutdown();
        }
    }

    // --- Routing / auth wrapper ---

    private interface Handler {
        void handle(HttpExchange exchange, Session session) throws IOException;
    }

    /**
     * Wraps a handler with: exception -&gt; 500 JSON, and (unless
     * {@code requireAuth} is false, i.e. only {@code /api/login}) bearer
     * token validation -&gt; 401 JSON. Every successful authenticated
     * request refreshes the session's sliding expiry.
     */
    private com.sun.net.httpserver.HttpHandler guard(Handler handler, boolean requireAuth) {
        return exchange -> {
            try {
                Session session = null;
                if (requireAuth) {
                    session = authenticate(exchange);
                    if (session == null) {
                        writeJson(exchange, 401, Map.of("error", "unauthorized"));
                        return;
                    }
                    session.expiresAt = Instant.now().plus(SESSION_TTL);
                }
                handler.handle(exchange, session);
            } catch (Exception e) {
                logger.warning("admin http api error handling " + exchange.getRequestURI() + ": " + e);
                try {
                    writeJson(exchange, 500, Map.of("error", "internal error"));
                } catch (IOException ignored) {
                    // Connection likely already gone; nothing more to do.
                }
            } finally {
                exchange.close();
            }
        };
    }

    private Session authenticate(HttpExchange exchange) {
        String header = exchange.getRequestHeaders().getFirst("Authorization");
        if (header == null || !header.startsWith("Bearer ")) {
            return null;
        }
        String token = header.substring("Bearer ".length()).trim();
        Session session = sessions.get(token);
        if (session == null) {
            return null;
        }
        if (session.expiresAt.isBefore(Instant.now())) {
            sessions.remove(token);
            return null;
        }
        return session;
    }

    // --- /api/login, /api/logout ---

    private void handleLogin(HttpExchange exchange, Session unused) throws IOException {
        if (!"POST".equals(exchange.getRequestMethod())) {
            writeJson(exchange, 404, Map.of("error", "not found"));
            return;
        }
        Map<?, ?> body = readJsonBody(exchange);
        String username = body == null ? null : asString(body.get("username"));
        String password = body == null ? null : asString(body.get("password"));
        if (username == null || password == null) {
            writeJson(exchange, 401, Map.of("error", "invalid credentials"));
            return;
        }

        Optional<AdminUser> maybeAdmin = await(userStore.findAdminByUsername(username));
        if (maybeAdmin.isEmpty() || !PasswordHashing.verify(password, maybeAdmin.get().passwordHash())) {
            writeJson(exchange, 401, Map.of("error", "invalid credentials"));
            return;
        }

        byte[] tokenBytes = new byte[32];
        random.nextBytes(tokenBytes);
        String token = Base64.getUrlEncoder().withoutPadding().encodeToString(tokenBytes);
        Instant expiresAt = Instant.now().plus(SESSION_TTL);
        sessions.put(token, new Session(maybeAdmin.get().id(), expiresAt));

        writeJson(exchange, 200, Map.of("token", token, "expiresAt", expiresAt.toString()));
    }

    private void handleLogout(HttpExchange exchange, Session session) throws IOException {
        String header = exchange.getRequestHeaders().getFirst("Authorization");
        if (header != null && header.startsWith("Bearer ")) {
            sessions.remove(header.substring("Bearer ".length()).trim());
        }
        exchange.sendResponseHeaders(204, -1);
    }

    // --- /api/vpn-users[/{id}[/rotate]] ---

    private void handleVpnUsers(HttpExchange exchange, Session session) throws IOException {
        String[] segments = pathSegments(exchange);
        String method = exchange.getRequestMethod();

        if (segments.length == 2) { // /api/vpn-users
            if ("GET".equals(method)) {
                List<VpnUser> users = await(userStore.listVpnUsers());
                List<Object> body = new ArrayList<>();
                for (VpnUser u : users) {
                    body.add(vpnUserJson(u, false));
                }
                writeJson(exchange, 200, body);
                return;
            }
            if ("POST".equals(method)) {
                Map<?, ?> body = readJsonBody(exchange);
                String label = body == null ? null : asString(body.get("label"));
                if (label == null || label.isBlank()) {
                    writeJson(exchange, 400, Map.of("error", "label is required"));
                    return;
                }
                VpnUser created = await(userStore.createVpnUser(label));
                writeJson(exchange, 201, vpnUserJson(created, true));
                return;
            }
        } else if (segments.length == 3) { // /api/vpn-users/{id}
            String id = segments[2];
            if ("PATCH".equals(method)) {
                Map<?, ?> body = readJsonBody(exchange);
                Object enabledRaw = body == null ? null : body.get("enabled");
                if (!(enabledRaw instanceof Boolean enabled)) {
                    writeJson(exchange, 400, Map.of("error", "enabled (boolean) is required"));
                    return;
                }
                await(userStore.setVpnUserEnabled(id, enabled));
                VpnUser updated = findVpnUserOrNull(id);
                if (updated == null) {
                    writeJson(exchange, 404, Map.of("error", "not found"));
                    return;
                }
                writeJson(exchange, 200, vpnUserJson(updated, false));
                return;
            }
            if ("DELETE".equals(method)) {
                await(userStore.deleteVpnUser(id));
                exchange.sendResponseHeaders(204, -1);
                return;
            }
        } else if (segments.length == 4 && "rotate".equals(segments[3])) { // /api/vpn-users/{id}/rotate
            String id = segments[2];
            if ("POST".equals(method)) {
                VpnUser rotated = await(userStore.rotateVpnUserSecret(id));
                writeJson(exchange, 200, vpnUserJson(rotated, true));
                return;
            }
        }

        writeJson(exchange, 404, Map.of("error", "not found"));
    }

    private VpnUser findVpnUserOrNull(String id) {
        List<VpnUser> all = await(userStore.listVpnUsers());
        for (VpnUser u : all) {
            if (u.id().equals(id)) {
                return u;
            }
        }
        return null;
    }

    private Map<String, Object> vpnUserJson(VpnUser u, boolean includeSecret) {
        Map<String, Object> json = new LinkedHashMap<>();
        json.put("id", u.id());
        json.put("keyId", HEX.formatHex(u.keyId()));
        json.put("label", u.label());
        json.put("enabled", u.enabled());
        json.put("online", onlineStatus.isOnline(u.id()));
        json.put("createdAt", u.createdAt().toString());
        json.put("lastSeenAt", u.lastSeenAt() == null ? null : u.lastSeenAt().toString());
        if (includeSecret) {
            json.put("secret", HEX.formatHex(u.secret()));
        }
        return json;
    }

    // --- /api/admins ---

    private void handleAdmins(HttpExchange exchange, Session session) throws IOException {
        String[] segments = pathSegments(exchange);
        String method = exchange.getRequestMethod();

        if (segments.length == 2) { // /api/admins
            if ("GET".equals(method)) {
                List<AdminUser> admins = await(userStore.listAdmins());
                List<Object> body = new ArrayList<>();
                for (AdminUser a : admins) {
                    body.add(adminJson(a));
                }
                writeJson(exchange, 200, body);
                return;
            }
            if ("POST".equals(method)) {
                Map<?, ?> body = readJsonBody(exchange);
                String username = body == null ? null : asString(body.get("username"));
                String password = body == null ? null : asString(body.get("password"));
                if (username == null || username.isBlank() || password == null || password.isEmpty()) {
                    writeJson(exchange, 400, Map.of("error", "username and password are required"));
                    return;
                }
                AdminUser created = await(userStore.createAdmin(username, PasswordHashing.hash(password)));
                writeJson(exchange, 201, adminJson(created));
                return;
            }
        } else if (segments.length == 3 && "me".equals(segments[2])) { // /api/admins/me
            if ("GET".equals(method)) {
                Optional<AdminUser> self = await(userStore.findAdminById(session.adminId));
                if (self.isEmpty()) {
                    writeJson(exchange, 404, Map.of("error", "not found"));
                    return;
                }
                writeJson(exchange, 200, adminJson(self.get()));
                return;
            }
        } else if (segments.length == 4 && "me".equals(segments[2]) && "password".equals(segments[3])) {
            if ("PATCH".equals(method)) {
                handleChangeOwnPassword(exchange, session);
                return;
            }
        }

        writeJson(exchange, 404, Map.of("error", "not found"));
    }

    private void handleChangeOwnPassword(HttpExchange exchange, Session session) throws IOException {
        Map<?, ?> body = readJsonBody(exchange);
        String currentPassword = body == null ? null : asString(body.get("currentPassword"));
        String newPassword = body == null ? null : asString(body.get("newPassword"));
        if (currentPassword == null || newPassword == null || newPassword.isEmpty()) {
            writeJson(exchange, 400, Map.of("error", "currentPassword and newPassword are required"));
            return;
        }

        Optional<AdminUser> maybeSelf = await(userStore.findAdminById(session.adminId));
        if (maybeSelf.isEmpty()) {
            writeJson(exchange, 404, Map.of("error", "not found"));
            return;
        }
        AdminUser self = maybeSelf.get();
        if (!PasswordHashing.verify(currentPassword, self.passwordHash())) {
            writeJson(exchange, 401, Map.of("error", "current password is incorrect"));
            return;
        }

        await(userStore.updateAdminPassword(self.id(), PasswordHashing.hash(newPassword)));
        exchange.sendResponseHeaders(204, -1);
    }

    private static Map<String, Object> adminJson(AdminUser a) {
        Map<String, Object> json = new LinkedHashMap<>();
        json.put("id", a.id());
        json.put("username", a.username());
        json.put("createdAt", a.createdAt().toString());
        return json;
    }

    // --- helpers ---

    private static String[] pathSegments(HttpExchange exchange) {
        String path = exchange.getRequestURI().getPath();
        List<String> parts = new ArrayList<>();
        for (String s : path.split("/")) {
            if (!s.isEmpty()) {
                parts.add(s);
            }
        }
        return parts.toArray(new String[0]);
    }

    private Map<?, ?> readJsonBody(HttpExchange exchange) throws IOException {
        try (InputStream in = exchange.getRequestBody()) {
            byte[] bytes = in.readAllBytes();
            if (bytes.length == 0) {
                return null;
            }
            return gson.fromJson(new String(bytes, StandardCharsets.UTF_8), Map.class);
        }
    }

    private void writeJson(HttpExchange exchange, int status, Object body) throws IOException {
        byte[] bytes = gson.toJson(body).getBytes(StandardCharsets.UTF_8);
        exchange.getResponseHeaders().set("Content-Type", "application/json; charset=utf-8");
        exchange.sendResponseHeaders(status, bytes.length);
        try (OutputStream out = exchange.getResponseBody()) {
            out.write(bytes);
        }
    }

    private static String asString(Object o) {
        return o instanceof String s ? s : null;
    }

    /** Blocks the calling (HTTP-executor, never Bukkit-main) thread for the store call's result. */
    private static <T> T await(CompletableFuture<T> future) {
        try {
            return future.join();
        } catch (CompletionException e) {
            throw (e.getCause() instanceof RuntimeException re) ? re : new RuntimeException(e.getCause());
        }
    }

    private static final class Session {
        final String adminId;
        volatile Instant expiresAt;

        Session(String adminId, Instant expiresAt) {
            this.adminId = adminId;
            this.expiresAt = expiresAt;
        }
    }
}

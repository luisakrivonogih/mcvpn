package dev.mcvpn.plugin;

import java.io.IOException;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.ExecutionException;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.TimeoutException;

import com.destroystokyo.paper.event.server.PaperServerListPingEvent;
import com.destroystokyo.paper.profile.PlayerProfile;

import org.bukkit.entity.Player;
import org.bukkit.event.EventHandler;
import org.bukkit.event.Listener;
import org.bukkit.event.player.PlayerJoinEvent;
import org.bukkit.event.player.PlayerQuitEvent;
import org.bukkit.plugin.java.JavaPlugin;
import org.bukkit.plugin.messaging.PluginMessageListener;

import dev.mcvpn.plugin.http.AdminHttpServer;
import dev.mcvpn.plugin.http.PasswordHashing;
import dev.mcvpn.plugin.store.AdminUser;
import dev.mcvpn.plugin.store.UserStore;
import dev.mcvpn.plugin.store.UserStoreFactory;

/**
 * Server side of the mcvpn transport. One persistent Minecraft connection
 * per player multiplexes many logical proxy streams (see {@link
 * PlayerMultiplex} / {@link StreamState}), all authenticated and encrypted
 * the same way as the client's {@code tunnel::multiplex} -- see {@link
 * TunnelCrypto} for the wire format both sides must agree on.
 *
 * Every plugin-message payload on our channel is an opaque encrypted
 * envelope; nothing here ever looks at cleartext beyond the leading
 * connection id. Anything that fails to authenticate is silently dropped,
 * never kicked or logged loudly: a party that doesn't know the secret
 * should see exactly what they'd see probing a real server that ignores an
 * unrecognized plugin channel.
 */
public final class McvpnPlugin extends JavaPlugin implements PluginMessageListener, Listener {

    private static final String DEFAULT_ADMIN_USERNAME = "admin";
    private static final String DEFAULT_ADMIN_PASSWORD = "admin";
    private static final long BOOTSTRAP_TIMEOUT_SECONDS = 10;

    private final Map<UUID, PlayerMultiplex> connections = new ConcurrentHashMap<>();

    private String channel;
    private boolean silenceJoinQuitMessages;
    private UserStore userStore;
    private AdminHttpServer adminHttpServer;

    @Override
    public void onEnable() {
        saveDefaultConfig();
        channel = getConfig().getString("channel", "mcvpn:tunnel");
        silenceJoinQuitMessages = getConfig().getBoolean("silence-join-quit-messages", true);

        userStore = UserStoreFactory.create(getConfig());
        if ("memory".equalsIgnoreCase(getConfig().getString("database.type", "memory"))) {
            getLogger().warning(
                    "database.type is still 'memory' — every per-user tunnel credential and admin "
                            + "account lives only in this server's RAM and is lost on restart. Configure "
                            + "a real backend under the database: section of plugins/McvpnPlugin/config.yml "
                            + "before exposing this server or its admin API anywhere but localhost.");
        }

        // Bootstrap a default admin account when none exist yet, so a fresh
        // install always has a way to log into the admin API -- and keep
        // warning loudly on every restart for as long as that default
        // account is still around. Must happen before the admin HTTP server
        // (below) starts accepting requests, so there's never a window
        // where the API is up with zero admins and no way to log in.
        bootstrapDefaultAdmin();

        getServer().getMessenger().registerIncomingPluginChannel(this, channel, this);
        getServer().getMessenger().registerOutgoingPluginChannel(this, channel);
        getServer().getPluginManager().registerEvents(this, this);

        // PluginCommand.execute() checks the command's plugin.yml permission
        // -- mcvpn.console, default: false -- before onCommand() ever runs.
        // Console counts as "op" for permission purposes, but a default:
        // false permission returns false unconditionally regardless of op
        // status, so without this attachment the console itself gets
        // rejected at the permission check and never reaches McvpnCommand's
        // own console-only enforcement below.
        getServer().getConsoleSender().addAttachment(this, "mcvpn.console", true);

        McvpnCommand commandExecutor = new McvpnCommand(this, userStore);
        var mcvpnCommand = getCommand("mcvpn");
        if (mcvpnCommand != null) {
            mcvpnCommand.setExecutor(commandExecutor);
        }

        // Overrides vanilla /list (Bukkit lets a plugin's plugin.yml command
        // take over a vanilla command by the same name) so it excludes
        // active tunnel connections the same way the tab list and server
        // list ping already do -- otherwise an op running /list, including
        // from console, would still see them by name.
        var listCommand = getCommand("list");
        if (listCommand != null) {
            listCommand.setExecutor(new HiddenListCommand(this));
        }

        if (getConfig().getBoolean("admin-api.enabled", true)) {
            String bind = getConfig().getString("admin-api.bind", "127.0.0.1");
            int port = getConfig().getInt("admin-api.port", 8081);
            adminHttpServer = new AdminHttpServer(getLogger(), userStore, this::isVpnUserOnline);
            try {
                adminHttpServer.start(bind, port);
                getLogger().info("admin http api listening on " + bind + ":" + port);
            } catch (IOException e) {
                getLogger().severe("failed to start admin http api on " + bind + ":" + port + ": " + e.getMessage());
                adminHttpServer = null;
            }
        }

        getLogger().info("tunnel channel '" + channel + "' registered");
    }

    /**
     * Ensures there's always at least one way to log into the admin HTTP
     * API. If no admin accounts exist at all, creates a default
     * {@code admin}/{@code admin} account. Then, regardless of whether it
     * was just created or has lingered from a previous start, loudly warns
     * on every single startup for as long as an account named exactly
     * {@code admin} still exists -- this is a standing security risk, not a
     * one-time event, so the warning is never shown just once.
     */
    private void bootstrapDefaultAdmin() {
        try {
            List<AdminUser> admins = userStore.listAdmins().get(BOOTSTRAP_TIMEOUT_SECONDS, TimeUnit.SECONDS);
            if (admins.isEmpty()) {
                userStore.createAdmin(DEFAULT_ADMIN_USERNAME, PasswordHashing.hash(DEFAULT_ADMIN_PASSWORD))
                        .get(BOOTSTRAP_TIMEOUT_SECONDS, TimeUnit.SECONDS);
            }
        } catch (TimeoutException | ExecutionException e) {
            getLogger().severe("failed to bootstrap default admin account: " + rootMessage(e));
            return;
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            getLogger().severe("interrupted while bootstrapping default admin account");
            return;
        }

        try {
            boolean defaultAdminStillExists = userStore.findAdminByUsername(DEFAULT_ADMIN_USERNAME)
                    .get(BOOTSTRAP_TIMEOUT_SECONDS, TimeUnit.SECONDS)
                    .isPresent();
            if (defaultAdminStillExists) {
                getLogger().warning(
                        "\n"
                                + "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!\n"
                                + "!! ADMIN ACCOUNT 'admin' EXISTS ON THIS SERVER\n"
                                + "!!\n"
                                + "!! Either no admin accounts existed at startup and mcvpn just auto-created\n"
                                + "!! one (username 'admin', password 'admin'), or a previously auto-created\n"
                                + "!! 'admin' account is still around from an earlier start. If you have not\n"
                                + "!! changed its password yet, it is still:\n"
                                + "!!\n"
                                + "!!     username: admin\n"
                                + "!!     password: admin\n"
                                + "!!\n"
                                + "!! Log into the admin API/panel NOW and either change this account's\n"
                                + "!! password or create a new admin account and DELETE this one, before\n"
                                + "!! exposing the admin API beyond localhost. This warning will repeat on\n"
                                + "!! every single restart for as long as an account named 'admin' exists,\n"
                                + "!! whether or not its password has been changed -- delete or rename it\n"
                                + "!! once you have another admin account to log in with.\n"
                                + "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!\n");
            }
        } catch (TimeoutException | ExecutionException e) {
            getLogger().severe("failed to check for default admin account: " + rootMessage(e));
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            getLogger().severe("interrupted while checking for default admin account");
        }
    }

    private static String rootMessage(Throwable t) {
        Throwable cause = t.getCause();
        return cause != null ? cause.getMessage() : t.getMessage();
    }

    @Override
    public void onDisable() {
        connections.values().forEach(PlayerMultiplex::close);
        connections.clear();
        if (adminHttpServer != null) {
            adminHttpServer.stop();
        }
        if (userStore != null) {
            userStore.close();
        }
    }

    @Override
    public void onPluginMessageReceived(String receivedChannel, Player player, byte[] message) {
        if (!channel.equals(receivedChannel)) {
            return;
        }
        connections
                .computeIfAbsent(player.getUniqueId(), id -> new PlayerMultiplex(this, player, channel, userStore))
                .handleEnvelope(message);
    }

    @EventHandler
    public void onPlayerJoin(PlayerJoinEvent event) {
        if (silenceJoinQuitMessages) {
            event.setJoinMessage(null);
        }

        // A newly joined real player shouldn't see any already-active
        // tunnel "players" in their tab list, and vice versa. Only
        // reciprocally hide connections that actually authenticated --
        // never react visibly to a bare connection attempt.
        Player joined = event.getPlayer();
        for (PlayerMultiplex connection : connections.values()) {
            if (!connection.isActive()) {
                continue;
            }
            Player tunnelPlayer = connection.player();
            if (!tunnelPlayer.equals(joined) && tunnelPlayer.isOnline()) {
                joined.hidePlayer(this, tunnelPlayer);
                tunnelPlayer.hidePlayer(this, joined);
            }
        }
    }

    @EventHandler
    public void onPlayerQuit(PlayerQuitEvent event) {
        if (silenceJoinQuitMessages) {
            event.setQuitMessage(null);
        }
        PlayerMultiplex connection = connections.remove(event.getPlayer().getUniqueId());
        if (connection != null) {
            connection.close();
        }
    }

    /**
     * Strips active tunnel connections out of the unauthenticated server
     * list ping (MOTD): both the player-count and the name sample. Unlike
     * the tab list (hidden per already-online-player via
     * {@link #onPlayerJoin}), a list ping needs no prior connection at all
     * -- anyone can send one -- so this is the other half of not leaking a
     * tunnel account's existence to a network observer.
     */
    @EventHandler
    public void onServerListPing(PaperServerListPingEvent event) {
        Set<UUID> tunnelPlayerIds = activeTunnelPlayerIds();
        if (tunnelPlayerIds.isEmpty()) {
            return;
        }
        event.getPlayerSample().removeIf(profile -> tunnelPlayerIds.contains(profile.getId()));
        event.setNumPlayers(Math.max(0, event.getNumPlayers() - tunnelPlayerIds.size()));
    }

    /** Store ids of active tunnel connections; also used by {@link HiddenListCommand} to filter {@code /list}. */
    Set<UUID> activeTunnelPlayerIds() {
        Set<UUID> ids = new HashSet<>();
        for (Map.Entry<UUID, PlayerMultiplex> entry : connections.entrySet()) {
            if (entry.getValue().isActive()) {
                ids.add(entry.getKey());
            }
        }
        return ids;
    }

    /** Whether the vpn user identified by {@code vpnUserId} currently has an authenticated tunnel connection. */
    boolean isVpnUserOnline(String vpnUserId) {
        for (PlayerMultiplex connection : connections.values()) {
            if (connection.isActive() && vpnUserId.equals(connection.vpnUserId())) {
                return true;
            }
        }
        return false;
    }
}

package dev.mcvpn.plugin;

import java.util.HexFormat;
import java.util.List;
import java.util.concurrent.ExecutionException;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.TimeoutException;

import org.bukkit.command.Command;
import org.bukkit.command.CommandExecutor;
import org.bukkit.command.CommandSender;
import org.bukkit.command.ConsoleCommandSender;

import dev.mcvpn.plugin.http.PasswordHashing;
import dev.mcvpn.plugin.store.AdminUser;
import dev.mcvpn.plugin.store.UserStore;
import dev.mcvpn.plugin.store.VpnUser;

/**
 * Console-only {@code /mcvpn} command: the only way to bootstrap the very
 * first admin account (the admin HTTP API in {@code http.AdminHttpServer}
 * can't create its own first user), plus convenience VPN-user management
 * that doesn't require standing up the SvelteKit panel.
 *
 * No player -- not even an op -- may see or run this. {@code plugin.yml}
 * gates it behind a {@code default: false} permission so it's invisible in
 * tab-completion and {@code /help} for every player. That same
 * {@code default: false} also blocks the console (a {@code default: false}
 * permission is unconditionally false regardless of op status, and console
 * only auto-passes {@code default: op} checks), so {@code McvpnPlugin
 * #onEnable} explicitly attaches the permission to the console sender to
 * compensate. {@link #onCommand} enforces the sender-type check itself too,
 * independent of all of that: a mcvpn player-facing surface that ever
 * revealed this plugin's admin command exists would be exactly the kind of
 * DPI-visible tell the whole project is built to avoid on the wire, so this
 * isn't left to permission configuration alone.
 *
 * {@link UserStore} is entirely asynchronous, but this handler runs on the
 * console thread that issued the command rather than the hot connection
 * path, so blocking briefly with {@code .get(5, TimeUnit.SECONDS)} is an
 * acceptable trade for much simpler code -- unlike {@link PlayerMultiplex},
 * which must never block.
 */
final class McvpnCommand implements CommandExecutor {

    private static final HexFormat HEX = HexFormat.of();
    private static final long TIMEOUT_SECONDS = 5;

    private final UserStore userStore;

    McvpnCommand(McvpnPlugin plugin, UserStore userStore) {
        this.userStore = userStore;
    }

    @Override
    public boolean onCommand(CommandSender sender, Command command, String label, String[] args) {
        if (!(sender instanceof ConsoleCommandSender)) {
            // Mimic vanilla's own "you mistyped a command" wording exactly,
            // rather than a permission-denied message -- the latter would
            // itself confirm a command (and therefore this plugin) exists.
            sender.sendMessage("Unknown command. Type \"/help\" for help.");
            return true;
        }

        if (args.length == 0) {
            sendUsage(sender);
            return true;
        }

        try {
            switch (args[0].toLowerCase(java.util.Locale.ROOT)) {
                case "admin" -> handleAdmin(sender, args);
                case "user" -> handleUser(sender, args);
                default -> sendUsage(sender);
            }
        } catch (TimeoutException e) {
            sender.sendMessage("mcvpn: timed out talking to the user store");
        } catch (ExecutionException e) {
            sender.sendMessage("mcvpn: error: " + rootMessage(e));
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            sender.sendMessage("mcvpn: interrupted");
        }
        return true;
    }

    private void handleAdmin(CommandSender sender, String[] args) throws InterruptedException, ExecutionException, TimeoutException {
        if (args.length >= 4 && "create".equalsIgnoreCase(args[1])) {
            String username = args[2];
            String password = args[3];
            AdminUser created = userStore.createAdmin(username, PasswordHashing.hash(password))
                    .get(TIMEOUT_SECONDS, TimeUnit.SECONDS);
            sender.sendMessage("mcvpn: created admin '" + created.username() + "' (id " + created.id() + ")");
            return;
        }
        if (args.length >= 2 && "list".equalsIgnoreCase(args[1])) {
            List<AdminUser> admins = userStore.listAdmins().get(TIMEOUT_SECONDS, TimeUnit.SECONDS);
            if (admins.isEmpty()) {
                sender.sendMessage("mcvpn: no admins yet");
                return;
            }
            for (AdminUser a : admins) {
                sender.sendMessage("mcvpn: admin " + a.username() + " (id " + a.id() + ")");
            }
            return;
        }
        sendUsage(sender);
    }

    private void handleUser(CommandSender sender, String[] args) throws InterruptedException, ExecutionException, TimeoutException {
        if (args.length >= 2 && "list".equalsIgnoreCase(args[1])) {
            List<VpnUser> users = userStore.listVpnUsers().get(TIMEOUT_SECONDS, TimeUnit.SECONDS);
            if (users.isEmpty()) {
                sender.sendMessage("mcvpn: no vpn users yet");
                return;
            }
            for (VpnUser u : users) {
                sender.sendMessage("mcvpn: " + u.label() + " keyId=" + HEX.formatHex(u.keyId())
                        + " enabled=" + u.enabled());
            }
            return;
        }
        if (args.length >= 3 && "create".equalsIgnoreCase(args[1])) {
            String label = args[2];
            VpnUser created = userStore.createVpnUser(label).get(TIMEOUT_SECONDS, TimeUnit.SECONDS);
            sender.sendMessage("mcvpn: created vpn user '" + created.label() + "'");
            sender.sendMessage("mcvpn: keyId=" + HEX.formatHex(created.keyId()));
            sender.sendMessage("mcvpn: secret=" + HEX.formatHex(created.secret()));
            sender.sendMessage("mcvpn: record these now -- the secret will not be shown again");
            return;
        }
        if (args.length >= 3 && "revoke".equalsIgnoreCase(args[1])) {
            byte[] keyId;
            try {
                keyId = HEX.parseHex(args[2]);
            } catch (IllegalArgumentException e) {
                sender.sendMessage("mcvpn: '" + args[2] + "' is not valid hex");
                return;
            }
            var maybeUser = userStore.findVpnUserByKeyId(keyId).get(TIMEOUT_SECONDS, TimeUnit.SECONDS);
            if (maybeUser.isEmpty()) {
                sender.sendMessage("mcvpn: no vpn user with keyId " + args[2]);
                return;
            }
            // Disabling (rather than deleting) is safer and reversible.
            userStore.setVpnUserEnabled(maybeUser.get().id(), false).get(TIMEOUT_SECONDS, TimeUnit.SECONDS);
            sender.sendMessage("mcvpn: disabled vpn user '" + maybeUser.get().label() + "'");
            return;
        }
        sendUsage(sender);
    }

    private static String rootMessage(Throwable t) {
        Throwable cause = t.getCause();
        return cause != null ? cause.getMessage() : t.getMessage();
    }

    private static void sendUsage(CommandSender sender) {
        sender.sendMessage("mcvpn: usage:");
        sender.sendMessage("  /mcvpn admin create <username> <password>");
        sender.sendMessage("  /mcvpn admin list");
        sender.sendMessage("  /mcvpn user list");
        sender.sendMessage("  /mcvpn user create <label>");
        sender.sendMessage("  /mcvpn user revoke <keyId>");
    }
}

package dev.mcvpn.plugin;

import java.util.ArrayList;
import java.util.List;
import java.util.Set;
import java.util.UUID;

import org.bukkit.Bukkit;
import org.bukkit.command.Command;
import org.bukkit.command.CommandExecutor;
import org.bukkit.command.CommandSender;
import org.bukkit.entity.Player;

/**
 * Overrides vanilla {@code /list} (registered under the same name in {@code
 * plugin.yml}, which Bukkit lets a plugin do in place of the built-in
 * command) so it reports the same thing a real server without any active
 * tunnel connections would: same format vanilla uses, active tunnel
 * connections excluded from both the count and the name list. Works
 * identically whether run by a player or from console -- there's no
 * separate "real" answer being hidden from one but not the other.
 */
final class HiddenListCommand implements CommandExecutor {

    private final McvpnPlugin plugin;

    HiddenListCommand(McvpnPlugin plugin) {
        this.plugin = plugin;
    }

    @Override
    public boolean onCommand(CommandSender sender, Command command, String label, String[] args) {
        Set<UUID> tunnelPlayerIds = plugin.activeTunnelPlayerIds();

        List<String> names = new ArrayList<>();
        for (Player player : Bukkit.getOnlinePlayers()) {
            if (!tunnelPlayerIds.contains(player.getUniqueId())) {
                names.add(player.getName());
            }
        }
        names.sort(String.CASE_INSENSITIVE_ORDER);

        sender.sendMessage("There are " + names.size() + " of a max of "
                + Bukkit.getMaxPlayers() + " players online: " + String.join(", ", names));
        return true;
    }
}

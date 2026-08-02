package dev.mcvpn.plugin;

import java.nio.ByteBuffer;
import java.security.GeneralSecurityException;
import java.util.Arrays;
import java.util.Map;
import java.util.Optional;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicReference;

import org.bukkit.Bukkit;
import org.bukkit.GameMode;
import org.bukkit.entity.Player;

import dev.mcvpn.plugin.store.UserStore;
import dev.mcvpn.plugin.store.VpnUser;

/**
 * One player's persistent tunnel connection: the crypto state and every
 * logical {@link StreamState} currently multiplexed over it.
 *
 * The crypto state isn't known at construction time -- it's only
 * established once this player's first message completes the authenticated
 * X25519 handshake (see {@link TunnelCrypto}). Until then this object
 * exists purely to hold that attempt; nothing observable happens for a
 * party that never produces a valid handshake message.
 */
final class PlayerMultiplex {

    private static final int MESSAGE_1_LEN =
            TunnelCrypto.CONNECTION_ID_LEN + TunnelCrypto.KEY_ID_LEN + TunnelCrypto.PUBLIC_KEY_LEN + TunnelCrypto.MAC_LEN;

    private final McvpnPlugin plugin;
    private final Player player;
    private final String channel;
    private final UserStore userStore;

    private final AtomicReference<TunnelCrypto> crypto = new AtomicReference<>();
    private final Map<Integer, StreamState> streams = new ConcurrentHashMap<>();
    private final Map<Integer, UdpAssociationState> udpAssociations = new ConcurrentHashMap<>();
    private final AtomicBoolean stealthApplied = new AtomicBoolean(false);

    // Resolved once handshake message 1 authenticates successfully; needed
    // afterwards by handleKeyUpdate's rotation calls (which need the raw
    // secret, but not the keyId -- rotation MACs don't cover it).
    private volatile VpnUser vpnUser;
    private volatile byte[] secret;

    // Only the client initiates rotations in the current design, so in
    // practice this plugin is always in the "reply" role -- but the
    // protocol is symmetric (see handleKeyUpdate), so this is tracked for
    // correctness rather than assumed away.
    private final AtomicReference<TunnelCrypto.Keypair> pendingRotation = new AtomicReference<>();

    PlayerMultiplex(McvpnPlugin plugin, Player player, String channel, UserStore userStore) {
        this.plugin = plugin;
        this.player = player;
        this.channel = channel;
        this.userStore = userStore;
    }

    McvpnPlugin plugin() {
        return plugin;
    }

    Player player() {
        return player;
    }

    String playerName() {
        return player.getName();
    }

    /** Whether this connection has completed the handshake. */
    boolean isActive() {
        return crypto.get() != null;
    }

    /** The authenticated vpn user's store id, or {@code null} before the handshake completes. */
    String vpnUserId() {
        VpnUser u = vpnUser;
        return u == null ? null : u.id();
    }

    /** Handles one raw plugin-message payload received from this player. */
    void handleEnvelope(byte[] message) {
        TunnelCrypto tc = crypto.get();

        if (tc == null) {
            handleHandshakeMessage1(message);
            return;
        }

        try {
            dispatch(Frame.decode(tc.open(message)));
        } catch (GeneralSecurityException e) {
            // Replay, corruption, or a stray message; drop and keep going.
        }
    }

    /**
     * Verifies and completes the client's handshake message 1
     * ({@code connection_id || key_id || epk_c || mac1}). Anything that
     * doesn't check out -- wrong length, unknown or disabled key_id, wrong
     * MAC -- is dropped without any reply or log noise a network observer
     * could see: identical to how a real server behaves when it doesn't
     * understand a plugin channel at all.
     *
     * The user lookup is asynchronous (the store may be a real database),
     * so this never blocks the calling thread; the rest of the handshake
     * runs in the lookup's completion callback.
     */
    private void handleHandshakeMessage1(byte[] message) {
        if (message.length != MESSAGE_1_LEN) {
            return;
        }
        int off = 0;
        byte[] connectionId = Arrays.copyOfRange(message, off, off += TunnelCrypto.CONNECTION_ID_LEN);
        byte[] keyId = Arrays.copyOfRange(message, off, off += TunnelCrypto.KEY_ID_LEN);
        byte[] epkC = Arrays.copyOfRange(message, off, off += TunnelCrypto.PUBLIC_KEY_LEN);
        byte[] mac1 = Arrays.copyOfRange(message, off, off + TunnelCrypto.MAC_LEN);

        userStore.findVpnUserByKeyId(keyId).thenAccept(maybeUser -> {
            try {
                completeHandshakeMessage1(maybeUser, connectionId, keyId, epkC, mac1);
            } catch (GeneralSecurityException e) {
                plugin.getLogger().warning("handshake crypto failure for " + player.getName() + ": " + e.getMessage());
            } catch (RuntimeException e) {
                plugin.getLogger().warning("handshake failure for " + player.getName() + ": " + e.getMessage());
            }
        });
    }

    private void completeHandshakeMessage1(Optional<VpnUser> maybeUser, byte[] connectionId, byte[] keyId,
            byte[] epkC, byte[] mac1) throws GeneralSecurityException {
        if (maybeUser.isEmpty() || !maybeUser.get().enabled()) {
            return; // unknown or disabled key_id: drop silently, same stealth property as a bad MAC
        }
        VpnUser user = maybeUser.get();

        byte[] expectedMac1 = TunnelCrypto.handshakeMac1(user.secret(), connectionId, keyId, epkC);
        if (!TunnelCrypto.constantTimeEquals(mac1, expectedMac1)) {
            return;
        }

        TunnelCrypto.Keypair serverKeypair = TunnelCrypto.Keypair.generate();
        byte[] epkS = serverKeypair.publicKeyBytes;
        byte[] dhOutput = serverKeypair.diffieHellman(epkC);

        TunnelCrypto derived = TunnelCrypto.derive(user.secret(), connectionId, epkC, epkS, dhOutput, false);
        if (!crypto.compareAndSet(null, derived)) {
            return; // already authenticated via a concurrent message
        }
        this.vpnUser = user;
        this.secret = user.secret();

        byte[] mac2 = TunnelCrypto.handshakeMac2(user.secret(), connectionId, keyId, epkC, epkS);
        byte[] reply = new byte[TunnelCrypto.PUBLIC_KEY_LEN + TunnelCrypto.MAC_LEN];
        System.arraycopy(epkS, 0, reply, 0, epkS.length);
        System.arraycopy(mac2, 0, reply, epkS.length, mac2.length);
        player.sendPluginMessage(plugin, channel, reply);

        // Authentication itself is proof this is a tunnel client, not a real
        // player -- hide it the instant the handshake completes rather than
        // waiting for the first stream to open, so it never has a chance to
        // show up in anyone's tab list.
        applyStealth();

        // Best-effort bookkeeping, not correctness-critical: fire and forget.
        userStore.touchLastSeen(user.id()).exceptionally(e -> null);
    }

    private void dispatch(Frame frame) {
        if (frame == null) {
            return;
        }
        switch (frame.type) {
            case OPEN -> {
                StreamState stream = new StreamState(this, frame.streamId);
                streams.put(frame.streamId, stream);
                stream.beginConnect(frame.openTarget());
            }
            case DATA -> {
                StreamState stream = streams.get(frame.streamId);
                if (stream != null) {
                    stream.handleData(frame.payload);
                }
            }
            case WINDOW_UPDATE -> {
                if (frame.payload.length == 4) {
                    StreamState stream = streams.get(frame.streamId);
                    if (stream != null) {
                        stream.handleWindowUpdate(ByteBuffer.wrap(frame.payload).getInt());
                    }
                }
            }
            case CLOSE -> {
                StreamState stream = streams.remove(frame.streamId);
                if (stream != null) {
                    stream.close();
                }
                UdpAssociationState udp = udpAssociations.remove(frame.streamId);
                if (udp != null) {
                    udp.close();
                }
            }
            case OPEN_UDP -> {
                UdpAssociationState udp = new UdpAssociationState(this, frame.streamId);
                udpAssociations.put(frame.streamId, udp);
            }
            case DATAGRAM -> {
                UdpAssociationState udp = udpAssociations.get(frame.streamId);
                if (udp != null) {
                    Frame.DatagramPayload d = frame.decodeDatagram();
                    if (d != null) {
                        udp.handleDatagram(d.host(), d.port(), d.data());
                    }
                }
            }
            case PING -> sendFrame(new Frame(Frame.CONTROL_STREAM, Frame.Type.PONG, frame.payload));
            case PONG -> {
                // Nothing to do; its arrival is the whole point.
            }
            case KEY_UPDATE -> handleKeyUpdate(frame.payload);
        }
    }

    /**
     * Handles a KEY_UPDATE frame, either as the reply to a rotation we
     * initiated or as a request from the peer to reply to -- see the Rust
     * client's {@code crypto::cipher} "Key rotation" docs for the full
     * protocol, which this mirrors exactly.
     */
    private void handleKeyUpdate(byte[] theirEpk) {
        if (theirEpk.length != TunnelCrypto.PUBLIC_KEY_LEN) {
            return;
        }
        TunnelCrypto tc = crypto.get();
        if (tc == null) {
            return; // can't happen in practice: dispatch() only runs after a successful open()
        }

        TunnelCrypto.Keypair mine = pendingRotation.getAndSet(null);
        try {
            if (mine != null) {
                // We initiated; this is their reply. We're "a", they're "b".
                byte[] dhOutput = mine.diffieHellman(theirEpk);
                tc.completeRotation(secret, mine.publicKeyBytes, theirEpk, dhOutput);
            } else {
                // They initiated; we reply. They're "a", we're "b".
                TunnelCrypto.Keypair serverKeypair = TunnelCrypto.Keypair.generate();
                byte[] dhOutput = serverKeypair.diffieHellman(theirEpk);
                byte[] replyPayload = Frame.keyUpdate(serverKeypair.publicKeyBytes).encode();
                byte[] sealedReply = tc.replyToRotation(secret, theirEpk, serverKeypair.publicKeyBytes, dhOutput, replyPayload);
                player.sendPluginMessage(plugin, channel, sealedReply);
            }
        } catch (GeneralSecurityException e) {
            plugin.getLogger().warning("key rotation failure for " + player.getName() + ": " + e.getMessage());
        }
    }

    void removeStream(int streamId) {
        streams.remove(streamId);
    }

    void removeUdpAssociation(int streamId) {
        udpAssociations.remove(streamId);
    }

    /** Encrypts and sends one frame back to the player. Returns false if that failed. */
    boolean sendFrame(Frame frame) {
        TunnelCrypto tc = crypto.get();
        if (tc == null || !player.isOnline()) {
            return false;
        }
        try {
            player.sendPluginMessage(plugin, channel, tc.seal(frame.encode()));
            return true;
        } catch (GeneralSecurityException e) {
            plugin.getLogger().warning(
                    "failed to seal outgoing frame for " + player.getName() + ": " + e.getMessage());
            return false;
        }
    }

    /**
     * Called once, right after the handshake authenticates: switches the
     * player to spectator and hides them from (and hides everyone else
     * from) the tab list. It's a bot connection, not someone actually
     * playing, and a frozen "player" other people can see and interact
     * with is its own kind of tell.
     */
    private void applyStealth() {
        if (!stealthApplied.compareAndSet(false, true)) {
            return;
        }
        Bukkit.getScheduler().runTask(plugin, () -> {
            if (!player.isOnline()) {
                return;
            }
            player.setGameMode(GameMode.SPECTATOR);
            for (Player other : Bukkit.getOnlinePlayers()) {
                if (!other.equals(player)) {
                    other.hidePlayer(plugin, player);
                    player.hidePlayer(plugin, other);
                }
            }
        });
    }

    void close() {
        streams.values().forEach(StreamState::close);
        streams.clear();
        udpAssociations.values().forEach(UdpAssociationState::close);
        udpAssociations.clear();
    }
}

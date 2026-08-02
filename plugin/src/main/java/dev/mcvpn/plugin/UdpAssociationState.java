package dev.mcvpn.plugin;

import java.io.IOException;
import java.net.DatagramPacket;
import java.net.DatagramSocket;
import java.net.InetAddress;
import java.util.Arrays;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.atomic.AtomicBoolean;

/**
 * One UDP association within a player's multiplexed tunnel connection
 * ({@link PlayerMultiplex}): the {@link StreamState} counterpart for
 * datagrams. Unlike a stream, there's no fixed target -- every
 * {@link Frame.Type#DATAGRAM} frame names its own destination, and replies
 * from whichever remote host(s) answered are relayed back the same way,
 * tagged with where they actually came from.
 *
 * One shared {@link DatagramSocket} handles the whole association (SOCKS5
 * UDP ASSOCIATE explicitly allows sending to different destinations over a
 * single relay port), created lazily on the first outbound datagram so
 * {@link #handleDatagram} never blocks the caller -- same reasoning as
 * {@link StreamState#beginConnect}'s async connect.
 */
final class UdpAssociationState {

    private static final int MAX_DATAGRAM_SIZE = 65507; // largest possible UDP payload

    private final PlayerMultiplex owner;
    private final int streamId;
    private final AtomicBoolean closed = new AtomicBoolean(false);
    private final Object socketLock = new Object();
    private DatagramSocket socket; // null until the first outbound datagram
    private volatile Thread readerThread;

    UdpAssociationState(PlayerMultiplex owner, int streamId) {
        this.owner = owner;
        this.streamId = streamId;
    }

    /** A datagram frame from the player: send {@code data} to {@code host:port}. */
    void handleDatagram(String host, int port, byte[] data) {
        CompletableFuture.runAsync(() -> {
            try {
                DatagramSocket s = ensureSocket();
                if (s == null) {
                    return; // already closed
                }
                InetAddress addr = InetAddress.getByName(host);
                s.send(new DatagramPacket(data, data.length, addr, port));
            } catch (IOException e) {
                owner.plugin().getLogger().fine(
                        "udp association " + streamId + " send to " + host + ":" + port
                                + " failed for " + owner.playerName() + ": " + e.getMessage());
            }
        });
    }

    /** Returns the shared socket, creating it (and starting the reply reader) on first use. */
    private DatagramSocket ensureSocket() throws IOException {
        synchronized (socketLock) {
            if (closed.get()) {
                return null;
            }
            if (socket == null) {
                socket = new DatagramSocket();
                Thread reader = new Thread(this::pumpTargetToPlayer,
                        "mcvpn-udp-" + owner.playerName() + "-" + streamId);
                reader.setDaemon(true);
                readerThread = reader;
                reader.start();
            }
            return socket;
        }
    }

    private void pumpTargetToPlayer() {
        DatagramSocket s;
        synchronized (socketLock) {
            s = socket;
        }
        if (s == null) {
            return;
        }
        byte[] buf = new byte[MAX_DATAGRAM_SIZE];
        try {
            while (!closed.get()) {
                DatagramPacket packet = new DatagramPacket(buf, buf.length);
                s.receive(packet);
                byte[] data = Arrays.copyOfRange(packet.getData(), packet.getOffset(),
                        packet.getOffset() + packet.getLength());
                String host = packet.getAddress().getHostAddress();
                int port = packet.getPort();
                if (!owner.sendFrame(Frame.datagram(streamId, host, port, data))) {
                    break;
                }
            }
        } catch (IOException ignored) {
            // Socket closed out from under us, or a real error -- either way close().
        } finally {
            close();
        }
    }

    void close() {
        if (!closed.compareAndSet(false, true)) {
            return;
        }
        DatagramSocket s;
        synchronized (socketLock) {
            s = socket;
        }
        if (s != null) {
            s.close();
        }
        Thread reader = readerThread;
        if (reader != null) {
            reader.interrupt();
        }
        owner.removeUdpAssociation(streamId);
    }
}

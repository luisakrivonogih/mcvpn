package dev.mcvpn.plugin;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.InetSocketAddress;
import java.net.Socket;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.Semaphore;
import java.util.concurrent.atomic.AtomicBoolean;

/**
 * One logical stream within a player's multiplexed tunnel connection
 * ({@link PlayerMultiplex}): a TCP socket to the target named by this
 * stream's Open frame, plus a background thread pumping target-&gt;player
 * bytes back out as Data frames.
 *
 * The target connection is opened asynchronously ({@link #beginConnect})
 * on the common fork-join pool, never on the caller's thread: Bukkit
 * delivers plugin messages on the main server tick thread, and a blocking
 * connect (or the DNS lookup inside it) there would stall every player on
 * the server for however long the target takes to answer.
 *
 * Flow-controlled the same way the client's `StreamSender` is:
 * {@link #creditSemaphore} tracks how many more bytes we're allowed to
 * push to the player without a WindowUpdate crediting us back, so one slow
 * browser tab can't make us buffer unboundedly or starve another stream
 * sharing the same connection.
 */
final class StreamState {

    private static final int CONNECT_TIMEOUT_MS = 10_000;
    private static final int INITIAL_WINDOW = 256 * 1024;
    private static final int MAX_CHUNK = 31_000;

    private final PlayerMultiplex owner;
    private final int streamId;
    private final AtomicBoolean closed = new AtomicBoolean(false);
    private final Semaphore creditSemaphore = new Semaphore(INITIAL_WINDOW);

    private final Object connectLock = new Object();
    private Socket socket; // null until the async connect finishes
    private List<byte[]> pending = new ArrayList<>();
    private volatile Thread readerThread;

    StreamState(PlayerMultiplex owner, int streamId) {
        this.owner = owner;
        this.streamId = streamId;
    }

    void beginConnect(String targetHostPort) {
        int idx = targetHostPort.lastIndexOf(':');
        if (idx <= 0 || idx == targetHostPort.length() - 1) {
            owner.plugin().getLogger().warning("malformed open target from " + owner.playerName());
            close();
            return;
        }
        String host = targetHostPort.substring(0, idx);
        int port;
        try {
            port = Integer.parseInt(targetHostPort.substring(idx + 1));
        } catch (NumberFormatException e) {
            owner.plugin().getLogger().warning("malformed open target from " + owner.playerName());
            close();
            return;
        }

        CompletableFuture.runAsync(() -> {
            boolean upstreamEnabled = owner.plugin().getConfig().getBoolean("upstream.enabled", false);
            try {
                Socket s = upstreamEnabled
                        ? connectThroughUpstream(
                                owner.plugin().getConfig().getString("upstream.host", "127.0.0.1"),
                                owner.plugin().getConfig().getInt("upstream.port", 3128),
                                host, port)
                        : connectDirect(host, port);
                onConnected(s, host, port);
            } catch (IOException e) {
                owner.plugin().getLogger().warning(
                        "failed to reach tunnel target " + host + ":" + port + " for " + owner.playerName()
                                + ": " + e.getMessage());
                close();
            }
        });
    }

    private static Socket connectDirect(String host, int port) throws IOException {
        Socket s = new Socket();
        s.connect(new InetSocketAddress(host, port), CONNECT_TIMEOUT_MS);
        s.setTcpNoDelay(true);
        return s;
    }

    /**
     * Opens a socket to {@code upstreamHost:upstreamPort} and issues a
     * plain HTTP CONNECT for {@code targetHost:targetPort} through it,
     * letting the final egress point be a further hop instead of this
     * server's direct internet connection.
     */
    private static Socket connectThroughUpstream(String upstreamHost, int upstreamPort,
            String targetHost, int targetPort) throws IOException {
        Socket s = new Socket();
        s.connect(new InetSocketAddress(upstreamHost, upstreamPort), CONNECT_TIMEOUT_MS);
        s.setTcpNoDelay(true);

        String request = "CONNECT " + targetHost + ":" + targetPort + " HTTP/1.1\r\n"
                + "Host: " + targetHost + ":" + targetPort + "\r\n\r\n";
        s.getOutputStream().write(request.getBytes(StandardCharsets.US_ASCII));
        s.getOutputStream().flush();

        String statusLine = readHttpStatusLine(s.getInputStream());
        if (statusLine == null || !statusLine.contains(" 200")) {
            closeQuietly(s);
            throw new IOException("upstream proxy did not return 200 for CONNECT "
                    + targetHost + ":" + targetPort + " (got: " + statusLine + ")");
        }
        return s;
    }

    private static String readHttpStatusLine(InputStream in) throws IOException {
        ByteArrayOutputStream buf = new ByteArrayOutputStream();
        int b;
        while ((b = in.read()) != -1) {
            buf.write(b);
            byte[] arr = buf.toByteArray();
            int len = arr.length;
            if (len >= 4 && arr[len - 4] == '\r' && arr[len - 3] == '\n'
                    && arr[len - 2] == '\r' && arr[len - 1] == '\n') {
                break;
            }
            if (len > 8192) {
                break;
            }
        }
        String response = buf.toString(StandardCharsets.US_ASCII);
        int idx = response.indexOf("\r\n");
        return idx >= 0 ? response.substring(0, idx) : (response.isEmpty() ? null : response);
    }

    private void onConnected(Socket s, String targetHost, int targetPort) {
        List<byte[]> toFlush;
        synchronized (connectLock) {
            if (closed.get()) {
                closeQuietly(s);
                return;
            }
            this.socket = s;
            toFlush = pending;
            pending = null;
        }

        for (byte[] data : toFlush) {
            writeToSocket(data);
        }

        Thread reader = new Thread(this::pumpTargetToPlayer,
                "mcvpn-stream-" + owner.playerName() + "-" + streamId);
        reader.setDaemon(true);
        readerThread = reader;
        reader.start();

        owner.plugin().getLogger().info(
                "opened stream " + streamId + " for " + owner.playerName() + " -> " + targetHost + ":" + targetPort);
    }

    /** Data received from the player for this stream. */
    void handleData(byte[] data) {
        synchronized (connectLock) {
            if (socket == null) {
                if (!closed.get()) {
                    pending.add(data);
                }
                return;
            }
        }
        writeToSocket(data);
    }

    /** A WindowUpdate from the player, crediting us to send more. */
    void handleWindowUpdate(int additionalBytes) {
        if (additionalBytes > 0) {
            creditSemaphore.release(additionalBytes);
        }
    }

    private void writeToSocket(byte[] data) {
        if (closed.get()) {
            return;
        }
        try {
            OutputStream out = socket.getOutputStream();
            out.write(data);
            out.flush();
        } catch (IOException e) {
            close();
        }
    }

    private void pumpTargetToPlayer() {
        byte[] buf = new byte[MAX_CHUNK];
        try {
            InputStream in = socket.getInputStream();
            int n;
            while (!closed.get() && (n = in.read(buf)) != -1) {
                // Blocks this stream's own thread only, never the shared
                // connection, until the player has credited us enough
                // window to send.
                creditSemaphore.acquire(n);
                byte[] chunk = n == buf.length ? buf.clone() : Arrays.copyOf(buf, n);
                if (!owner.sendFrame(Frame.data(streamId, chunk))) {
                    break;
                }
            }
        } catch (IOException | InterruptedException ignored) {
            // Falls through to close() regardless.
        } finally {
            close();
        }
    }

    void close() {
        if (!closed.compareAndSet(false, true)) {
            return;
        }
        Socket s;
        synchronized (connectLock) {
            s = socket;
        }
        if (s != null) {
            closeQuietly(s);
        }
        Thread reader = readerThread;
        if (reader != null) {
            reader.interrupt();
        }
        owner.removeStream(streamId);
    }

    private static void closeQuietly(Socket s) {
        try {
            s.close();
        } catch (IOException ignored) {
            // Nothing to do; the socket is going away either way.
        }
    }
}

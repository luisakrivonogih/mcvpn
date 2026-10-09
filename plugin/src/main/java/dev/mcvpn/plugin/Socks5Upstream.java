package dev.mcvpn.plugin;

import java.io.ByteArrayOutputStream;
import java.io.DataInputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.net.Socket;
import java.nio.charset.StandardCharsets;
import java.util.Arrays;

/**
 * Minimal SOCKS5 client (RFC 1928 CONNECT and UDP ASSOCIATE, RFC 1929
 * username/password auth) for sending a tunnel user's traffic to an
 * upstream SOCKS5 server instead of straight out. The username is the
 * authenticated tunnel user's label, so the upstream can route (or shape)
 * each user's traffic separately; the password is not meaningful.
 */
final class Socks5Upstream {

    static final int CONNECT_TIMEOUT_MS = 10_000;
    private static final byte VERSION = 5;
    private static final byte CMD_CONNECT = 1;
    private static final byte CMD_UDP_ASSOCIATE = 3;
    private static final byte ATYP_IPV4 = 1;
    private static final byte ATYP_DOMAIN = 3;
    private static final byte ATYP_IPV6 = 4;

    private Socks5Upstream() {
    }

    /** A TCP connection to {@code targetHost:targetPort} through the upstream. */
    static Socket connect(String proxyHost, int proxyPort, String username,
            String targetHost, int targetPort) throws IOException {
        Socket s = new Socket();
        try {
            s.connect(new InetSocketAddress(proxyHost, proxyPort), CONNECT_TIMEOUT_MS);
            s.setTcpNoDelay(true);
            negotiate(s, username);
            request(s, CMD_CONNECT, targetHost, targetPort);
            return s;
        } catch (IOException e) {
            closeQuietly(s);
            throw e;
        }
    }

    /**
     * Opens a UDP association. The returned control connection must stay
     * open for as long as the association is used; datagrams go to
     * {@link Association#relay()} wrapped with {@link #wrap}.
     */
    static Association associate(String proxyHost, int proxyPort, String username) throws IOException {
        Socket control = new Socket();
        try {
            control.connect(new InetSocketAddress(proxyHost, proxyPort), CONNECT_TIMEOUT_MS);
            negotiate(control, username);
            InetSocketAddress bound = request(control, CMD_UDP_ASSOCIATE, "0.0.0.0", 0);
            // A relay announced as the unspecified address means "the proxy's own address".
            InetSocketAddress relay = bound.getAddress().isAnyLocalAddress()
                    ? new InetSocketAddress(control.getInetAddress(), bound.getPort())
                    : bound;
            return new Association(control, relay);
        } catch (IOException e) {
            closeQuietly(control);
            throw e;
        }
    }

    record Association(Socket control, InetSocketAddress relay) {
        void close() {
            closeQuietly(control);
        }
    }

    /** A received relay datagram: where it came from, and its payload. */
    record Datagram(String host, int port, byte[] data) {
    }

    /** Prefixes {@code data} with the SOCKS5 UDP request header for {@code host:port}. */
    static byte[] wrap(String host, int port, byte[] data) throws IOException {
        ByteArrayOutputStream out = new ByteArrayOutputStream(data.length + 32);
        out.write(new byte[] {0, 0, 0}); // RSV, FRAG
        writeAddress(out, host, port);
        out.write(data);
        return out.toByteArray();
    }

    /** Parses a datagram received from the relay; null when malformed or fragmented. */
    static Datagram unwrap(byte[] packet, int length) {
        try {
            if (length < 4 || packet[2] != 0) {
                return null; // fragmentation is not supported
            }
            int off = 3;
            byte atyp = packet[off++];
            String host;
            switch (atyp) {
                case ATYP_IPV4 -> {
                    host = InetAddress.getByAddress(Arrays.copyOfRange(packet, off, off + 4)).getHostAddress();
                    off += 4;
                }
                case ATYP_IPV6 -> {
                    host = InetAddress.getByAddress(Arrays.copyOfRange(packet, off, off + 16)).getHostAddress();
                    off += 16;
                }
                case ATYP_DOMAIN -> {
                    int len = packet[off++] & 0xff;
                    host = new String(packet, off, len, StandardCharsets.US_ASCII);
                    off += len;
                }
                default -> {
                    return null;
                }
            }
            int port = ((packet[off] & 0xff) << 8) | (packet[off + 1] & 0xff);
            off += 2;
            if (off > length) {
                return null;
            }
            return new Datagram(host, port, Arrays.copyOfRange(packet, off, length));
        } catch (IOException | ArrayIndexOutOfBoundsException e) {
            return null;
        }
    }

    private static void negotiate(Socket s, String username) throws IOException {
        OutputStream out = s.getOutputStream();
        DataInputStream in = new DataInputStream(s.getInputStream());
        out.write(new byte[] {VERSION, 1, 2}); // one method: username/password
        out.flush();
        byte[] choice = new byte[2];
        in.readFully(choice);
        if (choice[0] != VERSION || choice[1] != 2) {
            throw new IOException("SOCKS5 upstream refused username/password authentication");
        }
        byte[] user = username.getBytes(StandardCharsets.UTF_8);
        if (user.length == 0 || user.length > 255) {
            throw new IOException("SOCKS5 username must be 1..255 bytes");
        }
        ByteArrayOutputStream auth = new ByteArrayOutputStream();
        auth.write(1);
        auth.write(user.length);
        auth.write(user);
        auth.write(1);
        auth.write('x');
        out.write(auth.toByteArray());
        out.flush();
        byte[] status = new byte[2];
        in.readFully(status);
        if (status[1] != 0) {
            throw new IOException("SOCKS5 upstream rejected user " + username);
        }
    }

    private static InetSocketAddress request(Socket s, byte cmd, String host, int port) throws IOException {
        ByteArrayOutputStream req = new ByteArrayOutputStream();
        req.write(new byte[] {VERSION, cmd, 0});
        writeAddress(req, host, port);
        OutputStream out = s.getOutputStream();
        out.write(req.toByteArray());
        out.flush();

        DataInputStream in = new DataInputStream(s.getInputStream());
        byte[] head = new byte[4];
        in.readFully(head);
        if (head[0] != VERSION || head[1] != 0) {
            throw new IOException("SOCKS5 upstream request failed with code " + (head[1] & 0xff));
        }
        InetAddress addr;
        switch (head[3]) {
            case ATYP_IPV4 -> addr = InetAddress.getByAddress(readN(in, 4));
            case ATYP_IPV6 -> addr = InetAddress.getByAddress(readN(in, 16));
            case ATYP_DOMAIN -> addr = InetAddress.getByName(new String(readN(in, in.readUnsignedByte()),
                    StandardCharsets.US_ASCII));
            default -> throw new IOException("SOCKS5 upstream sent an unknown address type");
        }
        return new InetSocketAddress(addr, in.readUnsignedShort());
    }

    private static void writeAddress(ByteArrayOutputStream out, String host, int port) throws IOException {
        byte[] literal = ipLiteral(host);
        if (literal != null) {
            out.write(literal.length == 4 ? ATYP_IPV4 : ATYP_IPV6);
            out.write(literal);
        } else {
            byte[] name = host.getBytes(StandardCharsets.US_ASCII);
            if (name.length > 255) {
                throw new IOException("host name too long for SOCKS5");
            }
            out.write(ATYP_DOMAIN);
            out.write(name.length);
            out.write(name);
        }
        out.write((port >> 8) & 0xff);
        out.write(port & 0xff);
    }

    /** The bytes of an IPv4/IPv6 literal, or null for a host name (never resolved here). */
    static byte[] ipLiteral(String host) {
        if (host.matches("\\d{1,3}(\\.\\d{1,3}){3}") || host.contains(":")) {
            try {
                return InetAddress.getByName(host).getAddress();
            } catch (IOException e) {
                return null;
            }
        }
        return null;
    }

    private static byte[] readN(InputStream in, int n) throws IOException {
        byte[] b = new byte[n];
        new DataInputStream(in).readFully(b);
        return b;
    }

    static void closeQuietly(Socket s) {
        try {
            s.close();
        } catch (IOException ignored) {
            // nothing to do
        }
    }
}

package dev.mcvpn.plugin;

import static org.junit.jupiter.api.Assertions.assertArrayEquals;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertNull;

import java.io.DataInputStream;
import java.io.OutputStream;
import java.net.ServerSocket;
import java.net.Socket;
import java.nio.charset.StandardCharsets;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.TimeUnit;
import org.junit.jupiter.api.Test;

class Socks5UpstreamTest {

    /** A one-shot SOCKS5 server recording the username and CONNECT target it was given. */
    private static CompletableFuture<String> fakeServer(ServerSocket server) {
        return CompletableFuture.supplyAsync(() -> {
            try (Socket c = server.accept()) {
                DataInputStream in = new DataInputStream(c.getInputStream());
                OutputStream out = c.getOutputStream();
                in.readFully(new byte[3]); // greeting: version, 1 method, username/password
                out.write(new byte[] {5, 2});
                in.readUnsignedByte(); // auth version
                byte[] user = new byte[in.readUnsignedByte()];
                in.readFully(user);
                in.readFully(new byte[in.readUnsignedByte()]); // password
                out.write(new byte[] {1, 0});
                byte[] head = new byte[4];
                in.readFully(head);
                byte[] host = new byte[in.readUnsignedByte()]; // ATYP domain
                in.readFully(host);
                int port = in.readUnsignedShort();
                out.write(new byte[] {5, 0, 0, 1, 127, 0, 0, 1, 0, 0});
                out.flush();
                return new String(user, StandardCharsets.UTF_8) + "@" + new String(host, StandardCharsets.US_ASCII)
                        + ":" + port;
            } catch (Exception e) {
                return "error: " + e;
            }
        });
    }

    @Test
    void connectAuthenticatesAsTheTunnelUser() throws Exception {
        try (ServerSocket server = new ServerSocket(0)) {
            CompletableFuture<String> seen = fakeServer(server);
            try (Socket s = Socks5Upstream.connect("127.0.0.1", server.getLocalPort(), "client-42", "inet.e2e", 8080)) {
                assertNotNull(s);
            }
            assertEquals("client-42@inet.e2e:8080", seen.get(5, TimeUnit.SECONDS));
        }
    }

    @Test
    void udpDatagramsRoundTripThroughTheRelayHeader() throws Exception {
        byte[] wrapped = Socks5Upstream.wrap("10.201.0.1", 53000, new byte[] {9, 8, 7});
        Socks5Upstream.Datagram d = Socks5Upstream.unwrap(wrapped, wrapped.length);
        assertNotNull(d);
        assertEquals("10.201.0.1", d.host());
        assertEquals(53000, d.port());
        assertArrayEquals(new byte[] {9, 8, 7}, d.data());

        byte[] named = Socks5Upstream.wrap("inet.e2e", 53, new byte[] {1});
        assertEquals("inet.e2e", Socks5Upstream.unwrap(named, named.length).host());
    }

    @Test
    void fragmentedOrTruncatedDatagramsAreDropped() {
        assertNull(Socks5Upstream.unwrap(new byte[] {0, 0, 1, 1, 10}, 5));
        assertNull(Socks5Upstream.unwrap(new byte[] {0, 0}, 2));
    }
}

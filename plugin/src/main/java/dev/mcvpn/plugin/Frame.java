package dev.mcvpn.plugin;

import java.nio.ByteBuffer;
import java.nio.charset.StandardCharsets;
import java.util.Arrays;

/**
 * The multiplexed frame format carried inside each encrypted envelope (see
 * {@link TunnelCrypto}). Must match the Rust client's {@code tunnel::frame}
 * module byte-for-byte:
 *
 * <pre>
 * stream_id:   u32 BE
 * frame_type:  u8
 * flags:       u8   (reserved, always 0)
 * payload_len: u32 BE
 * payload:     payload_len bytes
 * </pre>
 */
final class Frame {

    static final int HEADER_LEN = 4 + 1 + 1 + 4;
    static final int CONTROL_STREAM = 0;

    enum Type {
        OPEN(1),
        DATA(2),
        CLOSE(3),
        PING(4),
        PONG(5),
        WINDOW_UPDATE(6),
        KEY_UPDATE(7),
        OPEN_UDP(8),
        DATAGRAM(9);

        final byte wireValue;

        Type(int wireValue) {
            this.wireValue = (byte) wireValue;
        }

        static Type fromByte(byte b) {
            for (Type t : values()) {
                if (t.wireValue == b) {
                    return t;
                }
            }
            return null;
        }
    }

    final int streamId;
    final Type type;
    final byte[] payload;

    Frame(int streamId, Type type, byte[] payload) {
        this.streamId = streamId;
        this.type = type;
        this.payload = payload;
    }

    byte[] encode() {
        ByteBuffer buf = ByteBuffer.allocate(HEADER_LEN + payload.length);
        buf.putInt(streamId);
        buf.put(type.wireValue);
        buf.put((byte) 0); // flags, reserved
        buf.putInt(payload.length);
        buf.put(payload);
        return buf.array();
    }

    /** Returns {@code null} for anything malformed; callers must drop it, not throw. */
    static Frame decode(byte[] data) {
        if (data.length < HEADER_LEN) {
            return null;
        }
        ByteBuffer buf = ByteBuffer.wrap(data);
        int streamId = buf.getInt();
        Type type = Type.fromByte(buf.get());
        buf.get(); // flags, ignored
        int payloadLen = buf.getInt();
        if (type == null || payloadLen < 0 || payloadLen != buf.remaining()) {
            return null;
        }
        byte[] payload = new byte[payloadLen];
        buf.get(payload);
        return new Frame(streamId, type, payload);
    }

    static Frame data(int streamId, byte[] payload) {
        return new Frame(streamId, Type.DATA, payload);
    }

    static Frame close(int streamId) {
        return new Frame(streamId, Type.CLOSE, new byte[0]);
    }

    static Frame windowUpdate(int streamId, int additionalBytes) {
        return new Frame(streamId, Type.WINDOW_UPDATE, ByteBuffer.allocate(4).putInt(additionalBytes).array());
    }

    static Frame keyUpdate(byte[] ephemeralPublicKey) {
        return new Frame(CONTROL_STREAM, Type.KEY_UPDATE, ephemeralPublicKey);
    }

    /** Opens a UDP association -- see the Dart client's `Frame.openUdp` doc for why there's no fixed target. */
    static Frame openUdp(int streamId) {
        return new Frame(streamId, Type.OPEN_UDP, new byte[0]);
    }

    /**
     * One whole UDP datagram to/from {@code host:port}, never chunked. Wire
     * format: {@code host_len:u8 || host_utf8 || port:u16 BE || data} --
     * must match the Dart client's {@code Frame.datagram} byte-for-byte.
     */
    static Frame datagram(int streamId, String host, int port, byte[] data) {
        byte[] hostBytes = host.getBytes(StandardCharsets.UTF_8);
        ByteBuffer buf = ByteBuffer.allocate(1 + hostBytes.length + 2 + data.length);
        buf.put((byte) hostBytes.length);
        buf.put(hostBytes);
        buf.putShort((short) port);
        buf.put(data);
        return new Frame(streamId, Type.DATAGRAM, buf.array());
    }

    record DatagramPayload(String host, int port, byte[] data) {}

    /** Decodes this frame's payload as a [DatagramPayload], or null if malformed. */
    DatagramPayload decodeDatagram() {
        if (payload.length < 1) {
            return null;
        }
        int hostLen = payload[0] & 0xff;
        if (payload.length < 1 + hostLen + 2) {
            return null;
        }
        String host = new String(payload, 1, hostLen, StandardCharsets.UTF_8);
        int port = ((payload[1 + hostLen] & 0xff) << 8) | (payload[1 + hostLen + 1] & 0xff);
        byte[] data = Arrays.copyOfRange(payload, 1 + hostLen + 2, payload.length);
        return new DatagramPayload(host, port, data);
    }

    String openTarget() {
        return new String(payload, StandardCharsets.UTF_8);
    }
}

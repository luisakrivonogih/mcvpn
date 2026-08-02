import 'dart:convert';
import 'dart:typed_data';

import '../core/bytes.dart';

/// Multiplexed frame carried inside each AEAD-sealed envelope. Lets many
/// logical streams share one Minecraft connection.
///
/// Wire (plaintext, before sealing):
/// ```
/// stream_id:   u32 BE
/// frame_type:  u8
/// flags:       u8  (reserved, 0)
/// payload_len: u32 BE
/// payload:     payload_len bytes
/// ```
const int frameHeaderLen = 4 + 1 + 1 + 4;
const int controlStream = 0;

enum FrameType {
  open(1),
  data(2),
  close(3),
  ping(4),
  pong(5),
  windowUpdate(6),
  keyUpdate(7),
  openUdp(8),
  datagram(9);

  final int byte;
  const FrameType(this.byte);

  static FrameType? fromByte(int b) {
    for (final t in FrameType.values) {
      if (t.byte == b) return t;
    }
    return null;
  }
}

/// One decoded UDP [Frame.datagram] payload: `host_len:u8 || host_utf8 ||
/// port:u16 BE || data`. `host` is always a numeric IP literal in practice
/// (tun2socks only ever sees already-resolved destination IPs off the wire),
/// but domain names round-trip fine too since both sides just treat it as a
/// UTF-8 string.
typedef UdpDatagramPayload = ({String host, int port, Uint8List data});

class Frame {
  final int streamId;
  final FrameType type;
  final Uint8List payload;

  Frame(this.streamId, this.type, this.payload);

  Uint8List encode() {
    final w = ByteWriter()
      ..i32(streamId)
      ..u8(type.byte)
      ..u8(0)
      ..i32(payload.length)
      ..raw(payload);
    return w.toBytes();
  }

  static Frame? decode(Uint8List buf) {
    if (buf.length < frameHeaderLen) return null;
    final r = ByteReader(buf);
    final streamId = r.i32() & 0xffffffff;
    final type = FrameType.fromByte(r.u8());
    r.u8(); // flags
    final payloadLen = r.i32();
    if (type == null) return null;
    if (r.remaining != payloadLen) return null;
    final payload = r.takeBytes(payloadLen);
    return Frame(streamId, type, Uint8List.fromList(payload));
  }

  static Frame open(int streamId, String target) =>
      Frame(streamId, FrameType.open, Uint8List.fromList(utf8.encode(target)));

  static Frame dataFrame(int streamId, Uint8List payload) =>
      Frame(streamId, FrameType.data, payload);

  static Frame closeFrame(int streamId) =>
      Frame(streamId, FrameType.close, Uint8List(0));

  static Frame windowUpdate(int streamId, int additionalBytes) {
    final w = ByteWriter()..i32(additionalBytes);
    return Frame(streamId, FrameType.windowUpdate, w.toBytes());
  }

  static Frame keyUpdate(List<int> ephemeralPublicKey) =>
      Frame(controlStream, FrameType.keyUpdate,
          Uint8List.fromList(ephemeralPublicKey));

  /// Opens a UDP association -- unlike [open], no fixed target: each
  /// [datagram] frame that follows carries its own destination/source,
  /// exactly like a real SOCKS5 UDP ASSOCIATE relay.
  static Frame openUdp(int streamId) =>
      Frame(streamId, FrameType.openUdp, Uint8List(0));

  /// One whole UDP datagram to/from `host:port`, never chunked -- unlike
  /// [dataFrame], datagram boundaries must be preserved exactly as the
  /// caller handed them over.
  static Frame datagram(int streamId, String host, int port, Uint8List data) {
    final hostBytes = utf8.encode(host);
    final w = ByteWriter()
      ..u8(hostBytes.length)
      ..raw(hostBytes)
      ..u16(port)
      ..raw(data);
    return Frame(streamId, FrameType.datagram, w.toBytes());
  }

  /// Decodes a [datagram] frame's payload, or null if malformed.
  static UdpDatagramPayload? decodeDatagram(Uint8List payload) {
    try {
      final r = ByteReader(payload);
      final hostLen = r.u8();
      final host = utf8.decode(r.takeBytes(hostLen));
      final port = r.u16();
      final data = r.rest();
      return (host: host, port: port, data: data);
    } catch (_) {
      return null;
    }
  }
}

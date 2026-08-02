import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mcvpn/src/core/bytes.dart';
import 'package:mcvpn/src/core/mc_codec.dart';
import 'package:mcvpn/src/tunnel/tunnel_frame.dart';

void main() {
  test('VarInt round trips across the boundary values', () {
    for (final v in [0, 1, 127, 128, 255, 300, 25565, 2097151, 0x7fffffff]) {
      final w = ByteWriter()..varInt(v);
      final r = ByteReader(w.toBytes());
      expect(r.varInt(), v, reason: 'value $v');
    }
  });

  test('MC codec frames and reparses a packet (no compression)', () {
    final codec = MinecraftCodec();
    final body = Uint8List.fromList([1, 2, 3, 4, 5]);
    final framed = codec.encode(0x2a, body);

    final decode = MinecraftCodec();
    decode.feed(framed);
    final pkt = decode.nextPacket()!;
    expect(pkt.id, 0x2a);
    expect(pkt.body, body);
    expect(decode.nextPacket(), isNull);
  });

  test('MC codec handles a split frame arriving in two reads', () {
    final codec = MinecraftCodec();
    final framed = codec.encode(0x05, Uint8List.fromList(List.filled(40, 9)));

    final decode = MinecraftCodec();
    decode.feed(framed.sublist(0, 3));
    expect(decode.nextPacket(), isNull);
    decode.feed(framed.sublist(3));
    final pkt = decode.nextPacket()!;
    expect(pkt.id, 0x05);
    expect(pkt.body.length, 40);
  });

  test('MC codec round trips with compression enabled', () {
    final codec = MinecraftCodec()..setCompression(0);
    // A compressible body above threshold.
    final body = Uint8List.fromList(List.filled(500, 65));
    final framed = codec.encode(0x10, body);

    final decode = MinecraftCodec()..setCompression(0);
    decode.feed(framed);
    final pkt = decode.nextPacket()!;
    expect(pkt.id, 0x10);
    expect(pkt.body, body);
  });

  test('tunnel Frame encodes and decodes', () {
    final f = Frame.open(7, 'example.com:443');
    final decoded = Frame.decode(f.encode())!;
    expect(decoded.streamId, 7);
    expect(decoded.type, FrameType.open);
    expect(String.fromCharCodes(decoded.payload), 'example.com:443');

    final wu = Frame.windowUpdate(3, 4096);
    final wud = Frame.decode(wu.encode())!;
    expect(wud.type, FrameType.windowUpdate);
    expect(
      ByteData.sublistView(wud.payload).getUint32(0, Endian.big),
      4096,
    );
  });
}

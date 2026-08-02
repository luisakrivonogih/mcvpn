import 'dart:io';
import 'dart:typed_data';

import 'bytes.dart';

/// One decoded Minecraft packet: its id and the undecoded body bytes.
class RawPacket {
  final int id;
  final Uint8List body;
  const RawPacket(this.id, this.body);

  ByteReader reader() => ByteReader(body);
}

/// The Minecraft wire codec: VarInt length-prefixed frames with the optional
/// zlib compression envelope the server enables via SetCompression.
///
/// This layer knows nothing about connection state or specific packets — it
/// only turns `(packetId, body)` into framed bytes and back, exactly like
/// `net/codec.rs` on the Rust client.
class MinecraftCodec {
  /// -1 disables compression; >= 0 is the size at/above which packets are
  /// zlib-compressed (matching the server's announced threshold).
  int _threshold = -1;

  final BytesBuilder _inbound = BytesBuilder(copy: true);
  final ZLibCodec _zlib = ZLibCodec();

  void setCompression(int threshold) {
    _threshold = threshold;
  }

  bool get compressionEnabled => _threshold >= 0;

  /// Encodes a single packet into fully framed wire bytes.
  Uint8List encode(int packetId, Uint8List body) {
    final inner = ByteWriter()
      ..varInt(packetId)
      ..raw(body);
    final innerBytes = inner.toBytes();

    if (!compressionEnabled) {
      final out = ByteWriter()
        ..varInt(innerBytes.length)
        ..raw(innerBytes);
      return out.toBytes();
    }

    // Compressed framing.
    if (innerBytes.length >= _threshold) {
      final compressed = Uint8List.fromList(_zlib.encode(innerBytes));
      final packet = ByteWriter()
        ..varInt(innerBytes.length) // data length = uncompressed size
        ..raw(compressed);
      final packetBytes = packet.toBytes();
      final out = ByteWriter()
        ..varInt(packetBytes.length)
        ..raw(packetBytes);
      return out.toBytes();
    } else {
      final packet = ByteWriter()
        ..varInt(0) // data length 0 = uncompressed
        ..raw(innerBytes);
      final packetBytes = packet.toBytes();
      final out = ByteWriter()
        ..varInt(packetBytes.length)
        ..raw(packetBytes);
      return out.toBytes();
    }
  }

  /// Feeds newly-read TCP bytes into the internal reassembly buffer.
  void feed(List<int> data) => _inbound.add(data);

  /// Pulls the next fully-buffered packet, or null if one isn't complete yet.
  RawPacket? nextPacket() {
    final buf = _inbound.toBytes();
    final lenResult = tryReadVarInt(buf, 0);
    if (lenResult == null) return null;

    final frameLen = lenResult.value;
    final headerLen = lenResult.bytesRead;
    if (buf.length - headerLen < frameLen) return null; // frame incomplete

    final frame = Uint8List.sublistView(buf, headerLen, headerLen + frameLen);

    // Consume: rebuild the inbound buffer with the leftover tail.
    _inbound.clear();
    if (buf.length > headerLen + frameLen) {
      _inbound.add(Uint8List.sublistView(buf, headerLen + frameLen));
    }

    Uint8List inner;
    if (!compressionEnabled) {
      inner = frame;
    } else {
      final r = ByteReader(frame);
      final dataLength = r.varInt();
      final payload = r.rest();
      if (dataLength == 0) {
        inner = payload;
      } else {
        inner = Uint8List.fromList(_zlib.decode(payload));
      }
    }

    final ir = ByteReader(inner);
    final id = ir.varInt();
    final body = ir.rest();
    return RawPacket(id, body);
  }
}

import 'dart:convert';
import 'dart:typed_data';

/// Growable big-endian byte writer with Minecraft VarInt / String support.
///
/// Mirrors the encoding used by `valence_protocol` on the Rust client and by
/// the Java plugin: VarInts are LEB128 (7 data bits per byte, MSB = continue),
/// strings are `VarInt(byteLen) || utf8`, numeric types are big-endian.
class ByteWriter {
  final BytesBuilder _b = BytesBuilder(copy: false);

  void u8(int v) => _b.addByte(v & 0xff);

  void bool_(bool v) => u8(v ? 1 : 0);

  void u16(int v) {
    _b.add([(v >> 8) & 0xff, v & 0xff]);
  }

  void i32(int v) {
    final d = ByteData(4)..setInt32(0, v, Endian.big);
    _b.add(d.buffer.asUint8List());
  }

  void i64(int v) {
    final d = ByteData(8)..setInt64(0, v, Endian.big);
    _b.add(d.buffer.asUint8List());
  }

  void u64(int v) {
    final d = ByteData(8)..setUint64(0, v, Endian.big);
    _b.add(d.buffer.asUint8List());
  }

  void f32(double v) {
    final d = ByteData(4)..setFloat32(0, v, Endian.big);
    _b.add(d.buffer.asUint8List());
  }

  void f64(double v) {
    final d = ByteData(8)..setFloat64(0, v, Endian.big);
    _b.add(d.buffer.asUint8List());
  }

  void varInt(int value) {
    var v = value & 0xffffffff;
    while (true) {
      if ((v & ~0x7f) == 0) {
        u8(v);
        return;
      }
      u8((v & 0x7f) | 0x80);
      v = v >>> 7;
    }
  }

  void string(String s) {
    final data = utf8.encode(s);
    varInt(data.length);
    _b.add(data);
  }

  void raw(List<int> data) => _b.add(data);

  Uint8List toBytes() => _b.toBytes();

  int get length => _b.length;
}

/// Sequential big-endian byte reader, the counterpart to [ByteWriter].
class ByteReader {
  final Uint8List _data;
  int _pos = 0;

  ByteReader(this._data);

  int get remaining => _data.length - _pos;
  bool get hasRemaining => _pos < _data.length;

  int u8() {
    if (_pos >= _data.length) {
      throw const FormatException('ByteReader: unexpected end of buffer');
    }
    return _data[_pos++];
  }

  bool bool_() => u8() != 0;

  int u16() {
    final v = (u8() << 8) | u8();
    return v;
  }

  int i32() {
    final v = ByteData.sublistView(_data, _pos, _pos + 4).getInt32(0, Endian.big);
    _pos += 4;
    return v;
  }

  int i64() {
    final v = ByteData.sublistView(_data, _pos, _pos + 8).getInt64(0, Endian.big);
    _pos += 8;
    return v;
  }

  int u64() {
    final v = ByteData.sublistView(_data, _pos, _pos + 8).getUint64(0, Endian.big);
    _pos += 8;
    return v;
  }

  double f32() {
    final v = ByteData.sublistView(_data, _pos, _pos + 4).getFloat32(0, Endian.big);
    _pos += 4;
    return v;
  }

  double f64() {
    final v = ByteData.sublistView(_data, _pos, _pos + 8).getFloat64(0, Endian.big);
    _pos += 8;
    return v;
  }

  int varInt() {
    var result = 0;
    var shift = 0;
    while (true) {
      final b = u8();
      result |= (b & 0x7f) << shift;
      if ((b & 0x80) == 0) break;
      shift += 7;
      if (shift >= 35) {
        throw const FormatException('VarInt too long');
      }
    }
    return result;
  }

  String string() {
    final len = varInt();
    final bytes = takeBytes(len);
    return utf8.decode(bytes);
  }

  Uint8List takeBytes(int n) {
    if (_pos + n > _data.length) {
      throw const FormatException('ByteReader: not enough bytes');
    }
    final out = Uint8List.sublistView(_data, _pos, _pos + n);
    _pos += n;
    return out;
  }

  /// The unread tail of the buffer (used for `RawBytes` fields that run to end).
  Uint8List rest() {
    final out = Uint8List.sublistView(_data, _pos);
    _pos = _data.length;
    return out;
  }
}

/// Reads a Minecraft VarInt from a streaming buffer without consuming more than
/// necessary. Returns `null` if the buffer doesn't yet hold a full VarInt.
class VarIntResult {
  final int value;
  final int bytesRead;
  const VarIntResult(this.value, this.bytesRead);
}

VarIntResult? tryReadVarInt(Uint8List data, int offset) {
  var result = 0;
  var shift = 0;
  var i = offset;
  while (true) {
    if (i >= data.length) return null; // incomplete
    final b = data[i];
    result |= (b & 0x7f) << shift;
    i++;
    if ((b & 0x80) == 0) {
      return VarIntResult(result, i - offset);
    }
    shift += 7;
    if (shift >= 35) {
      throw const FormatException('VarInt too long');
    }
  }
}

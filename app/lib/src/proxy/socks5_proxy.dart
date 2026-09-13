import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../core/log.dart';
import '../tunnel/multiplexer.dart';
import '../tunnel/tunnel_client.dart';
import 'relay.dart';

/// A local, no-auth SOCKS5 proxy (RFC 1928): CONNECT for TCP, plus UDP
/// ASSOCIATE (needed for DNS -- tun2socks' SOCKS5 client always tries UDP
/// ASSOCIATE for UDP flows, and DNS-over-UDP is virtually all of them) —
/// the front door for anything that doesn't speak HTTP CONNECT.
class Socks5Proxy {
  final TunnelClient tunnel;
  final LogSink log;
  ServerSocket? _server;

  Socks5Proxy(this.tunnel, this.log);

  int get port => _server?.port ?? 0;

  Future<void> start(InternetAddress address, int port) async {
    final server = await ServerSocket.bind(address, port, shared: false);
    _server = server;
    log('[socks5] listening on ${address.address}:${server.port}');
    server.listen(_handle,
        onError: (Object e) => log('[socks5] accept error: $e'));
  }

  Future<void> stop() async {
    await _server?.close();
    _server = null;
  }

  Future<void> _handle(Socket socket) async {
    late final BufferedSocket bs;
    try {
      bs = BufferedSocket(socket);
      final ver = await bs.readByte();
      if (ver != 0x05) {
        bs.destroy();
        return;
      }
      final nMethods = await bs.readByte();
      await bs.readBytes(nMethods);
      bs.write([0x05, 0x00]); // no auth required

      final v2 = await bs.readByte();
      final cmd = await bs.readByte();
      await bs.readByte(); // RSV
      final atyp = await bs.readByte();
      if (v2 != 0x05) {
        bs.write([0x05, 0x07, 0x00, 0x01, 0, 0, 0, 0, 0, 0]);
        bs.destroy();
        return;
      }

      String host;
      switch (atyp) {
        case 0x01:
          final b = await bs.readBytes(4);
          host = '${b[0]}.${b[1]}.${b[2]}.${b[3]}';
          break;
        case 0x03:
          final len = await bs.readByte();
          final b = await bs.readBytes(len);
          host = String.fromCharCodes(b);
          break;
        case 0x04:
          final b = await bs.readBytes(16);
          host = _formatIpv6(b);
          break;
        default:
          bs.write([0x05, 0x08, 0x00, 0x01, 0, 0, 0, 0, 0, 0]);
          bs.destroy();
          return;
      }
      final portBytes = await bs.readBytes(2);
      final targetPort = (portBytes[0] << 8) | portBytes[1];

      if (cmd == 0x03) {
        await _handleUdpAssociate(bs, socket);
        return;
      }
      if (cmd != 0x01) {
        bs.write([0x05, 0x07, 0x00, 0x01, 0, 0, 0, 0, 0, 0]);
        bs.destroy();
        return;
      }

      final target =
          host.contains(':') ? '[$host]:$targetPort' : '$host:$targetPort';

      TunnelStream stream;
      try {
        stream = await tunnel.openStream(target);
      } catch (e) {
        log('[socks5] open $target failed: $e');
        bs.write([0x05, 0x01, 0x00, 0x01, 0, 0, 0, 0, 0, 0]);
        bs.destroy();
        return;
      }

      bs.write([0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0]); // success
      await bs.relayTo(stream);
    } catch (e) {
      log('[socks5] session error: $e');
      try {
        bs.destroy();
      } catch (_) {
        socket.destroy();
      }
    }
  }

  /// Handles UDP ASSOCIATE (RFC1928 §7): binds a local UDP relay port, tells
  /// the caller (tun2socks) where it is, then pumps datagrams in both
  /// directions between it and a tunnel [UdpAssociation] for as long as this
  /// request's TCP control connection stays open -- per the RFC, that
  /// connection's lifetime *is* the association's lifetime, there's no
  /// separate teardown message.
  Future<void> _handleUdpAssociate(BufferedSocket bs, Socket controlSocket) async {
    RawDatagramSocket? udp;
    UdpAssociation? assoc;
    StreamSubscription<RawSocketEvent>? udpSub;
    StreamSubscription<dynamic>? incomingSub;
    InternetAddress? clientAddress;
    int? clientPort;

    // Setup: anything that fails here hasn't committed a reply yet, so it
    // gets a proper SOCKS5 error reply, same courtesy as a failed CONNECT.
    try {
      udp = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
      assoc = await tunnel.openUdpAssociation();
    } catch (e) {
      log('[socks5] udp associate setup failed: $e');
      bs.write([0x05, 0x01, 0x00, 0x01, 0, 0, 0, 0, 0, 0]);
      udp?.close();
      assoc?.close();
      controlSocket.destroy();
      return;
    }

    final boundUdp = udp;
    final boundAssoc = assoc;
    try {
      final boundPort = boundUdp.port;
      bs.write([
        0x05, 0x00, 0x00, 0x01, // success, reserved, ATYP=IPv4
        127, 0, 0, 1,
        (boundPort >> 8) & 0xff, boundPort & 0xff,
      ]);

      // tun2socks -> here: unwrap the SOCKS5 UDP header and forward the
      // datagram into the tunnel. The first sender we see is remembered as
      // "where replies go" -- one client per association, same as every
      // other SOCKS5 UDP relay implementation assumes in practice.
      udpSub = boundUdp.listen((event) {
        if (event != RawSocketEvent.read) return;
        final dg = boundUdp.receive();
        if (dg == null) return;
        clientAddress ??= dg.address;
        clientPort ??= dg.port;
        final parsed = _decodeSocksUdpPacket(dg.data);
        if (parsed == null) return;
        boundAssoc.send(parsed.host, parsed.port, parsed.data);
      });

      // tunnel -> here: wrap each datagram back into the SOCKS5 UDP header
      // and send it to whichever local address tun2socks has been using.
      incomingSub = boundAssoc.incoming.listen((d) {
        final addr = clientAddress;
        final cport = clientPort;
        if (addr == null || cport == null) return;
        boundUdp.send(_encodeSocksUdpPacket(d.host, d.port, d.data), addr, cport);
      });

      await bs.onClosed;
    } catch (e) {
      log('[socks5] udp associate failed: $e');
    } finally {
      unawaited(udpSub?.cancel());
      unawaited(incomingSub?.cancel());
      boundUdp.close();
      boundAssoc.close();
      controlSocket.destroy();
    }
  }
}

class _SocksUdpPacket {
  final String host;
  final int port;
  final Uint8List data;
  _SocksUdpPacket(this.host, this.port, this.data);
}

/// Decodes a SOCKS5 UDP relay packet (RFC1928 §7): `RSV(2)=0 || FRAG(1)=0 ||
/// ATYP || DST.ADDR || DST.PORT || DATA`. Fragmentation (FRAG != 0) isn't
/// supported -- no real client needs it for DNS-sized datagrams.
_SocksUdpPacket? _decodeSocksUdpPacket(Uint8List raw) {
  if (raw.length < 4 || raw[0] != 0 || raw[1] != 0 || raw[2] != 0) return null;
  final atyp = raw[3];
  var offset = 4;
  String host;
  switch (atyp) {
    case 0x01:
      if (raw.length < offset + 4) return null;
      host = '${raw[offset]}.${raw[offset + 1]}.${raw[offset + 2]}.${raw[offset + 3]}';
      offset += 4;
      break;
    case 0x03:
      if (raw.length <= offset) return null;
      final len = raw[offset];
      offset += 1;
      if (raw.length < offset + len) return null;
      host = String.fromCharCodes(raw.sublist(offset, offset + len));
      offset += len;
      break;
    case 0x04:
      if (raw.length < offset + 16) return null;
      host = _formatIpv6(raw.sublist(offset, offset + 16));
      offset += 16;
      break;
    default:
      return null;
  }
  if (raw.length < offset + 2) return null;
  final port = (raw[offset] << 8) | raw[offset + 1];
  offset += 2;
  return _SocksUdpPacket(host, port, Uint8List.fromList(raw.sublist(offset)));
}

/// Encodes the same header format for the reply direction.
Uint8List _encodeSocksUdpPacket(String host, int port, Uint8List data) {
  final w = BytesBuilder();
  w.add([0, 0, 0]); // RSV, RSV, FRAG
  final ipv4 = _tryParseIpv4(host);
  if (ipv4 != null) {
    w.add([0x01, ...ipv4]);
  } else {
    final hostBytes = utf8.encode(host);
    w.add([0x03, hostBytes.length]);
    w.add(hostBytes);
  }
  w.add([(port >> 8) & 0xff, port & 0xff]);
  w.add(data);
  return w.toBytes();
}

List<int>? _tryParseIpv4(String host) {
  final parts = host.split('.');
  if (parts.length != 4) return null;
  final out = <int>[];
  for (final p in parts) {
    final n = int.tryParse(p);
    if (n == null || n < 0 || n > 255) return null;
    out.add(n);
  }
  return out;
}

String _formatIpv6(List<int> b) {
  final parts = <String>[];
  for (var i = 0; i < 16; i += 2) {
    parts.add(((b[i] << 8) | b[i + 1]).toRadixString(16));
  }
  return parts.join(':');
}

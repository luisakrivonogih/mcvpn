import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../core/log.dart';
import '../tunnel/multiplexer.dart';
import '../tunnel/tunnel_client.dart';
import 'relay.dart';

/// A local HTTP proxy carried over the tunnel. Handles both `CONNECT`
/// (HTTPS and any tunnelled TCP) and absolute-form plain HTTP requests —
/// the front door proxy-aware apps expect.
class HttpProxy {
  final TunnelClient tunnel;
  final LogSink log;
  ServerSocket? _server;

  HttpProxy(this.tunnel, this.log);

  int get port => _server?.port ?? 0;

  Future<void> start(InternetAddress address, int port) async {
    final server = await ServerSocket.bind(address, port, shared: false);
    _server = server;
    log('[http] listening on ${address.address}:${server.port}');
    server.listen(_handle, onError: (Object e) => log('[http] accept error: $e'));
  }

  Future<void> stop() async {
    await _server?.close();
    _server = null;
  }

  Future<void> _handle(Socket socket) async {
    final bs = BufferedSocket(socket);
    try {
      final headBytes = await bs.readUntilHeaderEnd();
      final head = ascii.decode(headBytes, allowInvalid: true);
      final lines = head.split('\r\n');
      final requestLine = lines.isNotEmpty ? lines.first : '';
      final parts = requestLine.split(' ');
      if (parts.length < 3) {
        bs.write(ascii.encode('HTTP/1.1 400 Bad Request\r\n\r\n'));
        bs.destroy();
        return;
      }
      final method = parts[0].toUpperCase();
      final target = parts[1];

      if (method == 'CONNECT') {
        await _handleConnect(bs, target);
      } else {
        await _handlePlain(bs, method, target, lines);
      }
    } catch (e) {
      log('[http] session error: $e');
      bs.destroy();
    }
  }

  Future<void> _handleConnect(BufferedSocket bs, String authority) async {
    final target = _normalizeAuthority(authority, defaultPort: 443);
    TunnelStream stream;
    try {
      stream = await tunnel.openStream(target);
    } catch (e) {
      log('[http] CONNECT $target failed: $e');
      bs.write(ascii.encode('HTTP/1.1 502 Bad Gateway\r\n\r\n'));
      bs.destroy();
      return;
    }
    bs.write(ascii.encode('HTTP/1.1 200 Connection Established\r\n\r\n'));
    await bs.relayTo(stream);
  }

  Future<void> _handlePlain(
      BufferedSocket bs, String method, String target, List<String> lines) async {
    Uri uri;
    try {
      uri = Uri.parse(target);
    } catch (_) {
      bs.write(ascii.encode('HTTP/1.1 400 Bad Request\r\n\r\n'));
      bs.destroy();
      return;
    }
    if (!uri.hasScheme || uri.host.isEmpty) {
      bs.write(ascii.encode('HTTP/1.1 400 Bad Request\r\n\r\n'));
      bs.destroy();
      return;
    }
    final port = uri.hasPort ? uri.port : 80;
    final targetHost = '${uri.host}:$port';

    // Rebuild an origin-form request for the destination server.
    final pathAndQuery =
        uri.path.isEmpty ? '/' : (uri.hasQuery ? '${uri.path}?${uri.query}' : uri.path);
    final sb = StringBuffer('$method $pathAndQuery HTTP/1.1\r\n');
    var hasHost = false;
    for (var i = 1; i < lines.length; i++) {
      final line = lines[i];
      if (line.isEmpty) continue;
      final lower = line.toLowerCase();
      if (lower.startsWith('proxy-connection:')) continue;
      if (lower.startsWith('host:')) hasHost = true;
      sb.write('$line\r\n');
    }
    if (!hasHost) {
      sb.write('Host: ${uri.host}${uri.hasPort ? ':$port' : ''}\r\n');
    }
    sb.write('\r\n');

    TunnelStream stream;
    try {
      stream = await tunnel.openStream(targetHost);
    } catch (e) {
      log('[http] $method $targetHost failed: $e');
      bs.write(ascii.encode('HTTP/1.1 502 Bad Gateway\r\n\r\n'));
      bs.destroy();
      return;
    }
    await stream.send(Uint8List.fromList(ascii.encode(sb.toString())));
    await bs.relayTo(stream);
  }

  String _normalizeAuthority(String authority, {required int defaultPort}) {
    if (authority.startsWith('[')) {
      // IPv6 literal, possibly with port.
      final close = authority.indexOf(']');
      if (close > 0) {
        final rest = authority.substring(close + 1);
        if (rest.startsWith(':')) return authority;
        return '$authority:$defaultPort';
      }
    }
    if (authority.contains(':')) return authority;
    return '$authority:$defaultPort';
  }
}

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'camouflage.dart';
import 'log.dart';
import 'mc_codec.dart';
import 'mc_packets.dart';

/// The plugin-channel the Play-state byte transport rides on. Also a
/// wire-visible fingerprint, isolated here for easy change.
const String tunnelChannel = 'mcvpn:tunnel';

/// Bukkit's plugin-message cap is 32766; stay comfortably under it.
const int maxFrameLen = 32000;

int _usernameCounter = 0;

/// Best-effort plain-text extraction from a Minecraft chat-component JSON
/// string -- the format both Login and Play Disconnect packets carry as
/// their reason. Falls back to the raw string if it isn't valid JSON (a
/// non-vanilla server could send a bare string), so the caller always gets
/// *something* rather than a silently swallowed reason.
String _plainTextFromChatJson(String raw) {
  try {
    final buf = StringBuffer();
    void visit(Object? node) {
      if (node is String) {
        buf.write(node);
      } else if (node is Map) {
        final text = node['text'];
        if (text is String) buf.write(text);
        final extra = node['extra'];
        if (extra is List) extra.forEach(visit);
      } else if (node is List) {
        node.forEach(visit);
      }
    }

    visit(jsonDecode(raw));
    final text = buf.toString();
    return text.isEmpty ? raw : text;
  } catch (_) {
    return raw;
  }
}

/// Reads a Login/Play Disconnect packet's reason, tolerating malformed
/// framing rather than letting a raw decode exception (e.g. FormatException
/// from invalid UTF-8) surface as the connection failure in place of the
/// actual disconnect reason -- a truncated/misaligned read here has been
/// observed intermittently and isn't fully root-caused yet, but whatever
/// its cause, it shouldn't hide the reason on the attempts that decode fine.
String _readDisconnectReason(RawPacket p) {
  try {
    return _plainTextFromChatJson(p.reader().string());
  } catch (e) {
    return 'reason unavailable ($e)';
  }
}

/// A short hex dump of a packet body, capped so a huge (e.g. GameJoin-sized)
/// payload doesn't blow up a log line -- just enough bytes to tell a real
/// server-sent packet apart from decode garbage.
String _hexPreview(Uint8List bytes, [int max = 48]) {
  final take = bytes.length > max ? bytes.sublist(0, max) : bytes;
  final s = take.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');
  return bytes.length > max ? '$s… (${bytes.length}B)' : s;
}

/// An async FIFO of decoded packets fed by the socket listener and drained
/// both by the login sequence and, later, the Play-state actor loop.
class _PacketQueue {
  final Queue<RawPacket> _items = Queue();
  Completer<RawPacket?>? _waiter;
  bool _closed = false;
  Object? _error;

  void add(RawPacket p) {
    if (_closed) return;
    final w = _waiter;
    if (w != null) {
      _waiter = null;
      w.complete(p);
    } else {
      _items.add(p);
    }
  }

  void close([Object? error]) {
    if (_closed) return;
    _closed = true;
    _error = error;
    final w = _waiter;
    if (w != null) {
      _waiter = null;
      w.complete(null);
    }
  }

  /// Returns the next packet, or null once the connection is closed.
  Future<RawPacket?> next() {
    if (_items.isNotEmpty) return Future.value(_items.removeFirst());
    if (_closed) return Future.value(null);
    final c = Completer<RawPacket?>();
    _waiter = c;
    return c.future;
  }

  Object? get error => _error;
}

/// A live Minecraft transport session, already through Handshake → Login →
/// Play with the tunnel channel announced. Exposes a simple byte pipe: send
/// tunnel payloads with [sendTunnel], receive them from [inbound].
class McSession {
  final Socket _socket;
  final MinecraftCodec _codec;
  final _PacketQueue _queue;
  final LogSink _log;

  final String uuid;
  final String username;
  final int entityId;

  final StreamController<Uint8List> _inboundCtrl =
      StreamController<Uint8List>();
  final Completer<void> _done = Completer<void>();

  Timer? _idleTimer;
  late final IdleSimulator _idle;
  bool _closed = false;

  McSession._(this._socket, this._codec, this._queue, this._log,
      {required this.uuid, required this.username, required this.entityId}) {
    _idle = IdleSimulator(entityId, 0, 0);
  }

  /// Tunnel-channel payloads arriving from the plugin.
  Stream<Uint8List> get inbound => _inboundCtrl.stream;

  /// Completes when the underlying connection has ended.
  Future<void> get done => _done.future;

  /// Sends a raw tunnel payload as a plugin message on the tunnel channel.
  void sendTunnel(Uint8List payload) {
    if (_closed) return;
    if (payload.length > maxFrameLen) {
      _log('[mc] outbound frame ${payload.length}B exceeds cap; closing');
      close();
      return;
    }
    _writePacket(
        PacketId.customPayloadC2s, buildCustomPayload(tunnelChannel, payload));
  }

  void _writePacket(int id, Uint8List body) {
    if (_closed) return;
    try {
      _socket.add(_codec.encode(id, body));
    } catch (e) {
      _log('[mc] write failed: $e');
      close();
    }
  }

  /// Connects and drives the connection all the way into Play.
  static Future<McSession> connect({
    required String host,
    required int port,
    required String usernamePrefix,
    required LogSink log,
  }) async {
    final socket = await Socket.connect(host, port,
        timeout: const Duration(seconds: 15));
    socket.setOption(SocketOption.tcpNoDelay, true);

    final codec = MinecraftCodec();
    final queue = _PacketQueue();

    late StreamSubscription<Uint8List> sub;
    sub = socket.listen(
      (data) {
        codec.feed(data);
        while (true) {
          RawPacket? p;
          try {
            p = codec.nextPacket();
          } catch (e) {
            queue.close(e);
            return;
          }
          if (p == null) break;
          // Must take effect before the next loop iteration decodes
          // whatever's already sitting in the buffer behind this packet --
          // reacting to SetCompression only later, from the async login
          // loop that drains `queue`, is one event-loop turn too late if
          // the server's *next* packet arrived in the same TCP segment
          // (extremely common: Paper sends SetCompression immediately
          // followed by a throttled login's Disconnect in one write). That
          // next packet would already be compressed server-side, but we'd
          // still be decoding it as plaintext, corrupting it -- this is
          // exactly what the intermittent "server rejected login: reason
          // unavailable (FormatException: ...)" reports turned out to be.
          if (p.id == PacketId.loginCompressionS2c) {
            final threshold = p.reader().varInt();
            codec.setCompression(threshold >= 0 ? threshold : -1);
          }
          queue.add(p);
        }
      },
      onError: (Object e) => queue.close(e),
      onDone: () => queue.close(),
      cancelOnError: true,
    );

    Future<RawPacket> expect() async {
      final p = await queue.next();
      if (p == null) {
        throw StateError(queue.error?.toString() ??
            'connection closed during handshake');
      }
      return p;
    }

    // Every packet seen during login/join, kept only so a failure can report
    // exactly what led up to it -- this state machine has no business
    // hitting an unexpected packet or a login-time disconnect once the
    // server has already sent LoginSuccess, so if that ever happens the
    // trail is the only way to tell "the server really did reject us" apart
    // from "we lost sync decoding something earlier" (compression, a large
    // GameJoin split across many more TCP segments than usual, etc. --
    // exactly the kind of thing that reproduces on a real mobile network
    // and not over a fast local one).
    final trail = <String>[];
    void traced(RawPacket p, [String suffix = '']) {
      trail.add('0x${p.id.toRadixString(16).padLeft(2, '0')}/${p.body.length}B$suffix');
    }

    try {
      // Handshake (no reply) then LoginStart.
      socket.add(codec.encode(PacketId.handshake, buildHandshake(host, port)));
      final username = _uniqueUsername(usernamePrefix);
      socket.add(codec.encode(PacketId.loginHelloC2s, buildLoginHello(username)));

      String? uuid;
      String? gotUsername;

      // Login state loop.
      loginLoop:
      while (true) {
        final p = await expect();
        traced(p);
        switch (p.id) {
          case PacketId.loginDisconnectS2c:
            throw StateError('server rejected login: ${_readDisconnectReason(p)} '
                '(raw ${_hexPreview(p.body)}) [trail: ${trail.join(' ')}]');
          case PacketId.loginHelloS2c:
            throw StateError(
                'server requested online-mode encryption (unsupported)');
          case PacketId.loginCompressionS2c:
            final threshold = p.reader().varInt();
            codec.setCompression(threshold >= 0 ? threshold : -1);
            break;
          case PacketId.loginQueryRequestS2c:
            final messageId = p.reader().varInt();
            socket.add(codec.encode(PacketId.loginQueryResponseC2s,
                buildLoginQueryResponse(messageId)));
            break;
          case PacketId.loginSuccessS2c:
            final s = parseLoginSuccess(p.reader());
            uuid = s.uuid;
            gotUsername = s.username;
            break loginLoop;
          default:
            throw StateError('unexpected packet 0x${p.id.toRadixString(16)} '
                'during login (raw ${_hexPreview(p.body)}) [trail: ${trail.join(' ')}]');
        }
      }

      // First Play packet is GameJoin.
      final join = await expect();
      traced(join, '(play)');
      if (join.id == PacketId.disconnectS2c) {
        throw StateError('server disconnected us entering play: ${_readDisconnectReason(join)} '
            '[trail: ${trail.join(' ')}]');
      }
      if (join.id != PacketId.gameJoinS2c) {
        throw StateError('expected GameJoin, got 0x${join.id.toRadixString(16)} '
            '(raw ${_hexPreview(join.body)}) [trail: ${trail.join(' ')}]');
      }
      final entityId = parseGameJoinEntityId(join.reader());

      // A real client sends ClientSettings immediately, then registers the
      // channels it understands.
      socket.add(codec.encode(PacketId.clientSettingsC2s, buildClientSettings()));
      socket.add(codec.encode(PacketId.customPayloadC2s,
          buildCustomPayload('minecraft:register', tunnelChannel.codeUnits)));

      final session = McSession._(socket, codec, queue, log,
          uuid: uuid, username: gotUsername, entityId: entityId);
      sub.onData(session._onData);
      sub.onError((Object e) => session._onError(e));
      sub.onDone(session._onDone);
      session._start();
      return session;
    } catch (e) {
      await sub.cancel();
      socket.destroy();
      rethrow;
    }
  }

  void _start() {
    _scheduleIdle();
    _drainInbound();
  }

  void _onData(Uint8List data) {
    _codec.feed(data);
    while (true) {
      RawPacket? p;
      try {
        p = _codec.nextPacket();
      } catch (e) {
        _onError(e);
        return;
      }
      if (p == null) break;
      _queue.add(p);
    }
  }

  void _onError(Object e) {
    _log('[mc] connection error: $e');
    _queue.close(e);
  }

  void _onDone() {
    _queue.close();
  }

  Future<void> _drainInbound() async {
    while (true) {
      final p = await _queue.next();
      if (p == null) break;
      _handlePlay(p);
      if (_closed) break;
    }
    close();
  }

  void _handlePlay(RawPacket p) {
    switch (p.id) {
      case PacketId.customPayloadS2c:
        final msg = parseCustomPayload(p.reader());
        if (msg.channel == tunnelChannel && !_inboundCtrl.isClosed) {
          _inboundCtrl.add(Uint8List.fromList(msg.data));
        }
        break;
      case PacketId.keepAliveS2c:
        final id = p.reader().u64();
        _writePacket(PacketId.keepAliveC2s, buildKeepAlive(id));
        break;
      case PacketId.disconnectS2c:
        _log('[mc] server disconnected us');
        close();
        break;
      case PacketId.playerPositionLookS2c:
        final ppl = parsePlayerPositionLook(p.reader());
        _idle.resync(ppl.yaw, ppl.pitch);
        _writePacket(
            PacketId.teleportConfirmC2s, buildTeleportConfirm(ppl.teleportId));
        break;
      default:
        break;
    }
  }

  void _scheduleIdle() {
    _idleTimer = Timer(_idle.nextDelay(), () {
      if (_closed) return;
      final action = _idle.nextAction();
      _writePacket(action.id, action.body);
      _scheduleIdle();
    });
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _idleTimer?.cancel();
    if (!_inboundCtrl.isClosed) _inboundCtrl.close();
    try {
      _socket.destroy();
    } catch (_) {}
    if (!_done.isCompleted) _done.complete();
  }

  static String _uniqueUsername(String prefix) {
    final n = _usernameCounter++ & 0xffff;
    final nanos = DateTime.now().microsecondsSinceEpoch & 0xffff;
    final r = Random().nextInt(0xffff);
    var name = '$prefix${nanos.toRadixString(16).padLeft(4, '0')}'
        '${(n ^ r).toRadixString(16).padLeft(4, '0')}';
    if (name.length > 16) name = name.substring(0, 16);
    return name;
  }
}

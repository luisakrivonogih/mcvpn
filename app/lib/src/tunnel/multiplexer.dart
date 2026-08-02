import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import '../core/async_queue.dart';
import '../core/log.dart';
import '../core/mc_session.dart';
import '../crypto/tunnel_crypto.dart';
import 'credit.dart';
import 'tunnel_frame.dart';

/// Wire-sized chunk cap: `maxFrameLen` minus frame header + AEAD overhead.
const int maxStreamChunk = 31000;

/// Bytes of unacknowledged data a stream may have in flight before its sender
/// must wait for a WindowUpdate.
const int _initialWindow = 256 * 1024;

const Duration _handshakeTimeout = Duration(seconds: 10);
const Duration _rotationInterval = Duration(seconds: 600);
const Duration _rotationJitter = Duration(seconds: 90);

Duration _nextRotationDelay() {
  final jitterMs = Random().nextInt(2 * _rotationJitter.inMilliseconds + 1);
  return _rotationInterval - _rotationJitter + Duration(milliseconds: jitterMs);
}

/// A single logical stream multiplexed over the tunnel: a plain bidirectional
/// byte pipe to a `host:port` on the far side.
class TunnelStream {
  final int id;
  final Credit _credit;
  final void Function(Frame) _enqueue;
  final StreamController<Uint8List> _incoming =
      StreamController<Uint8List>(sync: false);
  bool _sendClosed = false;

  TunnelStream(this.id, this._credit, this._enqueue);

  /// Inbound bytes from the far side. Ends when the stream closes either way.
  Stream<Uint8List> get incoming => _incoming.stream;

  /// Sends [data], chunked and flow-controlled. Only ever blocks this stream.
  Future<void> send(Uint8List data) async {
    var offset = 0;
    while (offset < data.length) {
      final end = min(offset + maxStreamChunk, data.length);
      final chunk = Uint8List.sublistView(data, offset, end);
      offset = end;
      await _credit.acquire(chunk.length);
      _enqueue(Frame.dataFrame(id, Uint8List.fromList(chunk)));
    }
  }

  void closeSend() {
    if (_sendClosed) return;
    _sendClosed = true;
    _enqueue(Frame.closeFrame(id));
  }

  void _deliver(Uint8List data) {
    if (!_incoming.isClosed) _incoming.add(data);
  }

  void _remoteClosed() {
    _credit.close();
    if (!_incoming.isClosed) _incoming.close();
  }
}

/// A UDP association multiplexed over the tunnel: unlike [TunnelStream],
/// there's no fixed target (each datagram names its own destination) and no
/// flow control -- datagrams are inherently lossy/unordered already, and
/// each one is capped well under the frame size limit by [Socks5Proxy], so
/// there's nothing worth back-pressuring.
class UdpAssociation {
  final int id;
  final void Function(Frame) _enqueue;
  final StreamController<UdpDatagramPayload> _incoming =
      StreamController<UdpDatagramPayload>(sync: false);
  bool _closed = false;

  UdpAssociation(this.id, this._enqueue);

  /// Inbound datagrams from the far side, each tagged with where it came
  /// from. Ends when the association closes either way.
  Stream<UdpDatagramPayload> get incoming => _incoming.stream;

  /// Sends one datagram to `host:port`. Fire-and-forget, like real UDP.
  void send(String host, int port, Uint8List data) {
    if (_closed) return;
    _enqueue(Frame.datagram(id, host, port, data));
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _enqueue(Frame.closeFrame(id));
  }

  void _deliver(UdpDatagramPayload d) {
    if (!_incoming.isClosed) _incoming.add(d);
  }

  void _remoteClosed() {
    if (!_incoming.isClosed) _incoming.close();
  }
}

/// One live tunnel over a single Minecraft connection: runs the authenticated
/// key exchange, then a single serialized event loop that owns the session
/// keys and all stream bookkeeping (mirrors `tunnel::multiplex` on Rust).
class TunnelConnection {
  final McSession _session;
  final List<int> _secret;
  final SessionCrypto _crypto;
  final LogSink _log;
  final void Function(int up, int down)? _onTraffic;

  final AsyncQueue<_Event> _events = AsyncQueue<_Event>();
  final Map<int, _Entry> _streams = {};
  int _nextStreamId = 1;
  EphemeralKeypair? _pendingRotation;
  Timer? _rotationTimer;
  StreamSubscription<Uint8List>? _sub;
  bool _running = true;
  int _totalStreams = 0;
  final Completer<void> _closed = Completer<void>();

  int get activeStreams => _streams.length;
  int get totalStreams => _totalStreams;

  TunnelConnection._(
      this._session, this._secret, this._crypto, this._log, this._onTraffic);

  Future<void> get done => _closed.future;
  bool get isAlive => _running;

  /// Establishes a Minecraft session's tunnel: runs the crypto handshake and
  /// starts the event loop.
  static Future<TunnelConnection> establish({
    required McSession session,
    required List<int> keyId,
    required List<int> secret,
    required LogSink log,
    void Function(int up, int down)? onTraffic,
  }) async {
    // All inbound tunnel payloads flow through one queue, in order. The
    // handshake reads the first message; a single pump then feeds every
    // subsequent payload into the event loop as an InboundEnvelope — keeping
    // strict wire order (important for the AEAD counter check).
    final inbox = AsyncQueue<Uint8List>();
    final sub = session.inbound.listen(inbox.add, onDone: inbox.close);

    try {
      final crypto = await _performHandshake(session, inbox, keyId, secret, log);
      final conn = TunnelConnection._(session, secret, crypto, log, onTraffic);
      conn._sub = sub;
      unawaited(conn._pumpInbound(inbox));
      session.done.then((_) => conn._events.add(_ConnectionDown()));
      conn._start();
      return conn;
    } catch (e) {
      await sub.cancel();
      rethrow;
    }
  }

  Future<void> _pumpInbound(AsyncQueue<Uint8List> inbox) async {
    while (true) {
      final p = await inbox.next();
      if (p == null) break;
      _events.add(_InboundEnvelope(p));
    }
    _events.add(_ConnectionDown());
  }

  static Future<SessionCrypto> _performHandshake(
      McSession session,
      AsyncQueue<Uint8List> inbox,
      List<int> keyId,
      List<int> secret,
      LogSink log) async {
    final connectionId = _randomBytes(connectionIdLen);
    final keypair = await EphemeralKeypair.generate();
    final epkC = keypair.publicKey;
    final mac1 = await handshakeMac1(secret, connectionId, keyId, epkC);

    final message1 = concatBytes([connectionId, keyId, epkC, mac1]);
    session.sendTunnel(message1);

    final reply = await inbox.next().timeout(_handshakeTimeout, onTimeout: () {
      throw TimeoutException(
          'handshake timed out — key_id/secret likely does not match');
    });
    if (reply == null) throw StateError('tunnel closed during handshake');
    if (reply.length != publicKeyLen + macLen) {
      throw StateError('malformed handshake reply');
    }
    final epkS = Uint8List.sublistView(reply, 0, publicKeyLen);
    final mac2 = Uint8List.sublistView(reply, publicKeyLen);
    final expectedMac2 =
        await handshakeMac2(secret, connectionId, keyId, epkC, epkS);
    if (!constantTimeEquals(mac2, expectedMac2)) {
      throw StateError('handshake authentication failed — credential mismatch');
    }
    final dh = await keypair.diffieHellman(epkS);
    log('[tunnel] handshake complete');
    return SessionCrypto.derive(
      secret: secret,
      connectionId: connectionId,
      epkC: epkC,
      epkS: epkS,
      dhOutput: dh,
      weAreClient: true,
    );
  }

  void _start() {
    _rotationTimer = Timer(_nextRotationDelay(), _onRotationTick);
    unawaited(_runLoop());
  }

  void _onRotationTick() {
    _events.add(_RotationTick());
    _rotationTimer = Timer(_nextRotationDelay(), _onRotationTick);
  }

  /// Opens a new logical stream to `host:port`.
  Future<TunnelStream> openStream(String target) {
    if (!_running) {
      return Future.error(StateError('tunnel is down'));
    }
    final completer = Completer<TunnelStream>();
    _events.add(_OpenRequest(target, completer));
    return completer.future;
  }

  /// Opens a new UDP association -- see [UdpAssociation] for why this has no
  /// fixed target, unlike [openStream].
  Future<UdpAssociation> openUdpAssociation() {
    if (!_running) {
      return Future.error(StateError('tunnel is down'));
    }
    final completer = Completer<UdpAssociation>();
    _events.add(_OpenUdpRequest(completer));
    return completer.future;
  }

  Future<void> _runLoop() async {
    while (_running) {
      final event = await _events.next();
      if (event == null) break;
      try {
        await _handle(event);
      } catch (e) {
        _log('[tunnel] loop error: $e');
      }
    }
    _shutdown();
  }

  Future<void> _handle(_Event event) async {
    if (event is _OpenRequest) {
      final id = _nextStreamId++;
      _totalStreams++;
      final credit = Credit(_initialWindow);
      final stream = TunnelStream(id, credit, _enqueueOutbound);
      _streams[id] = _StreamEntry(stream, credit);
      final sealed = await _crypto.seal(Frame.open(id, event.target).encode());
      _session.sendTunnel(sealed);
      event.completer.complete(stream);
    } else if (event is _OpenUdpRequest) {
      final id = _nextStreamId++;
      _totalStreams++;
      final assoc = UdpAssociation(id, _enqueueOutbound);
      _streams[id] = _UdpEntry(assoc);
      final sealed = await _crypto.seal(Frame.openUdp(id).encode());
      _session.sendTunnel(sealed);
      event.completer.complete(assoc);
    } else if (event is _OutboundFrame) {
      final frame = event.frame;
      if (frame.type == FrameType.data || frame.type == FrameType.datagram) {
        _onTraffic?.call(frame.payload.length, 0);
      }
      final sealed = await _crypto.seal(frame.encode());
      _session.sendTunnel(sealed);
      if (frame.type == FrameType.close) {
        _streams.remove(frame.streamId);
      }
    } else if (event is _InboundEnvelope) {
      await _handleInbound(event.sealed);
    } else if (event is _RotationTick) {
      if (_pendingRotation == null) {
        final kp = await EphemeralKeypair.generate();
        final sealed = await _crypto.seal(Frame.keyUpdate(kp.publicKey).encode());
        _session.sendTunnel(sealed);
        _pendingRotation = kp;
      }
    } else if (event is _ConnectionDown) {
      _running = false;
    }
  }

  Future<void> _handleInbound(Uint8List sealed) async {
    Uint8List plaintext;
    try {
      plaintext = await _crypto.open(sealed);
    } catch (_) {
      return; // not from an authenticated peer, or corrupt — drop it
    }
    final frame = Frame.decode(plaintext);
    if (frame == null) return;

    if (frame.type == FrameType.keyUpdate) {
      await _handleKeyUpdate(frame);
      return;
    }

    switch (frame.type) {
      case FrameType.data:
        final entry = _streams[frame.streamId];
        if (entry is! _StreamEntry) return;
        _onTraffic?.call(0, frame.payload.length);
        entry.stream._deliver(frame.payload);
        _enqueueOutbound(Frame.windowUpdate(frame.streamId, frame.payload.length));
        break;
      case FrameType.datagram:
        final entry = _streams[frame.streamId];
        if (entry is! _UdpEntry) return;
        final d = Frame.decodeDatagram(frame.payload);
        if (d == null) return;
        _onTraffic?.call(0, frame.payload.length);
        entry.assoc._deliver(d);
        break;
      case FrameType.windowUpdate:
        if (frame.payload.length == 4) {
          final credit =
              ByteData.sublistView(frame.payload).getUint32(0, Endian.big);
          final entry = _streams[frame.streamId];
          if (entry is _StreamEntry) entry.credit.release(credit);
        }
        break;
      case FrameType.close:
        final entry = _streams.remove(frame.streamId);
        entry?.remoteClosed();
        break;
      case FrameType.ping:
        _enqueueOutbound(Frame(controlStream, FrameType.pong, frame.payload));
        break;
      case FrameType.pong:
      case FrameType.open:
      case FrameType.openUdp:
      case FrameType.keyUpdate:
        break;
    }
  }

  Future<void> _handleKeyUpdate(Frame frame) async {
    if (frame.payload.length != publicKeyLen) return;
    final theirEpk = frame.payload;
    final pending = _pendingRotation;
    if (pending != null) {
      // We initiated; this is their reply. We're "a", they're "b".
      _pendingRotation = null;
      final dh = await pending.diffieHellman(theirEpk);
      await _crypto.completeRotation(
          secret: _secret, epkA: pending.publicKey, epkB: theirEpk, dhOutput: dh);
    } else {
      // They initiated; we reply. They're "a", we're "b".
      final kp = await EphemeralKeypair.generate();
      final dh = await kp.diffieHellman(theirEpk);
      final replyPlain = Frame.keyUpdate(kp.publicKey).encode();
      final sealedReply = await _crypto.replyToRotation(
        secret: _secret,
        epkA: theirEpk,
        epkB: kp.publicKey,
        dhOutput: dh,
        replyPlaintext: replyPlain,
      );
      _session.sendTunnel(sealedReply);
    }
  }

  void _enqueueOutbound(Frame frame) {
    if (!_running) return;
    _events.add(_OutboundFrame(frame));
  }

  void _shutdown() {
    _running = false;
    _rotationTimer?.cancel();
    _sub?.cancel();
    _sub = null;
    for (final entry in _streams.values) {
      entry.remoteClosed();
    }
    _streams.clear();
    _session.close();
    if (!_closed.isCompleted) _closed.complete();
  }

  void close() {
    _running = false;
    _events.add(_ConnectionDown());
  }
}

/// Either a TCP [_StreamEntry] or a UDP [_UdpEntry], keyed by streamId in the
/// same shared id space -- [FrameType.close] doesn't say which kind it's
/// closing, so the common teardown lives here.
abstract class _Entry {
  void remoteClosed();
}

class _StreamEntry extends _Entry {
  final TunnelStream stream;
  final Credit credit;
  _StreamEntry(this.stream, this.credit);

  @override
  void remoteClosed() => stream._remoteClosed();
}

class _UdpEntry extends _Entry {
  final UdpAssociation assoc;
  _UdpEntry(this.assoc);

  @override
  void remoteClosed() => assoc._remoteClosed();
}

Uint8List _randomBytes(int n) {
  final r = Random.secure();
  final out = Uint8List(n);
  for (var i = 0; i < n; i++) {
    out[i] = r.nextInt(256);
  }
  return out;
}

// --- Event types for the single serialized loop ---
abstract class _Event {}

class _OpenRequest extends _Event {
  final String target;
  final Completer<TunnelStream> completer;
  _OpenRequest(this.target, this.completer);
}

class _OpenUdpRequest extends _Event {
  final Completer<UdpAssociation> completer;
  _OpenUdpRequest(this.completer);
}

class _OutboundFrame extends _Event {
  final Frame frame;
  _OutboundFrame(this.frame);
}

class _InboundEnvelope extends _Event {
  final Uint8List sealed;
  _InboundEnvelope(this.sealed);
}

class _RotationTick extends _Event {}

class _ConnectionDown extends _Event {}

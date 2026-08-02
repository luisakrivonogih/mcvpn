import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../tunnel/multiplexer.dart';

/// Wraps a single-subscription [Socket] so a proxy handshake can pull bytes
/// (readByte / readBytes / readLine) and then hand the very same subscription
/// over to a full-duplex relay — without ever listening to the socket twice
/// (which dart:io forbids).
class BufferedSocket {
  final Socket socket;
  final List<int> _buffer = [];
  final List<Completer<void>> _waiters = [];
  late final StreamSubscription<Uint8List> _sub;
  bool _done = false;
  bool _relaying = false;
  TunnelStream? _stream;
  bool _shutdownCalled = false;
  final Completer<void> _closedCompleter = Completer<void>();

  BufferedSocket(this.socket) {
    socket.setOption(SocketOption.tcpNoDelay, true);
    _sub = socket.listen(
      _onData,
      onDone: () {
        _done = true;
        _completeClosed();
        if (_relaying) {
          _shutdown();
        } else {
          _wake();
        }
      },
      onError: (Object _) {
        _done = true;
        _completeClosed();
        if (_relaying) {
          _shutdown();
        } else {
          _wake();
        }
      },
    );
  }

  void _completeClosed() {
    if (!_closedCompleter.isCompleted) _closedCompleter.complete();
  }

  /// Resolves once the underlying socket has closed (or errored) -- used by
  /// SOCKS5 UDP ASSOCIATE, whose association lifetime is tied to this
  /// control connection per RFC1928, rather than to a relayed byte stream.
  Future<void> get onClosed => _closedCompleter.future;

  void _onData(Uint8List data) {
    if (_relaying) {
      final s = _stream;
      if (s != null) {
        s.send(Uint8List.fromList(data)).catchError((_) => _shutdown());
      }
    } else {
      _buffer.addAll(data);
      _wake();
    }
  }

  void _wake() {
    for (final w in _waiters) {
      if (!w.isCompleted) w.complete();
    }
    _waiters.clear();
  }

  Future<void> _await() {
    final c = Completer<void>();
    _waiters.add(c);
    return c.future;
  }

  Future<int> readByte() async => (await readBytes(1))[0];

  Future<List<int>> readBytes(int n) async {
    while (_buffer.length < n) {
      if (_done) throw StateError('socket closed mid-handshake');
      await _await();
    }
    final out = _buffer.sublist(0, n);
    _buffer.removeRange(0, n);
    return out;
  }

  /// Reads until a CRLFCRLF (end of an HTTP header block). Returns the bytes
  /// up to and including the terminator.
  Future<Uint8List> readUntilHeaderEnd({int maxBytes = 64 * 1024}) async {
    while (true) {
      final idx = _indexOfDoubleCrlf(_buffer);
      if (idx >= 0) {
        final end = idx + 4;
        final out = Uint8List.fromList(_buffer.sublist(0, end));
        _buffer.removeRange(0, end);
        return out;
      }
      if (_buffer.length > maxBytes) {
        throw StateError('HTTP header too large');
      }
      if (_done) throw StateError('socket closed before header end');
      await _await();
    }
  }

  void write(List<int> data) {
    try {
      socket.add(data);
    } catch (_) {
      _shutdown();
    }
  }

  /// Switches to full-duplex relay against [stream]. Any bytes already read
  /// past the handshake are forwarded first. Completes when the exchange ends.
  Future<void> relayTo(TunnelStream stream) async {
    _stream = stream;
    _relaying = true;

    // Flush leftover handshake bytes.
    if (_buffer.isNotEmpty) {
      final leftover = Uint8List.fromList(_buffer);
      _buffer.clear();
      unawaited(stream.send(leftover).catchError((_) => _shutdown()));
    }
    if (_done) {
      _shutdown();
      return;
    }

    final incomingSub = stream.incoming.listen(
      (data) {
        try {
          socket.add(data);
        } catch (_) {
          _shutdown();
        }
      },
      onDone: _shutdown,
      onError: (_) => _shutdown(),
    );

    final completer = Completer<void>();
    _onShutdown = () {
      incomingSub.cancel();
      if (!completer.isCompleted) completer.complete();
    };
    await completer.future;
  }

  void Function()? _onShutdown;

  void _shutdown() {
    if (_shutdownCalled) return;
    _shutdownCalled = true;
    _stream?.closeSend();
    _sub.cancel();
    try {
      socket.destroy();
    } catch (_) {}
    _onShutdown?.call();
  }

  void destroy() => _shutdown();
}

int _indexOfDoubleCrlf(List<int> b) {
  for (var i = 0; i + 3 < b.length; i++) {
    if (b[i] == 13 && b[i + 1] == 10 && b[i + 2] == 13 && b[i + 3] == 10) {
      return i;
    }
  }
  return -1;
}

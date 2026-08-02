import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/log.dart';
import '../core/mc_session.dart';
import 'multiplexer.dart';

enum TunnelPhase { idle, connecting, connected, reconnecting, stopped }

class TunnelStatus {
  final TunnelPhase phase;
  final String? detail;
  final String? username;
  const TunnelStatus(this.phase, {this.detail, this.username});
}

/// Supervises a tunnel for the lifetime it's asked to stay up: connect (with
/// backoff), run until the connection dies, reconnect, repeat — mirroring the
/// Rust client's `supervise`. Callers open streams through it and it fails
/// fast while reconnecting rather than queueing behind a dead connection.
class TunnelClient {
  final String host;
  final int port;
  final String usernamePrefix;
  final List<int> keyId;
  final List<int> secret;
  final LogSink log;
  final void Function(int up, int down)? onTraffic;

  final ValueNotifier<TunnelStatus> status =
      ValueNotifier<TunnelStatus>(const TunnelStatus(TunnelPhase.idle));

  TunnelConnection? _conn;
  bool _wantRunning = false;
  Duration _backoff = const Duration(seconds: 1);

  TunnelClient({
    required this.host,
    required this.port,
    required this.usernamePrefix,
    required this.keyId,
    required this.secret,
    required this.log,
    this.onTraffic,
  });

  bool get isConnected => _conn?.isAlive ?? false;
  int get activeStreams => _conn?.activeStreams ?? 0;
  int get totalStreams => _conn?.totalStreams ?? 0;

  /// Starts the supervise loop and returns once the first connection is up
  /// (or throws if the caller stops it before that).
  Future<void> start() async {
    if (_wantRunning) return;
    _wantRunning = true;
    unawaited(_supervise());
    // Wait until connected or stopped.
    final completer = Completer<void>();
    void listener() {
      final p = status.value.phase;
      if (p == TunnelPhase.connected && !completer.isCompleted) {
        completer.complete();
      } else if (p == TunnelPhase.stopped && !completer.isCompleted) {
        completer.completeError(StateError('tunnel stopped before connecting'));
      }
    }

    status.addListener(listener);
    try {
      await completer.future;
    } finally {
      status.removeListener(listener);
    }
  }

  Future<void> _supervise() async {
    while (_wantRunning) {
      status.value = const TunnelStatus(TunnelPhase.connecting);
      try {
        final session = await McSession.connect(
          host: host,
          port: port,
          usernamePrefix: usernamePrefix,
          log: log,
        );
        log('[tunnel] minecraft transport established: '
            '${session.username} (${session.uuid})');
        final conn = await TunnelConnection.establish(
          session: session,
          keyId: keyId,
          secret: secret,
          log: log,
          onTraffic: onTraffic,
        );
        _conn = conn;
        _backoff = const Duration(seconds: 1);
        status.value = TunnelStatus(TunnelPhase.connected,
            username: session.username);

        await conn.done;
        _conn = null;
        if (!_wantRunning) break;
        log('[tunnel] connection lost, reconnecting...');
        status.value = const TunnelStatus(TunnelPhase.reconnecting);
      } catch (e) {
        _conn = null;
        if (!_wantRunning) break;
        final message = e.toString();
        if (message.toLowerCase().contains('throttled') && _backoff.inSeconds < 6) {
          // Paper/Spigot's connection-throttle (spigot.yml, default 4s)
          // rejects repeat connections from the same IP inside that window.
          // Retrying on the normal 1s-start backoff just re-triggers it on
          // every single attempt, forever -- jump straight past the window
          // instead of ramping up from 1s.
          _backoff = const Duration(seconds: 6);
        }
        log('[tunnel] failed to connect: $e; retrying in '
            '${_backoff.inSeconds}s');
        status.value =
            TunnelStatus(TunnelPhase.reconnecting, detail: e.toString());
        await Future<void>.delayed(_backoff);
        _backoff = Duration(
            seconds: (_backoff.inSeconds * 2).clamp(1, 30));
      }
    }
    status.value = const TunnelStatus(TunnelPhase.stopped);
  }

  /// Opens a logical stream to `host:port`, or throws if reconnecting.
  Future<TunnelStream> openStream(String target) {
    final conn = _conn;
    if (conn == null || !conn.isAlive) {
      return Future.error(StateError('tunnel is reconnecting, try again shortly'));
    }
    return conn.openStream(target);
  }

  /// Opens a UDP association, or throws if reconnecting.
  Future<UdpAssociation> openUdpAssociation() {
    final conn = _conn;
    if (conn == null || !conn.isAlive) {
      return Future.error(StateError('tunnel is reconnecting, try again shortly'));
    }
    return conn.openUdpAssociation();
  }

  Future<void> stop() async {
    _wantRunning = false;
    _conn?.close();
    _conn = null;
    status.value = const TunnelStatus(TunnelPhase.stopped);
  }
}

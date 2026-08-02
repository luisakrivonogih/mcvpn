import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../model/models.dart';
import '../model/stats.dart';
import '../proxy/http_proxy.dart';
import '../proxy/socks5_proxy.dart';
import '../store/settings_store.dart';
import '../tunnel/tunnel_client.dart';
import 'system_proxy.dart';
import 'tun_platform.dart';

enum AppState { disconnected, connecting, connected, reconnecting, disconnecting, error }

/// The single source of truth the UI binds to: owns profiles/settings, the
/// live tunnel + proxies, traffic stats, and a rolling log.
class VpnController extends ChangeNotifier {
  final SettingsStore _store;

  final List<ServerProfile> _profiles = [];
  String? _selectedProfileId;
  ProxySettings _proxySettings = const ProxySettings();
  VpnMode _mode = VpnMode.systemProxy;

  AppState _state = AppState.disconnected;
  String? _statusDetail;
  String? _sessionUsername;

  final TrafficStats stats = TrafficStats();
  final Queue<LogEntry> _logs = Queue<LogEntry>();
  static const int _maxLogs = 500;

  TunnelClient? _tunnel;
  HttpProxy? _httpProxy;
  Socks5Proxy? _socksProxy;
  Timer? _statsTimer;
  int _lastUp = 0;
  int _lastDown = 0;

  VpnController(this._store);

  // --- Public state ---
  List<ServerProfile> get profiles => List.unmodifiable(_profiles);
  ProxySettings get proxySettings => _proxySettings;
  VpnMode get mode => _mode;
  AppState get state => _state;
  String? get statusDetail => _statusDetail;
  String? get sessionUsername => _sessionUsername;
  List<LogEntry> get logs => _logs.toList();
  bool get tunSupported => TunPlatform.isSupported;
  bool get systemProxySupported => SystemProxy.isSupported;

  ServerProfile? get selectedProfile {
    if (_profiles.isEmpty) return null;
    return _profiles.firstWhere(
      (p) => p.id == _selectedProfileId,
      orElse: () => _profiles.first,
    );
  }

  bool get isBusy =>
      _state == AppState.connecting ||
      _state == AppState.reconnecting ||
      _state == AppState.disconnecting;
  bool get isActive => _state != AppState.disconnected;

  Future<void> init() async {
    _profiles
      ..clear()
      ..addAll(_store.loadProfiles());
    _selectedProfileId = _store.selectedProfileId;
    _proxySettings = _store.loadProxySettings();
    _mode = _store.loadMode();
    if (!TunPlatform.isSupported && _mode == VpnMode.tun) {
      _mode = VpnMode.systemProxy;
    }
    if (!SystemProxy.isSupported && _mode == VpnMode.systemProxy) {
      _mode = VpnMode.tun;
    }
    notifyListeners();
  }

  // --- Profile management ---
  Future<void> upsertProfile(ServerProfile profile) async {
    final idx = _profiles.indexWhere((p) => p.id == profile.id);
    if (idx >= 0) {
      _profiles[idx] = profile;
    } else {
      _profiles.add(profile);
    }
    _selectedProfileId ??= profile.id;
    await _store.saveProfiles(_profiles);
    await _store.setSelectedProfileId(_selectedProfileId);
    notifyListeners();
  }

  Future<void> deleteProfile(String id) async {
    _profiles.removeWhere((p) => p.id == id);
    if (_selectedProfileId == id) {
      _selectedProfileId = _profiles.isEmpty ? null : _profiles.first.id;
    }
    await _store.saveProfiles(_profiles);
    await _store.setSelectedProfileId(_selectedProfileId);
    notifyListeners();
  }

  Future<void> selectProfile(String id) async {
    _selectedProfileId = id;
    await _store.setSelectedProfileId(id);
    notifyListeners();
  }

  Future<void> setMode(VpnMode mode) async {
    _mode = mode;
    await _store.saveMode(mode);
    notifyListeners();
  }

  Future<void> updateProxySettings(ProxySettings settings) async {
    _proxySettings = settings;
    await _store.saveProxySettings(settings);
    notifyListeners();
  }

  // --- Logging ---
  void log(String message) {
    _logs.add(LogEntry(DateTime.now(), message));
    while (_logs.length > _maxLogs) {
      _logs.removeFirst();
    }
    notifyListeners();
  }

  void clearLogs() {
    _logs.clear();
    notifyListeners();
  }

  // --- Connection lifecycle ---
  Future<void> connect() async {
    if (isActive) return;
    final profile = selectedProfile;
    if (profile == null) {
      _fail('No server selected');
      return;
    }
    final err = profile.validate();
    if (err != null) {
      _fail('Invalid profile: $err');
      return;
    }

    _setState(AppState.connecting);
    stats.reset();
    _lastUp = 0;
    _lastDown = 0;
    log('Connecting to ${profile.host}:${profile.port} in ${_mode.label} mode…');

    try {
      final tunnel = TunnelClient(
        host: profile.host,
        port: profile.port,
        usernamePrefix: profile.usernamePrefix,
        keyId: profile.keyId,
        secret: profile.keySecret,
        log: log,
        onTraffic: (up, down) {
          stats.bytesUp += up;
          stats.bytesDown += down;
        },
      );
      _tunnel = tunnel;
      tunnel.status.addListener(_onTunnelStatus);

      await tunnel.start();

      // Bind the local proxies.
      final address =
          _proxySettings.allowLan ? InternetAddress.anyIPv4 : InternetAddress.loopbackIPv4;
      final http = HttpProxy(tunnel, log);
      final socks = Socks5Proxy(tunnel, log);
      await http.start(address, _proxySettings.httpPort);
      await socks.start(address, _proxySettings.socksPort);
      _httpProxy = http;
      _socksProxy = socks;

      if (_mode == VpnMode.tun) {
        await _startTun();
      } else {
        await _startSystemProxy(http.port, socks.port);
      }

      stats.connectedSince = DateTime.now();
      _sessionUsername = tunnel.status.value.username;
      _setState(AppState.connected);
      _startStatsTimer();
      final modeSuffix = switch (_mode) {
        VpnMode.tun => '  •  full tunnel active',
        VpnMode.systemProxy => '  •  system proxy active',
      };
      log('Connected. HTTP proxy :${http.port}  •  SOCKS5 :${socks.port}$modeSuffix');
    } catch (e) {
      log('Connection failed: $e');
      await _teardown();
      _fail(e.toString());
    }
  }

  Future<void> _startTun() async {
    final ok = await TunPlatform.prepare();
    if (!ok) {
      throw StateError('VPN permission was not granted');
    }
    String? excludeIp;
    if (Platform.isWindows || Platform.isLinux) {
      final profile = selectedProfile!;
      final addrs = await InternetAddress.lookup(profile.host);
      if (addrs.isEmpty) {
        throw StateError('could not resolve ${profile.host} to exclude it from the tunnel');
      }
      excludeIp = addrs.first.address;
    }
    final started = await TunPlatform.start(
      socksPort: _socksProxy!.port,
      sessionName: selectedProfile?.name ?? 'mcvpn',
      excludeIp: excludeIp,
    );
    if (!started) {
      throw StateError('failed to start the OS VPN service');
    }
  }

  Future<void> _startSystemProxy(int httpPort, int socksPort) async {
    await SystemProxy.apply(httpPort: httpPort, socksPort: socksPort);
  }

  void _onTunnelStatus() {
    final st = _tunnel?.status.value;
    if (st == null) return;
    _statusDetail = st.detail;
    switch (st.phase) {
      case TunnelPhase.reconnecting:
        if (_state == AppState.connected) {
          _setState(AppState.reconnecting);
        }
        break;
      case TunnelPhase.connected:
        _sessionUsername = st.username;
        if (_state == AppState.reconnecting) {
          _setState(AppState.connected);
        }
        break;
      default:
        break;
    }
  }

  Future<void> disconnect() async {
    if (_state == AppState.disconnected || _state == AppState.disconnecting) return;
    log('Disconnecting…');
    _setState(AppState.disconnecting);
    await _teardown();
    stats.reset();
    _sessionUsername = null;
    _setState(AppState.disconnected);
    log('Disconnected.');
  }

  Future<void> _teardown() async {
    _statsTimer?.cancel();
    _statsTimer = null;
    if (_mode == VpnMode.tun) {
      try {
        await TunPlatform.stop();
      } catch (_) {}
    } else {
      try {
        await SystemProxy.revert();
      } catch (e) {
        log('[system-proxy] failed to revert cleanly: $e');
      }
    }
    await _httpProxy?.stop();
    await _socksProxy?.stop();
    _httpProxy = null;
    _socksProxy = null;
    _tunnel?.status.removeListener(_onTunnelStatus);
    await _tunnel?.stop();
    _tunnel = null;
  }

  void _startStatsTimer() {
    _statsTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      stats.upBytesPerSec = stats.bytesUp - _lastUp;
      stats.downBytesPerSec = stats.bytesDown - _lastDown;
      _lastUp = stats.bytesUp;
      _lastDown = stats.bytesDown;
      stats.activeStreams = _tunnel?.activeStreams ?? 0;
      stats.totalStreams = _tunnel?.totalStreams ?? 0;
      notifyListeners();
    });
  }

  void _fail(String message) {
    _statusDetail = message;
    _setState(AppState.error);
  }

  void _setState(AppState s) {
    _state = s;
    notifyListeners();
  }

  @override
  void dispose() {
    _teardown();
    super.dispose();
  }
}

class LogEntry {
  final DateTime time;
  final String message;
  LogEntry(this.time, this.message);
}

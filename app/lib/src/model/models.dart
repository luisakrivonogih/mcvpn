import 'dart:convert';
import 'dart:typed_data';

/// Which local front end carries traffic. Both modes run the local HTTP +
/// SOCKS5 proxies internally (see [VpnController]) -- they differ only in
/// how the rest of the system gets pointed at them.
enum VpnMode {
  /// Points the OS's system-wide proxy settings at the local proxies, so
  /// apps that don't have their own proxy setting (browsers, etc.) get
  /// routed automatically. Desktop only; apps that ignore the system proxy
  /// still go direct.
  systemProxy,

  /// Whole-device tunnel via the OS VPN service, routing all TCP/UDP through
  /// the tunnel. Requires the platform VPN permission.
  tun,
}

extension VpnModeX on VpnMode {
  String get label => switch (this) {
        VpnMode.systemProxy => 'System proxy',
        VpnMode.tun => 'Full tunnel',
      };
  String get id => switch (this) {
        VpnMode.systemProxy => 'system_proxy',
        VpnMode.tun => 'tun',
      };
  static VpnMode fromId(String? id) => switch (id) {
        'tun' => VpnMode.tun,
        _ => VpnMode.systemProxy,
      };
}

/// A saved connection: the Minecraft (Paper + mcvpn plugin) endpoint plus the
/// per-user credential issued by the admin panel.
class ServerProfile {
  final String id;
  final String name;
  final String host;
  final int port;

  /// key_id: 16 bytes, 32 hex chars.
  final String keyIdHex;

  /// key_secret: 32 bytes, 64 hex chars.
  final String keySecretHex;

  final String usernamePrefix;

  const ServerProfile({
    required this.id,
    required this.name,
    required this.host,
    required this.port,
    required this.keyIdHex,
    required this.keySecretHex,
    this.usernamePrefix = 'mcvpn_',
  });

  Uint8List get keyId => _hexDecode(keyIdHex);
  Uint8List get keySecret => _hexDecode(keySecretHex);

  String? validate() {
    if (name.trim().isEmpty) return 'Name is required';
    if (host.trim().isEmpty) return 'Server host is required';
    if (port < 1 || port > 65535) return 'Port must be 1–65535';
    if (!_isHex(keyIdHex, 16)) return 'key_id must be 32 hex characters (16 bytes)';
    if (!_isHex(keySecretHex, 32)) {
      return 'key_secret must be 64 hex characters (32 bytes)';
    }
    return null;
  }

  ServerProfile copyWith({
    String? name,
    String? host,
    int? port,
    String? keyIdHex,
    String? keySecretHex,
    String? usernamePrefix,
  }) {
    return ServerProfile(
      id: id,
      name: name ?? this.name,
      host: host ?? this.host,
      port: port ?? this.port,
      keyIdHex: keyIdHex ?? this.keyIdHex,
      keySecretHex: keySecretHex ?? this.keySecretHex,
      usernamePrefix: usernamePrefix ?? this.usernamePrefix,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'host': host,
        'port': port,
        'keyIdHex': keyIdHex,
        'keySecretHex': keySecretHex,
        'usernamePrefix': usernamePrefix,
      };

  factory ServerProfile.fromJson(Map<String, dynamic> j) => ServerProfile(
        id: j['id'] as String,
        name: j['name'] as String? ?? 'Server',
        host: j['host'] as String? ?? '127.0.0.1',
        port: (j['port'] as num?)?.toInt() ?? 25565,
        keyIdHex: j['keyIdHex'] as String? ?? '',
        keySecretHex: j['keySecretHex'] as String? ?? '',
        usernamePrefix: j['usernamePrefix'] as String? ?? 'mcvpn_',
      );

  String toJsonString() => jsonEncode(toJson());
}

/// Local proxy bind settings.
class ProxySettings {
  final int httpPort;
  final int socksPort;

  /// When true, bind to 0.0.0.0 (LAN-reachable) instead of loopback only.
  final bool allowLan;

  const ProxySettings({
    this.httpPort = 8080,
    this.socksPort = 1080,
    this.allowLan = false,
  });

  ProxySettings copyWith({int? httpPort, int? socksPort, bool? allowLan}) =>
      ProxySettings(
        httpPort: httpPort ?? this.httpPort,
        socksPort: socksPort ?? this.socksPort,
        allowLan: allowLan ?? this.allowLan,
      );

  Map<String, dynamic> toJson() =>
      {'httpPort': httpPort, 'socksPort': socksPort, 'allowLan': allowLan};

  factory ProxySettings.fromJson(Map<String, dynamic> j) => ProxySettings(
        httpPort: (j['httpPort'] as num?)?.toInt() ?? 8080,
        socksPort: (j['socksPort'] as num?)?.toInt() ?? 1080,
        allowLan: j['allowLan'] as bool? ?? false,
      );
}

Uint8List _hexDecode(String hex) {
  final clean = hex.trim().replaceAll(' ', '');
  final out = Uint8List(clean.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(clean.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

bool _isHex(String s, int bytes) {
  final clean = s.trim();
  if (clean.length != bytes * 2) return false;
  return RegExp(r'^[0-9a-fA-F]+$').hasMatch(clean);
}

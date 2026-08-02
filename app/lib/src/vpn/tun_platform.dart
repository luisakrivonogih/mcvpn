import 'dart:io';

import 'package:flutter/services.dart';

import 'desktop_tun.dart';

/// Bridges to whatever powers full-tunnel (TUN) mode on this platform.
///
/// The platform side establishes a TUN interface, excludes the app's own
/// Minecraft socket from it (so the tunnel doesn't loop back through
/// itself), and runs a tun2socks engine that forwards every captured
/// TCP/UDP flow to the local SOCKS5 proxy this Dart app already serves.
///
///  - Android: `android/.../McVpnService.kt` (VpnService) -- the native
///    side still needs a tun2socks engine wired into it; see that file.
///  - Windows/Linux: [DesktopTun] spawns `tun-engine` as an elevated
///    child process.
///  - iOS/macOS: not supported. Needs a NetworkExtension system extension,
///    which needs a paid Apple Developer Program account (blocked).
class TunPlatform {
  static const MethodChannel _channel = MethodChannel('dev.mcvpn/vpn');

  /// Whether whole-device TUN mode is available on this platform build.
  static bool get isSupported => Platform.isAndroid || Platform.isWindows || Platform.isLinux;

  static bool get _isDesktop => Platform.isWindows || Platform.isLinux;

  /// Requests the OS VPN permission (Android shows the system consent
  /// dialog). On desktop this just checks the engine binary is present --
  /// the actual privilege prompt (UAC / polkit) happens in [start].
  static Future<bool> prepare() async {
    if (Platform.isAndroid) {
      final ok = await _channel.invokeMethod<bool>('prepare');
      return ok ?? false;
    }
    if (_isDesktop) {
      return DesktopTun.available();
    }
    return false;
  }

  /// Starts the TUN and points its tun2socks engine at 127.0.0.1:[socksPort].
  /// [sessionName] is shown in the OS VPN status UI (Android only).
  /// [excludeIp] -- required on desktop -- is the resolved IP of the
  /// Minecraft server, kept off the tunnel via a host route so the
  /// connection carrying the tunnel doesn't route into itself.
  static Future<bool> start({
    required int socksPort,
    required String sessionName,
    String? excludeIp,
  }) async {
    if (Platform.isAndroid) {
      // MainActivity now waits for McVpnService to actually confirm the TUN
      // came up before resolving this call, so a failure inside the service
      // (e.g. a missing manifest permission) surfaces as a PlatformException
      // here rather than as a silent, always-true success.
      try {
        final ok = await _channel.invokeMethod<bool>('start', {
          'socksPort': socksPort,
          'sessionName': sessionName,
        });
        return ok ?? false;
      } on PlatformException catch (e) {
        throw StateError(e.message ?? 'failed to start the OS VPN service');
      }
    }
    if (_isDesktop) {
      if (excludeIp == null) {
        throw ArgumentError('excludeIp is required for desktop TUN mode');
      }
      await DesktopTun.start(socksPort: socksPort, excludeIp: excludeIp);
      return true;
    }
    return false;
  }

  /// Tears the TUN down.
  static Future<void> stop() async {
    if (Platform.isAndroid) {
      await _channel.invokeMethod<void>('stop');
      return;
    }
    if (_isDesktop) {
      await DesktopTun.stop();
    }
  }

  /// True if this side believes it has an active TUN. On Android this asks
  /// the OS; on desktop it's just local process-tracking state.
  static Future<bool> isRunning() async {
    if (Platform.isAndroid) {
      final running = await _channel.invokeMethod<bool>('isRunning');
      return running ?? false;
    }
    if (_isDesktop) {
      return DesktopTun.isRunning;
    }
    return false;
  }
}

import 'dart:async';
import 'dart:io';

/// Points the OS's system-wide network proxy settings at the app's local
/// HTTP/SOCKS5 proxies, so applications that don't have their own proxy
/// setting (browsers, etc.) get routed through the tunnel automatically.
///
/// This is not a real network-layer tunnel: apps that ignore the system
/// proxy (raw sockets, some games) still go direct. It's a much cheaper
/// alternative to a NetworkExtension/TUN-based whole-device tunnel that
/// fixes the common case ("why does my browser show my real IP") without
/// needing elevated privileges (macOS/Linux) or a signed system extension.
///
/// Three independent backends, one per desktop OS -- there's no portable
/// API for "set the system proxy":
///  - macOS: `networksetup`, applied per network service, via a single
///    elevated *watcher* process -- see the class doc on `_applyMacOS` for
///    why it's a long-lived watcher and not a plain apply-then-later-revert
///    pair of privileged calls.
///  - Windows: the per-user registry (`HKCU\...\Internet Settings`),
///    no elevation needed; broadcasts `INTERNET_OPTION_SETTINGS_CHANGED` so
///    already-running apps pick it up without a restart.
///  - Linux: GNOME's `gsettings` (`org.gnome.system.proxy`). This only
///    covers GNOME/GTK apps that read that schema (most browsers included)
///    -- there's no single proxy setting that spans every desktop
///    environment, so KDE/Sway/etc. users still need to configure manually.
///
/// Windows and Linux paths were written and cross-compiled from a
/// macOS-only dev machine with no Windows/Linux host to actually run them
/// on -- treat the first real run on each as a test, not a formality.
class SystemProxy {
  static bool get isSupported => Platform.isMacOS || Platform.isWindows || Platform.isLinux;

  static Process? _macWatcher;
  static Directory? _macCmdDir;
  static String? _macPendingRevert;
  static File? _macPendingRevertFile;
  static Map<String, String?>? _previousWindows;
  static Map<String, String>? _previousLinux;

  /// Applies the proxy, after snapshotting whatever was there before so
  /// [revert] can restore it exactly.
  static Future<void> apply({
    required int httpPort,
    required int socksPort,
  }) async {
    if (Platform.isMacOS) {
      await _applyMacOS(httpPort, socksPort);
    } else if (Platform.isWindows) {
      await _applyWindows(httpPort, socksPort);
    } else if (Platform.isLinux) {
      await _applyLinux(httpPort, socksPort);
    }
  }

  /// Restores whatever was in place before [apply].
  static Future<void> revert() async {
    if (Platform.isMacOS) {
      await _revertMacOS();
    } else if (Platform.isWindows) {
      await _revertWindows();
    } else if (Platform.isLinux) {
      await _revertLinux();
    }
  }

  // --- macOS: networksetup, driven by a single elevated *watcher* process ---
  //
  // A naive "one privileged call to apply, another later to revert" design
  // (what this used to be) has two problems: it asks for the admin password
  // twice per connection, and if the app is force-quit, crashes, or the
  // window is just closed without hitting Disconnect, the revert call never
  // happens at all -- the system proxy is left pointing at a SOCKS5 server
  // that's no longer running, breaking all networking until someone notices
  // and fixes it by hand (this actually happened -- see the commit this
  // comment landed in).
  //
  // [_applyMacOS] asks for elevation exactly once *per app run*, not once
  // per connect. The first call starts a long-lived elevated shell (the
  // "watcher") that stays up polling a command file in a private temp
  // directory for as long as this app process is alive (`kill -0 $pid`) --
  // the same crash/force-quit net as before, since the watcher reverts
  // whatever it's holding and exits on its own the moment that check fails,
  // with no Dart code needing to run at all. Every apply/revert after the
  // first just drops a fresh script into that command file and waits for an
  // ack; no new authorization prompt, because it's still the same
  // already-elevated shell running it. Disconnecting no longer kills the
  // watcher, only reverts through it -- it sits idle (a cheap 0.2s poll
  // loop) between sessions and only actually exits, taking its temp dir
  // with it, once the app quits.
  //
  // The command directory lives under macOS's per-user TMPDIR, which is
  // already mode 0700 (unlike the shared /tmp on Linux) -- chmod'd 700
  // again here as defense in depth, since anything written to that file
  // gets executed with admin privileges.
  static Future<void> _applyMacOS(int httpPort, int socksPort) async {
    final services = await _enabledServices();
    if (services.isEmpty) {
      throw StateError('no enabled network services found');
    }
    final previous = await Future.wait(services.map(_snapshot));

    final applyScript = StringBuffer();
    for (final service in services) {
      final s = _shellEscape(service);
      applyScript.writeln('networksetup -setwebproxy $s 127.0.0.1 $httpPort');
      applyScript.writeln('networksetup -setwebproxystate $s on');
      applyScript.writeln('networksetup -setsecurewebproxy $s 127.0.0.1 $httpPort');
      applyScript.writeln('networksetup -setsecurewebproxystate $s on');
      applyScript.writeln('networksetup -setsocksfirewallproxy $s 127.0.0.1 $socksPort');
      applyScript.writeln('networksetup -setsocksfirewallproxystate $s on');
    }
    final revertScript = StringBuffer();
    for (final snap in previous) {
      revertScript.write(snap.restoreCommands());
    }

    await _ensureMacWatcher();
    // Written before the apply call (not after) so that a crash/force-quit
    // occurring *during* the apply itself still leaves the watcher with a
    // revert script to run -- see _ensureMacWatcher's script for the other
    // half of this.
    final revertFile = _macPendingRevertFile;
    if (revertFile != null) {
      await revertFile.writeAsString(revertScript.toString());
    }
    final error = await _runElevatedMac(applyScript.toString());
    if (error != null) {
      throw StateError('failed to apply system proxy: $error');
    }
    _macPendingRevert = revertScript.toString();
  }

  static Future<void> _revertMacOS() async {
    final revertScript = _macPendingRevert;
    _macPendingRevert = null;
    if (revertScript == null) return;
    final error = await _runElevatedMac(revertScript);
    if (error != null) {
      throw StateError('failed to revert system proxy: $error');
    }
    // Reverted cleanly -- clear the watcher's copy so it doesn't redo this
    // (harmlessly, but pointlessly) once this process eventually exits.
    try {
      await _macPendingRevertFile?.delete();
    } catch (_) {}
  }

  /// Starts the elevated watcher if one isn't already running for this app
  /// run. Prompts for the admin password exactly once; every later
  /// apply/revert reuses this same process.
  static Future<void> _ensureMacWatcher() async {
    if (_macWatcher != null) return;
    final dir = await Directory.systemTemp.createTemp('mcvpn-sysproxy-');
    try {
      await Process.run('chmod', ['700', dir.path]);
    } catch (_) {}

    final cmdPath = _shellEscape('${dir.path}/cmd.sh');
    final ackPath = _shellEscape('${dir.path}/ack');
    final logPath = _shellEscape('${dir.path}/log');
    final revertPath = _shellEscape('${dir.path}/pending_revert.sh');
    final dirPath = _shellEscape(dir.path);

    // The `bash $revertPath` line is the actual safety net for a crash or
    // force-quit: the loop above only runs commands Dart hands it while the
    // app is alive, so once `kill -0 $pid` finally fails we still have to
    // explicitly replay whatever revert script Dart last wrote to disk
    // before dropping the temp dir -- without this line the watcher just
    // vanishes and leaves the proxy pointed at ports that no longer exist.
    final watcherScript = '''
while kill -0 $pid 2>/dev/null; do
  if [ -f $cmdPath ]; then
    if bash $cmdPath >$logPath 2>&1; then
      echo OK >$ackPath
    else
      echo ERROR >$ackPath
    fi
    rm -f $cmdPath
  fi
  sleep 0.2
done
if [ -f $revertPath ]; then
  bash $revertPath >$logPath 2>&1
fi
rm -rf $dirPath
''';

    final watcher = await _startElevated(watcherScript);
    _macWatcher = watcher;
    _macCmdDir = dir;
    _macPendingRevertFile = File('${dir.path}/pending_revert.sh');
    unawaited(watcher.exitCode.then((_) {
      if (identical(_macWatcher, watcher)) {
        _macWatcher = null;
        _macPendingRevertFile = null;
        _macCmdDir = null;
      }
    }));
  }

  /// Drops [script] into the watcher's command file and waits for it to
  /// run, returning null on success or an error description on failure.
  static Future<String?> _runElevatedMac(String script) async {
    final dir = _macCmdDir;
    final watcher = _macWatcher;
    if (dir == null || watcher == null) {
      return 'elevated helper is not running (elevation prompt dismissed?)';
    }
    final cmdFile = File('${dir.path}/cmd.sh');
    final ackFile = File('${dir.path}/ack');
    final logFile = File('${dir.path}/log');
    for (final f in [ackFile, logFile]) {
      if (await f.exists()) await f.delete();
    }
    await cmdFile.writeAsString(script);

    var watcherExited = false;
    unawaited(watcher.exitCode.then((_) => watcherExited = true));

    final deadline = DateTime.now().add(const Duration(seconds: 20));
    while (DateTime.now().isBefore(deadline)) {
      if (await ackFile.exists()) {
        final status = (await ackFile.readAsString()).trim();
        try {
          await ackFile.delete();
        } catch (_) {}
        if (status == 'OK') return null;
        final log = await logFile.exists() ? await logFile.readAsString() : '';
        return log.trim().isEmpty ? 'command failed' : log.trim();
      }
      if (watcherExited) {
        return 'elevated helper exited unexpectedly';
      }
      await Future.delayed(const Duration(milliseconds: 200));
    }
    return 'timed out waiting for the elevated helper';
  }

  static Future<Process> _startElevated(String script) async {
    final escaped = script.replaceAll('\\', '\\\\').replaceAll('"', '\\"');
    return Process.start('osascript', [
      '-e',
      'do shell script "$escaped" with administrator privileges with prompt '
          '"mcvpn needs to update your network proxy settings."',
    ]);
  }

  static Future<List<String>> _enabledServices() async {
    final result = await Process.run('networksetup', ['-listallnetworkservices']);
    if (result.exitCode != 0) {
      throw StateError('networksetup -listallnetworkservices failed: ${result.stderr}');
    }
    final lines = (result.stdout as String).split('\n');
    return lines
        .skip(1) // "An asterisk (*) denotes that a network service is disabled."
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty && !l.startsWith('*'))
        .toList();
  }

  static Future<_ServiceSnapshot> _snapshot(String service) async {
    final web = await _getProxy('-getwebproxy', service);
    final secure = await _getProxy('-getsecurewebproxy', service);
    final socks = await _getProxy('-getsocksfirewallproxy', service);
    return _ServiceSnapshot(service: service, web: web, secure: secure, socks: socks);
  }

  static Future<_ProxyState> _getProxy(String flag, String service) async {
    final result = await Process.run('networksetup', [flag, service]);
    final out = result.stdout as String;
    bool enabled = false;
    String server = '';
    String port = '0';
    for (final line in out.split('\n')) {
      final parts = line.split(':');
      if (parts.length < 2) continue;
      final key = parts[0].trim();
      final value = parts.sublist(1).join(':').trim();
      switch (key) {
        case 'Enabled':
          enabled = value == 'Yes';
          break;
        case 'Server':
          server = value;
          break;
        case 'Port':
          port = value;
          break;
      }
    }
    return _ProxyState(enabled: enabled, server: server, port: port);
  }

  static String _shellEscape(String s) => "'${s.replaceAll("'", "'\\''")}'";

  // --- Windows: per-user registry, no elevation needed ---

  static const _winKey = r'HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings';

  static Future<void> _applyWindows(int httpPort, int socksPort) async {
    _previousWindows = {
      'ProxyEnable': await _regQuery('ProxyEnable'),
      'ProxyServer': await _regQuery('ProxyServer'),
    };
    final proxyServer =
        'http=127.0.0.1:$httpPort;https=127.0.0.1:$httpPort;socks=127.0.0.1:$socksPort';
    await _regSet('ProxyServer', proxyServer);
    await _regSet('ProxyEnable', '1', type: 'REG_DWORD');
    await _notifyWindowsProxyChange();
  }

  static Future<void> _revertWindows() async {
    final previous = _previousWindows;
    _previousWindows = null;
    if (previous == null) return;

    final enable = previous['ProxyEnable'];
    if (enable == null) {
      await _regDelete('ProxyEnable');
    } else {
      await _regSet('ProxyEnable', enable, type: 'REG_DWORD');
    }
    final server = previous['ProxyServer'];
    if (server == null) {
      await _regDelete('ProxyServer');
    } else {
      await _regSet('ProxyServer', server);
    }
    await _notifyWindowsProxyChange();
  }

  /// Returns the current value, or null if the value doesn't exist.
  static Future<String?> _regQuery(String name) async {
    final result = await Process.run('reg', ['query', _winKey, '/v', name]);
    if (result.exitCode != 0) return null;
    for (final line in (result.stdout as String).split('\n')) {
      final trimmed = line.trim();
      if (!trimmed.startsWith(name)) continue;
      final parts = trimmed.split(RegExp(r'\s+'));
      if (parts.length >= 3) return parts.sublist(2).join(' ');
    }
    return null;
  }

  static Future<void> _regSet(String name, String value, {String type = 'REG_SZ'}) async {
    final result = await Process.run(
        'reg', ['add', _winKey, '/v', name, '/t', type, '/d', value, '/f']);
    if (result.exitCode != 0) {
      throw StateError('reg add $name failed: ${result.stderr}');
    }
  }

  static Future<void> _regDelete(String name) async {
    // Fails harmlessly if the value never existed, which is fine here.
    await Process.run('reg', ['delete', _winKey, '/v', name, '/f']);
  }

  /// Broadcasts INTERNET_OPTION_SETTINGS_CHANGED (39) + INTERNET_OPTION_REFRESH
  /// (37) via wininet.dll so already-running apps (browsers) notice the
  /// registry change without needing a restart.
  static Future<void> _notifyWindowsProxyChange() async {
    const script = r'''
$sig = '[DllImport("wininet.dll", SetLastError = true)] public static extern bool InternetSetOption(IntPtr hInternet, int dwOption, IntPtr lpBuffer, int dwBufferLength);'
Add-Type -MemberDefinition $sig -Namespace WinAPI -Name Internet
[WinAPI.Internet]::InternetSetOption([IntPtr]::Zero, 39, [IntPtr]::Zero, 0) | Out-Null
[WinAPI.Internet]::InternetSetOption([IntPtr]::Zero, 37, [IntPtr]::Zero, 0) | Out-Null
''';
    await Process.run(
        'powershell', ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', script]);
  }

  // --- Linux: GNOME's gsettings (org.gnome.system.proxy). No portable
  // equivalent for other desktop environments exists. ---

  static Future<void> _applyLinux(int httpPort, int socksPort) async {
    if (!await _hasGsettings()) {
      throw StateError(
          'automatic system proxy is only wired up for GNOME (gsettings not found on PATH); '
          'set your desktop\'s proxy manually to 127.0.0.1:$httpPort (HTTP/HTTPS) and '
          '127.0.0.1:$socksPort (SOCKS5)');
    }
    _previousLinux = {
      'proxy.mode': await _gget('org.gnome.system.proxy', 'mode'),
      'http.host': await _gget('org.gnome.system.proxy.http', 'host'),
      'http.port': await _gget('org.gnome.system.proxy.http', 'port'),
      'https.host': await _gget('org.gnome.system.proxy.https', 'host'),
      'https.port': await _gget('org.gnome.system.proxy.https', 'port'),
      'socks.host': await _gget('org.gnome.system.proxy.socks', 'host'),
      'socks.port': await _gget('org.gnome.system.proxy.socks', 'port'),
    };
    await _gset('org.gnome.system.proxy.http', 'host', "'127.0.0.1'");
    await _gset('org.gnome.system.proxy.http', 'port', '$httpPort');
    await _gset('org.gnome.system.proxy.https', 'host', "'127.0.0.1'");
    await _gset('org.gnome.system.proxy.https', 'port', '$httpPort');
    await _gset('org.gnome.system.proxy.socks', 'host', "'127.0.0.1'");
    await _gset('org.gnome.system.proxy.socks', 'port', '$socksPort');
    await _gset('org.gnome.system.proxy', 'mode', "'manual'");
  }

  static Future<void> _revertLinux() async {
    final previous = _previousLinux;
    _previousLinux = null;
    if (previous == null) return;
    await _gset('org.gnome.system.proxy.http', 'host', previous['http.host']!);
    await _gset('org.gnome.system.proxy.http', 'port', previous['http.port']!);
    await _gset('org.gnome.system.proxy.https', 'host', previous['https.host']!);
    await _gset('org.gnome.system.proxy.https', 'port', previous['https.port']!);
    await _gset('org.gnome.system.proxy.socks', 'host', previous['socks.host']!);
    await _gset('org.gnome.system.proxy.socks', 'port', previous['socks.port']!);
    await _gset('org.gnome.system.proxy', 'mode', previous['proxy.mode']!);
  }

  static Future<bool> _hasGsettings() async {
    try {
      final result = await Process.run('which', ['gsettings']);
      return result.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  static Future<String> _gget(String schema, String key) async {
    final result = await Process.run('gsettings', ['get', schema, key]);
    return (result.stdout as String).trim();
  }

  static Future<void> _gset(String schema, String key, String value) async {
    final result = await Process.run('gsettings', ['set', schema, key, value]);
    if (result.exitCode != 0) {
      throw StateError('gsettings set $schema $key failed: ${result.stderr}');
    }
  }
}

class _ProxyState {
  final bool enabled;
  final String server;
  final String port;
  const _ProxyState({required this.enabled, required this.server, required this.port});
}

class _ServiceSnapshot {
  final String service;
  final _ProxyState web;
  final _ProxyState secure;
  final _ProxyState socks;

  const _ServiceSnapshot({
    required this.service,
    required this.web,
    required this.secure,
    required this.socks,
  });

  String restoreCommands() {
    final s = SystemProxy._shellEscape(service);
    final out = StringBuffer();
    out.writeln(_restore('setwebproxy', 'setwebproxystate', s, web));
    out.writeln(_restore('setsecurewebproxy', 'setsecurewebproxystate', s, secure));
    out.writeln(_restore('setsocksfirewallproxy', 'setsocksfirewallproxystate', s, socks));
    return out.toString();
  }

  String _restore(String setFlag, String stateFlag, String service, _ProxyState state) {
    final lines = StringBuffer();
    if (state.server.isNotEmpty) {
      lines.writeln('networksetup -$setFlag $service ${state.server} ${state.port}');
    }
    lines.writeln('networksetup -$stateFlag $service ${state.enabled ? 'on' : 'off'}');
    return lines.toString();
  }
}

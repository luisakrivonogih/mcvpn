import 'dart:async';
import 'dart:io';

/// Drives `tun-engine` (see `tun-engine/`) as a child process on
/// Windows and Linux -- the desktop equivalent of Android's McVpnService.
///
/// Synchronization with the engine is file-based rather than stdio-based:
/// on Windows the engine has to run elevated ("Start-Process -Verb RunAs"),
/// which puts it in a new session with no inherited stdio, so this side
/// can't read its stdout or send Ctrl+C. Instead:
///  - [start] polls a status file the engine writes on ready/error.
///  - [stop] creates a stop file the engine polls for and deletes on exit.
///
/// The engine binary is expected next to the app's own executable, named
/// `tun-engine.exe` (Windows) or `tun-engine` (Linux) -- the build script
/// is responsible for putting it there (see `scripts/build.sh`).
class DesktopTun {
  static Process? _elevator; // the (unelevated) launcher process, Linux only
  static File? _statusFile;
  static File? _stopFile;
  static bool _running = false;

  static bool get isRunning => _running;

  static File get _engineBinary {
    final dir = File(Platform.resolvedExecutable).parent.path;
    final name = Platform.isWindows ? 'tun-engine.exe' : 'tun-engine';
    return File('$dir${Platform.pathSeparator}$name');
  }

  static Future<bool> available() async => _engineBinary.exists();

  static Future<void> start({
    required int socksPort,
    required String excludeIp,
  }) async {
    if (_running) return;
    final engine = _engineBinary;
    if (!await engine.exists()) {
      throw StateError('tun-engine binary not found at ${engine.path}');
    }

    final tmp = Directory.systemTemp;
    final tag = DateTime.now().microsecondsSinceEpoch;
    final statusFile = File('${tmp.path}${Platform.pathSeparator}mcvpn-tun-status-$tag.txt');
    final stopFile = File('${tmp.path}${Platform.pathSeparator}mcvpn-tun-stop-$tag.txt');
    if (await statusFile.exists()) await statusFile.delete();
    if (await stopFile.exists()) await stopFile.delete();
    _statusFile = statusFile;
    _stopFile = stopFile;

    final engineArgs = [
      '-proxy', '127.0.0.1:$socksPort',
      '-exclude-ip', excludeIp,
      '-status-file', statusFile.path,
      '-stop-file', stopFile.path,
    ];

    if (Platform.isWindows) {
      // Start-Process -Verb RunAs triggers the UAC prompt and elevates only
      // the engine, not this (already-running, unelevated) app.
      final argList = engineArgs.map((a) => "'${a.replaceAll("'", "''")}'").join(',');
      final script = "Start-Process -FilePath '${engine.path}' -ArgumentList @($argList) "
          "-Verb RunAs -WindowStyle Hidden";
      _elevator = await Process.start(
          'powershell', ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', script]);
    } else {
      // pkexec shows the standard polkit authentication dialog.
      _elevator = await Process.start('pkexec', [engine.path, ...engineArgs]);
    }

    final status = await _waitForStatus(
      statusFile,
      elevator: _elevator!,
      timeout: const Duration(seconds: 20),
    );
    if (status == null) {
      throw StateError('tun-engine did not report a status in time (elevation prompt dismissed?)');
    }
    if (status.startsWith('MCVPN_TUN_ERROR')) {
      _running = false;
      throw StateError(status);
    }
    _running = true;
  }

  static Future<void> stop() async {
    if (!_running) return;
    _running = false;
    try {
      await _stopFile?.create(recursive: true);
    } catch (_) {}
    // Give the engine a moment to revert routing before we let go of it;
    // it deletes the stop file itself once it has, so poll for that.
    final stopFile = _stopFile;
    if (stopFile != null) {
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (DateTime.now().isBefore(deadline) && await stopFile.exists()) {
        await Future.delayed(const Duration(milliseconds: 200));
      }
    }
    await _statusFile?.delete().catchError((_) => _statusFile!);
    _statusFile = null;
    _stopFile = null;
    _elevator = null;
  }

  /// Polls [statusFile] for a status line, giving up early -- rather than
  /// waiting out the full [timeout] -- if [elevator] (the launcher: the
  /// unelevated `powershell`/`pkexec` process) exits first, which is what
  /// happens immediately when the user dismisses the elevation prompt.
  static Future<String?> _waitForStatus(
    File statusFile, {
    required Process elevator,
    required Duration timeout,
  }) async {
    var elevatorExited = false;
    unawaited(elevator.exitCode.then((_) => elevatorExited = true));

    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (await statusFile.exists()) {
        final content = (await statusFile.readAsString()).trim();
        if (content.isNotEmpty) return content;
      }
      // Only bail out on an early launcher exit once we've given the status
      // file one more poll -- on Linux, pkexec's own exit can race the
      // engine's first write.
      if (elevatorExited && !await statusFile.exists()) {
        return null;
      }
      await Future.delayed(const Duration(milliseconds: 200));
    }
    return null;
  }
}

/// Formatting helpers for the UI.
library;

String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  const units = ['KB', 'MB', 'GB', 'TB'];
  double v = bytes / 1024;
  var i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  return '${v.toStringAsFixed(v >= 100 ? 0 : 1)} ${units[i]}';
}

String formatRate(int bytesPerSec) => '${formatBytes(bytesPerSec)}/s';

String formatDuration(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes % 60;
  final s = d.inSeconds % 60;
  final mm = m.toString().padLeft(2, '0');
  final ss = s.toString().padLeft(2, '0');
  if (h > 0) return '$h:$mm:$ss';
  return '$mm:$ss';
}

String twoDigits(int n) => n.toString().padLeft(2, '0');

String formatTime(DateTime t) =>
    '${twoDigits(t.hour)}:${twoDigits(t.minute)}:${twoDigits(t.second)}';

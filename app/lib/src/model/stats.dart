/// Live traffic + session counters shown on the home screen.
class TrafficStats {
  int bytesUp;
  int bytesDown;
  int totalStreams;
  int activeStreams;
  DateTime? connectedSince;

  // Rolling throughput (bytes/sec), updated once per second.
  int upBytesPerSec;
  int downBytesPerSec;

  TrafficStats({
    this.bytesUp = 0,
    this.bytesDown = 0,
    this.totalStreams = 0,
    this.activeStreams = 0,
    this.connectedSince,
    this.upBytesPerSec = 0,
    this.downBytesPerSec = 0,
  });

  void reset() {
    bytesUp = 0;
    bytesDown = 0;
    totalStreams = 0;
    activeStreams = 0;
    connectedSince = null;
    upBytesPerSec = 0;
    downBytesPerSec = 0;
  }

  Duration get uptime => connectedSince == null
      ? Duration.zero
      : DateTime.now().difference(connectedSince!);
}

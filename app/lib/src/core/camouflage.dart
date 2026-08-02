import 'dart:math';
import 'dart:typed_data';

import 'mc_packets.dart';

/// Client-initiated Play-state traffic a real Minecraft client produces just
/// by sitting connected: `ClientSettings` on join, then a steady trickle of
/// looking around, occasional arm swings and sneak toggles. Without it, the
/// session's outbound traffic is only handshake + keep-alive replies + tunnel
/// payloads — itself a fingerprint on an offline-mode (unencrypted) session.
class IdleSimulator {
  static const Duration idleMin = Duration(seconds: 2);
  static const Duration idleMax = Duration(seconds: 6);

  final int entityId;
  double _yaw;
  double _pitch;
  bool _sneaking = false;
  final Random _rng = Random();

  IdleSimulator(this.entityId, this._yaw, this._pitch);

  /// Resync to a server-authoritative orientation (spawn/any teleport).
  void resync(double yaw, double pitch) {
    _yaw = yaw;
    _pitch = pitch;
  }

  Duration nextDelay() {
    final span = (idleMax - idleMin).inMilliseconds;
    return idleMin + Duration(milliseconds: _rng.nextInt(span + 1));
  }

  /// Returns the body bytes + packet id of the next idle action, weighted
  /// heavily toward looking around (what an idle player produces most).
  ({int id, Uint8List body}) nextAction() {
    final roll = _rng.nextInt(10);
    if (roll <= 6) {
      _yaw = _wrapYaw(_yaw + _rng.nextDouble() * 50 - 25);
      _pitch = (_pitch + _rng.nextDouble() * 30 - 15).clamp(-89.0, 89.0);
      return (id: PacketId.lookAndOnGroundC2s, body: buildLook(_yaw, _pitch, true));
    } else if (roll <= 8) {
      return (id: PacketId.handSwingC2s, body: buildHandSwing());
    } else {
      _sneaking = !_sneaking;
      final action = _sneaking ? 0 : 1; // Start / Stop sneaking
      return (
        id: PacketId.clientCommandC2s,
        body: buildClientCommand(entityId, action)
      );
    }
  }

  static double _wrapYaw(double deg) {
    var d = deg % 360.0;
    if (d > 180.0) d -= 360.0;
    if (d < -180.0) d += 360.0;
    return d;
  }
}

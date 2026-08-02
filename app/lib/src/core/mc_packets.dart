import 'dart:typed_data';

import 'bytes.dart';

/// Minecraft 1.20.1.
const int protocolVersion = 763;

/// Packet ids for protocol 763, extracted from `valence_generated`'s
/// `packets.json`. Grouped by direction/state.
class PacketId {
  // Handshaking (C2S)
  static const int handshake = 0x00;

  // Login C2S
  static const int loginHelloC2s = 0x00;
  static const int loginQueryResponseC2s = 0x02;

  // Login S2C
  static const int loginDisconnectS2c = 0x00;
  static const int loginHelloS2c = 0x01; // encryption request (online mode)
  static const int loginSuccessS2c = 0x02;
  static const int loginCompressionS2c = 0x03;
  static const int loginQueryRequestS2c = 0x04;

  // Play C2S
  static const int teleportConfirmC2s = 0x00;
  static const int clientSettingsC2s = 0x08;
  static const int customPayloadC2s = 0x0d;
  static const int keepAliveC2s = 0x12;
  static const int lookAndOnGroundC2s = 0x16;
  static const int clientCommandC2s = 0x1e;
  static const int handSwingC2s = 0x2f;

  // Play S2C
  static const int customPayloadS2c = 0x17;
  static const int disconnectS2c = 0x1a;
  static const int keepAliveS2c = 0x23;
  static const int gameJoinS2c = 0x28;
  static const int playerPositionLookS2c = 0x3c;
}

// ---------------------------------------------------------------------------
// C2S packet body builders. Each returns the *body* bytes (after the packet
// id VarInt); MinecraftCodec.encode prepends the id and frames it.
// ---------------------------------------------------------------------------

/// Handshake: intent to log in. next_state Login = VarInt 2.
Uint8List buildHandshake(String serverAddress, int serverPort) {
  return (ByteWriter()
        ..varInt(protocolVersion)
        ..string(serverAddress)
        ..u16(serverPort)
        ..varInt(2))
      .toBytes();
}

/// LoginStart: username, then Option<UUID> (absent => bool false).
Uint8List buildLoginHello(String username) {
  return (ByteWriter()
        ..string(username)
        ..bool_(false))
      .toBytes();
}

/// LoginPluginResponse: message id + Option (absent => "not understood").
Uint8List buildLoginQueryResponse(int messageId) {
  return (ByteWriter()
        ..varInt(messageId)
        ..bool_(false))
      .toBytes();
}

/// CustomPayload (plugin message): channel string + raw payload to end.
Uint8List buildCustomPayload(String channel, List<int> data) {
  return (ByteWriter()
        ..string(channel)
        ..raw(data))
      .toBytes();
}

/// TeleportConfirm: echoes the server's teleport id.
Uint8List buildTeleportConfirm(int teleportId) {
  return (ByteWriter()..varInt(teleportId)).toBytes();
}

/// KeepAlive reply: echoes the server's 8-byte id.
Uint8List buildKeepAlive(int id) {
  return (ByteWriter()..u64(id)).toBytes();
}

/// ClientSettings — the packet a real client sends once on entering Play.
Uint8List buildClientSettings() {
  // displayed_skin_parts: all 7 visible parts on => 0x7f.
  return (ByteWriter()
        ..string('en_us')
        ..u8(10) // view distance
        ..varInt(0) // chat mode: Enabled
        ..bool_(true) // chat colors
        ..u8(0x7f) // displayed skin parts
        ..varInt(1) // main arm: Right
        ..bool_(false) // enable text filtering
        ..bool_(true)) // allow server listings
      .toBytes();
}

/// LookAndOnGround — idle look-around camouflage.
Uint8List buildLook(double yaw, double pitch, bool onGround) {
  return (ByteWriter()
        ..f32(yaw)
        ..f32(pitch)
        ..bool_(onGround))
      .toBytes();
}

/// HandSwing — occasional arm swing (Hand::Main = VarInt 0).
Uint8List buildHandSwing() {
  return (ByteWriter()..varInt(0)).toBytes();
}

/// ClientCommand — sneak toggles. action StartSneaking=0 / StopSneaking=1.
Uint8List buildClientCommand(int entityId, int action) {
  return (ByteWriter()
        ..varInt(entityId)
        ..varInt(action)
        ..varInt(0)) // jump boost
      .toBytes();
}

// ---------------------------------------------------------------------------
// S2C parse results — only the fields this client actually needs.
// ---------------------------------------------------------------------------

class LoginSuccess {
  final String uuid; // canonical string form
  final String username;
  LoginSuccess(this.uuid, this.username);
}

LoginSuccess parseLoginSuccess(ByteReader r) {
  final uuidBytes = r.takeBytes(16);
  final uuid = _formatUuid(uuidBytes);
  final username = r.string();
  return LoginSuccess(uuid, username);
}

class PlayerPositionLook {
  final double yaw;
  final double pitch;
  final int teleportId;
  PlayerPositionLook(this.yaw, this.pitch, this.teleportId);
}

PlayerPositionLook parsePlayerPositionLook(ByteReader r) {
  r.f64(); // x
  r.f64(); // y
  r.f64(); // z
  final yaw = r.f32();
  final pitch = r.f32();
  r.u8(); // flags
  final teleportId = r.varInt();
  return PlayerPositionLook(yaw, pitch, teleportId);
}

/// GameJoin's first field is the entity id (BE i32) — all this client needs.
int parseGameJoinEntityId(ByteReader r) => r.i32();

/// CustomPayload S2C: channel + remaining bytes.
class IncomingPluginMessage {
  final String channel;
  final Uint8List data;
  IncomingPluginMessage(this.channel, this.data);
}

IncomingPluginMessage parseCustomPayload(ByteReader r) {
  final channel = r.string();
  final data = r.rest();
  return IncomingPluginMessage(channel, data);
}

String _formatUuid(Uint8List b) {
  final s = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
  return '${s.substring(0, 8)}-${s.substring(8, 12)}-${s.substring(12, 16)}-'
      '${s.substring(16, 20)}-${s.substring(20)}';
}

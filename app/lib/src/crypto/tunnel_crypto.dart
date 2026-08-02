import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// Cryptographic core of the tunnel — a byte-for-byte port of the Rust
/// client's `crypto::cipher` and the Java plugin's `TunnelCrypto`.
///
/// Handshake (two plaintext messages, before any AEAD traffic):
/// ```
/// C -> S: connection_id(16) || key_id(16) || epk_c(32) || mac1(32)
///   mac1 = HMAC-SHA256(secret, connection_id || key_id || epk_c)
/// S -> C: epk_s(32) || mac2(32)
///   mac2 = HMAC-SHA256(secret, connection_id || key_id || epk_c || epk_s)
/// ```
/// Session keys: HKDF-SHA256 over the X25519 DH output *mixed with the
/// user secret*. Each AEAD frame: `counter(8 BE) || ChaCha20-Poly1305(pt)+tag`.

const int connectionIdLen = 16;
const int keyIdLen = 16;
const int publicKeyLen = 32;
const int macLen = 32;
const int _keyLen = 32;

final _x25519 = X25519();
final _hmac = Hmac.sha256();
final _aead = Chacha20.poly1305Aead();

/// A fresh, single-use X25519 keypair.
class EphemeralKeypair {
  final SimpleKeyPair _keyPair;
  final Uint8List publicKey;
  EphemeralKeypair._(this._keyPair, this.publicKey);

  static Future<EphemeralKeypair> generate() async {
    final kp = await _x25519.newKeyPair();
    final pub = await kp.extractPublicKey();
    return EphemeralKeypair._(kp, Uint8List.fromList(pub.bytes));
  }

  /// Raw 32-byte X25519 shared secret (unhashed), matching the Rust/Java sides.
  Future<Uint8List> diffieHellman(List<int> theirPublic) async {
    final remote = SimplePublicKey(theirPublic, type: KeyPairType.x25519);
    final shared = await _x25519.sharedSecretKey(
      keyPair: _keyPair,
      remotePublicKey: remote,
    );
    return Uint8List.fromList(await shared.extractBytes());
  }
}

Uint8List concatBytes(List<List<int>> parts) {
  final total = parts.fold<int>(0, (a, p) => a + p.length);
  final out = Uint8List(total);
  var pos = 0;
  for (final p in parts) {
    out.setRange(pos, pos + p.length, p);
    pos += p.length;
  }
  return out;
}

Future<Uint8List> hmacSha256(List<int> key, List<int> data) async {
  final mac = await _hmac.calculateMac(data, secretKey: SecretKey(key));
  return Uint8List.fromList(mac.bytes);
}

Future<Uint8List> handshakeMac1(
    List<int> secret, List<int> connectionId, List<int> keyId, List<int> epkC) {
  return hmacSha256(secret, concatBytes([connectionId, keyId, epkC]));
}

Future<Uint8List> handshakeMac2(List<int> secret, List<int> connectionId,
    List<int> keyId, List<int> epkC, List<int> epkS) {
  return hmacSha256(secret, concatBytes([connectionId, keyId, epkC, epkS]));
}

/// HKDF-SHA256 extract-then-expand.
Future<Uint8List> _hkdf(
    List<int> salt, List<int> ikm, List<int> info, int length) async {
  final hkdf = Hkdf(hmac: _hmac, outputLength: length);
  final key = await hkdf.deriveKey(
    secretKey: SecretKey(ikm),
    nonce: salt, // HKDF salt
    info: info,
  );
  return Uint8List.fromList(await key.extractBytes());
}

/// Constant-time comparison for MAC verification.
bool constantTimeEquals(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}

Uint8List _nonceFromCounter(int counter) {
  final nonce = Uint8List(12);
  final bd = ByteData.sublistView(nonce);
  bd.setUint64(4, counter, Endian.big);
  return nonce;
}

/// AEAD state for one direction of post-handshake traffic.
class _DirectionalCipher {
  final SecretKey _key;
  int _nextSendCounter = 0;
  int _lastAcceptedCounter = 0;
  bool _haveAcceptedAny = false;

  _DirectionalCipher(List<int> keyBytes) : _key = SecretKey(keyBytes);

  Future<Uint8List> seal(List<int> plaintext) async {
    final counter = _nextSendCounter++;
    final nonce = _nonceFromCounter(counter);
    final box = await _aead.encrypt(plaintext, secretKey: _key, nonce: nonce);
    final out = Uint8List(8 + box.cipherText.length + box.mac.bytes.length);
    ByteData.sublistView(out).setUint64(0, counter, Endian.big);
    out.setRange(8, 8 + box.cipherText.length, box.cipherText);
    out.setRange(8 + box.cipherText.length, out.length, box.mac.bytes);
    return out;
  }

  Future<Uint8List> open(Uint8List sealed) async {
    if (sealed.length < 8 + 16) {
      throw const FormatException('sealed frame too short');
    }
    final counter = ByteData.sublistView(sealed, 0, 8).getUint64(0, Endian.big);
    if (_haveAcceptedAny && counter <= _lastAcceptedCounter) {
      throw StateError('non-increasing counter (replay or corruption)');
    }
    final tagStart = sealed.length - 16;
    final cipherText = Uint8List.sublistView(sealed, 8, tagStart);
    final tag = Uint8List.sublistView(sealed, tagStart);
    final nonce = _nonceFromCounter(counter);
    final plaintext = await _aead.decrypt(
      SecretBox(cipherText, nonce: nonce, mac: Mac(tag)),
      secretKey: _key,
    );
    _lastAcceptedCounter = counter;
    _haveAcceptedAny = true;
    return Uint8List.fromList(plaintext);
  }
}

/// Both directions' AEAD state for one Minecraft connection, with the brief
/// current-plus-previous inbound window used during key rotation.
class SessionCrypto {
  _DirectionalCipher _currentOutbound;
  _DirectionalCipher _currentInbound;
  _DirectionalCipher? _previousInbound;

  SessionCrypto._(this._currentOutbound, this._currentInbound);

  static Future<SessionCrypto> derive({
    required List<int> secret,
    required List<int> connectionId,
    required List<int> epkC,
    required List<int> epkS,
    required List<int> dhOutput,
    required bool weAreClient,
  }) async {
    final salt = concatBytes([connectionId, epkC, epkS]);
    final ikm = concatBytes([dhOutput, secret]);
    final c2s = await _hkdf(salt, ikm, _label('mcvpn tunnel c2s'), _keyLen);
    final s2c = await _hkdf(salt, ikm, _label('mcvpn tunnel s2c'), _keyLen);
    final outbound = weAreClient ? c2s : s2c;
    final inbound = weAreClient ? s2c : c2s;
    return SessionCrypto._(
        _DirectionalCipher(outbound), _DirectionalCipher(inbound));
  }

  Future<Uint8List> seal(List<int> plaintext) => _currentOutbound.seal(plaintext);

  /// Tries the current inbound key, then the previous (only present just after
  /// a rotation). Dropping the fallback on the first current-key success is
  /// what confirms the peer switched over too.
  Future<Uint8List> open(Uint8List sealed) async {
    try {
      final pt = await _currentInbound.open(sealed);
      _previousInbound = null;
      return pt;
    } catch (_) {
      final prev = _previousInbound;
      if (prev != null) {
        return prev.open(sealed);
      }
      rethrow;
    }
  }

  /// Replier side of a rotation: seal the reply under the outgoing key, then
  /// swap in the new keys.
  Future<Uint8List> replyToRotation({
    required List<int> secret,
    required List<int> epkA,
    required List<int> epkB,
    required List<int> dhOutput,
    required List<int> replyPlaintext,
  }) async {
    final sealedReply = await _currentOutbound.seal(replyPlaintext);
    await _rotateKeys(secret, epkA, epkB, dhOutput, weAreA: false);
    return sealedReply;
  }

  /// Initiator side of a rotation: swap in the new keys once the reply arrives.
  Future<void> completeRotation({
    required List<int> secret,
    required List<int> epkA,
    required List<int> epkB,
    required List<int> dhOutput,
  }) {
    return _rotateKeys(secret, epkA, epkB, dhOutput, weAreA: true);
  }

  Future<void> _rotateKeys(
      List<int> secret, List<int> epkA, List<int> epkB, List<int> dhOutput,
      {required bool weAreA}) async {
    final salt = concatBytes([epkA, epkB]);
    final ikm = concatBytes([dhOutput, secret]);
    final a2b = await _hkdf(salt, ikm, _label('mcvpn rotate a2b'), _keyLen);
    final b2a = await _hkdf(salt, ikm, _label('mcvpn rotate b2a'), _keyLen);
    final outbound = weAreA ? a2b : b2a;
    final inbound = weAreA ? b2a : a2b;
    _previousInbound = _currentInbound;
    _currentInbound = _DirectionalCipher(inbound);
    _currentOutbound = _DirectionalCipher(outbound);
  }
}

List<int> _label(String s) => s.codeUnits;

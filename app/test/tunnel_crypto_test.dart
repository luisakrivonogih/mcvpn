import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mcvpn/src/crypto/tunnel_crypto.dart';

void main() {
  test('X25519 handshake + AEAD round trips both directions', () async {
    final secret = Uint8List.fromList(List.generate(32, (i) => i));
    final connectionId = Uint8List.fromList(List.generate(16, (i) => 100 + i));

    final clientKp = await EphemeralKeypair.generate();
    final serverKp = await EphemeralKeypair.generate();
    final epkC = clientKp.publicKey;
    final epkS = serverKp.publicKey;

    final dhClient = await clientKp.diffieHellman(epkS);
    final dhServer = await serverKp.diffieHellman(epkC);
    expect(dhClient, equals(dhServer), reason: 'X25519 shared secret must match');

    final client = await SessionCrypto.derive(
      secret: secret,
      connectionId: connectionId,
      epkC: epkC,
      epkS: epkS,
      dhOutput: dhClient,
      weAreClient: true,
    );
    final server = await SessionCrypto.derive(
      secret: secret,
      connectionId: connectionId,
      epkC: epkC,
      epkS: epkS,
      dhOutput: dhServer,
      weAreClient: false,
    );

    final msg = Uint8List.fromList('hello over minecraft'.codeUnits);
    final sealed = await client.seal(msg);
    final opened = await server.open(sealed);
    expect(opened, equals(msg));

    final reply = Uint8List.fromList('and back again'.codeUnits);
    final sealedReply = await server.seal(reply);
    final openedReply = await client.open(sealedReply);
    expect(openedReply, equals(reply));
  });

  test('handshake MACs are deterministic and order-sensitive', () async {
    final secret = Uint8List.fromList(List.filled(32, 7));
    final cid = Uint8List.fromList(List.filled(16, 1));
    final keyId = Uint8List.fromList(List.filled(16, 2));
    final epkC = Uint8List.fromList(List.filled(32, 3));
    final epkS = Uint8List.fromList(List.filled(32, 4));

    final a = await handshakeMac1(secret, cid, keyId, epkC);
    final b = await handshakeMac1(secret, cid, keyId, epkC);
    expect(a, equals(b));
    expect(a.length, 32);

    final m2 = await handshakeMac2(secret, cid, keyId, epkC, epkS);
    expect(m2, isNot(equals(a)));
  });

  test('AEAD rejects a replayed counter', () async {
    final secret = Uint8List.fromList(List.filled(32, 9));
    final cid = Uint8List.fromList(List.filled(16, 5));
    final clientKp = await EphemeralKeypair.generate();
    final serverKp = await EphemeralKeypair.generate();
    final dh = await clientKp.diffieHellman(serverKp.publicKey);
    final dh2 = await serverKp.diffieHellman(clientKp.publicKey);

    final client = await SessionCrypto.derive(
      secret: secret,
      connectionId: cid,
      epkC: clientKp.publicKey,
      epkS: serverKp.publicKey,
      dhOutput: dh,
      weAreClient: true,
    );
    final server = await SessionCrypto.derive(
      secret: secret,
      connectionId: cid,
      epkC: clientKp.publicKey,
      epkS: serverKp.publicKey,
      dhOutput: dh2,
      weAreClient: false,
    );

    final sealed = await client.seal(Uint8List.fromList([1, 2, 3]));
    await server.open(sealed);
    // Replaying the same sealed frame must fail (non-increasing counter).
    await expectLater(server.open(sealed), throwsA(anything));
  });

  test('constant-time equality', () {
    expect(constantTimeEquals([1, 2, 3], [1, 2, 3]), isTrue);
    expect(constantTimeEquals([1, 2, 3], [1, 2, 4]), isFalse);
    expect(constantTimeEquals([1, 2], [1, 2, 3]), isFalse);
  });
}

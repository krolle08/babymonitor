import 'dart:convert';

import 'package:babymonitor/core/auth_engine.dart';
import 'package:babymonitor/core/identity.dart';
import 'package:flutter_test/flutter_test.dart';

/// A deterministic stand-in for Ed25519 that models the property the engine
/// relies on: a signature verifies only against the public key whose matching
/// private key produced it, and only over the exact bytes that were signed.
///
/// A "key id" identifies a keypair. Public-key bytes are `utf8("pk:<id>")`; a
/// signature is `utf8("sig:<id>:<base64(message)>")`.
List<int> _pkBytes(int keyId) => utf8.encode('pk:$keyId');
String _pkB64(int keyId) => base64Url.encode(_pkBytes(keyId));

Signer _signerFor(int keyId) =>
    (message) async => utf8.encode('sig:$keyId:${base64Url.encode(message)}');

Future<bool> _verify(
    List<int> pk, List<int> sig, List<int> message) async {
  final pkStr = utf8.decode(pk);
  if (!pkStr.startsWith('pk:')) return false;
  final id = pkStr.substring(3);
  return utf8.decode(sig) == 'sig:$id:${base64Url.encode(message)}';
}

/// Counter-based byte generator so every nonce/token is distinct and the tests
/// are fully reproducible.
RandomBytes _sequentialBytes() {
  var counter = 1;
  return (count) {
    final out = List<int>.filled(count, 0);
    for (var i = 0; i < count; i++) {
      out[i] = (counter + i) & 0xFF;
    }
    counter += count + 7;
    return out;
  };
}

void main() {
  const cameraKeyId = 1;
  const parentKeyId = 2;

  final cameraIdentity = DeviceIdentity(
    deviceId: 'CAM0000000000001',
    name: 'Nursery',
    publicKey: _pkB64(cameraKeyId),
  );
  final parentIdentity = DeviceIdentity(
    deviceId: 'PAR0000000000002',
    name: "Mom's phone",
    publicKey: _pkB64(parentKeyId),
  );

  late DateTime clock;
  DateTime now() => clock;

  AuthEngine cameraEngine() => AuthEngine(
        sign: _signerFor(cameraKeyId),
        verify: _verify,
        randomBytes: _sequentialBytes(),
        identity: cameraIdentity,
        now: now,
      );
  AuthEngine parentEngine() => AuthEngine(
        sign: _signerFor(parentKeyId),
        verify: _verify,
        randomBytes: _sequentialBytes(),
        identity: parentIdentity,
        now: now,
      );

  String? cameraTrustsParent(String deviceId) =>
      deviceId == parentIdentity.deviceId ? parentIdentity.publicKey : null;

  setUp(() => clock = DateTime.utc(2026, 7, 18, 20, 0, 0));

  group('§8.2 session handshake', () {
    test('full happy path authenticates both roles', () async {
      final camera = cameraEngine();
      final parent = parentEngine();

      // 1. Parent → join-room auth.
      final parentAuth = parent.makeParentJoinAuth();
      expect(parentAuth.deviceId, parentIdentity.deviceId);
      expect(parentAuth.pk, parentIdentity.publicKey);

      // 2. Camera → auth-challenge.
      final challenge =
          await camera.buildChallenge(parentAuth: parentAuth, peerId: 'peer-1');
      expect(camera.issuedNonceFor('peer-1'), challenge.nonce);

      // 2b. Parent verifies the camera identity.
      final cameraOk = await parent.verifyCameraChallenge(
        challenge: challenge,
        myNonce: parentAuth.nonce,
        trustedCameraPk: cameraIdentity.publicKey,
      );
      expect(cameraOk, isTrue);

      // 3. Parent → auth-response.
      final response = await parent.buildAuthResponse(challenge: challenge);
      expect(response.peerId, 'peer-1');

      // 4. Camera verifies the parent.
      final verdict = await camera.verifyAuthResponse(
        response: response,
        nonceIssued: challenge.nonce,
        trustedPkLookup: cameraTrustsParent,
      );
      expect(verdict, AuthVerdict.authenticated);
      // Nonce consumed on success.
      expect(camera.issuedNonceFor('peer-1'), isNull);
    });

    test('parent rejects a camera whose key changed (MITM/reinstall)', () async {
      final camera = cameraEngine();
      final parent = parentEngine();
      final parentAuth = parent.makeParentJoinAuth();
      final challenge =
          await camera.buildChallenge(parentAuth: parentAuth, peerId: 'peer-1');

      final ok = await parent.verifyCameraChallenge(
        challenge: challenge,
        myNonce: parentAuth.nonce,
        trustedCameraPk: _pkB64(999), // different key than the camera signed with
      );
      expect(ok, isFalse);
    });

    test('parent challenge verification is bound to its own nonce', () async {
      final camera = cameraEngine();
      final parent = parentEngine();
      final parentAuth = parent.makeParentJoinAuth();
      final challenge =
          await camera.buildChallenge(parentAuth: parentAuth, peerId: 'peer-1');

      final ok = await parent.verifyCameraChallenge(
        challenge: challenge,
        myNonce: 'a-different-nonce',
        trustedCameraPk: cameraIdentity.publicKey,
      );
      expect(ok, isFalse);
    });

    test('wrong signature is rejected (badSignature)', () async {
      final camera = cameraEngine();
      final parent = parentEngine();
      final parentAuth = parent.makeParentJoinAuth();
      final challenge =
          await camera.buildChallenge(parentAuth: parentAuth, peerId: 'peer-1');

      final tampered = AuthResponse(
        peerId: challenge.peerId,
        deviceId: parentIdentity.deviceId,
        pk: parentIdentity.publicKey,
        sig: base64Url.encode(utf8.encode('sig:$parentKeyId:forged')),
      );
      final verdict = await camera.verifyAuthResponse(
        response: tampered,
        nonceIssued: challenge.nonce,
        trustedPkLookup: cameraTrustsParent,
      );
      expect(verdict, AuthVerdict.badSignature);
    });

    test('unknown device is rejected (notTrusted)', () async {
      final camera = cameraEngine();
      final parent = parentEngine();
      final parentAuth = parent.makeParentJoinAuth();
      final challenge =
          await camera.buildChallenge(parentAuth: parentAuth, peerId: 'peer-1');
      final response = await parent.buildAuthResponse(challenge: challenge);

      final verdict = await camera.verifyAuthResponse(
        response: response,
        nonceIssued: challenge.nonce,
        trustedPkLookup: (_) => null, // not in the trust store
      );
      expect(verdict, AuthVerdict.notTrusted);
    });

    test('presented key differing from the trusted key is rejected', () async {
      final camera = cameraEngine();
      final parent = parentEngine();
      final parentAuth = parent.makeParentJoinAuth();
      final challenge =
          await camera.buildChallenge(parentAuth: parentAuth, peerId: 'peer-1');
      final response = await parent.buildAuthResponse(challenge: challenge);

      final verdict = await camera.verifyAuthResponse(
        response: response,
        nonceIssued: challenge.nonce,
        trustedPkLookup: (_) => _pkB64(777), // trust store holds a different key
      );
      expect(verdict, AuthVerdict.notTrusted);
    });

    test('replayed auth-response is rejected (single-use nonce)', () async {
      final camera = cameraEngine();
      final parent = parentEngine();
      final parentAuth = parent.makeParentJoinAuth();
      final challenge =
          await camera.buildChallenge(parentAuth: parentAuth, peerId: 'peer-1');
      final response = await parent.buildAuthResponse(challenge: challenge);

      final first = await camera.verifyAuthResponse(
        response: response,
        nonceIssued: challenge.nonce,
        trustedPkLookup: cameraTrustsParent,
      );
      expect(first, AuthVerdict.authenticated);

      final second = await camera.verifyAuthResponse(
        response: response,
        nonceIssued: challenge.nonce,
        trustedPkLookup: cameraTrustsParent,
      );
      expect(second, AuthVerdict.replay);
    });

    test('distinct peers get distinct nonces', () async {
      final camera = cameraEngine();
      final parent = parentEngine();
      final a = await camera.buildChallenge(
          parentAuth: parent.makeParentJoinAuth(), peerId: 'peer-a');
      final b = await camera.buildChallenge(
          parentAuth: parent.makeParentJoinAuth(), peerId: 'peer-b');
      expect(a.nonce, isNot(b.nonce));
    });
  });

  group('§8.1 pairing tokens', () {
    test('pairing happy path adds the parent and consumes the token', () async {
      final camera = cameraEngine();
      final parent = parentEngine();

      final token = camera.issuePairingToken();
      expect(camera.hasValidPairingToken(token), isTrue);

      final request = await parent.buildPairRequest(token);
      final outcome = await camera.verifyPairRequest(request);
      expect(outcome.accepted, isTrue);
      expect(outcome.device!.deviceId, parentIdentity.deviceId);
      expect(outcome.device!.pk, parentIdentity.publicKey);
      expect(outcome.device!.role, DeviceRole.parent);

      // Single use: the token is gone afterward.
      expect(camera.hasValidPairingToken(token), isFalse);
      final replay = await camera.verifyPairRequest(request);
      expect(replay.accepted, isFalse);
    });

    test('a proof for an unknown token is rejected', () async {
      final camera = cameraEngine();
      final parent = parentEngine();
      camera.issuePairingToken(); // some token is outstanding
      final request = await parent.buildPairRequest('not-the-real-token');
      final outcome = await camera.verifyPairRequest(request);
      expect(outcome.accepted, isFalse);
    });

    test('an expired token no longer verifies (5-minute TTL)', () async {
      final camera = cameraEngine();
      final parent = parentEngine();
      final token = camera.issuePairingToken();
      final request = await parent.buildPairRequest(token);

      clock = clock.add(const Duration(minutes: 5, seconds: 1));
      expect(camera.hasValidPairingToken(token), isFalse);
      final outcome = await camera.verifyPairRequest(request);
      expect(outcome.accepted, isFalse);
    });

    test('a token just inside the TTL still verifies', () async {
      final camera = cameraEngine();
      final parent = parentEngine();
      final token = camera.issuePairingToken();
      final request = await parent.buildPairRequest(token);

      clock = clock.add(const Duration(minutes: 4, seconds: 59));
      final outcome = await camera.verifyPairRequest(request);
      expect(outcome.accepted, isTrue);
    });

    test('clearPairingTokens ends the pairing session', () async {
      final camera = cameraEngine();
      final parent = parentEngine();
      final token = camera.issuePairingToken();
      final request = await parent.buildPairRequest(token);
      camera.clearPairingTokens();
      expect(camera.hasValidPairingToken(), isFalse);
      final outcome = await camera.verifyPairRequest(request);
      expect(outcome.accepted, isFalse);
    });
  });
}

/// Session-authentication and pairing-token logic (docs/PROTOCOL.md §8.1/§8.2).
///
/// Pure Dart — **no Flutter, no crypto package**. All signing and verification
/// is injected as async callbacks ([Signer]/[Verifier]) so the concrete
/// Ed25519 implementation stays in `services/crypto_service.dart` and this
/// class remains unit-testable with a fake signer.
///
/// The engine is usable by both roles:
///   * Parent: [makeParentJoinAuth] → [verifyCameraChallenge] → [buildAuthResponse].
///   * Camera: [buildChallenge] → [verifyAuthResponse]; plus [issuePairingToken]
///     and [verifyPairRequest] for the §8.1 ceremony.
///
/// Signed-message binding (canonical for this build): each signature covers the
/// UTF-8 bytes of the base64url nonce (or token) concatenated with the UTF-8
/// bytes of the peer/device id — i.e. `utf8(nonce) ∥ utf8(peerId)`. Both sides
/// hold these values as strings, which avoids any base64 decode ambiguity.
library;

import 'dart:convert';

import 'identity.dart';

/// Signs [message] with this device's private key, returning raw signature
/// bytes. Injected by `CryptoService`.
typedef Signer = Future<List<int>> Function(List<int> message);

/// Verifies that [signature] over [message] was produced by the holder of
/// [publicKey] (all raw bytes). Injected by `CryptoService`.
typedef Verifier = Future<bool> Function(
    List<int> publicKey, List<int> signature, List<int> message);

/// Returns [count] cryptographically-random bytes. Injected so tests can use a
/// deterministic generator.
typedef RandomBytes = List<int> Function(int count);

/// The `auth` object a parent sends inside `join-room` (§8.2 step 1).
class ParentJoinAuth {
  const ParentJoinAuth({
    required this.deviceId,
    required this.pk,
    required this.nonce,
  });

  final String deviceId;

  /// base64url parent public key.
  final String pk;

  /// base64url fresh 32-byte challenge for the camera (`nonce_p`).
  final String nonce;

  Map<String, dynamic> toJson() =>
      {'deviceId': deviceId, 'pk': pk, 'nonce': nonce};

  factory ParentJoinAuth.fromJson(Map<String, dynamic> json) => ParentJoinAuth(
        deviceId: json['deviceId'] as String,
        pk: json['pk'] as String,
        nonce: json['nonce'] as String,
      );
}

/// `auth-challenge` (camera → parent, §8.2 step 2).
class AuthChallenge {
  const AuthChallenge({
    required this.peerId,
    required this.nonce,
    required this.sig,
  });

  final String peerId;

  /// base64url fresh 32-byte challenge for the parent (`nonce_c`).
  final String nonce;

  /// base64url `sign(privKey_camera, nonce_p ∥ peerId)`.
  final String sig;

  Map<String, dynamic> toJson() =>
      {'peerId': peerId, 'nonce': nonce, 'sig': sig};

  factory AuthChallenge.fromJson(Map<String, dynamic> json) => AuthChallenge(
        peerId: json['peerId'] as String,
        nonce: json['nonce'] as String,
        sig: json['sig'] as String,
      );
}

/// `auth-response` (parent → camera, §8.2 step 3).
class AuthResponse {
  const AuthResponse({
    required this.peerId,
    required this.deviceId,
    required this.pk,
    required this.sig,
  });

  final String peerId;
  final String deviceId;

  /// base64url parent public key.
  final String pk;

  /// base64url `sign(privKey_parent, nonce_c ∥ peerId)`.
  final String sig;

  Map<String, dynamic> toJson() =>
      {'peerId': peerId, 'deviceId': deviceId, 'pk': pk, 'sig': sig};

  factory AuthResponse.fromJson(Map<String, dynamic> json) => AuthResponse(
        peerId: json['peerId'] as String,
        deviceId: json['deviceId'] as String,
        pk: json['pk'] as String,
        sig: json['sig'] as String,
      );
}

/// `pair-request` (parent → camera on LAN only, §8.1 step 2).
class PairRequest {
  const PairRequest({
    required this.deviceId,
    required this.name,
    required this.pk,
    required this.proof,
  });

  final String deviceId;
  final String name;

  /// base64url parent public key.
  final String pk;

  /// base64url `sign(privKey_parent, token ∥ deviceId_parent)`.
  final String proof;

  Map<String, dynamic> toJson() =>
      {'deviceId': deviceId, 'name': name, 'pk': pk, 'proof': proof};

  factory PairRequest.fromJson(Map<String, dynamic> json) => PairRequest(
        deviceId: json['deviceId'] as String,
        name: json['name'] as String,
        pk: json['pk'] as String,
        proof: json['proof'] as String,
      );
}

/// Outcome of the camera verifying a parent's `auth-response` (§8.2 step 4).
enum AuthVerdict {
  /// Trusted device, fresh nonce, valid signature — proceed with the offer.
  authenticated,

  /// Device id unknown, or the presented key differs from the trusted one.
  notTrusted,

  /// Nonce already consumed — replayed `auth-response`.
  replay,

  /// Signature did not verify against the presented key.
  badSignature,
}

/// Result of verifying a `pair-request` against the outstanding tokens (§8.1).
class PairOutcome {
  const PairOutcome._(this.accepted, this.reason, this.device);

  /// Accepted: [device] is the parent to add to the trust store.
  factory PairOutcome.accepted(TrustedDevice device) =>
      PairOutcome._(true, null, device);

  /// Rejected with a human-readable [reason] (echoed in `pair-response`).
  factory PairOutcome.rejected(String reason) =>
      PairOutcome._(false, reason, null);

  final bool accepted;
  final String? reason;
  final TrustedDevice? device;
}

class AuthEngine {
  AuthEngine({
    required Signer sign,
    required Verifier verify,
    required RandomBytes randomBytes,
    required this.identity,
    DateTime Function() now = DateTime.now,
    this.pairingTokenTtl = const Duration(minutes: 5),
    this.nonceBytes = 32,
    this.tokenBytes = 32,
  })  : _sign = sign,
        _verify = verify,
        _randomBytes = randomBytes,
        _now = now;

  final Signer _sign;
  final Verifier _verify;
  final RandomBytes _randomBytes;
  final DateTime Function() _now;

  /// This device's own identity (deviceId, name, base64url public key).
  final DeviceIdentity identity;

  /// How long a pairing token stays valid (§8.1: 5 minutes).
  final Duration pairingTokenTtl;
  final int nonceBytes;
  final int tokenBytes;

  /// Nonces issued in [buildChallenge] but not yet consumed, keyed by peerId.
  final Map<String, String> _issuedNonces = {};

  /// Nonces already consumed by a successful [verifyAuthResponse] — replay
  /// guard (single use).
  final Set<String> _consumedNonces = {};

  /// Outstanding pairing tokens → issue time (for TTL + single use).
  final Map<String, DateTime> _pairingTokens = {};

  // --- Parent side (§8.2) ---

  /// Builds the `auth` object for `join-room` and returns the fresh `nonce_p`
  /// the caller must retain to verify the camera's challenge.
  ParentJoinAuth makeParentJoinAuth() => ParentJoinAuth(
        deviceId: identity.deviceId,
        pk: identity.publicKey,
        nonce: _freshNonce(),
      );

  /// Verifies the camera's `auth-challenge` signature over `nonce_p ∥ peerId`
  /// against [trustedCameraPk] (the parent's stored key for that camera).
  /// A `false` result means the camera key changed — surface the MITM alert.
  Future<bool> verifyCameraChallenge({
    required AuthChallenge challenge,
    required String myNonce,
    required String trustedCameraPk,
  }) async {
    return _verifySig(
      pk: trustedCameraPk,
      sig: challenge.sig,
      boundNonce: myNonce,
      peerId: challenge.peerId,
    );
  }

  /// Parent side (§8.1 step 2): after scanning the QR, signs `token ∥ deviceId`
  /// and returns the `pair-request` to send over the LAN link.
  Future<PairRequest> buildPairRequest(String token) async {
    final proof = await _sign(_bind(token, identity.deviceId));
    return PairRequest(
      deviceId: identity.deviceId,
      name: identity.name,
      pk: identity.publicKey,
      proof: _b64.encode(proof),
    );
  }

  /// Signs `nonce_c ∥ peerId` and returns the parent's `auth-response`.
  Future<AuthResponse> buildAuthResponse({required AuthChallenge challenge}) async {
    final sig = await _sign(_bind(challenge.nonce, challenge.peerId));
    return AuthResponse(
      peerId: challenge.peerId,
      deviceId: identity.deviceId,
      pk: identity.publicKey,
      sig: _b64.encode(sig),
    );
  }

  // --- Camera side (§8.2) ---

  /// Issues a per-peer challenge: signs `nonce_p ∥ peerId` and returns the
  /// `auth-challenge`. The generated `nonce_c` is remembered for
  /// [verifyAuthResponse]'s single-use bookkeeping.
  Future<AuthChallenge> buildChallenge({
    required ParentJoinAuth parentAuth,
    required String peerId,
  }) async {
    final nonceC = _freshNonce();
    _issuedNonces[peerId] = nonceC;
    final sig = await _sign(_bind(parentAuth.nonce, peerId));
    return AuthChallenge(peerId: peerId, nonce: nonceC, sig: _b64.encode(sig));
  }

  /// The `nonce_c` issued for [peerId] in [buildChallenge], or null if none is
  /// outstanding (already consumed / never issued).
  String? issuedNonceFor(String peerId) => _issuedNonces[peerId];

  /// Verifies a parent's `auth-response` (§8.2 step 4).
  ///
  /// [nonceIssued] is the `nonce_c` the camera sent this peer (see
  /// [issuedNonceFor]); [trustedPkLookup] returns the trusted base64url key for
  /// a deviceId or null. Order: trust → replay → signature. A successful verify
  /// consumes the nonce so a replay is rejected.
  Future<AuthVerdict> verifyAuthResponse({
    required AuthResponse response,
    required String nonceIssued,
    required String? Function(String deviceId) trustedPkLookup,
  }) async {
    final trustedPk = trustedPkLookup(response.deviceId);
    if (trustedPk == null || !_constantTimeEquals(trustedPk, response.pk)) {
      return AuthVerdict.notTrusted;
    }
    if (_consumedNonces.contains(nonceIssued)) {
      return AuthVerdict.replay;
    }
    final ok = await _verifySig(
      pk: response.pk,
      sig: response.sig,
      boundNonce: nonceIssued,
      peerId: response.peerId,
    );
    if (!ok) return AuthVerdict.badSignature;
    _consumedNonces.add(nonceIssued);
    _issuedNonces.remove(response.peerId);
    return AuthVerdict.authenticated;
  }

  /// Forgets any nonce state for a peer that left mid-handshake.
  void forgetPeer(String peerId) => _issuedNonces.remove(peerId);

  // --- Pairing tokens (§8.1, camera side) ---

  /// Generates a fresh single-use pairing token (32 random bytes, base64url)
  /// and records it with a 5-minute TTL. Returns the token to embed in the QR.
  String issuePairingToken() {
    _pruneExpiredTokens();
    final token = _b64.encode(_randomBytes(tokenBytes));
    _pairingTokens[token] = _now();
    return token;
  }

  /// True when [token] (or any token, if omitted) is currently outstanding and
  /// unexpired.
  bool hasValidPairingToken([String? token]) {
    _pruneExpiredTokens();
    if (token == null) return _pairingTokens.isNotEmpty;
    return _pairingTokens.containsKey(token);
  }

  /// Drops every outstanding token (camera left pairing mode).
  void clearPairingTokens() => _pairingTokens.clear();

  /// Verifies a `pair-request` proof against the outstanding tokens (§8.1
  /// step 3). On success the matching token is consumed and a [TrustedDevice]
  /// (role: parent) is returned for the trust store.
  Future<PairOutcome> verifyPairRequest(PairRequest request) async {
    _pruneExpiredTokens();
    if (_pairingTokens.isEmpty) {
      return PairOutcome.rejected('no pairing session active');
    }
    List<int> proofBytes;
    List<int> pkBytes;
    try {
      proofBytes = _b64.decode(request.proof);
      pkBytes = _b64.decode(request.pk);
    } catch (_) {
      return PairOutcome.rejected('malformed proof or key');
    }
    for (final token in _pairingTokens.keys.toList()) {
      final message = _bind(token, request.deviceId);
      if (await _verify(pkBytes, proofBytes, message)) {
        _pairingTokens.remove(token); // single use
        return PairOutcome.accepted(TrustedDevice(
          deviceId: request.deviceId,
          name: request.name,
          pk: request.pk,
          role: DeviceRole.parent,
          addedAt: _now(),
        ));
      }
    }
    return PairOutcome.rejected('pairing proof did not verify');
  }

  // --- Internals ---

  static const Base64Codec _b64 = Base64Codec.urlSafe();

  String _freshNonce() => _b64.encode(_randomBytes(nonceBytes));

  /// Canonical signed message: `utf8(nonce) ∥ utf8(peerId)`.
  List<int> _bind(String nonce, String peerId) =>
      [...utf8.encode(nonce), ...utf8.encode(peerId)];

  Future<bool> _verifySig({
    required String pk,
    required String sig,
    required String boundNonce,
    required String peerId,
  }) async {
    List<int> pkBytes;
    List<int> sigBytes;
    try {
      pkBytes = _b64.decode(pk);
      sigBytes = _b64.decode(sig);
    } catch (_) {
      return false;
    }
    return _verify(pkBytes, sigBytes, _bind(boundNonce, peerId));
  }

  void _pruneExpiredTokens() {
    final cutoff = _now().subtract(pairingTokenTtl);
    _pairingTokens.removeWhere((_, issuedAt) => issuedAt.isBefore(cutoff));
  }

  /// Length-aware constant-time comparison of two base64url strings, so a
  /// trusted-key check does not leak via timing.
  static bool _constantTimeEquals(String a, String b) {
    final ab = utf8.encode(a);
    final bb = utf8.encode(b);
    var diff = ab.length ^ bb.length;
    final n = ab.length < bb.length ? ab.length : bb.length;
    for (var i = 0; i < n; i++) {
      diff |= ab[i] ^ bb[i];
    }
    return diff == 0;
  }
}

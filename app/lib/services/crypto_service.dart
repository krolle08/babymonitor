/// Device keypair + signing service (docs/PROTOCOL.md §8, TR9).
///
/// Generates an Ed25519 keypair on first run (`package:cryptography`), persists
/// the 32-byte private seed in platform secure storage
/// (`flutter_secure_storage` — Android Keystore / iOS Keychain) and never lets
/// it leave the device. Exposes the base64url public key + deviceId and the
/// [sign]/[verify] helpers that `AuthEngine` injects (§8.2).
///
/// If secure storage is unavailable the service falls back to an in-memory
/// keypair for the session (logged) so the app still runs — the golden path
/// (NTR7) never depends on the keystore being reachable.
library;

import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../core/auth_engine.dart' show Signer, Verifier;
import '../core/identity.dart';
import 'settings_service.dart';

class CryptoService {
  CryptoService._(this._keyPair, this._publicKeyBytes, this.deviceId);

  static final Ed25519 _ed25519 = Ed25519();
  static const String _kSeedKey = 'ed25519_seed_b64';

  static CryptoService? _instance;

  final SimpleKeyPair _keyPair;
  final List<int> _publicKeyBytes;

  /// The 16-hex device id (§5.3), shared with [SettingsService.deviceId].
  final String deviceId;

  /// Loads (or returns) the singleton, ensuring a keypair exists. Call once at
  /// startup after [SettingsService.load].
  static Future<CryptoService> load({
    FlutterSecureStorage? storage,
    String? deviceId,
  }) async {
    final existing = _instance;
    if (existing != null) return existing;

    final store = storage ?? const FlutterSecureStorage();
    final id = deviceId ?? SettingsService.instance.deviceId;
    SimpleKeyPair keyPair;
    try {
      final seedB64 = await store.read(key: _kSeedKey);
      if (seedB64 != null) {
        keyPair = await _ed25519.newKeyPairFromSeed(base64Url.decode(seedB64));
      } else {
        keyPair = await _ed25519.newKeyPair();
        final seed = await keyPair.extractPrivateKeyBytes();
        await store.write(key: _kSeedKey, value: base64Url.encode(seed));
      }
    } catch (e) {
      debugPrint('CryptoService: secure storage unavailable ($e) — '
          'using an in-memory keypair for this session');
      keyPair = await _ed25519.newKeyPair();
    }
    final publicKey = await keyPair.extractPublicKey();
    return _instance = CryptoService._(keyPair, publicKey.bytes, id);
  }

  /// The loaded singleton. [load] must have completed first.
  static CryptoService get instance {
    final loaded = _instance;
    if (loaded == null) {
      throw StateError('CryptoService.load() has not completed yet');
    }
    return loaded;
  }

  /// base64url-encoded 32-byte Ed25519 public key.
  String get publicKeyBase64 => base64Url.encode(_publicKeyBytes);

  /// This device's public identity with the given display [name].
  DeviceIdentity identity(String name) => DeviceIdentity(
        deviceId: deviceId,
        name: name,
        publicKey: publicKeyBase64,
      );

  /// Signs [message] with the private key, returning raw signature bytes.
  Future<List<int>> sign(List<int> message) async {
    final signature = await _ed25519.sign(message, keyPair: _keyPair);
    return signature.bytes;
  }

  /// Verifies [signature] over [message] against the raw Ed25519 [publicKey].
  Future<bool> verify(
      List<int> publicKey, List<int> signature, List<int> message) async {
    try {
      final key = SimplePublicKey(publicKey, type: KeyPairType.ed25519);
      return await _ed25519.verify(
        message,
        signature: Signature(signature, publicKey: key),
      );
    } catch (e) {
      debugPrint('CryptoService: verify failed: $e');
      return false;
    }
  }

  /// [Signer] tear-off for `AuthEngine` injection.
  Signer get signer => sign;

  /// [Verifier] tear-off for `AuthEngine` injection.
  Verifier get verifier => verify;
}

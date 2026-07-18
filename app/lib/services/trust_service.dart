/// Trust store for paired devices (docs/PROTOCOL.md §8, F12).
///
/// The trust list is **public data** (no private keys) so it lives in normal
/// [SharedPreferences] as a JSON array of [TrustedDevice]. Both roles use it:
/// the camera to authorize parents (§8.2 step 4) and the parent to recognise a
/// camera's key (§8.2 step 2). Mutations (add / rename / revoke) persist and
/// fan out on [changes] so live sessions and the UI react (e.g. drop a revoked
/// peer).
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:shared_preferences/shared_preferences.dart';

import '../core/identity.dart';

class TrustService {
  TrustService._(this._prefs, this._devices);

  static const String _kTrusted = 'trusted_devices';

  static TrustService? _instance;

  final SharedPreferences _prefs;
  final List<TrustedDevice> _devices;
  final StreamController<List<TrustedDevice>> _changes =
      StreamController<List<TrustedDevice>>.broadcast();

  /// Loads (or returns) the singleton trust store.
  static Future<TrustService> load({SharedPreferences? prefs}) async {
    final existing = _instance;
    if (existing != null) return existing;
    final store = prefs ?? await SharedPreferences.getInstance();
    final devices = _decode(store.getString(_kTrusted));
    return _instance = TrustService._(store, devices);
  }

  /// The loaded singleton. [load] must have completed first.
  static TrustService get instance {
    final loaded = _instance;
    if (loaded == null) {
      throw StateError('TrustService.load() has not completed yet');
    }
    return loaded;
  }

  static List<TrustedDevice> _decode(String? raw) {
    if (raw == null || raw.isEmpty) return [];
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      return list
          .map((e) => TrustedDevice.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (e) {
      debugPrint('TrustService: corrupt trust store ignored: $e');
      return [];
    }
  }

  /// A snapshot of the current trust list (unmodifiable).
  List<TrustedDevice> get devices => List.unmodifiable(_devices);

  /// Trusted cameras only (for a parent picking which to watch).
  List<TrustedDevice> get cameras =>
      _devices.where((d) => d.role == DeviceRole.camera).toList();

  /// Trusted parents only (for the camera's authorization checks).
  List<TrustedDevice> get parents =>
      _devices.where((d) => d.role == DeviceRole.parent).toList();

  /// Emits the full list on every mutation.
  Stream<List<TrustedDevice>> get changes => _changes.stream;

  TrustedDevice? byDeviceId(String deviceId) {
    for (final device in _devices) {
      if (device.deviceId == deviceId) return device;
    }
    return null;
  }

  bool isTrusted(String deviceId) => byDeviceId(deviceId) != null;

  /// The trusted base64url public key for [deviceId], or null if not trusted.
  /// This is the lookup `AuthEngine.verifyAuthResponse` expects.
  String? trustedPk(String deviceId) => byDeviceId(deviceId)?.pk;

  /// Adds or replaces a trusted device (re-pairing updates the key/name).
  Future<void> add(TrustedDevice device) async {
    _devices.removeWhere((d) => d.deviceId == device.deviceId);
    _devices.add(device);
    await _persistAndNotify();
  }

  /// Renames a trusted device; no-op if unknown.
  Future<void> rename(String deviceId, String name) async {
    final index = _devices.indexWhere((d) => d.deviceId == deviceId);
    if (index < 0) return;
    _devices[index] = _devices[index].copyWith(name: name);
    await _persistAndNotify();
  }

  /// Revokes (removes) a trusted device. The next auth attempt from it fails;
  /// live sessions listening to [changes] drop it (§8, F12).
  Future<void> revoke(String deviceId) async {
    final before = _devices.length;
    _devices.removeWhere((d) => d.deviceId == deviceId);
    if (_devices.length == before) return;
    await _persistAndNotify();
  }

  Future<void> _persistAndNotify() async {
    try {
      await _prefs.setString(
          _kTrusted, jsonEncode(_devices.map((d) => d.toJson()).toList()));
    } catch (e) {
      debugPrint('TrustService: persist failed: $e');
    }
    if (!_changes.isClosed) _changes.add(devices);
  }

  Future<void> dispose() async {
    await _changes.close();
  }
}

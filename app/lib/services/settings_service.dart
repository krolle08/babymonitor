/// SharedPreferences-backed runtime settings (docs/PROTOCOL.md §5.1).
///
/// Holds everything the Settings screen edits (server URLs, family token,
/// noise sensitivity) plus device identity and reconnect bookkeeping for both
/// roles. Load once with [SettingsService.load]; read synchronously after.
library;

import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

import '../config/app_config.dart';

/// Singleton settings store. `await SettingsService.load()` during startup,
/// then use [SettingsService.instance] (or the returned reference) everywhere.
class SettingsService {
  SettingsService._(this._prefs);

  static SettingsService? _instance;

  /// Loads (or returns) the singleton. Generates [deviceId] on first run
  /// (16 hex chars from [Random.secure], generated exactly once).
  static Future<SettingsService> load() async {
    final existing = _instance;
    if (existing != null) return existing;
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getString(_kDeviceId) == null) {
      await prefs.setString(_kDeviceId, _generateDeviceId());
    }
    return _instance = SettingsService._(prefs);
  }

  /// The loaded singleton. [load] must have completed first.
  static SettingsService get instance {
    final loaded = _instance;
    if (loaded == null) {
      throw StateError('SettingsService.load() has not completed yet');
    }
    return loaded;
  }

  final SharedPreferences _prefs;

  static const _kSignalingUrl = 'signalingUrl';
  static const _kApiBaseUrl = 'apiBaseUrl';
  static const _kFamilyToken = 'familyToken';
  static const _kNoiseSensitivity = 'noiseSensitivity';
  static const _kDeviceId = 'deviceId';
  static const _kRole = 'role';
  static const _kLastRoomId = 'lastRoomId';
  static const _kReclaimToken = 'reclaimToken';
  static const _kLastJoinedRoom = 'lastJoinedRoom';
  static const _kLastPeerId = 'lastPeerId';
  static const _kAllowCodeJoins = 'allowCodeJoins';
  static const _kDeviceName = 'deviceName';
  static const _kLanAddrPrefix = 'lanAddr:'; // + camera deviceId

  static String _generateDeviceId() {
    final rng = Random.secure();
    const hexDigits = '0123456789abcdef';
    return List.generate(16, (_) => hexDigits[rng.nextInt(16)]).join();
  }

  // --- Identity ---

  /// Stable per-install device id: 16 hex chars, generated once.
  String get deviceId => _prefs.getString(_kDeviceId)!;

  /// 'camera' | 'parent' | null (not chosen yet — role picker, TR8).
  String? get role => _prefs.getString(_kRole);

  Future<void> setRole(String value) async {
    if (value != 'camera' && value != 'parent') {
      throw ArgumentError.value(value, 'role', "must be 'camera' or 'parent'");
    }
    await _prefs.setString(_kRole, value);
  }

  // --- Server endpoints + auth (PROTOCOL §3, §6) ---

  String get signalingUrl =>
      _prefs.getString(_kSignalingUrl) ?? AppConfig.defaultSignalingUrl;

  Future<void> setSignalingUrl(String value) =>
      _prefs.setString(_kSignalingUrl, value);

  String get apiBaseUrl =>
      _prefs.getString(_kApiBaseUrl) ?? AppConfig.defaultApiBaseUrl;

  Future<void> setApiBaseUrl(String value) =>
      _prefs.setString(_kApiBaseUrl, value);

  /// Shared-secret bearer token (TR7). Empty string until configured.
  String get familyToken => _prefs.getString(_kFamilyToken) ?? '';

  Future<void> setFamilyToken(String value) =>
      _prefs.setString(_kFamilyToken, value);

  // --- Noise sensitivity (F7) ---

  /// 'low' | 'medium' | 'high'.
  String get noiseSensitivity {
    final value = _prefs.getString(_kNoiseSensitivity);
    if (value != null && AppConfig.noiseThresholds.containsKey(value)) {
      return value;
    }
    return AppConfig.defaultNoiseSensitivity;
  }

  Future<void> setNoiseSensitivity(String value) async {
    if (!AppConfig.noiseThresholds.containsKey(value)) {
      throw ArgumentError.value(
          value, 'noiseSensitivity', "must be 'low', 'medium' or 'high'");
    }
    await _prefs.setString(_kNoiseSensitivity, value);
  }

  /// The 0.0–1.0 trigger level for the current [noiseSensitivity].
  double get noiseThreshold =>
      AppConfig.noiseThresholds[noiseSensitivity] ??
      AppConfig.noiseThresholds[AppConfig.defaultNoiseSensitivity]!;

  // --- Camera reconnect bookkeeping (PROTOCOL §2.1 reclaim) ---

  /// Room the camera last created, for post-crash/reconnect reclaim.
  String? get lastRoomId => _prefs.getString(_kLastRoomId);

  /// Reclaim token paired with [lastRoomId].
  String? get reclaimToken => _prefs.getString(_kReclaimToken);

  Future<void> setCameraRoom(String roomId, String reclaimToken) async {
    await _prefs.setString(_kLastRoomId, roomId);
    await _prefs.setString(_kReclaimToken, reclaimToken);
  }

  Future<void> clearCameraRoom() async {
    await _prefs.remove(_kLastRoomId);
    await _prefs.remove(_kReclaimToken);
  }

  // --- Parent rejoin bookkeeping (PROTOCOL §2.1 join-room peerId reuse) ---

  /// Room the parent last joined.
  String? get lastJoinedRoom => _prefs.getString(_kLastJoinedRoom);

  /// peerId the server assigned in [lastJoinedRoom], reused on rejoin.
  String? get lastPeerId => _prefs.getString(_kLastPeerId);

  Future<void> setParentRoom(String roomId, String peerId) async {
    await _prefs.setString(_kLastJoinedRoom, roomId);
    await _prefs.setString(_kLastPeerId, peerId);
  }

  Future<void> clearParentRoom() async {
    await _prefs.remove(_kLastJoinedRoom);
    await _prefs.remove(_kLastPeerId);
  }

  // --- Trust / LAN identity (F11/F12, PROTOCOL §7, §8) ---

  /// Whether guests may join by typing the room code (§8.2 bootstrap). Default
  /// on (NTR2). Trusted devices never need the code regardless of this.
  bool get allowCodeJoins => _prefs.getBool(_kAllowCodeJoins) ?? true;

  Future<void> setAllowCodeJoins(bool value) =>
      _prefs.setBool(_kAllowCodeJoins, value);

  /// This device's human-readable pairing name (shown in the peer's trust list
  /// and in the QR/mDNS TXT). Defaults to `Camera <id>` / `Parent <id>` using
  /// the last 4 hex of [deviceId] so two phones in a house are distinguishable.
  String get deviceName {
    final stored = _prefs.getString(_kDeviceName);
    if (stored != null && stored.trim().isNotEmpty) return stored.trim();
    final suffix = deviceId.substring(deviceId.length - 4);
    final base = role == 'camera' ? 'Camera' : 'Parent';
    return '$base $suffix';
  }

  Future<void> setDeviceName(String value) =>
      _prefs.setString(_kDeviceName, value.trim());

  /// Last LAN `ws://host:port/ws` address seen for a trusted camera, tried
  /// first on connect/reconnect (§7 connection order). Keyed by camera
  /// deviceId so multiple cameras are remembered independently.
  String? lastLanAddress(String cameraDeviceId) =>
      _prefs.getString('$_kLanAddrPrefix$cameraDeviceId');

  Future<void> setLastLanAddress(String cameraDeviceId, String address) =>
      _prefs.setString('$_kLanAddrPrefix$cameraDeviceId', address);

  Future<void> clearLastLanAddress(String cameraDeviceId) =>
      _prefs.remove('$_kLanAddrPrefix$cameraDeviceId');
}

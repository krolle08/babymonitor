/// SharedPreferences-backed runtime settings (docs/PROTOCOL.md §5.1).
///
/// Holds everything the Settings screen edits (server URLs, family token,
/// noise sensitivity) plus device identity and reconnect bookkeeping for both
/// roles. Load once with [SettingsService.load]; read synchronously after.
library;

import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

import '../config/app_config.dart';
import '../core/camera_controls.dart';

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
  static const _kNoiseThreshold = 'noiseThreshold'; // custom bar, F13
  static const _kNoiseSustainMs = 'noiseSustainMs';
  static const _kIgnoreSteadySound = 'ignoreSteadySound';
  static const _kAudioHangMs = 'audioHangMs';
  static const _kCameraBrightness = 'cameraBrightness'; // F15
  static const _kCameraNightMode = 'cameraNightMode';
  static const _kListenMode = 'listenMode'; // F13, per parent device
  static const _kPlaybackVolume = 'playbackVolume';

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

  /// Picks one of the three presets. Clears any custom bar (F13) so the
  /// preset is what actually applies.
  Future<void> setNoiseSensitivity(String value) async {
    if (!AppConfig.noiseThresholds.containsKey(value)) {
      throw ArgumentError.value(
          value, 'noiseSensitivity', "must be 'low', 'medium' or 'high'");
    }
    await _prefs.setString(_kNoiseSensitivity, value);
    await _prefs.remove(_kNoiseThreshold);
  }

  /// The 0.0–1.0 trigger level in force: a custom bar set with
  /// [setNoiseThreshold] if there is one, else the [noiseSensitivity] preset.
  double get noiseThreshold {
    final custom = _prefs.getDouble(_kNoiseThreshold);
    if (custom != null && custom.isFinite) {
      return custom
          .clamp(AppConfig.minNoiseThreshold, AppConfig.maxNoiseThreshold)
          .toDouble();
    }
    return AppConfig.noiseThresholds[noiseSensitivity] ??
        AppConfig.noiseThresholds[AppConfig.defaultNoiseSensitivity]!;
  }

  /// True when the bar was dragged to a value of its own rather than left on
  /// one of the three presets.
  bool get hasCustomNoiseThreshold => _prefs.getDouble(_kNoiseThreshold) != null;

  /// Sets the bar directly (the slider under the live level meter, F13).
  Future<void> setNoiseThreshold(double value) => _prefs.setDouble(
        _kNoiseThreshold,
        value
            .clamp(AppConfig.minNoiseThreshold, AppConfig.maxNoiseThreshold)
            .toDouble(),
      );

  // --- Sound filter (F13) ---

  /// How long a sound must hold above the bar before it alerts.
  Duration get noiseSustain {
    final ms = _prefs.getInt(_kNoiseSustainMs);
    if (ms == null) return AppConfig.defaultNoiseSustain;
    return Duration(
        milliseconds: ms.clamp(0, AppConfig.maxNoiseSustain.inMilliseconds));
  }

  /// Whether steady background sound (breathing, a fan) is filtered out.
  bool get ignoreSteadySound =>
      _prefs.getBool(_kIgnoreSteadySound) ?? AppConfig.defaultIgnoreSteadySound;

  /// How long parents keep hearing the room after it goes quiet (squelch hang).
  Duration get audioHang {
    final ms = _prefs.getInt(_kAudioHangMs);
    if (ms == null) return AppConfig.defaultAudioHang;
    return Duration(
        milliseconds: ms.clamp(0, AppConfig.maxAudioHang.inMilliseconds));
  }

  /// The complete sound filter the camera's noise gate runs with (F13).
  SoundFilter get soundFilter => SoundFilter(
        threshold: noiseThreshold,
        sustain: noiseSustain,
        ignoreSteady: ignoreSteadySound,
        hang: audioHang,
      );

  Future<void> setSoundFilter(SoundFilter filter) async {
    await setNoiseThreshold(filter.threshold);
    await _prefs.setInt(
      _kNoiseSustainMs,
      filter.sustain.inMilliseconds
          .clamp(0, AppConfig.maxNoiseSustain.inMilliseconds),
    );
    await _prefs.setBool(_kIgnoreSteadySound, filter.ignoreSteady);
    await _prefs.setInt(
      _kAudioHangMs,
      filter.hang.inMilliseconds.clamp(0, AppConfig.maxAudioHang.inMilliseconds),
    );
  }

  // --- Audio playback on this device (F13) ---

  /// What this phone does with the camera's audio. Local to the device, so
  /// one parent can filter while the other listens to everything.
  ListenMode get listenMode =>
      ListenMode.parse(_prefs.getString(_kListenMode) ??
          AppConfig.defaultListenMode);

  Future<void> setListenMode(ListenMode mode) =>
      _prefs.setString(_kListenMode, mode.id);

  /// Playback volume for the camera's audio on this phone, 0.0–1.0.
  double get playbackVolume {
    final value = _prefs.getDouble(_kPlaybackVolume);
    if (value == null || !value.isFinite) return 1.0;
    return value.clamp(0.0, 1.0).toDouble();
  }

  Future<void> setPlaybackVolume(double value) =>
      _prefs.setDouble(_kPlaybackVolume, value.clamp(0.0, 1.0).toDouble());

  // --- Camera image controls (F15) ---

  /// Picture gain, -1.0 … 1.0 (0.0 = untouched).
  double get cameraBrightness {
    final value = _prefs.getDouble(_kCameraBrightness);
    if (value == null || !value.isFinite) return 0.0;
    return value.clamp(-1.0, 1.0).toDouble();
  }

  /// Low-light capture profile (F15). The torch is deliberately *not*
  /// persisted — a camera that restarts must never light the room by itself.
  bool get cameraNightMode => _prefs.getBool(_kCameraNightMode) ?? false;

  /// The camera's saved controls, used as the starting point of a session.
  CameraControls get cameraControls => CameraControls(
        brightness: cameraBrightness,
        nightMode: cameraNightMode,
        sound: soundFilter,
      );

  Future<void> setCameraControls(CameraControls controls) async {
    await _prefs.setDouble(
        _kCameraBrightness, controls.brightness.clamp(-1.0, 1.0).toDouble());
    await _prefs.setBool(_kCameraNightMode, controls.nightMode);
    await setSoundFilter(controls.sound);
  }

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

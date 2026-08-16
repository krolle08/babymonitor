/// Camera image + sound-filter controls (F13/F15, docs/PROTOCOL.md §4).
///
/// Pure Dart — the same value object is edited on the camera unit, sent over
/// the `health` data channel by a parent, applied by [CameraSession] and used
/// by both roles to tint the video. No Flutter imports (NTR5).
library;

import 'dart:math' as math;

import '../config/app_config.dart';

double _clampDouble(num value, double min, double max) {
  if (!value.isFinite) return min;
  return value.clamp(min, max).toDouble();
}

/// The bar for what the camera's noise gate ignores (F13).
///
/// Three independent knobs, because "ignore snoring" is three different
/// problems: snoring is *loud but short*, breathing is *quiet but constant*,
/// and a fan is *steady and somewhere in between*.
class SoundFilter {
  const SoundFilter({
    this.threshold = AppConfig.defaultNoiseThreshold,
    this.sustain = AppConfig.defaultNoiseSustain,
    this.ignoreSteady = AppConfig.defaultIgnoreSteadySound,
    this.hang = AppConfig.defaultAudioHang,
  });

  /// Level 0.0–1.0 a sound must reach before it counts at all — the "bar".
  final double threshold;

  /// How long the sound must stay above the bar before it alerts. This is the
  /// snoring/cough/creak filter: a snore is a 1–2 s burst, a baby who needs
  /// you keeps going.
  final Duration sustain;

  /// Ignore sound that only sits just above the room's learned quiet floor
  /// (breathing, a fan, a white-noise machine) — see [NoiseGate].
  final bool ignoreSteady;

  /// How long the parent keeps hearing the room after it falls quiet again.
  /// This is the squelch's hang time: it decides how much of the *tail* of an
  /// event is played, not whether the event counts.
  final Duration hang;

  static const SoundFilter defaults = SoundFilter();

  SoundFilter copyWith({
    double? threshold,
    Duration? sustain,
    bool? ignoreSteady,
    Duration? hang,
  }) =>
      SoundFilter(
        threshold: threshold ?? this.threshold,
        sustain: sustain ?? this.sustain,
        ignoreSteady: ignoreSteady ?? this.ignoreSteady,
        hang: hang ?? this.hang,
      );

  Map<String, dynamic> toJson() => {
        'threshold': threshold,
        'sustainMs': sustain.inMilliseconds,
        'ignoreSteady': ignoreSteady,
        'hangMs': hang.inMilliseconds,
      };

  /// Applies the fields present in [json]; anything missing or malformed keeps
  /// this object's value (forward compatibility, NTR6).
  SoundFilter patch(Map<String, dynamic> json) {
    final threshold = json['threshold'];
    final sustainMs = json['sustainMs'];
    final ignoreSteady = json['ignoreSteady'];
    final hangMs = json['hangMs'];
    return SoundFilter(
      threshold: threshold is num
          ? _clampDouble(threshold, AppConfig.minNoiseThreshold,
              AppConfig.maxNoiseThreshold)
          : this.threshold,
      sustain: sustainMs is num
          ? Duration(
              milliseconds: sustainMs
                  .toInt()
                  .clamp(0, AppConfig.maxNoiseSustain.inMilliseconds))
          : sustain,
      ignoreSteady: ignoreSteady is bool ? ignoreSteady : this.ignoreSteady,
      hang: hangMs is num
          ? Duration(
              milliseconds:
                  hangMs.toInt().clamp(0, AppConfig.maxAudioHang.inMilliseconds))
          : hang,
    );
  }

  static SoundFilter fromJson(Map<String, dynamic> json) =>
      defaults.patch(json);

  @override
  bool operator ==(Object other) =>
      other is SoundFilter &&
      other.threshold == threshold &&
      other.sustain == sustain &&
      other.ignoreSteady == ignoreSteady &&
      other.hang == hang;

  @override
  int get hashCode => Object.hash(threshold, sustain, ignoreSteady, hang);

  @override
  String toString() => 'SoundFilter(threshold: $threshold, '
      'sustain: ${sustain.inMilliseconds}ms, ignoreSteady: $ignoreSteady, '
      'hang: ${hang.inMilliseconds}ms)';
}

/// What a parent device does with the camera's audio (F13).
///
/// The filter decides *what counts*; this decides how much of that reaches
/// the speaker on this particular phone — mum can filter while dad listens
/// to everything.
enum ListenMode {
  /// Play the room only while the camera's gate is open — the default, and
  /// the answer to "don't play snoring at me all night".
  filtered('filtered', 'Filtered'),

  /// Play everything, snoring included (classic monitor behaviour).
  alwaysOn('always', 'Always on'),

  /// Play nothing. Alerts and the picture still work.
  muted('muted', 'Muted');

  const ListenMode(this.id, this.label);

  /// Stable identifier for storage.
  final String id;

  /// Short human label for the UI.
  final String label;

  static ListenMode parse(String? id) => values.firstWhere(
        (mode) => mode.id == id,
        orElse: () => filtered,
      );
}

/// A point on the picture, in normalised frame coordinates (0.0–1.0 from the
/// top-left of the *video frame*, not the widget). Used to tell the camera
/// where to meter its exposure (F15).
class MeteringPoint {
  const MeteringPoint(this.x, this.y);

  final double x;
  final double y;

  static const MeteringPoint centre = MeteringPoint(0.5, 0.5);

  Map<String, dynamic> toJson() => {'x': x, 'y': y};

  /// Parses a point, returning null for anything malformed or out of frame —
  /// `null` on the wire means "back to automatic metering".
  static MeteringPoint? tryFromJson(Object? json) {
    if (json is! Map) return null;
    final x = json['x'];
    final y = json['y'];
    if (x is! num || y is! num || !x.isFinite || !y.isFinite) return null;
    if (x < 0 || x > 1 || y < 0 || y > 1) return null;
    return MeteringPoint(x.toDouble(), y.toDouble());
  }

  @override
  bool operator ==(Object other) =>
      other is MeteringPoint && other.x == x && other.y == y;

  @override
  int get hashCode => Object.hash(x, y);

  @override
  String toString() => 'MeteringPoint(${x.toStringAsFixed(3)}, '
      '${y.toStringAsFixed(3)})';
}

/// A camera the phone offers (F15 camera picker). The infrared route needs the
/// *front* camera on most phones — rear sensors sit behind an IR-cut filter —
/// so which lens is capturing has to be a setting, not an assumption.
class CameraOption {
  const CameraOption({
    required this.deviceId,
    required this.label,
    this.facing = 'unknown',
  });

  final String deviceId;

  /// Platform label, e.g. "Camera 0, Facing back, Orientation 90".
  final String label;

  /// `'front'` | `'back'` | `'unknown'`.
  final String facing;

  /// Short name for a button: "Back camera", "Front camera", or the label.
  String get shortLabel => switch (facing) {
        'front' => 'Front camera',
        'back' => 'Back camera',
        _ => label.isEmpty ? deviceId : label,
      };

  Map<String, dynamic> toJson() =>
      {'deviceId': deviceId, 'label': label, 'facing': facing};

  static CameraOption? tryFromJson(Object? json) {
    if (json is! Map) return null;
    final deviceId = json['deviceId'];
    if (deviceId is! String || deviceId.isEmpty) return null;
    return CameraOption(
      deviceId: deviceId,
      label: json['label'] is String ? json['label'] as String : '',
      facing: json['facing'] is String ? json['facing'] as String : 'unknown',
    );
  }

  /// Derives the facing from a platform label — Android reports
  /// "Camera 0, Facing back, …" and there is no structured field for it.
  static String facingFromLabel(String label) {
    final lower = label.toLowerCase();
    if (lower.contains('front')) return 'front';
    if (lower.contains('back') || lower.contains('rear')) return 'back';
    return 'unknown';
  }

  @override
  bool operator ==(Object other) =>
      other is CameraOption &&
      other.deviceId == deviceId &&
      other.label == label &&
      other.facing == facing;

  @override
  int get hashCode => Object.hash(deviceId, label, facing);
}

/// Everything a parent can change about the camera while watching (F15).
class CameraControls {
  const CameraControls({
    this.brightness = 0.0,
    this.nightMode = false,
    this.light = false,
    this.sound = SoundFilter.defaults,
    this.cameraId,
    this.exposurePoint,
    this.nightFrameRate = AppConfig.nightCaptureFrameRate,
  });

  /// Picture gain applied when rendering, -1.0 (darker) … 1.0 (brighter).
  /// 0.0 leaves the frame untouched. Both units render with the same value so
  /// what the camera operator frames is what the parents see.
  final double brightness;

  /// Low-light capture profile on the camera (longer exposure per frame) plus
  /// a night-friendly render curve.
  final bool nightMode;

  /// The camera phone's torch — the only real light source it has. Off by
  /// default; bright, so it is always an explicit choice.
  final bool light;

  /// Noise-alert filtering (F13), adjustable from either unit.
  final SoundFilter sound;

  /// Which camera is capturing, or null for the default (rear) one.
  final String? cameraId;

  /// Where the camera meters its exposure, or null for automatic. Pointing it
  /// at the crib stops a bright doorway or window from fooling the meter into
  /// underexposing the one thing you want to see.
  final MeteringPoint? exposurePoint;

  /// Capture frame rate used in night mode. Lower = longer exposure per frame
  /// = a brighter picture in a dark room, at the cost of smoothness.
  final int nightFrameRate;

  static const CameraControls defaults = CameraControls();

  /// Nullable fields need an explicit clear — `copyWith(exposurePoint: null)`
  /// cannot be told apart from "leave it alone".
  CameraControls copyWith({
    double? brightness,
    bool? nightMode,
    bool? light,
    SoundFilter? sound,
    String? cameraId,
    MeteringPoint? exposurePoint,
    int? nightFrameRate,
    bool clearCameraId = false,
    bool clearExposurePoint = false,
  }) =>
      CameraControls(
        brightness: brightness ?? this.brightness,
        nightMode: nightMode ?? this.nightMode,
        light: light ?? this.light,
        sound: sound ?? this.sound,
        cameraId: clearCameraId ? null : (cameraId ?? this.cameraId),
        exposurePoint:
            clearExposurePoint ? null : (exposurePoint ?? this.exposurePoint),
        nightFrameRate: nightFrameRate ?? this.nightFrameRate,
      );

  Map<String, dynamic> toJson() => {
        'brightness': brightness,
        'nightMode': nightMode,
        'light': light,
        'sound': sound.toJson(),
        'cameraId': cameraId,
        'exposurePoint': exposurePoint?.toJson(),
        'nightFrameRate': nightFrameRate,
      };

  /// Applies the fields present in [json], keeping everything else.
  ///
  /// For the two nullable fields an explicit `null` **is** a value — it means
  /// "back to automatic" — so presence of the key, not of a value, decides.
  CameraControls patch(Map<String, dynamic> json) {
    final brightness = json['brightness'];
    final nightMode = json['nightMode'];
    final light = json['light'];
    final sound = json['sound'];
    final nightFrameRate = json['nightFrameRate'];
    return CameraControls(
      brightness:
          brightness is num ? _clampDouble(brightness, -1.0, 1.0) : this.brightness,
      nightMode: nightMode is bool ? nightMode : this.nightMode,
      light: light is bool ? light : this.light,
      sound: sound is Map<String, dynamic> ? this.sound.patch(sound) : this.sound,
      cameraId: json.containsKey('cameraId')
          ? (json['cameraId'] is String && (json['cameraId'] as String).isNotEmpty
              ? json['cameraId'] as String
              : null)
          : cameraId,
      exposurePoint: json.containsKey('exposurePoint')
          ? MeteringPoint.tryFromJson(json['exposurePoint'])
          : exposurePoint,
      nightFrameRate: nightFrameRate is num
          ? nightFrameRate.toInt().clamp(
              AppConfig.minNightFrameRate, AppConfig.maxNightFrameRate)
          : this.nightFrameRate,
    );
  }

  static CameraControls fromJson(Map<String, dynamic> json) =>
      defaults.patch(json);

  @override
  bool operator ==(Object other) =>
      other is CameraControls &&
      other.brightness == brightness &&
      other.nightMode == nightMode &&
      other.light == light &&
      other.sound == sound &&
      other.cameraId == cameraId &&
      other.exposurePoint == exposurePoint &&
      other.nightFrameRate == nightFrameRate;

  @override
  int get hashCode => Object.hash(brightness, nightMode, light, sound, cameraId,
      exposurePoint, nightFrameRate);

  @override
  String toString() => 'CameraControls(brightness: $brightness, '
      'nightMode: $nightMode, light: $light, sound: $sound, '
      'cameraId: $cameraId, exposurePoint: $exposurePoint, '
      'nightFrameRate: $nightFrameRate)';
}

/// What the camera hardware can actually do — parents grey out the rest
/// instead of offering a switch that silently does nothing.
class CameraCapabilities {
  const CameraCapabilities({this.torch = false, this.cameras = const []});

  /// The camera phone has a torch this app may switch on.
  final bool torch;

  /// The lenses this phone offers, so a parent can switch to the one that
  /// actually sees the crib (or sees infrared).
  final List<CameraOption> cameras;

  static const CameraCapabilities none = CameraCapabilities();

  Map<String, dynamic> toJson() => {
        'torch': torch,
        'cameras': [for (final camera in cameras) camera.toJson()],
      };

  static CameraCapabilities fromJson(Map<String, dynamic> json) {
    final cameras = json['cameras'];
    return CameraCapabilities(
      torch: json['torch'] is bool ? json['torch'] as bool : false,
      cameras: cameras is List
          ? [
              for (final entry in cameras) ?CameraOption.tryFromJson(entry),
            ]
          : const [],
    );
  }

  @override
  bool operator ==(Object other) =>
      other is CameraCapabilities &&
      other.torch == torch &&
      _sameCameras(other.cameras, cameras);

  static bool _sameCameras(List<CameraOption> a, List<CameraOption> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(torch, Object.hashAll(cameras));
}

/// A `camera-state` broadcast: what the camera is doing + what it can do.
class CameraState {
  const CameraState({
    required this.controls,
    required this.capabilities,
    this.gateOpen = false,
  });

  final CameraControls controls;
  final CameraCapabilities capabilities;

  /// Whether the sound gate is open right now — carried so a parent that has
  /// just connected knows immediately whether to play the room.
  final bool gateOpen;

  Map<String, dynamic> toJson() => {
        'controls': controls.toJson(),
        'caps': capabilities.toJson(),
        'gateOpen': gateOpen,
      };

  static CameraState fromJson(Map<String, dynamic> json) {
    final controls = json['controls'];
    final caps = json['caps'];
    final gateOpen = json['gateOpen'];
    return CameraState(
      controls: controls is Map<String, dynamic>
          ? CameraControls.fromJson(controls)
          : CameraControls.defaults,
      capabilities: caps is Map<String, dynamic>
          ? CameraCapabilities.fromJson(caps)
          : CameraCapabilities.none,
      gateOpen: gateOpen is bool ? gateOpen : false,
    );
  }

  CameraState copyWith({
    CameraControls? controls,
    CameraCapabilities? capabilities,
    bool? gateOpen,
  }) =>
      CameraState(
        controls: controls ?? this.controls,
        capabilities: capabilities ?? this.capabilities,
        gateOpen: gateOpen ?? this.gateOpen,
      );

  @override
  bool operator ==(Object other) =>
      other is CameraState &&
      other.controls == controls &&
      other.capabilities == capabilities &&
      other.gateOpen == gateOpen;

  @override
  int get hashCode => Object.hash(controls, capabilities, gateOpen);
}

/// The 4x5 colour matrix (20 values, row-major, offsets in 0–255) that renders
/// [brightness]/[nightMode] on a video frame — see `AdjustableVideoView`.
///
/// Brightness is a gain (multiply), not just an offset: lifting a dark frame
/// by adding grey washes it out, while gain actually pulls the dim detail up.
/// Night mode adds gain and desaturates, because in low light the colour
/// channels are mostly sensor noise and grey is easier to read at 3 a.m.
List<double> videoColorMatrix({
  required double brightness,
  required bool nightMode,
}) {
  final b = _clampDouble(brightness, -1.0, 1.0);
  final gain = math.max(0.0, 1.0 + b) * (nightMode ? 1.35 : 1.0);
  final offset = b * 24.0 + (nightMode ? 14.0 : 0.0);
  final saturation = nightMode ? 0.35 : 1.0;

  // Rec. 709 luma weights for the desaturation part of the matrix.
  const lr = 0.2126, lg = 0.7152, lb = 0.0722;
  final s = saturation;
  final rr = (lr + s * (1 - lr)) * gain;
  final rg = (lg - s * lg) * gain;
  final rb = (lb - s * lb) * gain;
  final gr = (lr - s * lr) * gain;
  final gg = (lg + s * (1 - lg)) * gain;
  final gb = (lb - s * lb) * gain;
  final br = (lr - s * lr) * gain;
  final bg = (lg - s * lg) * gain;
  final bb = (lb + s * (1 - lb)) * gain;

  return <double>[
    rr, rg, rb, 0.0, offset, //
    gr, gg, gb, 0.0, offset, //
    br, bg, bb, 0.0, offset, //
    0.0, 0.0, 0.0, 1.0, 0.0, //
  ];
}

/// Maps a tap on the rendered video to a point on the actual frame (F15
/// tap-to-meter).
///
/// The widget and the frame rarely have the same shape: `contain` letterboxes
/// (bars the user can tap, which are *not* on the frame) and `cover` crops
/// (frame edges the user cannot reach). Metering the wrong spot is worse than
/// not metering, so this does the arithmetic rather than assuming the widget
/// and the frame line up.
///
/// Returns null when the tap landed on a letterbox bar, or when the frame size
/// is not known yet.
MeteringPoint? mapTapToFrame({
  required double tapX,
  required double tapY,
  required double widgetWidth,
  required double widgetHeight,
  required double videoWidth,
  required double videoHeight,
  required bool cover,
}) {
  if (widgetWidth <= 0 || widgetHeight <= 0) return null;
  if (videoWidth <= 0 || videoHeight <= 0) return null;

  final widgetAspect = widgetWidth / widgetHeight;
  final videoAspect = videoWidth / videoHeight;
  // Scale the frame to the widget the way the renderer does, then work out
  // where the frame's top-left corner ended up.
  final scale = (videoAspect > widgetAspect) == cover
      ? widgetHeight / videoHeight
      : widgetWidth / videoWidth;
  final drawnWidth = videoWidth * scale;
  final drawnHeight = videoHeight * scale;
  final offsetX = (widgetWidth - drawnWidth) / 2;
  final offsetY = (widgetHeight - drawnHeight) / 2;

  final x = (tapX - offsetX) / drawnWidth;
  final y = (tapY - offsetY) / drawnHeight;
  if (x < 0 || x > 1 || y < 0 || y > 1) return null; // letterbox bar
  return MeteringPoint(x, y);
}

/// True when [videoColorMatrix] would be the identity — lets the render path
/// skip the (not free) colour-filter layer entirely.
bool isNeutralVideoAdjustment({
  required double brightness,
  required bool nightMode,
}) =>
    !nightMode && brightness.abs() < 0.001;

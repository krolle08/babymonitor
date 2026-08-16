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

  static const SoundFilter defaults = SoundFilter();

  SoundFilter copyWith({
    double? threshold,
    Duration? sustain,
    bool? ignoreSteady,
  }) =>
      SoundFilter(
        threshold: threshold ?? this.threshold,
        sustain: sustain ?? this.sustain,
        ignoreSteady: ignoreSteady ?? this.ignoreSteady,
      );

  Map<String, dynamic> toJson() => {
        'threshold': threshold,
        'sustainMs': sustain.inMilliseconds,
        'ignoreSteady': ignoreSteady,
      };

  /// Applies the fields present in [json]; anything missing or malformed keeps
  /// this object's value (forward compatibility, NTR6).
  SoundFilter patch(Map<String, dynamic> json) {
    final threshold = json['threshold'];
    final sustainMs = json['sustainMs'];
    final ignoreSteady = json['ignoreSteady'];
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
    );
  }

  static SoundFilter fromJson(Map<String, dynamic> json) =>
      defaults.patch(json);

  @override
  bool operator ==(Object other) =>
      other is SoundFilter &&
      other.threshold == threshold &&
      other.sustain == sustain &&
      other.ignoreSteady == ignoreSteady;

  @override
  int get hashCode => Object.hash(threshold, sustain, ignoreSteady);

  @override
  String toString() => 'SoundFilter(threshold: $threshold, '
      'sustain: ${sustain.inMilliseconds}ms, ignoreSteady: $ignoreSteady)';
}

/// Everything a parent can change about the camera while watching (F15).
class CameraControls {
  const CameraControls({
    this.brightness = 0.0,
    this.nightMode = false,
    this.light = false,
    this.sound = SoundFilter.defaults,
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

  static const CameraControls defaults = CameraControls();

  CameraControls copyWith({
    double? brightness,
    bool? nightMode,
    bool? light,
    SoundFilter? sound,
  }) =>
      CameraControls(
        brightness: brightness ?? this.brightness,
        nightMode: nightMode ?? this.nightMode,
        light: light ?? this.light,
        sound: sound ?? this.sound,
      );

  Map<String, dynamic> toJson() => {
        'brightness': brightness,
        'nightMode': nightMode,
        'light': light,
        'sound': sound.toJson(),
      };

  /// Applies the fields present in [json], keeping everything else.
  CameraControls patch(Map<String, dynamic> json) {
    final brightness = json['brightness'];
    final nightMode = json['nightMode'];
    final light = json['light'];
    final sound = json['sound'];
    return CameraControls(
      brightness:
          brightness is num ? _clampDouble(brightness, -1.0, 1.0) : this.brightness,
      nightMode: nightMode is bool ? nightMode : this.nightMode,
      light: light is bool ? light : this.light,
      sound: sound is Map<String, dynamic> ? this.sound.patch(sound) : this.sound,
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
      other.sound == sound;

  @override
  int get hashCode => Object.hash(brightness, nightMode, light, sound);

  @override
  String toString() => 'CameraControls(brightness: $brightness, '
      'nightMode: $nightMode, light: $light, sound: $sound)';
}

/// What the camera hardware can actually do — parents grey out the rest
/// instead of offering a switch that silently does nothing.
class CameraCapabilities {
  const CameraCapabilities({this.torch = false});

  /// The camera phone has a torch this app may switch on.
  final bool torch;

  static const CameraCapabilities none = CameraCapabilities();

  Map<String, dynamic> toJson() => {'torch': torch};

  static CameraCapabilities fromJson(Map<String, dynamic> json) =>
      CameraCapabilities(torch: json['torch'] is bool ? json['torch'] as bool : false);

  @override
  bool operator ==(Object other) =>
      other is CameraCapabilities && other.torch == torch;

  @override
  int get hashCode => torch.hashCode;
}

/// A `camera-state` broadcast: what the camera is doing + what it can do.
class CameraState {
  const CameraState({required this.controls, required this.capabilities});

  final CameraControls controls;
  final CameraCapabilities capabilities;

  Map<String, dynamic> toJson() => {
        'controls': controls.toJson(),
        'caps': capabilities.toJson(),
      };

  static CameraState fromJson(Map<String, dynamic> json) {
    final controls = json['controls'];
    final caps = json['caps'];
    return CameraState(
      controls: controls is Map<String, dynamic>
          ? CameraControls.fromJson(controls)
          : CameraControls.defaults,
      capabilities: caps is Map<String, dynamic>
          ? CameraCapabilities.fromJson(caps)
          : CameraCapabilities.none,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is CameraState &&
      other.controls == controls &&
      other.capabilities == capabilities;

  @override
  int get hashCode => Object.hash(controls, capabilities);
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

/// True when [videoColorMatrix] would be the identity — lets the render path
/// skip the (not free) colour-filter layer entirely.
bool isNeutralVideoAdjustment({
  required double brightness,
  required bool nightMode,
}) =>
    !nightMode && brightness.abs() < 0.001;

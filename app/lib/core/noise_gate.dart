/// Noise-alert gate with anti-spam cooldown and sound filtering
/// (spec F7/F13, docs/PROTOCOL.md §5.2).
///
/// Pure Dart — the host samples the audio level and supplies the clock, so
/// the cooldown, the sustain window and the learned quiet floor are all
/// testable without real time.
library;

import 'dart:math' as math;

import '../config/app_config.dart';
import 'camera_controls.dart';

/// Fires when a sound clears the bar and *keeps* clearing it, at most once per
/// [cooldown] (F7: 30 s between alerts).
///
/// Three filters, applied in order (F13 — "don't wake me for snoring"):
///
/// 1. **[threshold]** — the bar. Anything quieter never counts.
/// 2. **steady-background rejection** ([ignoreSteady]) — the gate learns the
///    room's quiet floor from every sub-threshold sample (breathing, a fan,
///    a white-noise machine) and additionally requires [steadyMargin] above
///    it, so a floor that creeps up towards the bar does not start alerting.
///    The floor only ever learns from sound *below* the bar, so a long cry can
///    never train the gate into silence (NTR1: no silent failures).
/// 3. **[sustain]** — how long the sound must stay above the bar. This is what
///    separates snoring (1–2 s bursts, and a cough or a creaking floorboard)
///    from a baby who actually needs someone.
class NoiseGate {
  NoiseGate({
    required this.threshold,
    required this.cooldown,
    this.sustain = Duration.zero,
    this.ignoreSteady = false,
    this.steadyMargin = AppConfig.steadySoundMargin,
    this.floorAlpha = AppConfig.quietFloorAlpha,
  });

  /// Builds a gate from a [SoundFilter] (the value object both units edit).
  factory NoiseGate.fromFilter(SoundFilter filter, {required Duration cooldown}) =>
      NoiseGate(
        threshold: filter.threshold,
        cooldown: cooldown,
        sustain: filter.sustain,
        ignoreSteady: filter.ignoreSteady,
      );

  /// Minimum time between fires (F7 AC: no duplicate alerts within 30 s).
  final Duration cooldown;

  /// How fast the quiet floor follows the room (EMA weight per sample).
  final double floorAlpha;

  /// Current trigger level (0.0–1.0). Mutable — settings changes apply live;
  /// the next [feed] uses the new value.
  double threshold;

  /// How long a sound must stay above [threshold] before it fires.
  /// [Duration.zero] restores the plain F7 behaviour (fire on first sample).
  Duration sustain;

  /// Whether the learned quiet floor also gates the alert.
  bool ignoreSteady;

  /// How far above the quiet floor a sound must be when [ignoreSteady] is on.
  double steadyMargin;

  DateTime? _lastFiredAt;
  DateTime? _loudSince;
  double _quietFloor = 0.0;

  /// When the gate last fired, or null if it never has.
  DateTime? get lastFiredAt => _lastFiredAt;

  /// When the current above-the-bar sound started, or null if it is quiet.
  DateTime? get loudSince => _loudSince;

  /// The room's learned quiet level (0.0–1.0) — what the gate treats as
  /// "steady background". Surfaced so the UI can draw it under the meter.
  double get quietFloor => _quietFloor;

  /// The level a sound has to clear right now, including the steady-background
  /// margin. This is the number the level meter draws its bar at.
  double get effectiveThreshold => ignoreSteady
      ? math.max(threshold, _quietFloor + steadyMargin)
      : threshold;

  /// Feed one audio-level sample. Returns true (and starts the cooldown) when
  /// the sample clears [effectiveThreshold], has been clearing it for
  /// [sustain], and the cooldown has elapsed since the last fire.
  bool feed(double level, DateTime now) {
    if (level < threshold) {
      // Quiet: forget the run and let the floor learn this sample. Learning
      // only from sub-threshold sound is deliberate — see the class doc.
      _loudSince = null;
      _quietFloor += floorAlpha * (level - _quietFloor);
      return false;
    }
    if (ignoreSteady && level < _quietFloor + steadyMargin) {
      _loudSince = null; // steady background, not an event
      return false;
    }
    final since = _loudSince ??= now;
    if (now.difference(since) < sustain) return false; // not long enough yet
    final last = _lastFiredAt;
    if (last != null && now.difference(last) < cooldown) return false;
    _lastFiredAt = now;
    return true;
  }

  /// Applies a new filter live (F7 AC: settings changes take effect on the
  /// next sample). The cooldown and the learned floor are kept — the room did
  /// not change, only the bar did.
  void applyFilter(SoundFilter filter) {
    threshold = filter.threshold;
    sustain = filter.sustain;
    ignoreSteady = filter.ignoreSteady;
  }

  /// Clear the cooldown, the sustain run and the learned floor (fresh session).
  void reset() {
    _lastFiredAt = null;
    _loudSince = null;
    _quietFloor = 0.0;
  }
}

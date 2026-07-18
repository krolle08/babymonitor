/// Noise-alert gate with anti-spam cooldown (spec F7, docs/PROTOCOL.md §5.2).
///
/// Pure Dart — the host samples the audio level and supplies the clock, so
/// the cooldown is testable without real time.
library;

/// Fires when the audio level reaches [threshold], at most once per
/// [cooldown] (F7: 30 s between alerts).
class NoiseGate {
  NoiseGate({required this.threshold, required this.cooldown});

  /// Minimum time between fires (F7 AC: no duplicate alerts within 30 s).
  final Duration cooldown;

  /// Current trigger level (0.0–1.0). Mutable — settings changes apply live;
  /// the next [feed] uses the new value.
  double threshold;

  DateTime? _lastFiredAt;

  /// When the gate last fired, or null if it never has.
  DateTime? get lastFiredAt => _lastFiredAt;

  /// Feed one audio-level sample. Returns true (and starts the cooldown)
  /// when `level >= threshold` and the cooldown has elapsed since the last
  /// fire. Sub-threshold samples never affect the cooldown.
  bool feed(double level, DateTime now) {
    if (level < threshold) return false;
    final last = _lastFiredAt;
    if (last != null && now.difference(last) < cooldown) return false;
    _lastFiredAt = now;
    return true;
  }

  /// Clear the cooldown (fresh session).
  void reset() {
    _lastFiredAt = null;
  }
}

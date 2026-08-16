/// Camera-side audio-level monitor (F7/F13, docs/PROTOCOL.md §5.3).
///
/// Thin timer wrapper used by `CameraSession`: it periodically pulls the
/// outbound audio level (supplied by the session from `getStats()`
/// media-source audioLevel, 0.0 fallback) and feeds [NoiseGate] — the single
/// decision point for noise alerts (bar + sustain + steady-background filter
/// + 30 s cooldown). Every sample is also published on [levels] so both units
/// can draw a live meter under the bar (F13: you can *see* what you are
/// filtering out). Sampling failures are swallowed (NTR3: monitoring must
/// never break the stream).
library;

import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint;

import '../config/app_config.dart';
import '../core/camera_controls.dart';
import '../core/noise_gate.dart';

class NoiseMonitor {
  NoiseMonitor({
    required Future<double> Function() sampleLevel,
    required SoundFilter filter,
    this.onNoise,
    this.sampleInterval = const Duration(seconds: 1),
    Duration cooldown = AppConfig.noiseCooldown,
    DateTime Function() now = DateTime.now,
  })  : _sampleLevel = sampleLevel,
        _now = now,
        gate = NoiseGate.fromFilter(filter, cooldown: cooldown);

  /// The single decision point (F7/F13): bar, sustain, steady floor and
  /// cooldown all live here.
  final NoiseGate gate;

  /// Fired with the sampled level whenever the gate fires.
  final void Function(double level)? onNoise;

  final Future<double> Function() _sampleLevel;
  final DateTime Function() _now;
  final Duration sampleInterval;

  final StreamController<double> _levels = StreamController<double>.broadcast();

  Timer? _timer;
  bool _sampling = false;
  double _lastLevel = 0.0;

  /// Every sampled level (0.0–1.0), for the live meter on both units.
  Stream<double> get levels => _levels.stream;

  /// Most recent sampled level (0.0–1.0); also stamped into heartbeats.
  double get lastLevel => _lastLevel;

  /// Current trigger level.
  double get threshold => gate.threshold;

  /// Settings changes apply live — the very next sample uses the new values.
  void applyFilter(SoundFilter filter) => gate.applyFilter(filter);

  /// Starts (or restarts) periodic sampling.
  void start() {
    stop();
    _timer = Timer.periodic(sampleInterval, (_) {
      unawaited(_sample());
    });
  }

  Future<void> _sample() async {
    if (_sampling) return; // never let a slow getStats() pile up
    _sampling = true;
    try {
      final level = await _sampleLevel();
      _lastLevel = level.isFinite ? level.clamp(0.0, 1.0).toDouble() : 0.0;
      if (!_levels.isClosed) _levels.add(_lastLevel);
      if (gate.feed(_lastLevel, _now())) {
        onNoise?.call(_lastLevel);
      }
    } catch (e) {
      debugPrint('NoiseMonitor: sample failed: $e');
    } finally {
      _sampling = false;
    }
  }

  /// Stops sampling (the gate's cooldown state is kept; see [reset]).
  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// Fresh session: clears the cooldown, the learned floor and the last level.
  void reset() {
    gate.reset();
    _lastLevel = 0.0;
  }

  /// [stop] plus stream teardown. The monitor is unusable afterwards.
  Future<void> dispose() async {
    stop();
    await _levels.close();
  }
}

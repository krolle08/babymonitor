/// Camera-side audio-level monitor (F7, docs/PROTOCOL.md §5.3).
///
/// Thin timer wrapper used by `CameraSession`: it periodically pulls the
/// outbound audio level (supplied by the session from `getStats()`
/// media-source audioLevel, 0.0 fallback) and feeds [NoiseGate] — the single
/// decision point for noise alerts (threshold + 30 s cooldown). Sampling
/// failures are swallowed (NTR3: monitoring must never break the stream).
library;

import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint;

import '../config/app_config.dart';
import '../core/noise_gate.dart';

class NoiseMonitor {
  NoiseMonitor({
    required Future<double> Function() sampleLevel,
    required double threshold,
    this.onNoise,
    this.sampleInterval = const Duration(seconds: 1),
    Duration cooldown = AppConfig.noiseCooldown,
    DateTime Function() now = DateTime.now,
  })  : _sampleLevel = sampleLevel,
        _now = now,
        gate = NoiseGate(threshold: threshold, cooldown: cooldown);

  /// The single decision point (F7): threshold + cooldown live here.
  final NoiseGate gate;

  /// Fired with the sampled level whenever the gate fires.
  final void Function(double level)? onNoise;

  final Future<double> Function() _sampleLevel;
  final DateTime Function() _now;
  final Duration sampleInterval;

  Timer? _timer;
  bool _sampling = false;
  double _lastLevel = 0.0;

  /// Most recent sampled level (0.0–1.0); also stamped into heartbeats.
  double get lastLevel => _lastLevel;

  /// Current trigger level.
  double get threshold => gate.threshold;

  /// Settings changes apply live — the very next sample uses the new value.
  set threshold(double value) => gate.threshold = value;

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

  /// Fresh session: clears the cooldown and the last level.
  void reset() {
    gate.reset();
    _lastLevel = 0.0;
  }
}

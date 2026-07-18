/// Freeze detection from decoded-frame-count samples (spec F5,
/// docs/PROTOCOL.md §5.2).
///
/// Deliberate deviation from the spec's "frame hash": the detector is fed the
/// receiver's cumulative `framesDecoded` counter (WebRTC `getStats()`) every
/// `freezeSampleInterval`. A static scene (sleeping baby in a dark room) still
/// produces new decoded frames while the pipeline is alive, so the
/// decoded-frame-count delta cannot false-positive the way frame hashing does
/// (spec F5 open question). Pure Dart, no timers — the host samples.
library;

import '../config/app_config.dart';

/// Edge-triggered freeze detector.
///
/// Call [feed] every `freezeSampleInterval` (5 s) with the current cumulative
/// decoded-frame count. If the value is identical for
/// [identicalSamplesToFreeze] (2) consecutive feeds after the first, the
/// stream is frozen (10 s, F5 AC) and [onFrozen] fires exactly once. Any
/// subsequent change means frames are flowing again: [onRecovered] fires if
/// we were frozen.
class FreezeDetector {
  FreezeDetector({
    this.identicalSamplesToFreeze = AppConfig.freezeIdenticalSamples,
    this.onFrozen,
    this.onRecovered,
  }) : assert(identicalSamplesToFreeze >= 1);

  /// Consecutive identical samples (after the first) that mean frozen (TR4: 2).
  final int identicalSamplesToFreeze;

  /// Fired once on the transition into frozen (edge-triggered).
  final void Function()? onFrozen;

  /// Fired once on the transition out of frozen.
  final void Function()? onRecovered;

  int? _lastSample;
  int _identicalCount = 0;
  bool _frozen = false;

  /// Whether the stream is currently considered frozen.
  bool get frozen => _frozen;

  /// Feed one `framesDecoded` sample. See class docs for semantics. A sample
  /// *lower* than the previous one (stats counter reset after an ICE restart)
  /// also counts as decoding activity, i.e. not frozen.
  void feed(int framesDecoded) {
    final last = _lastSample;
    _lastSample = framesDecoded;

    if (last == null) {
      // First sample: nothing to compare against yet.
      return;
    }

    if (framesDecoded == last) {
      _identicalCount++;
      if (_identicalCount >= identicalSamplesToFreeze && !_frozen) {
        _frozen = true;
        onFrozen?.call();
      }
    } else {
      _identicalCount = 0;
      if (_frozen) {
        _frozen = false;
        onRecovered?.call();
      }
    }
  }

  /// Forget all samples and freeze state (fresh session / new peer
  /// connection). Does not fire callbacks.
  void reset() {
    _lastSample = null;
    _identicalCount = 0;
    _frozen = false;
  }
}

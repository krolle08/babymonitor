/// The F3 health-check finite state machine (docs/PROTOCOL.md §5.2).
///
/// Pure Dart — no Flutter imports, no internal timers (NTR5). The host drives
/// time by calling [tick] every second and supplies the clock via `now`, so
/// every transition is deterministic and mock-clock testable.
library;

import 'dart:async';

import '../config/app_config.dart';
import 'health_state.dart';
import 'heartbeat_tracker.dart';

/// Health FSM over [HealthState] (spec.md F3 table).
///
/// Transition semantics:
/// - initial state is [HealthState.connecting]; the first heartbeat moves it
///   to [HealthState.connected]
/// - [tick] while connected/degraded: `missed >= reconnectingAfterMissed`
///   (3+) → reconnecting; else `missed >= degradedAfterMissed` (1–2) →
///   degraded (only from connected; degraded is silent, spec F3)
/// - a heartbeat while degraded or reconnecting → connected (resumed)
/// - [onFreezeDetected] from connected/degraded → frozen
/// - [onFreezeRecovered] from frozen → connected
/// - while frozen, heartbeats do NOT clear the state (stream alive but
///   picture frozen — F5)
/// - [onReconnectExhausted] from any state → failed (terminal)
/// - failed is only left via [manualReset] → connecting
/// - [onReconnected] from reconnecting → connected
class HealthMonitor {
  HealthMonitor({
    required DateTime Function() now,
    Duration heartbeatInterval = AppConfig.heartbeatInterval,
    this.degradedAfterMissed = AppConfig.degradedAfterMissed,
    this.reconnectingAfterMissed = AppConfig.reconnectingAfterMissed,
  })  : assert(degradedAfterMissed >= 1),
        assert(reconnectingAfterMissed > degradedAfterMissed),
        _now = now,
        _tracker = HeartbeatTracker(interval: heartbeatInterval);

  final DateTime Function() _now;
  final HeartbeatTracker _tracker;

  /// Missed heartbeats at which the state degrades (TR4: 1).
  final int degradedAfterMissed;

  /// Missed heartbeats at which reconnection starts (TR4: 3).
  final int reconnectingAfterMissed;

  final StreamController<HealthState> _controller =
      StreamController<HealthState>.broadcast();

  HealthState _state = HealthState.connecting;

  /// Current state.
  HealthState get state => _state;

  /// Broadcast stream of state changes — emits only when the state actually
  /// changes (F3 AC: exposed as a stream/observable for UI binding).
  Stream<HealthState> get states => _controller.stream;

  /// A heartbeat with sequence [seq] arrived now.
  void onHeartbeat(int seq) {
    _tracker.onHeartbeat(seq, _now());
    switch (_state) {
      case HealthState.connecting:
      case HealthState.degraded:
      case HealthState.reconnecting:
        _setState(HealthState.connected);
      case HealthState.connected:
      case HealthState.frozen: // heartbeats never clear FROZEN (F5)
      case HealthState.failed: // terminal until manualReset
        break;
    }
  }

  /// Host calls this every second; evaluates missed-heartbeat thresholds.
  void tick() {
    if (_state != HealthState.connected && _state != HealthState.degraded) {
      return;
    }
    final missed = _tracker.missedCount(_now());
    if (missed >= reconnectingAfterMissed) {
      _setState(HealthState.reconnecting);
    } else if (missed >= degradedAfterMissed &&
        _state == HealthState.connected) {
      _setState(HealthState.degraded);
    }
  }

  /// FreezeDetector reported a frozen picture (F5).
  void onFreezeDetected() {
    if (_state == HealthState.connected || _state == HealthState.degraded) {
      _setState(HealthState.frozen);
    }
  }

  /// FreezeDetector reported frames flowing again.
  void onFreezeRecovered() {
    if (_state == HealthState.frozen) {
      _setState(HealthState.connected);
    }
  }

  /// Reconnect attempts exhausted (F4) — terminal failure from any state.
  void onReconnectExhausted() {
    _setState(HealthState.failed);
  }

  /// A reconnect succeeded while we were reconnecting.
  void onReconnected() {
    if (_state == HealthState.reconnecting) {
      // The reconnect itself proves liveness; refresh the tracker so the next
      // tick doesn't instantly bounce back to reconnecting before the first
      // post-reconnect heartbeat lands.
      _tracker.touch(_now());
      _setState(HealthState.connected);
    }
  }

  /// User-initiated reset (only exit from [HealthState.failed]) — back to a
  /// fresh [HealthState.connecting] with no heartbeat history.
  void manualReset() {
    _tracker.reset();
    _setState(HealthState.connecting);
  }

  /// Release the stream controller.
  void dispose() {
    _controller.close();
  }

  void _setState(HealthState next) {
    if (next == _state) return;
    _state = next;
    if (!_controller.isClosed) _controller.add(next);
  }
}

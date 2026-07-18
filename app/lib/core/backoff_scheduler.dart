/// Exponential backoff schedule for auto-reconnect (spec F4, TR4).
///
/// Pure Dart, no timers — the host asks for the next delay and schedules it
/// itself, so the schedule is testable with a mock clock (F4 AC).
library;

import '../config/app_config.dart';

/// Yields 3 s → 6 s → 12 s → 30 s → 30 s… (last entry repeats) and tracks how
/// many attempts have been handed out.
class BackoffScheduler {
  BackoffScheduler({
    List<int> scheduleSeconds = AppConfig.backoffScheduleSeconds,
    this.maxRetries = AppConfig.maxReconnectRetries,
  })  : assert(scheduleSeconds.isNotEmpty, 'schedule must not be empty'),
        assert(maxRetries > 0),
        _scheduleSeconds = List.unmodifiable(scheduleSeconds);

  final List<int> _scheduleSeconds;

  /// Attempts after which [exhausted] becomes true (TR4: 5).
  final int maxRetries;

  int _attempts = 0;

  /// Number of delays handed out since construction or the last [reset].
  int get attempts => _attempts;

  /// True once [maxRetries] delays have been handed out — the caller should
  /// transition the FSM to FAILED (F4).
  bool get exhausted => _attempts >= maxRetries;

  /// Returns the delay to wait before the next reconnect attempt and advances
  /// the schedule. Beyond the end of the schedule the last entry repeats.
  Duration nextDelay() {
    final index = _attempts < _scheduleSeconds.length
        ? _attempts
        : _scheduleSeconds.length - 1;
    _attempts++;
    return Duration(seconds: _scheduleSeconds[index]);
  }

  /// A successful reconnect resets the retry counter and backoff (F4 AC).
  void reset() {
    _attempts = 0;
  }
}

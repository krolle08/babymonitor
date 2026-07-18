/// Heartbeat bookkeeping for the health FSM (docs/PROTOCOL.md §5.2, spec F3).
///
/// Pure Dart — no Flutter imports (NTR5). The host feeds it heartbeats and a
/// clock value; it never reads the wall clock itself.
library;

import '../config/app_config.dart';

/// Tracks the last-seen heartbeat (seq + arrival time) and derives how many
/// full heartbeat intervals have elapsed without one.
class HeartbeatTracker {
  HeartbeatTracker({this.interval = AppConfig.heartbeatInterval})
      : assert(interval > Duration.zero, 'interval must be positive');

  /// Expected spacing between heartbeats (TR4: 3 s).
  final Duration interval;

  int? _lastSeq;
  DateTime? _lastAt;

  /// Sequence number of the most recent heartbeat, or null if none received.
  int? get lastSeq => _lastSeq;

  /// Arrival time of the most recent heartbeat, or null if none received.
  DateTime? get lastHeartbeatAt => _lastAt;

  /// Whether at least one heartbeat has ever been recorded.
  bool get hasReceived => _lastAt != null;

  /// Record a heartbeat with sequence [seq] arriving at [at].
  void onHeartbeat(int seq, DateTime at) {
    _lastSeq = seq;
    _lastAt = at;
  }

  /// Refresh liveness without a new sequence number (e.g. a successful
  /// reconnect proves the link is alive before the next heartbeat lands).
  /// No-op if no heartbeat was ever received.
  void touch(DateTime at) {
    if (_lastAt != null) _lastAt = at;
  }

  /// Number of *full* heartbeat intervals elapsed since the last heartbeat:
  /// `floor(gap / interval)`.
  ///
  /// Returns 0 when no heartbeat has ever been received (the FSM is still in
  /// `connecting` then, and missed-count rules do not apply), and 0 for a
  /// negative gap (clock skew).
  int missedCount(DateTime now) {
    final last = _lastAt;
    if (last == null) return 0;
    final gap = now.difference(last);
    if (gap.isNegative) return 0;
    return gap.inMicroseconds ~/ interval.inMicroseconds;
  }

  /// Forget everything (fresh session).
  void reset() {
    _lastSeq = null;
    _lastAt = null;
  }
}

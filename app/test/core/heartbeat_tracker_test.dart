import 'package:babymonitor/core/heartbeat_tracker.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final t0 = DateTime.utc(2026, 1, 1, 12, 0, 0);

  group('HeartbeatTracker', () {
    test('never-received case: missedCount is 0 and nothing recorded', () {
      final tracker = HeartbeatTracker();
      expect(tracker.hasReceived, isFalse);
      expect(tracker.lastSeq, isNull);
      expect(tracker.lastHeartbeatAt, isNull);
      expect(tracker.missedCount(t0), 0);
      expect(tracker.missedCount(t0.add(const Duration(hours: 1))), 0);
    });

    test('records seq and arrival time', () {
      final tracker = HeartbeatTracker();
      tracker.onHeartbeat(7, t0);
      expect(tracker.hasReceived, isTrue);
      expect(tracker.lastSeq, 7);
      expect(tracker.lastHeartbeatAt, t0);
    });

    test('missedCount is floor(gap / interval) with the 3s default', () {
      final tracker = HeartbeatTracker();
      tracker.onHeartbeat(1, t0);
      expect(tracker.missedCount(t0), 0);
      expect(tracker.missedCount(t0.add(const Duration(seconds: 2))), 0);
      expect(
        tracker.missedCount(t0.add(const Duration(milliseconds: 2999))),
        0,
      );
      expect(tracker.missedCount(t0.add(const Duration(seconds: 3))), 1);
      expect(
        tracker.missedCount(t0.add(const Duration(milliseconds: 5999))),
        1,
      );
      expect(tracker.missedCount(t0.add(const Duration(seconds: 6))), 2);
      expect(
        tracker.missedCount(t0.add(const Duration(milliseconds: 8999))),
        2,
      );
      expect(tracker.missedCount(t0.add(const Duration(seconds: 9))), 3);
      expect(tracker.missedCount(t0.add(const Duration(seconds: 30))), 10);
    });

    test('a new heartbeat resets the gap', () {
      final tracker = HeartbeatTracker();
      tracker.onHeartbeat(1, t0);
      final t1 = t0.add(const Duration(seconds: 10));
      expect(tracker.missedCount(t1), 3);
      tracker.onHeartbeat(2, t1);
      expect(tracker.lastSeq, 2);
      expect(tracker.missedCount(t1), 0);
      expect(tracker.missedCount(t1.add(const Duration(seconds: 3))), 1);
    });

    test('honours a custom interval', () {
      final tracker = HeartbeatTracker(interval: const Duration(seconds: 5));
      tracker.onHeartbeat(1, t0);
      expect(tracker.missedCount(t0.add(const Duration(seconds: 4))), 0);
      expect(tracker.missedCount(t0.add(const Duration(seconds: 5))), 1);
      expect(tracker.missedCount(t0.add(const Duration(seconds: 14))), 2);
    });

    test('negative gap (clock skew) clamps to 0', () {
      final tracker = HeartbeatTracker();
      tracker.onHeartbeat(1, t0);
      expect(
        tracker.missedCount(t0.subtract(const Duration(seconds: 10))),
        0,
      );
    });

    test('touch refreshes liveness without changing seq', () {
      final tracker = HeartbeatTracker();
      tracker.onHeartbeat(5, t0);
      final t1 = t0.add(const Duration(seconds: 12));
      expect(tracker.missedCount(t1), 4);
      tracker.touch(t1);
      expect(tracker.lastSeq, 5);
      expect(tracker.missedCount(t1), 0);
    });

    test('touch before any heartbeat is a no-op', () {
      final tracker = HeartbeatTracker();
      tracker.touch(t0);
      expect(tracker.hasReceived, isFalse);
      expect(tracker.lastHeartbeatAt, isNull);
    });

    test('reset forgets everything', () {
      final tracker = HeartbeatTracker();
      tracker.onHeartbeat(3, t0);
      tracker.reset();
      expect(tracker.hasReceived, isFalse);
      expect(tracker.lastSeq, isNull);
      expect(tracker.missedCount(t0.add(const Duration(minutes: 5))), 0);
    });
  });
}

import 'package:babymonitor/core/backoff_scheduler.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('BackoffScheduler', () {
    test('default schedule yields 3, 6, 12, 30, 30 seconds (F4/TR4)', () {
      final scheduler = BackoffScheduler();
      final delays = [for (var i = 0; i < 5; i++) scheduler.nextDelay()];
      expect(delays, const [
        Duration(seconds: 3),
        Duration(seconds: 6),
        Duration(seconds: 12),
        Duration(seconds: 30),
        Duration(seconds: 30),
      ]);
    });

    test('last interval keeps repeating beyond the schedule', () {
      final scheduler = BackoffScheduler(maxRetries: 100);
      for (var i = 0; i < 4; i++) {
        scheduler.nextDelay();
      }
      for (var i = 0; i < 10; i++) {
        expect(scheduler.nextDelay(), const Duration(seconds: 30));
      }
    });

    test('attempts counts handed-out delays', () {
      final scheduler = BackoffScheduler();
      expect(scheduler.attempts, 0);
      scheduler.nextDelay();
      expect(scheduler.attempts, 1);
      scheduler.nextDelay();
      scheduler.nextDelay();
      expect(scheduler.attempts, 3);
    });

    test('exhausted after 5 attempts (default maxRetries), not before', () {
      final scheduler = BackoffScheduler();
      for (var i = 0; i < 4; i++) {
        scheduler.nextDelay();
        expect(scheduler.exhausted, isFalse,
            reason: 'not exhausted after ${i + 1} attempts');
      }
      scheduler.nextDelay(); // 5th
      expect(scheduler.exhausted, isTrue);
    });

    test('reset restores the schedule and clears exhaustion (F4 AC)', () {
      final scheduler = BackoffScheduler();
      for (var i = 0; i < 5; i++) {
        scheduler.nextDelay();
      }
      expect(scheduler.exhausted, isTrue);
      scheduler.reset();
      expect(scheduler.attempts, 0);
      expect(scheduler.exhausted, isFalse);
      expect(scheduler.nextDelay(), const Duration(seconds: 3));
      expect(scheduler.nextDelay(), const Duration(seconds: 6));
    });

    test('custom schedule and maxRetries are honoured', () {
      final scheduler =
          BackoffScheduler(scheduleSeconds: const [1, 2], maxRetries: 3);
      expect(scheduler.nextDelay(), const Duration(seconds: 1));
      expect(scheduler.nextDelay(), const Duration(seconds: 2));
      expect(scheduler.exhausted, isFalse);
      expect(scheduler.nextDelay(), const Duration(seconds: 2));
      expect(scheduler.exhausted, isTrue);
    });
  });
}

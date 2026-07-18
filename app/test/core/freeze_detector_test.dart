import 'package:babymonitor/core/freeze_detector.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('FreezeDetector', () {
    late int frozenCalls;
    late int recoveredCalls;
    late FreezeDetector detector;

    setUp(() {
      frozenCalls = 0;
      recoveredCalls = 0;
      detector = FreezeDetector(
        onFrozen: () => frozenCalls++,
        onRecovered: () => recoveredCalls++,
      );
    });

    test('frozen after 2 identical samples following the first (10s, F5)',
        () {
      detector.feed(100); // first sample — baseline
      expect(detector.frozen, isFalse);
      detector.feed(100); // identical #1 (5s)
      expect(detector.frozen, isFalse);
      expect(frozenCalls, 0);
      detector.feed(100); // identical #2 (10s) -> frozen
      expect(detector.frozen, isTrue);
      expect(frozenCalls, 1);
    });

    test('not frozen while the counter increases (static scene stays healthy)',
        () {
      // A sleeping baby still produces decoded frames — counter keeps rising.
      for (final sample in [100, 250, 400, 550, 700, 850]) {
        detector.feed(sample);
        expect(detector.frozen, isFalse);
      }
      expect(frozenCalls, 0);
      expect(recoveredCalls, 0);
    });

    test('an increase between identical samples resets the freeze count', () {
      detector.feed(100);
      detector.feed(100); // identical #1
      detector.feed(150); // activity — count resets
      detector.feed(150); // identical #1 again
      expect(detector.frozen, isFalse);
      detector.feed(150); // identical #2 -> frozen
      expect(detector.frozen, isTrue);
      expect(frozenCalls, 1);
    });

    test('recovery event fired when frames flow again', () {
      detector.feed(100);
      detector.feed(100);
      detector.feed(100); // frozen
      expect(detector.frozen, isTrue);
      detector.feed(130); // frames again -> recovered
      expect(detector.frozen, isFalse);
      expect(recoveredCalls, 1);
    });

    test('edge-triggered: onFrozen fires exactly once per freeze episode', () {
      detector.feed(100);
      for (var i = 0; i < 10; i++) {
        detector.feed(100); // long freeze — many identical samples
      }
      expect(frozenCalls, 1);
      detector.feed(200); // recover
      expect(recoveredCalls, 1);
      detector.feed(200);
      detector.feed(200); // second freeze episode
      expect(frozenCalls, 2);
      expect(recoveredCalls, 1);
    });

    test('onRecovered never fires if it was never frozen', () {
      detector.feed(100);
      detector.feed(100); // only 1 identical sample
      detector.feed(200);
      expect(recoveredCalls, 0);
    });

    test('counter reset (lower sample after ICE restart) counts as activity',
        () {
      detector.feed(500);
      detector.feed(500);
      detector.feed(500); // frozen
      expect(detector.frozen, isTrue);
      detector.feed(10); // stats counter restarted — frames decoding again
      expect(detector.frozen, isFalse);
      expect(recoveredCalls, 1);
    });

    test('reset clears state without firing callbacks', () {
      detector.feed(100);
      detector.feed(100);
      detector.feed(100); // frozen
      detector.reset();
      expect(detector.frozen, isFalse);
      expect(recoveredCalls, 0);
      // After reset the next sample is a fresh baseline.
      detector.feed(100);
      detector.feed(100);
      expect(detector.frozen, isFalse);
      detector.feed(100);
      expect(detector.frozen, isTrue);
      expect(frozenCalls, 2);
    });

    test('custom identicalSamplesToFreeze threshold', () {
      final d = FreezeDetector(identicalSamplesToFreeze: 3);
      d.feed(1);
      d.feed(1);
      d.feed(1);
      expect(d.frozen, isFalse);
      d.feed(1);
      expect(d.frozen, isTrue);
    });
  });
}

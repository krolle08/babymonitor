import 'package:babymonitor/core/noise_gate.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final t0 = DateTime.utc(2026, 1, 1, 22, 0, 0);
  const cooldown = Duration(seconds: 30);

  group('NoiseGate', () {
    test('fires when level meets or exceeds the threshold', () {
      final gate = NoiseGate(threshold: 0.30, cooldown: cooldown);
      expect(gate.feed(0.30, t0), isTrue); // exactly at threshold fires
    });

    test('does not fire below the threshold', () {
      final gate = NoiseGate(threshold: 0.30, cooldown: cooldown);
      expect(gate.feed(0.29, t0), isFalse);
      expect(gate.feed(0.0, t0), isFalse);
      expect(gate.lastFiredAt, isNull);
    });

    test('respects the 30s cooldown (F7: no duplicate alerts)', () {
      final gate = NoiseGate(threshold: 0.30, cooldown: cooldown);
      expect(gate.feed(0.9, t0), isTrue);
      expect(gate.feed(0.9, t0.add(const Duration(seconds: 1))), isFalse);
      expect(gate.feed(0.9, t0.add(const Duration(seconds: 29))), isFalse);
      expect(
        gate.feed(0.9, t0.add(const Duration(milliseconds: 29999))),
        isFalse,
      );
      // Cooldown elapsed exactly — fires again.
      expect(gate.feed(0.9, t0.add(const Duration(seconds: 30))), isTrue);
      // And the cooldown window restarts from the second fire.
      expect(gate.feed(0.9, t0.add(const Duration(seconds: 45))), isFalse);
      expect(gate.feed(0.9, t0.add(const Duration(seconds: 60))), isTrue);
    });

    test('sub-threshold samples during cooldown do not extend it', () {
      final gate = NoiseGate(threshold: 0.30, cooldown: cooldown);
      expect(gate.feed(0.9, t0), isTrue);
      expect(gate.feed(0.1, t0.add(const Duration(seconds: 29))), isFalse);
      expect(gate.feed(0.9, t0.add(const Duration(seconds: 30))), isTrue);
    });

    test('threshold change applies live (settings change, F7 AC)', () {
      final gate = NoiseGate(threshold: 0.50, cooldown: cooldown);
      expect(gate.feed(0.30, t0), isFalse); // below 'low' sensitivity
      gate.threshold = 0.15; // user switches to high sensitivity
      expect(gate.threshold, 0.15);
      expect(gate.feed(0.30, t0), isTrue); // same level now fires
      // Raising the threshold suppresses again (after cooldown to isolate).
      gate.threshold = 0.95;
      expect(gate.feed(0.90, t0.add(const Duration(minutes: 5))), isFalse);
    });

    test('reset clears the cooldown', () {
      final gate = NoiseGate(threshold: 0.30, cooldown: cooldown);
      expect(gate.feed(0.9, t0), isTrue);
      gate.reset();
      expect(gate.lastFiredAt, isNull);
      expect(gate.feed(0.9, t0.add(const Duration(seconds: 1))), isTrue);
    });
  });
}

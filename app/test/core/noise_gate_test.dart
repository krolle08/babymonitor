import 'package:babymonitor/core/camera_controls.dart';
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

  // F13 — the sound filter: snoring must not wake anybody.
  group('NoiseGate sustain', () {
    NoiseGate build() => NoiseGate(
          threshold: 0.30,
          cooldown: cooldown,
          sustain: const Duration(seconds: 2),
        );

    test('a short burst (a snore) never fires', () {
      final gate = build();
      // Two 1 s snores with a quiet second between them: each run restarts.
      expect(gate.feed(0.80, t0), isFalse);
      expect(gate.feed(0.05, t0.add(const Duration(seconds: 1))), isFalse);
      expect(gate.feed(0.80, t0.add(const Duration(seconds: 2))), isFalse);
      expect(gate.feed(0.05, t0.add(const Duration(seconds: 3))), isFalse);
      expect(gate.lastFiredAt, isNull);
    });

    test('sustained crying fires once the window has passed', () {
      final gate = build();
      expect(gate.feed(0.80, t0), isFalse); // 0 s of sustain so far
      expect(gate.feed(0.80, t0.add(const Duration(seconds: 1))), isFalse);
      expect(gate.feed(0.80, t0.add(const Duration(seconds: 2))), isTrue);
    });

    test('still crying re-alerts as soon as the cooldown expires', () {
      final gate = build();
      gate.feed(0.80, t0);
      gate.feed(0.80, t0.add(const Duration(seconds: 1)));
      expect(gate.feed(0.80, t0.add(const Duration(seconds: 2))), isTrue);
      expect(gate.feed(0.80, t0.add(const Duration(seconds: 20))), isFalse);
      // 30 s after the fire, and the run never broke — alert again.
      expect(gate.feed(0.80, t0.add(const Duration(seconds: 32))), isTrue);
    });

    test('a dip below the bar restarts the sustain window', () {
      final gate = build();
      gate.feed(0.80, t0);
      expect(gate.feed(0.10, t0.add(const Duration(seconds: 1))), isFalse);
      expect(gate.feed(0.80, t0.add(const Duration(seconds: 2))), isFalse);
      expect(gate.feed(0.80, t0.add(const Duration(seconds: 3))), isFalse);
      expect(gate.feed(0.80, t0.add(const Duration(seconds: 4))), isTrue);
    });

    test('zero sustain keeps the original F7 behaviour', () {
      final gate = NoiseGate(threshold: 0.30, cooldown: cooldown);
      expect(gate.feed(0.31, t0), isTrue);
    });
  });

  group('NoiseGate steady background', () {
    test('a floor that creeps up to the bar pushes the bar up with it', () {
      final gate = NoiseGate(
        threshold: 0.45,
        cooldown: cooldown,
        ignoreSteady: true,
        steadyMargin: 0.08,
        floorAlpha: 0.5, // converge fast so the test stays readable
      );
      var now = t0;
      for (var i = 0; i < 10; i++) {
        gate.feed(0.44, now); // a fan humming just under the bar
        now = now.add(const Duration(seconds: 1));
      }
      expect(gate.quietFloor, closeTo(0.44, 0.01));
      // The setting did not move; the bar in force did.
      expect(gate.threshold, 0.45);
      expect(gate.effectiveThreshold, closeTo(0.52, 0.01));
    });

    test('a floor well below the bar leaves the bar alone', () {
      final gate = NoiseGate(
        threshold: 0.50,
        cooldown: cooldown,
        ignoreSteady: true,
        floorAlpha: 0.5,
      );
      var now = t0;
      for (var i = 0; i < 10; i++) {
        gate.feed(0.10, now);
        now = now.add(const Duration(seconds: 1));
      }
      expect(gate.quietFloor, closeTo(0.10, 0.01));
      expect(gate.effectiveThreshold, 0.50);
    });

    test('rejects sound that only just clears the learned floor', () {
      final gate = NoiseGate(
        threshold: 0.30,
        cooldown: cooldown,
        ignoreSteady: true,
        steadyMargin: 0.08,
        floorAlpha: 0.5,
      );
      var now = t0;
      for (var i = 0; i < 10; i++) {
        gate.feed(0.28, now); // breathing, just under the bar
        now = now.add(const Duration(seconds: 1));
      }
      // 0.31 clears the bar but not floor (0.28) + margin (0.08).
      expect(gate.feed(0.31, now), isFalse);
      // A real cry clears both.
      expect(gate.feed(0.70, now.add(const Duration(seconds: 1))), isTrue);
    });

    test('a long cry can never train the gate into silence (NTR1)', () {
      final gate = NoiseGate(
        threshold: 0.30,
        cooldown: cooldown,
        ignoreSteady: true,
        floorAlpha: 0.5,
      );
      var now = t0;
      var fires = 0;
      for (var i = 0; i < 300; i++) {
        if (gate.feed(0.90, now)) fires++;
        now = now.add(const Duration(seconds: 1));
      }
      // 5 minutes of crying, one alert per 30 s cooldown — the floor never
      // learns from above-the-bar sound, so alerts keep coming.
      expect(fires, 10);
      expect(gate.quietFloor, 0.0);
    });

    test('off by default — the floor is learned but not applied', () {
      final gate = NoiseGate(threshold: 0.30, cooldown: cooldown);
      var now = t0;
      for (var i = 0; i < 10; i++) {
        gate.feed(0.29, now);
        now = now.add(const Duration(seconds: 1));
      }
      expect(gate.effectiveThreshold, 0.30);
      expect(gate.feed(0.30, now), isTrue);
    });
  });

  group('NoiseGate.fromFilter', () {
    test('takes every knob from the filter', () {
      final gate = NoiseGate.fromFilter(
        const SoundFilter(
          threshold: 0.42,
          sustain: Duration(seconds: 5),
          ignoreSteady: false,
        ),
        cooldown: cooldown,
      );
      expect(gate.threshold, 0.42);
      expect(gate.sustain, const Duration(seconds: 5));
      expect(gate.ignoreSteady, isFalse);
    });

    test('applyFilter changes the bar live, keeping the cooldown', () {
      final gate = NoiseGate(threshold: 0.30, cooldown: cooldown);
      expect(gate.feed(0.90, t0), isTrue);
      gate.applyFilter(const SoundFilter(
        threshold: 0.95,
        sustain: Duration(seconds: 4),
        ignoreSteady: true,
      ));
      expect(gate.threshold, 0.95);
      expect(gate.sustain, const Duration(seconds: 4));
      expect(gate.ignoreSteady, isTrue);
      // The cooldown from the earlier fire is still running.
      expect(gate.lastFiredAt, t0);
    });
  });
}

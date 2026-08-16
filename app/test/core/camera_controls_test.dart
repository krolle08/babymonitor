// Camera image + sound-filter value objects (F13/F15, PROTOCOL §4): JSON
// round-trips, partial patches from the wire, and the render matrix.

import 'package:babymonitor/config/app_config.dart';
import 'package:babymonitor/core/camera_controls.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SoundFilter', () {
    test('round-trips through JSON', () {
      const filter = SoundFilter(
        threshold: 0.42,
        sustain: Duration(seconds: 6),
        ignoreSteady: false,
        hang: Duration(seconds: 30),
      );
      expect(SoundFilter.fromJson(filter.toJson()), filter);
    });

    test('a patch only touches the fields it carries', () {
      const filter = SoundFilter(
        threshold: 0.42,
        sustain: Duration(seconds: 6),
        ignoreSteady: false,
        hang: Duration(seconds: 30),
      );
      final patched = filter.patch({'threshold': 0.60});
      expect(patched.threshold, 0.60);
      expect(patched.sustain, const Duration(seconds: 6));
      expect(patched.ignoreSteady, isFalse);
      expect(patched.hang, const Duration(seconds: 30));
    });

    test('malformed and out-of-range values are ignored or clamped', () {
      const filter = SoundFilter(threshold: 0.42);
      expect(filter.patch({'threshold': 'loud'}).threshold, 0.42);
      expect(filter.patch({'ignoreSteady': 'yes'}).ignoreSteady,
          filter.ignoreSteady);
      expect(filter.patch({'threshold': 9.0}).threshold,
          AppConfig.maxNoiseThreshold);
      expect(filter.patch({'threshold': -3.0}).threshold,
          AppConfig.minNoiseThreshold);
      expect(filter.patch({'sustainMs': 999999}).sustain,
          AppConfig.maxNoiseSustain);
      expect(filter.patch({'sustainMs': -5}).sustain, Duration.zero);
      expect(filter.patch({'hangMs': 999999}).hang, AppConfig.maxAudioHang);
      expect(filter.patch({'hangMs': -1}).hang, Duration.zero);
    });
  });

  group('ListenMode', () {
    test('round-trips through its stored id', () {
      for (final mode in ListenMode.values) {
        expect(ListenMode.parse(mode.id), mode);
      }
    });

    test('an unknown or missing id falls back to filtered', () {
      expect(ListenMode.parse(null), ListenMode.filtered);
      expect(ListenMode.parse('whisper'), ListenMode.filtered);
    });
  });

  group('CameraState gate', () {
    test('carries the squelch state so a new parent knows at once', () {
      const state = CameraState(
        controls: CameraControls.defaults,
        capabilities: CameraCapabilities.none,
        gateOpen: true,
      );
      expect(CameraState.fromJson(state.toJson()).gateOpen, isTrue);
    });

    test('defaults to closed when the field is absent', () {
      expect(CameraState.fromJson(const {}).gateOpen, isFalse);
    });
  });

  group('CameraControls', () {
    const controls = CameraControls(
      brightness: 0.4,
      nightMode: true,
      light: true,
      sound: SoundFilter(threshold: 0.55),
    );

    test('round-trips through JSON', () {
      expect(CameraControls.fromJson(controls.toJson()), controls);
    });

    test('a nested sound patch keeps the picture settings', () {
      final patched = controls.patch({
        'sound': {'sustainMs': 4000},
      });
      expect(patched.brightness, 0.4);
      expect(patched.nightMode, isTrue);
      expect(patched.light, isTrue);
      expect(patched.sound.threshold, 0.55);
      expect(patched.sound.sustain, const Duration(seconds: 4));
    });

    test('brightness is clamped to the renderable range', () {
      expect(controls.patch({'brightness': 5.0}).brightness, 1.0);
      expect(controls.patch({'brightness': -5.0}).brightness, -1.0);
      expect(controls.patch({'brightness': double.nan}).brightness, -1.0);
    });

    test('unknown keys are ignored (forward compatibility, NTR6)', () {
      expect(controls.patch({'zoom': 2.0, 'irLed': true}), controls);
    });
  });

  group('CameraState', () {
    test('round-trips controls + capabilities', () {
      const state = CameraState(
        controls: CameraControls(brightness: -0.2),
        capabilities: CameraCapabilities(torch: true),
      );
      expect(CameraState.fromJson(state.toJson()), state);
    });

    test('a state message with nothing in it falls back to defaults', () {
      final state = CameraState.fromJson(const {});
      expect(state.controls, CameraControls.defaults);
      expect(state.capabilities.torch, isFalse);
    });
  });

  group('videoColorMatrix', () {
    test('neutral settings are the identity matrix', () {
      expect(
        isNeutralVideoAdjustment(brightness: 0.0, nightMode: false),
        isTrue,
      );
      final matrix = videoColorMatrix(brightness: 0.0, nightMode: false);
      const identity = <double>[
        1, 0, 0, 0, 0, //
        0, 1, 0, 0, 0, //
        0, 0, 1, 0, 0, //
        0, 0, 0, 1, 0, //
      ];
      expect(matrix.length, 20);
      for (var i = 0; i < matrix.length; i++) {
        expect(matrix[i], closeTo(identity[i], 0.0001), reason: 'cell $i');
      }
    });

    test('positive brightness gains and lifts, negative darkens', () {
      final up = videoColorMatrix(brightness: 0.5, nightMode: false);
      expect(up[0], greaterThan(1.0)); // red gain
      expect(up[4], greaterThan(0.0)); // red offset
      final down = videoColorMatrix(brightness: -0.5, nightMode: false);
      expect(down[0], lessThan(1.0));
      expect(down[4], lessThan(0.0));
    });

    test('night mode adds gain and desaturates', () {
      final day = videoColorMatrix(brightness: 0.0, nightMode: false);
      final night = videoColorMatrix(brightness: 0.0, nightMode: true);
      // Each colour row sums to the overall gain: a grey pixel gets brighter.
      double rowSum(List<double> m) => m[0] + m[1] + m[2];
      expect(rowSum(night), greaterThan(rowSum(day)));
      expect(night[1], greaterThan(0.0)); // red row now mixes in green
      expect(night[4], greaterThan(day[4])); // blacks lifted
      expect(isNeutralVideoAdjustment(brightness: 0.0, nightMode: true),
          isFalse);
    });

    test('a neutral row keeps alpha untouched', () {
      final matrix = videoColorMatrix(brightness: 0.8, nightMode: true);
      expect(matrix[15], 0.0);
      expect(matrix[16], 0.0);
      expect(matrix[17], 0.0);
      expect(matrix[18], 1.0);
      expect(matrix[19], 0.0);
    });
  });
}

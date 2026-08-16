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

  group('CameraControls lens, metering and night frame rate', () {
    test('an explicit null clears the lens and the metering point', () {
      const controls = CameraControls(
        cameraId: '1',
        exposurePoint: MeteringPoint(0.3, 0.7),
      );
      final cleared = controls.patch({'cameraId': null, 'exposurePoint': null});
      expect(cleared.cameraId, isNull);
      expect(cleared.exposurePoint, isNull);
    });

    test('an absent key keeps the current value', () {
      const controls = CameraControls(
        cameraId: '1',
        exposurePoint: MeteringPoint(0.3, 0.7),
      );
      final patched = controls.patch({'brightness': 0.5});
      expect(patched.cameraId, '1');
      expect(patched.exposurePoint, const MeteringPoint(0.3, 0.7));
    });

    test('copyWith needs an explicit clear for the nullable fields', () {
      const controls = CameraControls(
        cameraId: '1',
        exposurePoint: MeteringPoint(0.3, 0.7),
      );
      expect(controls.copyWith(brightness: 0.2).cameraId, '1');
      expect(controls.copyWith(clearCameraId: true).cameraId, isNull);
      expect(controls.copyWith(clearExposurePoint: true).exposurePoint, isNull);
    });

    test('an off-frame metering point is rejected, not clamped', () {
      // Clamping would silently meter somewhere the user did not choose.
      expect(MeteringPoint.tryFromJson({'x': 1.4, 'y': 0.5}), isNull);
      expect(MeteringPoint.tryFromJson({'x': -0.1, 'y': 0.5}), isNull);
      expect(MeteringPoint.tryFromJson({'x': 'left', 'y': 0.5}), isNull);
      expect(MeteringPoint.tryFromJson(null), isNull);
      expect(MeteringPoint.tryFromJson({'x': 0.25, 'y': 0.75}),
          const MeteringPoint(0.25, 0.75));
    });

    test('night frame rate is clamped to what is worth capturing', () {
      const controls = CameraControls();
      expect(controls.patch({'nightFrameRate': 1}).nightFrameRate,
          AppConfig.minNightFrameRate);
      expect(controls.patch({'nightFrameRate': 60}).nightFrameRate,
          AppConfig.maxNightFrameRate);
    });

    test('round-trips the whole thing through JSON', () {
      const controls = CameraControls(
        brightness: -0.3,
        nightMode: true,
        cameraId: 'front-1',
        exposurePoint: MeteringPoint(0.4, 0.6),
        nightFrameRate: 5,
      );
      expect(CameraControls.fromJson(controls.toJson()), controls);
    });
  });

  group('CameraOption', () {
    test('reads the facing out of the platform label', () {
      expect(CameraOption.facingFromLabel('Camera 1, Facing front, Orient 270'),
          'front');
      expect(CameraOption.facingFromLabel('Camera 0, Facing back, Orient 90'),
          'back');
      expect(CameraOption.facingFromLabel('USB Camera'), 'unknown');
    });

    test('names itself for a button', () {
      expect(
        const CameraOption(deviceId: '1', label: 'x', facing: 'front')
            .shortLabel,
        'Front camera',
      );
      expect(
        const CameraOption(deviceId: '9', label: 'Thermal').shortLabel,
        'Thermal',
      );
    });

    test('capabilities carry the lens list over the wire', () {
      const caps = CameraCapabilities(
        torch: true,
        cameras: [
          CameraOption(deviceId: '0', label: 'Camera 0', facing: 'back'),
          CameraOption(deviceId: '1', label: 'Camera 1', facing: 'front'),
        ],
      );
      expect(CameraCapabilities.fromJson(caps.toJson()), caps);
    });

    test('malformed lens entries are dropped, not crashed on', () {
      final caps = CameraCapabilities.fromJson({
        'torch': false,
        'cameras': [
          {'deviceId': '0', 'label': 'Camera 0', 'facing': 'back'},
          {'label': 'no id'},
          'nonsense',
        ],
      });
      expect(caps.cameras.length, 1);
      expect(caps.cameras.single.deviceId, '0');
    });
  });

  group('mapTapToFrame', () {
    // A 640x480 (4:3) frame inside a 400x400 square widget.
    MeteringPoint? tap(double x, double y, {bool cover = false}) =>
        mapTapToFrame(
          tapX: x,
          tapY: y,
          widgetWidth: 400,
          widgetHeight: 400,
          videoWidth: 640,
          videoHeight: 480,
          cover: cover,
        );

    test('contain: the centre of the widget is the centre of the frame', () {
      final point = tap(200, 200);
      expect(point!.x, closeTo(0.5, 0.001));
      expect(point.y, closeTo(0.5, 0.001));
    });

    test('contain: letterbox bars are not on the frame at all', () {
      // 4:3 in a square leaves 50px bars top and bottom.
      expect(tap(200, 10), isNull, reason: 'top bar');
      expect(tap(200, 390), isNull, reason: 'bottom bar');
      expect(tap(200, 60), isNotNull, reason: 'just inside the picture');
    });

    test('contain: a tap maps past the bar, not through it', () {
      // y=50 is the very top of the drawn picture → frame y 0.
      final top = tap(200, 50);
      expect(top!.y, closeTo(0.0, 0.01));
      final bottom = tap(200, 350);
      expect(bottom!.y, closeTo(1.0, 0.01));
    });

    test('cover: the frame is cropped, so every tap lands on it', () {
      expect(tap(200, 10, cover: true), isNotNull);
      expect(tap(200, 390, cover: true), isNotNull);
      final centre = tap(200, 200, cover: true);
      expect(centre!.x, closeTo(0.5, 0.001));
      expect(centre.y, closeTo(0.5, 0.001));
    });

    test('cover: the cropped-away edges are outside the visible tap area', () {
      // Filling a square from 4:3 crops the sides: the visible frame runs
      // x 0.125…0.875, so the widget's left edge is not frame x=0.
      final left = tap(0, 200, cover: true);
      expect(left!.x, closeTo(0.125, 0.001));
    });

    test('returns null rather than guessing before the frame size is known',
        () {
      expect(
        mapTapToFrame(
          tapX: 10,
          tapY: 10,
          widgetWidth: 400,
          widgetHeight: 400,
          videoWidth: 0,
          videoHeight: 0,
          cover: false,
        ),
        isNull,
      );
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

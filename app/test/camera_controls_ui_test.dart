// Camera-controls panel UI contract (F13/F15): what a parent can change, what
// the hardware refuses, and that the camera stays the source of truth.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:babymonitor/core/camera_controls.dart';
import 'package:babymonitor/widgets/camera_controls_panel.dart';
import 'package:babymonitor/widgets/sound_level_meter.dart';

void main() {
  const withTorch = CameraState(
    controls: CameraControls.defaults,
    capabilities: CameraCapabilities(torch: true),
  );
  const withoutTorch = CameraState(
    controls: CameraControls.defaults,
    capabilities: CameraCapabilities.none,
  );

  Future<void> pumpPanel(
    WidgetTester tester, {
    required CameraState state,
    required ValueChanged<CameraControls> onChanged,
    Stream<CameraState>? states,
    Stream<double>? levels,
    bool enabled = true,
    ListenMode? listenMode,
    bool audible = true,
    Stream<bool>? audibleStates,
    ValueChanged<ListenMode>? onListenModeChanged,
  }) async {
    // A tall surface so the whole panel is built and hit-testable — the
    // sound-on-this-phone section sits below a phone-sized fold.
    await tester.binding.setSurfaceSize(const Size(800, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CameraControlsPanel(
            initialState: state,
            states: states,
            levels: levels,
            onChanged: onChanged,
            enabled: enabled,
            listenMode: listenMode,
            audible: audible,
            audibleStates: audibleStates,
            onListenModeChanged: onListenModeChanged,
          ),
        ),
      ),
    );
  }

  group('CameraControlsPanel', () {
    testWidgets('shows picture and sound-filter controls', (tester) async {
      await pumpPanel(tester, state: withTorch, onChanged: (_) {});

      expect(find.text('Camera controls'), findsOneWidget);
      expect(find.text('Brightness'), findsOneWidget);
      expect(find.text('Night mode'), findsOneWidget);
      expect(find.text('Camera light'), findsOneWidget);
      expect(find.text('Ignore sounds quieter than'), findsOneWidget);
      expect(find.byType(SoundLevelMeter), findsOneWidget);
    });

    testWidgets('night mode commits and lifts the brightness with it',
        (tester) async {
      CameraControls? committed;
      await pumpPanel(
        tester,
        state: withTorch,
        onChanged: (controls) => committed = controls,
      );

      await tester.tap(find.widgetWithText(SwitchListTile, 'Night mode'));
      await tester.pump();

      expect(committed?.nightMode, isTrue);
      expect(committed!.brightness, greaterThan(0.0));
    });

    testWidgets('the light switch is disabled on a phone with no torch',
        (tester) async {
      await pumpPanel(tester, state: withoutTorch, onChanged: (_) {});

      final tile = tester.widget<SwitchListTile>(
        find.widgetWithText(SwitchListTile, 'Camera light'),
      );
      expect(tile.onChanged, isNull);
      expect(
        find.text('This camera phone has no light this app can switch on.'),
        findsOneWidget,
      );
    });

    testWidgets('every control is disabled with no link to the camera',
        (tester) async {
      await pumpPanel(
        tester,
        state: withTorch,
        onChanged: (_) {},
        enabled: false,
      );

      expect(find.textContaining('Not connected to the camera'), findsOneWidget);
      for (final label in const ['Night mode', 'Camera light']) {
        final tile = tester.widget<SwitchListTile>(
          find.widgetWithText(SwitchListTile, label),
        );
        expect(tile.onChanged, isNull, reason: label);
      }
    });

    testWidgets('adopts state broadcast by the camera (source of truth)',
        (tester) async {
      final states = StreamController<CameraState>.broadcast();
      addTearDown(states.close);
      await pumpPanel(
        tester,
        state: withoutTorch,
        states: states.stream,
        onChanged: (_) {},
      );

      // The camera reports that it does have a torch, and is already on it.
      states.add(const CameraState(
        controls: CameraControls(light: true, nightMode: true),
        capabilities: CameraCapabilities(torch: true),
      ));
      await tester.pump();

      final tile = tester.widget<SwitchListTile>(
        find.widgetWithText(SwitchListTile, 'Camera light'),
      );
      expect(tile.onChanged, isNotNull);
      expect(tile.value, isTrue);
    });

    testWidgets('the meter follows the live level', (tester) async {
      final levels = StreamController<double>.broadcast();
      addTearDown(levels.close);
      await pumpPanel(
        tester,
        state: withTorch,
        levels: levels.stream,
        onChanged: (_) {},
      );

      expect(find.text('Now 0%'), findsOneWidget);
      levels.add(0.62);
      await tester.pump();
      expect(find.text('Now 62%'), findsOneWidget);
      expect(find.text('above the bar — alerts'), findsOneWidget);
    });
  });

  // F15 — lens choice, metering and the night capture rate.
  group('CameraControlsPanel camera', () {
    const twoLenses = CameraState(
      controls: CameraControls.defaults,
      capabilities: CameraCapabilities(
        torch: true,
        cameras: [
          CameraOption(deviceId: '0', label: 'Camera 0', facing: 'back'),
          CameraOption(deviceId: '1', label: 'Camera 1', facing: 'front'),
        ],
      ),
    );

    testWidgets('no lens picker on a phone with one camera', (tester) async {
      await pumpPanel(tester, state: withTorch, onChanged: (_) {});
      expect(find.text('Lens'), findsNothing);
    });

    testWidgets('picking the front lens commits its device id', (tester) async {
      CameraControls? committed;
      await pumpPanel(
        tester,
        state: twoLenses,
        onChanged: (controls) => committed = controls,
      );

      expect(find.text('Lens'), findsOneWidget);
      await tester.tap(find.text('Front camera'));
      await tester.pump();
      expect(committed?.cameraId, '1');

      // …and back to the default rear camera.
      await tester.tap(find.text('Default'));
      await tester.pump();
      expect(committed?.cameraId, isNull);
    });

    testWidgets('metering explains itself and resets to auto', (tester) async {
      CameraControls? committed;
      await pumpPanel(
        tester,
        state: const CameraState(
          controls: CameraControls(exposurePoint: MeteringPoint(0.25, 0.75)),
          capabilities: CameraCapabilities(torch: true),
        ),
        onChanged: (controls) => committed = controls,
      );

      expect(find.textContaining('Metering on the spot you chose'),
          findsOneWidget);
      await tester.tap(find.text('Auto'));
      await tester.pump();
      expect(committed, isNotNull);
      expect(committed!.exposurePoint, isNull);
      expect(find.textContaining('Long-press the picture'), findsOneWidget);
    });

    testWidgets('the night frame rate appears only in night mode',
        (tester) async {
      await pumpPanel(tester, state: withTorch, onChanged: (_) {});
      expect(find.text('Night frame rate'), findsNothing);

      await tester.tap(find.widgetWithText(SwitchListTile, 'Night mode'));
      await tester.pump();
      expect(find.text('Night frame rate'), findsOneWidget);
      expect(find.text('8 fps'), findsOneWidget);
    });
  });

  // F13 — what actually reaches this phone's speaker.
  group('CameraControlsPanel playback', () {
    testWidgets('the camera unit gets no "sound on this phone" section',
        (tester) async {
      await pumpPanel(tester, state: withTorch, onChanged: (_) {});
      expect(find.text('SOUND ON THIS PHONE'), findsNothing);
      expect(find.text('Filtered'), findsNothing);
    });

    testWidgets('a parent can switch to always-on', (tester) async {
      ListenMode? chosen;
      await pumpPanel(
        tester,
        state: withTorch,
        onChanged: (_) {},
        listenMode: ListenMode.filtered,
        onListenModeChanged: (mode) => chosen = mode,
      );

      await tester.tap(find.text('Always on'));
      await tester.pump();

      expect(chosen, ListenMode.alwaysOn);
      expect(
        find.textContaining('Everything the camera hears is played'),
        findsOneWidget,
      );
    });

    testWidgets('filtered mode explains a quiet speaker, live', (tester) async {
      final audibleStates = StreamController<bool>.broadcast();
      addTearDown(audibleStates.close);
      await pumpPanel(
        tester,
        state: withTorch,
        onChanged: (_) {},
        listenMode: ListenMode.filtered,
        audible: true,
        audibleStates: audibleStates.stream,
      );

      expect(find.textContaining('Playing — the room is above the bar'),
          findsOneWidget);

      // The room settles: the speaker goes quiet, and the panel says why.
      audibleStates.add(false);
      await tester.pump();
      expect(
        find.textContaining('the room is below the bar, so nothing is played'),
        findsOneWidget,
      );
    });

    testWidgets('muted is called out as the risky mode it is', (tester) async {
      await pumpPanel(
        tester,
        state: withTorch,
        onChanged: (_) {},
        listenMode: ListenMode.muted,
        onListenModeChanged: (_) {},
      );

      expect(
        find.textContaining('Nothing is played on this phone'),
        findsOneWidget,
      );
      // Alerts must still be promised, not silently dropped.
      expect(find.textContaining('Noise alerts and the picture still work'),
          findsOneWidget);
    });
  });
}

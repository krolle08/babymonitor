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
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CameraControlsPanel(
            initialState: state,
            states: states,
            levels: levels,
            onChanged: onChanged,
            enabled: enabled,
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
}

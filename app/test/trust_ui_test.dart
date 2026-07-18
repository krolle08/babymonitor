// F11/F12 UI tests (SPEC-ADDENDUM): trusted-devices management, the parent
// camera picker, and the camera-identity security alert. All hermetic — no
// sockets, no mDNS, no camera; trust data is the live TrustService singleton
// backed by mock SharedPreferences, discovery and alert streams are injected.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:babymonitor/core/identity.dart';
import 'package:babymonitor/screens/parent_screen.dart';
import 'package:babymonitor/screens/trusted_devices_screen.dart';
import 'package:babymonitor/services/discovery_service.dart';
import 'package:babymonitor/services/settings_service.dart';
import 'package:babymonitor/services/trust_service.dart';
import 'package:babymonitor/widgets/security_alert_listener.dart';

TrustedDevice _camera(String id, String name) => TrustedDevice(
      deviceId: id,
      name: name,
      pk: 'pk-$id',
      role: DeviceRole.camera,
      addedAt: DateTime(2026, 7, 1),
    );

TrustedDevice _parent(String id, String name) => TrustedDevice(
      deviceId: id,
      name: name,
      pk: 'pk-$id',
      role: DeviceRole.parent,
      addedAt: DateTime(2026, 7, 2),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late TrustService trust;

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await SettingsService.load();
    trust = await TrustService.load();
  });

  // Bring the shared singleton to a known-empty state before each test.
  setUp(() async {
    for (final device in trust.devices.toList()) {
      await trust.revoke(device.deviceId);
    }
    await SettingsService.instance.setRole('parent');
  });

  group('TrustedDevicesScreen', () {
    testWidgets('shows the empty state when nothing is paired', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: TrustedDevicesScreen()),
      );
      await tester.pumpAndSettle();

      expect(find.text('No trusted devices yet'), findsOneWidget);
      expect(find.text('Add camera'), findsOneWidget); // parent-role FAB
    });

    testWidgets('lists paired devices with their names', (tester) async {
      await trust.add(_camera('cam0001', 'Nursery cam'));
      await trust.add(_parent('par0002', 'Dad’s phone'));

      await tester.pumpWidget(
        const MaterialApp(home: TrustedDevicesScreen()),
      );
      await tester.pumpAndSettle();

      expect(find.text('Nursery cam'), findsOneWidget);
      expect(find.text('Dad’s phone'), findsOneWidget);
    });

    testWidgets('revoke asks for confirmation and removes the device',
        (tester) async {
      await trust.add(_parent('par0003', 'Mom’s phone'));

      await tester.pumpWidget(
        const MaterialApp(home: TrustedDevicesScreen()),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remove'));
      await tester.pumpAndSettle();

      // Confirmation dialog warns that the device can no longer connect.
      expect(find.textContaining('can no longer connect'), findsOneWidget);

      await tester.tap(find.widgetWithText(FilledButton, 'Remove'));
      await tester.pumpAndSettle();

      expect(find.text('Mom’s phone'), findsNothing);
      expect(find.text('No trusted devices yet'), findsOneWidget);
      expect(trust.isTrusted('par0003'), isFalse);
    });
  });

  group('Parent camera picker', () {
    testWidgets('shows trusted cameras and the code fallback', (tester) async {
      await trust.add(_camera('cam0010', 'Nursery cam'));

      await tester.pumpWidget(
        MaterialApp(
          home: ParentScreen(
            onSwitchRole: () {},
            discoverCameras: () async => const [],
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Trusted camera appears, and the room-code fallback is present.
      expect(find.text('Nursery cam'), findsOneWidget);
      expect(find.text('Your cameras'), findsOneWidget);
      expect(find.text('Join with a code'), findsOneWidget);
      // Not discovered → no nearby badge.
      expect(find.text('Nearby'), findsNothing);
    });

    testWidgets('marks a discovered trusted camera as nearby', (tester) async {
      await trust.add(_camera('cam0020', 'Living room'));

      await tester.pumpWidget(
        MaterialApp(
          home: ParentScreen(
            onSwitchRole: () {},
            discoverCameras: () async => const [
              DiscoveredCamera(
                deviceId: 'cam0020',
                name: 'Living room',
                host: '192.168.1.42',
                port: 47800,
              ),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Living room'), findsOneWidget);
      expect(find.text('Nearby'), findsOneWidget);
    });

    testWidgets('shows the no-cameras card when none are paired',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: ParentScreen(
            onSwitchRole: () {},
            discoverCameras: () async => const [],
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('No paired cameras'), findsOneWidget);
      expect(find.text('Join with a code'), findsOneWidget);
    });
  });

  group('SecurityAlertListener', () {
    testWidgets('shows a blocking alert on an event and disconnects on dismiss',
        (tester) async {
      final controller = StreamController<String>();
      addTearDown(controller.close);
      var dismissed = false;

      await tester.pumpWidget(
        MaterialApp(
          home: SecurityAlertListener(
            alerts: controller.stream,
            onDismiss: () => dismissed = true,
            child: const Scaffold(body: Center(child: Text('stream'))),
          ),
        ),
      );

      controller.add('Camera identity changed — re-pair to continue watching.');
      await tester.pump(); // deliver the stream event
      await tester.pumpAndSettle(); // dialog animates in

      expect(find.text('Security warning'), findsOneWidget);
      expect(find.textContaining('Camera identity changed'), findsOneWidget);
      expect(dismissed, isFalse);

      await tester.tap(find.widgetWithText(FilledButton, 'Disconnect'));
      await tester.pumpAndSettle();

      expect(dismissed, isTrue);
      expect(find.text('Security warning'), findsNothing);
    });
  });
}

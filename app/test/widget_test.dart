// UI smoke tests: app boot -> role picker, HealthBadge state labels,
// ReconnectBanner countdown text (F3/F4 UI contract).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:babymonitor/core/health_state.dart';
import 'package:babymonitor/main.dart';
import 'package:babymonitor/widgets/health_badge.dart';
import 'package:babymonitor/widgets/reconnect_banner.dart';
import 'package:babymonitor/services/settings_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await SettingsService.load();
  });

  group('app smoke', () {
    testWidgets('pumps and shows the role picker with both role cards',
        (tester) async {
      await tester.pumpWidget(const BabyMonitorApp());

      expect(find.text('Camera unit'), findsOneWidget);
      expect(find.text('Point at baby'), findsOneWidget);
      expect(find.text('Parent unit'), findsOneWidget);
      expect(find.text('Watch the feed'), findsOneWidget);
    });
  });

  group('HealthBadge', () {
    const expectedLabels = {
      HealthState.connecting: 'CONNECTING',
      HealthState.connected: 'CONNECTED',
      HealthState.degraded: 'DEGRADED',
      HealthState.reconnecting: 'RECONNECTING',
      HealthState.frozen: 'FROZEN',
      HealthState.failed: 'FAILED',
    };

    testWidgets('renders every state with its expected label', (tester) async {
      for (final state in HealthState.values) {
        await tester.pumpWidget(
          MaterialApp(home: Scaffold(body: HealthBadge(state: state))),
        );
        expect(
          find.text(expectedLabels[state]!),
          findsOneWidget,
          reason: 'badge label for $state',
        );
      }
    });
  });

  group('ReconnectBanner', () {
    testWidgets('shows the live countdown text', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ReconnectBanner(secondsRemaining: 7, onRetryNow: () {}),
          ),
        ),
      );
      expect(find.textContaining('Reconnecting in 7s'), findsOneWidget);
      expect(find.text('Retry now'), findsOneWidget);
    });

    testWidgets('shows "now" when the countdown reaches zero', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ReconnectBanner(secondsRemaining: 0, onRetryNow: () {}),
          ),
        ),
      );
      expect(find.textContaining('Reconnecting now'), findsOneWidget);
    });

    testWidgets('retry-now fires the callback', (tester) async {
      var retried = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ReconnectBanner(
              secondsRemaining: 3,
              onRetryNow: () => retried = true,
            ),
          ),
        ),
      );
      await tester.tap(find.text('Retry now'));
      expect(retried, isTrue);
    });
  });
}

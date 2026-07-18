/// Local notifications for noise + connection alerts (F7, docs/PROTOCOL.md
/// §5.3). Uses `flutter_local_notifications`; alerts are delivered while the
/// app is backgrounded (F7 AC / AT-09). Never throws to callers (NTR3).
library;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../core/health_state.dart';

class NotificationService {
  NotificationService._();

  static final NotificationService instance = NotificationService._();

  static const String _channelId = 'alerts';
  static const String _channelName = 'Alerts';
  static const String _channelDescription =
      'Baby monitor noise and connection alerts';

  // Stable ids so a newer alert of the same kind replaces the previous one.
  static const int _noiseId = 1;
  static const int _connectionId = 2;

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  bool _initialized = false;

  /// Plugin init + Android channel creation. Permissions are NOT requested
  /// here — call [requestPermissions] at a sensible UX moment.
  Future<void> init() async {
    if (_initialized) return;
    try {
      const android = AndroidInitializationSettings('@mipmap/ic_launcher');
      const ios = DarwinInitializationSettings(
        requestAlertPermission: false,
        requestBadgePermission: false,
        requestSoundPermission: false,
      );
      await _plugin.initialize(
        settings: const InitializationSettings(android: android, iOS: ios),
      );
      await _plugin
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>()
          ?.createNotificationChannel(const AndroidNotificationChannel(
            _channelId,
            _channelName,
            description: _channelDescription,
            importance: Importance.max,
          ));
      _initialized = true;
    } catch (e) {
      debugPrint('NotificationService: init failed: $e');
    }
  }

  /// Android 13+ POST_NOTIFICATIONS / iOS alert+sound+badge prompt.
  /// Returns whether notifications are permitted (best effort).
  Future<bool> requestPermissions() async {
    try {
      final android = _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      if (android != null) {
        // Pre-Android-13 has no runtime prompt — null means "not applicable".
        return await android.requestNotificationsPermission() ?? true;
      }
      final ios = _plugin.resolvePlatformSpecificImplementation<
          IOSFlutterLocalNotificationsPlugin>();
      if (ios != null) {
        return await ios.requestPermissions(
              alert: true,
              badge: true,
              sound: true,
            ) ??
            false;
      }
      return true;
    } catch (e) {
      debugPrint('NotificationService: permission request failed: $e');
      return false;
    }
  }

  NotificationDetails get _details => const NotificationDetails(
        android: AndroidNotificationDetails(
          _channelId,
          _channelName,
          channelDescription: _channelDescription,
          importance: Importance.max,
          priority: Priority.high,
          category: AndroidNotificationCategory.alarm,
        ),
        iOS: DarwinNotificationDetails(
          presentAlert: true,
          presentSound: true,
          presentBanner: true,
        ),
      );

  /// Noise above threshold (F7) — delivered even when backgrounded (AT-09).
  Future<void> showNoiseAlert(double level) async {
    final percent = (level.clamp(0.0, 1.0) * 100).round();
    await _show(
      id: _noiseId,
      title: 'Noise detected',
      body: 'The baby made a sound (level $percent%). Open to watch.',
    );
  }

  /// Connection-health alert (F3/F4/F5 — fail loudly, NTR1). Actionable
  /// messages, not generic errors (F5 AC). CONNECTED clears the alert;
  /// DEGRADED is deliberately silent (F3).
  Future<void> showConnectionAlert(HealthState state) async {
    switch (state) {
      case HealthState.reconnecting:
        await _show(
          id: _connectionId,
          title: 'Connection lost',
          body: 'Reconnecting to the camera automatically…',
        );
      case HealthState.frozen:
        await _show(
          id: _connectionId,
          title: 'Stream frozen',
          body: 'The picture stopped updating. Restarting the connection — '
              'check the camera phone if this repeats.',
        );
      case HealthState.failed:
        await _show(
          id: _connectionId,
          title: 'Connection failed',
          body: 'Automatic reconnect gave up. Open the app and tap '
              'Reconnect, and check the camera phone.',
        );
      case HealthState.connected:
        await _cancel(_connectionId); // healthy again — clear the alert
      case HealthState.connecting:
      case HealthState.degraded:
        break; // silent (F3: DEGRADED produces no visible change)
    }
  }

  Future<void> _show({
    required int id,
    required String title,
    required String body,
  }) async {
    if (!_initialized) await init();
    try {
      await _plugin.show(
        id: id,
        title: title,
        body: body,
        notificationDetails: _details,
      );
    } catch (e) {
      debugPrint('NotificationService: show "$title" failed: $e');
    }
  }

  Future<void> _cancel(int id) async {
    if (!_initialized) return;
    try {
      await _plugin.cancel(id: id);
    } catch (e) {
      debugPrint('NotificationService: cancel failed: $e');
    }
  }
}

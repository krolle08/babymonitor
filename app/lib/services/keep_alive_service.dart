/// Keeps the parent unit connected while the phone sleeps / the screen is off.
///
/// Android backgrounds and then Doze-suspends an ordinary app a few minutes
/// after the screen turns off, which would drop the WebRTC connection and stop
/// noise alerts. This wraps a native Android **foreground service** (+ a partial
/// wakelock) that keeps the app's process — and the live connection running in
/// it — alive through the night. Also nudges the user to exempt the app from
/// battery optimization (essential on aggressive OEMs, e.g. Huawei/Xiaomi).
///
/// No-op on non-Android platforms (iOS needs a different mechanism — see the
/// roadmap in the connection docs). Never throws to callers (NTR3).
library;

import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show debugPrint, kIsWeb;
import 'package:flutter/services.dart';

class KeepAliveService {
  KeepAliveService._();

  static final KeepAliveService instance = KeepAliveService._();

  static const MethodChannel _channel =
      MethodChannel('dk.madsen.babymonitor/keepalive');

  bool get _android => !kIsWeb && Platform.isAndroid;

  /// Starts the foreground service so monitoring survives screen-off/Doze.
  /// [text] is shown in the ongoing notification the OS requires.
  Future<void> start({
    String title = 'Baby Monitor',
    String text = 'Listening for sounds…',
  }) async {
    if (!_android) return;
    try {
      await _channel.invokeMethod('start', {'title': title, 'text': text});
    } catch (e) {
      debugPrint('KeepAliveService: start failed: $e');
    }
  }

  /// Stops the foreground service and releases the wakelock.
  Future<void> stop() async {
    if (!_android) return;
    try {
      await _channel.invokeMethod('stop');
    } catch (e) {
      debugPrint('KeepAliveService: stop failed: $e');
    }
  }

  /// Whether the app is already exempt from battery optimization. Treated as
  /// `true` off-Android (nothing to exempt).
  Future<bool> isIgnoringBatteryOptimizations() async {
    if (!_android) return true;
    try {
      final value =
          await _channel.invokeMethod<bool>('isIgnoringBatteryOptimizations');
      return value ?? false;
    } catch (e) {
      debugPrint('KeepAliveService: battery check failed: $e');
      return false;
    }
  }

  /// Prompts the user to exempt the app from battery optimization. No-ops if
  /// already exempt or off-Android.
  Future<void> requestIgnoreBatteryOptimizations() async {
    if (!_android) return;
    try {
      await _channel.invokeMethod('requestIgnoreBatteryOptimizations');
    } catch (e) {
      debugPrint('KeepAliveService: battery request failed: $e');
    }
  }
}

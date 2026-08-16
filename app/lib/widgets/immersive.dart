/// Full-screen (immersive) mode helper for both units (F14).
///
/// Kept in one place so every screen leaves the system UI in the same state,
/// including the crash-safe restore in `dispose()`. Failures are swallowed:
/// a device that will not hide its status bar must not take monitoring down
/// (NTR3).
library;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart';

/// Hides ([on] = true) or restores the status/navigation bars. Rotation is
/// left alone — both platforms already allow landscape, which is half the
/// point of a full-screen view.
Future<void> setImmersive(bool on) async {
  try {
    await SystemChrome.setEnabledSystemUIMode(
      on ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge,
    );
  } catch (e) {
    debugPrint('immersive: setEnabledSystemUIMode($on) failed: $e');
  }
}

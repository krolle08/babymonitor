/// Amber reconnect banner (spec F4): live countdown to the next automatic
/// attempt plus a "Retry now" shortcut. The parent screen builds it as soon
/// as the health FSM enters RECONNECTING (F3 AC: banner within 1 s).
library;

import 'package:flutter/material.dart';

class ReconnectBanner extends StatelessWidget {
  const ReconnectBanner({super.key, this.secondsRemaining, this.onRetryNow});

  /// Seconds until the next automatic reconnect attempt; null or 0 means an
  /// attempt is running right now.
  final int? secondsRemaining;

  /// Called when the user taps "Retry now".
  final VoidCallback? onRetryNow;

  static const Color _background = Color(0xFF3A2C08);
  static const Color _foreground = Color(0xFFFCD34D);

  @override
  Widget build(BuildContext context) {
    final seconds = secondsRemaining;
    final message = (seconds == null || seconds <= 0)
        ? 'Reconnecting now…'
        : 'Reconnecting in ${seconds}s…';
    return Material(
      color: _background,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: _foreground.withValues(alpha: 0.4)),
        ),
        padding: const EdgeInsets.fromLTRB(12, 8, 6, 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: _foreground,
              ),
            ),
            const SizedBox(width: 10),
            Text(
              message,
              style: const TextStyle(
                color: _foreground,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(width: 8),
            TextButton(
              onPressed: onRetryNow,
              style: TextButton.styleFrom(foregroundColor: _foreground),
              child: const Text('Retry now'),
            ),
          ],
        ),
      ),
    );
  }
}

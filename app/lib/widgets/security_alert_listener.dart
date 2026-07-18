/// Blocking camera-identity alert (docs/PROTOCOL.md §8.2, F12).
///
/// Listens to a [ParentSession.securityAlerts] stream and, on the first event,
/// shows a hard, red, blocking dialog — the camera's key no longer matches the
/// trusted one (possible MITM or a reinstalled camera). Dismissing it means
/// "stop trusting this stream", so [onDismiss] disconnects. The dialog is shown
/// at most once at a time; a reconnect loop that re-emits will not stack it.
library;

import 'dart:async';

import 'package:flutter/material.dart';

class SecurityAlertListener extends StatefulWidget {
  const SecurityAlertListener({
    super.key,
    required this.alerts,
    required this.onDismiss,
    required this.child,
  });

  /// Camera-identity / not-trusted alerts to react to.
  final Stream<String> alerts;

  /// Called when the user acknowledges the alert — disconnect the stream.
  final VoidCallback onDismiss;

  final Widget child;

  @override
  State<SecurityAlertListener> createState() => _SecurityAlertListenerState();
}

class _SecurityAlertListenerState extends State<SecurityAlertListener> {
  StreamSubscription<String>? _sub;
  bool _dialogOpen = false;

  @override
  void initState() {
    super.initState();
    _sub = widget.alerts.listen(_onAlert);
  }

  @override
  void didUpdateWidget(SecurityAlertListener oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.alerts != widget.alerts) {
      unawaited(_sub?.cancel());
      _sub = widget.alerts.listen(_onAlert);
    }
  }

  void _onAlert(String message) {
    if (_dialogOpen || !mounted) return;
    _dialogOpen = true;
    unawaited(_showAlert(message));
  }

  Future<void> _showAlert(String message) async {
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        return AlertDialog(
          icon: const Icon(Icons.gpp_maybe, color: Color(0xFFEF4444), size: 40),
          title: const Text('Security warning'),
          content: Text(message),
          actions: [
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFF7F1D1D),
                foregroundColor: const Color(0xFFFECACA),
              ),
              child: const Text('Disconnect'),
            ),
          ],
        );
      },
    );
    _dialogOpen = false;
    if (mounted) widget.onDismiss();
  }

  @override
  void dispose() {
    unawaited(_sub?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Full-screen pairing QR overlay (docs/PROTOCOL.md §8.1, F12).
///
/// Shown by the **camera** to add a trusted device. Enters pairing mode
/// ([CameraSession.startPairing]), renders the QR payload white-on-dark and
/// large enough to scan at arm's length, counts the 5-minute token down live,
/// and flips from "waiting for scan…" to a success state the moment
/// [TrustService.changes] reports a newly-trusted parent. Leaving the overlay
/// (done / cancel / back) always calls [CameraSession.stopPairing].
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../core/identity.dart';
import '../services/trust_service.dart';
import '../services/webrtc_service.dart';

/// Pushes the pairing overlay as a full-screen route.
Future<void> showPairingOverlay(BuildContext context, CameraSession session) {
  return Navigator.of(context).push(
    MaterialPageRoute<void>(
      fullscreenDialog: true,
      builder: (_) => PairingQrOverlay(session: session),
    ),
  );
}

class PairingQrOverlay extends StatefulWidget {
  const PairingQrOverlay({super.key, required this.session, this.trust});

  final CameraSession session;

  /// Trust store to watch for the new device (defaults to the singleton).
  final TrustService? trust;

  @override
  State<PairingQrOverlay> createState() => _PairingQrOverlayState();
}

class _PairingQrOverlayState extends State<PairingQrOverlay> {
  /// Token lifetime shown to the user (§8.1: 5 minutes).
  static const Duration _tokenTtl = Duration(minutes: 5);

  TrustService get _trust => widget.trust ?? TrustService.instance;

  StreamSubscription<List<TrustedDevice>>? _trustSub;
  Timer? _ticker;

  Set<String> _knownParentIds = {};
  String? _payload;
  bool _loading = true;
  bool _unavailable = false;
  bool _expired = false;
  Duration _remaining = _tokenTtl;
  String? _pairedName;

  @override
  void initState() {
    super.initState();
    _knownParentIds = _trust.parents.map((d) => d.deviceId).toSet();
    _trustSub = _trust.changes.listen(_onTrustChanged);
    unawaited(_beginPairing());
  }

  Future<void> _beginPairing() async {
    setState(() {
      _loading = true;
      _unavailable = false;
      _expired = false;
      _pairedName = null;
      _remaining = _tokenTtl;
    });
    final payload = await widget.session.startPairing();
    if (!mounted) return;
    if (payload == null) {
      setState(() {
        _loading = false;
        _unavailable = true;
      });
      return;
    }
    setState(() {
      _payload = payload;
      _loading = false;
    });
    _startTicker();
  }

  void _startTicker() {
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      final next = _remaining - const Duration(seconds: 1);
      if (next <= Duration.zero) {
        setState(() {
          _remaining = Duration.zero;
          _expired = true;
        });
        _ticker?.cancel();
        unawaited(widget.session.stopPairing());
      } else {
        setState(() => _remaining = next);
      }
    });
  }

  void _onTrustChanged(List<TrustedDevice> devices) {
    if (_pairedName != null) return; // already celebrating one
    for (final device in devices) {
      if (device.role == DeviceRole.parent &&
          !_knownParentIds.contains(device.deviceId)) {
        _ticker?.cancel();
        setState(() => _pairedName = device.name);
        unawaited(widget.session.stopPairing());
        if (mounted) {
          ScaffoldMessenger.of(context)
            ..hideCurrentSnackBar()
            ..showSnackBar(
              SnackBar(content: Text('Paired with ${device.name}')),
            );
        }
        return;
      }
    }
  }

  Future<void> _close() async {
    await widget.session.stopPairing();
    if (mounted) Navigator.of(context).pop();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    unawaited(_trustSub?.cancel());
    // Ensure pairing mode never lingers after the overlay is gone (§8.1).
    unawaited(widget.session.stopPairing());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Add trusted device'),
        leading: IconButton(
          icon: const Icon(Icons.close),
          tooltip: 'Cancel',
          onPressed: () => unawaited(_close()),
        ),
      ),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: _buildBody(context),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.all(48),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (_unavailable) return _buildUnavailable(context);
    if (_pairedName != null) return _buildSuccess(context);
    return _buildWaiting(context);
  }

  Widget _buildWaiting(BuildContext context) {
    final theme = Theme.of(context);
    final payload = _payload;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Scan on the other phone',
          textAlign: TextAlign.center,
          style: theme.textTheme.headlineSmall,
        ),
        const SizedBox(height: 8),
        Text(
          'On the parent phone, open Trusted devices and tap '
          '"Add camera", then point it at this code.',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 24),
        if (_expired)
          _buildExpired(context)
        else if (payload != null) ...[
          Center(
            child: Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(20),
              ),
              child: QrImageView(
                data: payload,
                size: 260,
                backgroundColor: Colors.white,
                // High error-correction survives glare/angle at arm's length.
                errorCorrectionLevel: QrErrorCorrectLevel.Q,
              ),
            ),
          ),
          const SizedBox(height: 20),
          _CountdownPill(remaining: _remaining),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 10),
              Text(
                'Waiting for scan…',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ],
        const SizedBox(height: 24),
        OutlinedButton(
          onPressed: () => unawaited(_close()),
          child: const Text('Cancel'),
        ),
      ],
    );
  }

  Widget _buildExpired(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      children: [
        Icon(Icons.timer_off_outlined,
            size: 48, color: theme.colorScheme.onSurfaceVariant),
        const SizedBox(height: 12),
        Text(
          'Pairing code expired',
          style: theme.textTheme.titleMedium,
        ),
        const SizedBox(height: 6),
        Text(
          'For safety the code is only valid for five minutes.',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 16),
        FilledButton.icon(
          onPressed: () => unawaited(_beginPairing()),
          icon: const Icon(Icons.refresh),
          label: const Text('Show a new code'),
        ),
      ],
    );
  }

  Widget _buildUnavailable(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.wifi_off_outlined,
            size: 48, color: theme.colorScheme.onSurfaceVariant),
        const SizedBox(height: 12),
        Text('Can’t pair right now', style: theme.textTheme.titleLarge),
        const SizedBox(height: 8),
        Text(
          'Local pairing needs the camera’s network endpoint, which '
          'isn’t available. Make sure monitoring is running and try again.',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 20),
        FilledButton(
          onPressed: () => unawaited(_close()),
          child: const Text('Close'),
        ),
      ],
    );
  }

  Widget _buildSuccess(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.verified_user, size: 64, color: Color(0xFF10B981)),
        const SizedBox(height: 16),
        Text('Paired', style: theme.textTheme.headlineSmall),
        const SizedBox(height: 8),
        Text(
          '${_pairedName!} can now connect with no code — just by opening the '
          'app and tapping this camera.',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 24),
        FilledButton(
          onPressed: () => unawaited(_close()),
          child: const Text('Done'),
        ),
      ],
    );
  }
}

/// Live "Expires in m:ss" pill for the pairing token.
class _CountdownPill extends StatelessWidget {
  const _CountdownPill({required this.remaining});

  final Duration remaining;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final minutes = remaining.inMinutes;
    final seconds = remaining.inSeconds % 60;
    final text = 'Expires in $minutes:${seconds.toString().padLeft(2, '0')}';
    return Center(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.timer_outlined,
                size: 16, color: scheme.onSurfaceVariant),
            const SizedBox(width: 6),
            Text(
              text,
              style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }
}

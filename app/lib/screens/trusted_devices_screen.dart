/// Trusted-devices management (docs/PROTOCOL.md §8, F12).
///
/// Lists every paired device from [TrustService] (name, role, short id, when it
/// was added) with rename and revoke. Adding a device is role-specific:
///   * Camera — enters pairing mode and shows the QR overlay for a parent to
///     scan ([showPairingOverlay]).
///   * Parent — scans a camera's QR and completes the §8.1 ceremony over the
///     LAN ([PairingClient]).
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../core/identity.dart';
import '../services/pairing_client.dart';
import '../services/settings_service.dart';
import '../services/trust_service.dart';
import '../services/webrtc_service.dart';
import '../widgets/pairing_qr_overlay.dart';

class TrustedDevicesScreen extends StatefulWidget {
  const TrustedDevicesScreen({super.key, this.cameraSession, this.trust});

  /// The live camera session, when opened from the camera unit — required to
  /// enter pairing mode. Absent for the parent role.
  final CameraSession? cameraSession;

  /// Trust store (defaults to the singleton).
  final TrustService? trust;

  @override
  State<TrustedDevicesScreen> createState() => _TrustedDevicesScreenState();
}

class _TrustedDevicesScreenState extends State<TrustedDevicesScreen> {
  TrustService get _trust => widget.trust ?? TrustService.instance;

  bool get _isCamera => SettingsService.instance.role == 'camera';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Trusted devices')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => unawaited(_add()),
        icon: Icon(_isCamera ? Icons.qr_code_2 : Icons.qr_code_scanner),
        label: Text(_isCamera ? 'Add device' : 'Add camera'),
      ),
      body: StreamBuilder<List<TrustedDevice>>(
        stream: _trust.changes,
        initialData: _trust.devices,
        builder: (context, snapshot) {
          final devices = snapshot.data ?? const <TrustedDevice>[];
          if (devices.isEmpty) return _EmptyState(isCamera: _isCamera);
          final sorted = [...devices]
            ..sort((a, b) => b.addedAt.compareTo(a.addedAt));
          return ListView.separated(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 96),
            itemCount: sorted.length,
            separatorBuilder: (_, _) => const SizedBox(height: 8),
            itemBuilder: (context, index) => _DeviceTile(
              device: sorted[index],
              onRename: () => unawaited(_rename(sorted[index])),
              onRevoke: () => unawaited(_revoke(sorted[index])),
            ),
          );
        },
      ),
    );
  }

  Future<void> _add() async {
    if (_isCamera) {
      await _addFromCamera();
    } else {
      await _addFromParent();
    }
  }

  // --- Camera role: show a QR for the parent to scan ---

  Future<void> _addFromCamera() async {
    final session = widget.cameraSession;
    if (session == null) {
      _snack('Start monitoring on the camera first, then add a device.');
      return;
    }
    await showPairingOverlay(context, session);
  }

  // --- Parent role: scan a camera's QR and pair over the LAN ---

  Future<void> _addFromParent() async {
    final payload = await Navigator.of(context).push<PairingPayload>(
      MaterialPageRoute<PairingPayload>(
        fullscreenDialog: true,
        builder: (_) => const _ScanCameraScreen(),
      ),
    );
    if (payload == null || !mounted) return;
    await _pair(payload);
  }

  Future<void> _pair(PairingPayload payload) async {
    // Blocking progress while the LAN ceremony runs (§8.1).
    unawaited(showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _PairingProgressDialog(name: payload.name),
    ));
    final result = await PairingClient().pair(payload);
    if (!mounted) return;
    Navigator.of(context).pop(); // dismiss the progress dialog
    if (result.success) {
      _snack('Paired with ${result.camera?.name ?? payload.name}');
    } else {
      _snack(result.reason ?? 'Pairing failed.');
    }
  }

  // --- Rename / revoke ---

  Future<void> _rename(TrustedDevice device) async {
    final controller = TextEditingController(text: device.name);
    final newName = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Rename device'),
        content: TextField(
          controller: controller,
          autofocus: true,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(
            labelText: 'Name',
            hintText: 'e.g. Mom’s phone',
          ),
          onSubmitted: (value) => Navigator.of(dialogContext).pop(value.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.of(dialogContext).pop(controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (newName != null && newName.isNotEmpty && newName != device.name) {
      await _trust.rename(device.deviceId, newName);
    }
  }

  Future<void> _revoke(TrustedDevice device) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        icon: const Icon(Icons.link_off, color: Color(0xFFEF4444)),
        title: Text('Remove ${device.name}?'),
        content: const Text(
          'This device can no longer connect. If it is watching right now, it '
          'will be disconnected. You can pair it again later.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFF7F1D1D),
              foregroundColor: const Color(0xFFFECACA),
            ),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await _trust.revoke(device.deviceId);
      _snack('${device.name} removed');
    }
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }
}

class _DeviceTile extends StatelessWidget {
  const _DeviceTile({
    required this.device,
    required this.onRename,
    required this.onRevoke,
  });

  final TrustedDevice device;
  final VoidCallback onRename;
  final VoidCallback onRevoke;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isCamera = device.role == DeviceRole.camera;
    final shortId = device.deviceId.length <= 6
        ? device.deviceId
        : device.deviceId.substring(0, 6);
    final added = DateFormat.yMMMd().format(device.addedAt.toLocal());
    return Card(
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: theme.colorScheme.surfaceContainerHigh,
          child: Icon(
            isCamera ? Icons.videocam_outlined : Icons.smartphone,
            color: theme.colorScheme.primary,
          ),
        ),
        title: Text(device.name),
        subtitle: Text(
          '${isCamera ? 'Camera' : 'Parent'} · #$shortId · added $added',
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        trailing: PopupMenuButton<String>(
          icon: const Icon(Icons.more_vert),
          onSelected: (value) {
            if (value == 'rename') onRename();
            if (value == 'revoke') onRevoke();
          },
          itemBuilder: (_) => const [
            PopupMenuItem(value: 'rename', child: Text('Rename')),
            PopupMenuItem(value: 'revoke', child: Text('Remove')),
          ],
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.isCamera});

  final bool isCamera;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.devices_other,
                size: 56, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(height: 16),
            Text('No trusted devices yet', style: theme.textTheme.titleLarge),
            const SizedBox(height: 8),
            Text(
              isCamera
                  ? 'Tap “Add device” to show a pairing code. On the parent '
                      'phone, scan it once — after that it connects with no '
                      'code, even with the internet down.'
                  : 'Tap “Add camera” to scan a camera’s pairing code. Once '
                      'paired you can watch with a single tap — no room code, '
                      'no internet needed at home.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}

/// Modal spinner shown while the LAN pairing ceremony runs.
class _PairingProgressDialog extends StatelessWidget {
  const _PairingProgressDialog({required this.name});

  final String name;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      content: Row(
        children: [
          const SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 16),
          Expanded(child: Text('Pairing with $name…')),
        ],
      ),
    );
  }
}

/// Full-screen QR scanner. Pops with the parsed [PairingPayload] on the first
/// valid baby-monitor pairing code; other codes are ignored (keep scanning).
class _ScanCameraScreen extends StatefulWidget {
  const _ScanCameraScreen();

  @override
  State<_ScanCameraScreen> createState() => _ScanCameraScreenState();
}

class _ScanCameraScreenState extends State<_ScanCameraScreen> {
  bool _handled = false;

  void _onDetect(BarcodeCapture capture) {
    if (_handled) return;
    for (final barcode in capture.barcodes) {
      final raw = barcode.rawValue;
      if (raw == null || raw.isEmpty) continue;
      try {
        final payload = PairingPayload.parse(raw);
        _handled = true;
        Navigator.of(context).pop(payload);
        return;
      } on FormatException {
        // Not one of our pairing codes — keep scanning.
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: const Text('Scan camera code'),
        leading: IconButton(
          icon: const Icon(Icons.close),
          tooltip: 'Cancel',
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          MobileScanner(onDetect: _onDetect),
          // Simple viewfinder + instruction over the live preview.
          IgnorePointer(
            child: Center(
              child: Container(
                width: 240,
                height: 240,
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.white70, width: 3),
                  borderRadius: BorderRadius.circular(20),
                ),
              ),
            ),
          ),
          const IgnorePointer(
            child: Align(
              alignment: Alignment.bottomCenter,
              child: Padding(
                padding: EdgeInsets.only(bottom: 48, left: 24, right: 24),
                child: Text(
                  'Point at the pairing code on the camera phone',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white, fontSize: 15),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

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
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../core/identity.dart';
import '../services/pairing_client.dart';
import '../services/settings_service.dart';
import '../services/trust_service.dart';
import '../services/webrtc_service.dart';
import '../widgets/pairing_qr_overlay.dart';

/// How the parent chooses to add a camera (§8.1): optically by QR, or by a
/// typed/pasted code for devices without a usable camera (e.g. emulators).
enum _AddMethod { scan, manual }

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
    final method = await _chooseAddMethod();
    if (method == null || !mounted) return;
    PairingPayload? payload;
    switch (method) {
      case _AddMethod.scan:
        payload = await Navigator.of(context).push<PairingPayload>(
          MaterialPageRoute<PairingPayload>(
            fullscreenDialog: true,
            builder: (_) => const _ScanCameraScreen(),
          ),
        );
      case _AddMethod.manual:
        payload = await _promptForManualCode();
    }
    if (payload == null || !mounted) return;
    await _pair(payload);
  }

  /// Lets the parent pick how to add a camera: point the camera at the QR, or
  /// type/paste the code (the only option that works where there's no usable
  /// camera, e.g. an emulator).
  Future<_AddMethod?> _chooseAddMethod() {
    return showModalBottomSheet<_AddMethod>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.qr_code_scanner),
              title: const Text('Scan QR code'),
              subtitle: const Text('Point at the code on the camera phone'),
              onTap: () => Navigator.of(sheetContext).pop(_AddMethod.scan),
            ),
            ListTile(
              leading: const Icon(Icons.keyboard),
              title: const Text('Enter code'),
              subtitle: const Text('Type or paste the code — no camera needed'),
              onTap: () => Navigator.of(sheetContext).pop(_AddMethod.manual),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  /// Prompts for a typed/pasted pairing code and parses it. Returns the parsed
  /// [PairingPayload], or `null` if cancelled. Invalid input is reported inline
  /// so the dialog stays open for a correction.
  Future<PairingPayload?> _promptForManualCode() async {
    final controller = TextEditingController();
    final payload = await showDialog<PairingPayload>(
      context: context,
      builder: (dialogContext) {
        String? error;
        return StatefulBuilder(
          builder: (dialogContext, setLocal) {
            void submit() {
              try {
                final parsed = PairingPayload.parseFlexible(controller.text);
                Navigator.of(dialogContext).pop(parsed);
              } on FormatException {
                setLocal(() =>
                    error = 'That doesn’t look like a valid pairing code.');
              }
            }

            return AlertDialog(
              title: const Text('Enter pairing code'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'On the camera phone, open Trusted devices → Add device, '
                    'then copy the code shown under the QR.',
                    style: Theme.of(dialogContext).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: controller,
                    autofocus: true,
                    minLines: 2,
                    maxLines: 4,
                    textInputAction: TextInputAction.done,
                    decoration: InputDecoration(
                      labelText: 'Pairing code',
                      hintText: 'BM1-…',
                      errorText: error,
                      border: const OutlineInputBorder(),
                    ),
                    onChanged: (_) {
                      if (error != null) setLocal(() => error = null);
                    },
                    onSubmitted: (_) => submit(),
                  ),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: () async {
                        final data =
                            await Clipboard.getData(Clipboard.kTextPlain);
                        final text = data?.text?.trim();
                        if (text != null && text.isNotEmpty) {
                          controller.text = text;
                          if (error != null) setLocal(() => error = null);
                        }
                      },
                      icon: const Icon(Icons.paste, size: 18),
                      label: const Text('Paste'),
                    ),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  child: const Text('Cancel'),
                ),
                FilledButton(onPressed: submit, child: const Text('Join')),
              ],
            );
          },
        );
      },
    );
    controller.dispose();
    return payload;
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

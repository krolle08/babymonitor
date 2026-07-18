/// Camera-unit screen (spec F1/F2/F7/F8/F9, docs/PROTOCOL.md §5.4).
///
/// Starts a [CameraSession] on entry (wakelock keeps the screen on — F2),
/// shows the giant 6-char room code parents type (NTR2: pairing under 60 s),
/// a local preview, the joined-parents count (F8), the wakelock warning
/// banner (F2 AC) and a noise-sensitivity quick toggle (F7). Stop closes the
/// sleep-log session (F9) and returns to the role picker.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../services/settings_service.dart';
import '../services/sleep_log_service.dart';
import '../services/webrtc_service.dart';

enum _Phase { starting, running, error }

class CameraScreen extends StatefulWidget {
  const CameraScreen({super.key, required this.onExit});

  /// Called after the session is fully stopped — the host shows the picker.
  final VoidCallback onExit;

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen> {
  final SleepLogService _log = SleepLogService();
  final RTCVideoRenderer _renderer = RTCVideoRenderer();
  final List<StreamSubscription<dynamic>> _subs = [];

  late CameraSession _session;

  _Phase _phase = _Phase.starting;
  String? _roomId;
  int _parentCount = 0;
  String? _warning;
  bool _parentTalking = false;
  bool _rendererReady = false;
  bool _stopping = false;
  bool _tornDown = false;
  String _sensitivity = SettingsService.instance.noiseSensitivity;

  Timer? _roomPoll;

  @override
  void initState() {
    super.initState();
    _session = CameraSession(log: _log);
    _subscribe();
    // CameraSession exposes the room code as a getter set when the server
    // answers `create-room` — poll it cheaply until it lands.
    _roomPoll = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (mounted && _session.roomId != _roomId) {
        setState(() => _roomId = _session.roomId);
      }
    });
    unawaited(_start());
  }

  void _subscribe() {
    _subs.add(_session.warnings.listen((message) {
      if (mounted) setState(() => _warning = message);
    }));
    _subs.add(_session.parentCount.listen((count) {
      if (mounted) setState(() => _parentCount = count);
    }));
    _subs.add(_session.parentTalk.listen((event) {
      if (mounted) setState(() => _parentTalking = event.on);
    }));
  }

  Future<void> _cancelSubs() async {
    for (final sub in _subs) {
      await sub.cancel();
    }
    _subs.clear();
  }

  Future<void> _start() async {
    try {
      await _log.start();
      if (!_rendererReady) {
        await _renderer.initialize();
        _rendererReady = true;
      }
      await _session.start();
      _renderer.srcObject = _session.localStream;
      if (mounted) setState(() => _phase = _Phase.running);
    } catch (e) {
      debugPrint('CameraScreen: session start failed: $e');
      if (mounted) setState(() => _phase = _Phase.error);
    }
  }

  /// A failed [CameraSession.start] leaves that session object spent — build
  /// a fresh one and try again (permissions may have been granted meanwhile).
  Future<void> _retry() async {
    await _cancelSubs();
    unawaited(_session.dispose());
    _session = CameraSession(log: _log);
    _subscribe();
    if (mounted) setState(() => _phase = _Phase.starting);
    await _start();
  }

  Future<void> _stop() async {
    if (_stopping) return;
    setState(() => _stopping = true);
    await _teardown();
    if (mounted) widget.onExit();
  }

  Future<void> _teardown() async {
    if (_tornDown) return;
    _tornDown = true;
    _roomPoll?.cancel();
    _roomPoll = null;
    await _cancelSubs();
    await _session.dispose(); // logs session end + releases wakelock (F2, F9)
    await _log.dispose();
  }

  @override
  void dispose() {
    if (!_tornDown) {
      _tornDown = true;
      _roomPoll?.cancel();
      _roomPoll = null;
      for (final sub in _subs) {
        unawaited(sub.cancel());
      }
      _subs.clear();
      unawaited(_session.dispose());
      unawaited(_log.dispose());
    }
    _renderer.srcObject = null;
    unawaited(_renderer.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Camera unit'),
        actions: [
          IconButton(
            icon: const Icon(Icons.swap_horiz),
            tooltip: 'Switch role',
            onPressed: _stopping ? null : () => unawaited(_stop()),
          ),
        ],
      ),
      body: SafeArea(
        child: switch (_phase) {
          _Phase.starting => const Center(child: CircularProgressIndicator()),
          _Phase.error => _buildError(context),
          _Phase.running => _buildRunning(context),
        },
      ),
    );
  }

  Widget _buildError(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.videocam_off_outlined,
              size: 56,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 16),
            Text('Camera unavailable', style: theme.textTheme.titleLarge),
            const SizedBox(height: 8),
            Text(
              'Could not start the camera. Check that this app has camera '
              'and microphone permissions, then try again.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: () => unawaited(_retry()),
              icon: const Icon(Icons.refresh),
              label: const Text('Try again'),
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: _stopping ? null : () => unawaited(_stop()),
              child: const Text('Back to role picker'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRunning(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _RoomCodeCard(roomId: _roomId),
          if (_warning != null) ...[
            const SizedBox(height: 12),
            _WarningBanner(
              message: _warning!,
              onDismiss: () => setState(() => _warning = null),
            ),
          ],
          const SizedBox(height: 12),
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: ColoredBox(
                color: Colors.black,
                child: RTCVideoView(
                  _renderer,
                  mirror: false,
                  objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitContain,
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              _InfoChip(
                icon: Icons.visibility_outlined,
                label: _parentCount == 1
                    ? '1 parent watching'
                    : '$_parentCount parents watching',
              ),
              const SizedBox(width: 8),
              if (_parentTalking)
                const _InfoChip(
                  icon: Icons.record_voice_over_outlined,
                  label: 'Parent talking',
                  color: Color(0xFF10B981),
                ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            'NOISE ALERT SENSITIVITY',
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              letterSpacing: 1.5,
            ),
          ),
          const SizedBox(height: 8),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'low', label: Text('Low')),
              ButtonSegment(value: 'medium', label: Text('Medium')),
              ButtonSegment(value: 'high', label: Text('High')),
            ],
            selected: {_sensitivity},
            showSelectedIcon: false,
            onSelectionChanged: (selection) {
              final value = selection.first;
              _session.setNoiseSensitivity(value); // applies live (F7)
              setState(() => _sensitivity = value);
            },
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _stopping ? null : () => unawaited(_stop()),
            icon: const Icon(Icons.stop_circle_outlined),
            label: Text(_stopping ? 'Stopping…' : 'Stop monitoring'),
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFF7F1D1D),
              foregroundColor: const Color(0xFFFECACA),
              padding: const EdgeInsets.symmetric(vertical: 16),
            ),
          ),
        ],
      ),
    );
  }
}

class _RoomCodeCard extends StatelessWidget {
  const _RoomCodeCard({required this.roomId});

  final String? roomId;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final code = roomId;
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Column(
          children: [
            Text(
              'ROOM CODE',
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                letterSpacing: 2,
              ),
            ),
            const SizedBox(height: 6),
            if (code == null)
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 12),
                  Text(
                    'Waiting for the server…',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              )
            else
              FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  code,
                  style: TextStyle(
                    fontSize: 56,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 12,
                    color: theme.colorScheme.primary,
                  ),
                ),
              ),
            const SizedBox(height: 4),
            Text(
              'Parents type this code to watch',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Amber warning banner, e.g. wakelock acquisition failure (F2 AC: surfaced
/// to the user with a clear message).
class _WarningBanner extends StatelessWidget {
  const _WarningBanner({required this.message, required this.onDismiss});

  final String message;
  final VoidCallback onDismiss;

  static const Color _background = Color(0xFF3A2C08);
  static const Color _foreground = Color(0xFFFCD34D);

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: _background,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _foreground.withValues(alpha: 0.4)),
      ),
      padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
      child: Row(
        children: [
          const Icon(Icons.warning_amber_rounded, color: _foreground, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(color: _foreground, fontSize: 13),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close, color: _foreground, size: 18),
            tooltip: 'Dismiss',
            onPressed: onDismiss,
          ),
        ],
      ),
    );
  }
}

class _InfoChip extends StatelessWidget {
  const _InfoChip({required this.icon, required this.label, this.color});

  final IconData icon;
  final String label;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final fg = color ?? scheme.onSurfaceVariant;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: fg),
          const SizedBox(width: 6),
          Text(label, style: TextStyle(color: fg, fontSize: 12)),
        ],
      ),
    );
  }
}

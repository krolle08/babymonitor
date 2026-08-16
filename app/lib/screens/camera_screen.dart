/// Camera-unit screen (spec F1/F2/F7/F8/F9/F13/F14/F15, docs/PROTOCOL.md §5.4).
///
/// Starts a [CameraSession] on entry (wakelock keeps the screen on — F2),
/// shows the giant 6-char room code parents type (NTR2: pairing under 60 s),
/// a local preview rendered with the session's picture settings (F15), the
/// joined-parents count (F8), the wakelock warning banner (F2 AC) and a live
/// sound-filter meter (F13). A full-screen preview (F14) makes it easy to
/// check the framing from across the room before leaving. Stop closes the
/// sleep-log session (F9) and returns to the role picker.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../core/camera_controls.dart';
import '../services/settings_service.dart';
import '../services/sleep_log_service.dart';
import '../services/webrtc_service.dart';
import '../widgets/adjustable_video_view.dart';
import '../widgets/camera_controls_panel.dart';
import '../widgets/immersive.dart';
import '../widgets/pairing_qr_overlay.dart';
import '../widgets/sound_level_meter.dart';
import 'trusted_devices_screen.dart';

enum _Phase { starting, running, error }

class CameraScreen extends StatefulWidget {
  const CameraScreen({super.key, required this.onExit});

  /// Called after the session is fully stopped — the host shows the picker.
  final VoidCallback onExit;

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen> {
  /// How long the overlay stays up in full-screen before fading away.
  static const Duration _chromeTimeout = Duration(seconds: 4);

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
  bool _allowCodeJoins = SettingsService.instance.allowCodeJoins;

  /// Picture + sound-filter settings (F13/F15), seeded from what was saved so
  /// the preview is correct before the session reports in.
  CameraState _cameraState = CameraState(
    controls: SettingsService.instance.cameraControls,
    capabilities: CameraCapabilities.none,
  );
  double _level = 0.0;

  /// Whether the room is currently passing the filter — i.e. whether parents
  /// are hearing anything at all right now (F13).
  bool _gateOpen = false;

  bool _fullscreen = false;
  bool _chromeVisible = true;
  Timer? _chromeTimer;
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
    _subs.add(_session.cameraStates.listen((state) {
      if (mounted) setState(() => _cameraState = state);
    }));
    _subs.add(_session.audioLevels.listen((level) {
      if (mounted) setState(() => _level = level);
    }));
    _subs.add(_session.audioGate.listen((open) {
      if (mounted) setState(() => _gateOpen = open);
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
      if (mounted) {
        setState(() {
          _phase = _Phase.running;
          _cameraState = _session.cameraState;
        });
      }
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
    _chromeTimer?.cancel();
    _chromeTimer = null;
    if (_fullscreen) unawaited(setImmersive(false));
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
    _chromeTimer?.cancel();
    _chromeTimer = null;
    if (_fullscreen) unawaited(setImmersive(false));
    _renderer.srcObject = null;
    unawaited(_renderer.dispose());
    super.dispose();
  }

  // --- Full-screen preview (F14) ---

  void _setFullscreen(bool value) {
    setState(() {
      _fullscreen = value;
      _chromeVisible = true;
    });
    unawaited(setImmersive(value));
    _restartChromeTimer();
  }

  void _restartChromeTimer() {
    _chromeTimer?.cancel();
    if (!_fullscreen) return;
    _chromeTimer = Timer(_chromeTimeout, () {
      if (mounted && _fullscreen) setState(() => _chromeVisible = false);
    });
  }

  void _tapPreview() {
    if (!_fullscreen) return;
    setState(() => _chromeVisible = !_chromeVisible);
    _restartChromeTimer();
  }

  // --- Controls (F13/F15) ---

  /// The camera reads its own level off the outbound stream (`getStats()`
  /// media-source), so there is nothing to sample until someone is watching.
  /// Say so rather than showing a meter stuck at zero.
  String? get _meterNote => _parentCount > 0
      ? null
      : 'The meter runs while a parent is watching — connect one to set the '
          'bar against the real room.';

  Future<void> _openControls() {
    _restartChromeTimer();
    return showCameraControlsSheet(
      context,
      initialState: _cameraState,
      states: _session.cameraStates,
      levels: _session.audioLevels,
      enabled: _phase == _Phase.running,
      disabledHint: 'The camera is not running yet.',
      meterNote: _meterNote,
      onPreview: (controls) =>
          setState(() => _cameraState = _cameraState.copyWith(controls: controls)),
      onChanged: (controls) => unawaited(_session.applyControls(controls)),
    );
  }

  void _openTrustedDevices() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => TrustedDevicesScreen(cameraSession: _session),
      ),
    );
  }

  Future<void> _addTrustedDevice() => showPairingOverlay(context, _session);

  Future<void> _setAllowCodeJoins(bool value) async {
    setState(() => _allowCodeJoins = value);
    await SettingsService.instance.setAllowCodeJoins(value);
  }

  @override
  Widget build(BuildContext context) {
    if (_fullscreen && _phase == _Phase.running) {
      return _buildFullscreen(context);
    }
    return Scaffold(
      appBar: AppBar(
        title: const Text('Camera unit'),
        actions: [
          IconButton(
            icon: const Icon(Icons.tune),
            tooltip: 'Camera controls',
            onPressed: _phase == _Phase.running
                ? () => unawaited(_openControls())
                : null,
          ),
          IconButton(
            icon: const Icon(Icons.devices_outlined),
            tooltip: 'Trusted devices',
            onPressed: _phase == _Phase.running ? _openTrustedDevices : null,
          ),
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

  Widget _buildPreview() => AdjustableVideoView(
        renderer: _renderer,
        brightness: _cameraState.controls.brightness,
        nightMode: _cameraState.controls.nightMode,
        objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitContain,
      );

  /// Full-screen framing check (F14): the whole screen is the crib view, with
  /// an overlay that fades out so nothing competes with the picture.
  Widget _buildFullscreen(BuildContext context) {
    final code = _roomId;
    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        onTap: _tapPreview,
        child: Stack(
          fit: StackFit.expand,
          children: [
            _buildPreview(),
            AnimatedOpacity(
              opacity: _chromeVisible ? 1 : 0,
              duration: const Duration(milliseconds: 200),
              child: IgnorePointer(
                ignoring: !_chromeVisible,
                child: SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      children: [
                        Row(
                          children: [
                            _OverlayChip(
                              icon: Icons.visibility_outlined,
                              label: _parentCount == 1
                                  ? '1 parent'
                                  : '$_parentCount parents',
                            ),
                            if (code != null) ...[
                              const SizedBox(width: 8),
                              _OverlayChip(icon: Icons.key_outlined, label: code),
                            ],
                            const Spacer(),
                            _OverlayButton(
                              icon: Icons.tune,
                              tooltip: 'Camera controls',
                              onPressed: () => unawaited(_openControls()),
                            ),
                            const SizedBox(width: 8),
                            _OverlayButton(
                              icon: Icons.fullscreen_exit,
                              tooltip: 'Exit full screen',
                              onPressed: () => _setFullscreen(false),
                            ),
                          ],
                        ),
                        const Spacer(),
                        SoundLevelMeter(
                          level: _level,
                          threshold: _cameraState.controls.sound.threshold,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRunning(BuildContext context) {
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
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    _buildPreview(),
                    Positioned(
                      right: 8,
                      bottom: 8,
                      child: _OverlayButton(
                        icon: Icons.fullscreen,
                        tooltip: 'Full screen',
                        onPressed: () => _setFullscreen(true),
                      ),
                    ),
                  ],
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
              if (_cameraState.controls.nightMode) ...[
                const SizedBox(width: 8),
                const _InfoChip(
                  icon: Icons.nightlight_round,
                  label: 'Night mode',
                  color: Color(0xFF93C5FD),
                ),
              ],
            ],
          ),
          const SizedBox(height: 12),
          _SoundFilterCard(
            level: _level,
            filter: _cameraState.controls.sound,
            note: _meterNote,
            gateOpen: _gateOpen,
            playingTo: _parentCount,
            onAdjust: () => unawaited(_openControls()),
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: () => unawaited(_addTrustedDevice()),
            icon: const Icon(Icons.add_link),
            label: const Text('Add trusted device'),
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 14),
            ),
          ),
          const SizedBox(height: 8),
          _AllowCodeJoinsTile(
            value: _allowCodeJoins,
            onChanged: (value) => unawaited(_setAllowCodeJoins(value)),
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

/// Live meter + the current bar, with a shortcut into the full control sheet
/// (F13). Sitting next to the crib you can watch the baby breathe and see
/// that it stays under the bar.
class _SoundFilterCard extends StatelessWidget {
  const _SoundFilterCard({
    required this.level,
    required this.filter,
    required this.onAdjust,
    required this.gateOpen,
    required this.playingTo,
    this.note,
  });

  final double level;
  final SoundFilter filter;
  final VoidCallback onAdjust;

  /// Whether the room currently passes the filter and is being played.
  final bool gateOpen;

  /// How many parents are connected — nobody is hearing anything at zero.
  final int playingTo;

  /// Why the meter is not moving, when it is not moving.
  final String? note;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sustain = filter.sustain.inSeconds;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Text(
                  'SOUND FILTER',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    letterSpacing: 1.5,
                  ),
                ),
                if (playingTo > 0) ...[
                  const SizedBox(width: 8),
                  Icon(
                    gateOpen ? Icons.hearing : Icons.hearing_disabled,
                    size: 14,
                    color: gateOpen
                        ? const Color(0xFF10B981)
                        : theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    gateOpen ? 'playing' : 'not played',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: gateOpen
                          ? const Color(0xFF10B981)
                          : theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
                const Spacer(),
                TextButton.icon(
                  onPressed: onAdjust,
                  icon: const Icon(Icons.tune, size: 18),
                  label: const Text('Adjust'),
                ),
              ],
            ),
            const SizedBox(height: 4),
            SoundLevelMeter(level: level, threshold: filter.threshold),
            const SizedBox(height: 8),
            if (note != null) ...[
              Text(
                note!,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: 6),
            ],
            Text(
              'Alerts above ${(filter.threshold * 100).round()}%'
              '${sustain > 0 ? ', held for ${sustain}s' : ''}'
              '${filter.ignoreSteady ? ', steady background ignored' : ''}.',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}

/// Camera-only guest-access toggle (§8.2 bootstrap): when off, only paired
/// devices can watch. Persisted; applies the next time monitoring starts.
class _AllowCodeJoinsTile extends StatelessWidget {
  const _AllowCodeJoinsTile({required this.value, required this.onChanged});

  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: EdgeInsets.zero,
      child: SwitchListTile(
        value: value,
        onChanged: onChanged,
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
        title: const Text('Allow room-code joins'),
        subtitle: Text(
          value
              ? 'Guests can watch by typing the room code.'
              : 'Only paired devices can watch. Applies on next start.',
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
      ),
    );
  }
}

class _RoomCodeCard extends StatelessWidget {
  const _RoomCodeCard({required this.roomId});

  /// The cloud room code, or null when the camera has no cloud connection yet
  /// (fully-offline / local-only mode — F11/NTR7).
  final String? roomId;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final code = roomId;
    final online = code != null;
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Column(
          children: [
            Align(
              alignment: Alignment.centerRight,
              child: _TransportChip(online: online),
            ),
            Text(
              online ? 'ROOM CODE' : 'TRUSTED DEVICES ONLY',
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                letterSpacing: 2,
              ),
            ),
            const SizedBox(height: 6),
            if (!online)
              Column(
                children: [
                  Icon(Icons.shield_outlined,
                      size: 36, color: theme.colorScheme.primary),
                  const SizedBox(height: 6),
                  Text(
                    'Offline — local mode',
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: theme.colorScheme.onSurface,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'No cloud code yet. Paired phones on this WiFi can still '
                    'connect with no internet.',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              )
            else ...[
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
          ],
        ),
      ),
    );
  }
}

/// Quiet cloud-reachability indicator (NTR7): never an alert style — a cloud
/// outage only removes remote viewing, it is not a monitoring failure.
class _TransportChip extends StatelessWidget {
  const _TransportChip({required this.online});

  final bool online;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = scheme.onSurfaceVariant;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(online ? Icons.cloud_done_outlined : Icons.cloud_off_outlined,
            size: 14, color: color),
        const SizedBox(width: 4),
        Text(
          online ? 'online' : 'offline — local mode',
          style: TextStyle(color: color, fontSize: 11),
        ),
      ],
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

/// Dark translucent chip legible on top of a video frame (F14 overlay).
class _OverlayChip extends StatelessWidget {
  const _OverlayChip({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xCC0A101F),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: const Color(0x33FFFFFF)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: const Color(0xFF93A1BC)),
          const SizedBox(width: 6),
          Text(
            label,
            style: const TextStyle(color: Color(0xFFC6D0E2), fontSize: 12),
          ),
        ],
      ),
    );
  }
}

/// Round translucent icon button for video overlays (F14).
class _OverlayButton extends StatelessWidget {
  const _OverlayButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xCC0A101F),
      shape: const CircleBorder(side: BorderSide(color: Color(0x33FFFFFF))),
      clipBehavior: Clip.antiAlias,
      child: IconButton(
        icon: Icon(icon, color: const Color(0xFFC6D0E2)),
        tooltip: tooltip,
        onPressed: onPressed,
      ),
    );
  }
}

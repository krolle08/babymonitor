/// Parent-unit screen (spec F1/F3–F7, docs/PROTOCOL.md §5.4).
///
/// Join flow (6-char code, last room prefilled — NTR2), full-screen stream,
/// health badge (F3: DEGRADED shows only as a badge color change), reconnect
/// banner with live countdown (F4), frozen alert + failed overlay with a
/// manual reconnect (F5/F3), hold-to-talk (F6), latency chip (F1) and noise
/// alerts — in-app snackbar when foregrounded, local notification when
/// backgrounded (F7 / AT-09).
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../config/app_config.dart';
import '../core/health_state.dart';
import '../services/notification_service.dart';
import '../services/settings_service.dart';
import '../services/webrtc_service.dart';
import '../widgets/health_badge.dart';
import '../widgets/ptt_button.dart';
import '../widgets/reconnect_banner.dart';
import 'history_screen.dart';
import 'settings_screen.dart';

class ParentScreen extends StatefulWidget {
  const ParentScreen({super.key, required this.onSwitchRole});

  /// "Switch role" escape hatch — the host shows the role picker.
  final VoidCallback onSwitchRole;

  @override
  State<ParentScreen> createState() => _ParentScreenState();
}

class _ParentScreenState extends State<ParentScreen>
    with WidgetsBindingObserver {
  late final TextEditingController _codeController;
  final RTCVideoRenderer _renderer = RTCVideoRenderer();
  final List<StreamSubscription<dynamic>> _subs = [];

  ParentSession? _session;
  bool _rendererReady = false;
  bool _joining = false;
  bool _inRoom = false;
  bool _hasVideo = false;
  HealthState _health = HealthState.connecting;
  int? _retrySeconds;
  int? _latencyMs;
  String _roomCode = '';
  AppLifecycleState _lifecycle = AppLifecycleState.resumed;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _lifecycle =
        WidgetsBinding.instance.lifecycleState ?? AppLifecycleState.resumed;
    _codeController = TextEditingController(
      text: SettingsService.instance.lastJoinedRoom ?? '',
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _lifecycle = state;
  }

  bool get _foregrounded => _lifecycle == AppLifecycleState.resumed;

  bool get _canJoin => _codeController.text.trim().length == 6 && !_joining;

  Future<void> _join() async {
    final code = _codeController.text.trim().toUpperCase();
    if (code.length != 6 || _joining || _inRoom) return;
    setState(() => _joining = true);
    // Noise alerts must reach a backgrounded parent (AT-09) — ask now, at
    // the moment the user starts monitoring.
    unawaited(NotificationService.instance.requestPermissions());
    if (!_rendererReady) {
      await _renderer.initialize();
      _rendererReady = true;
    }
    final session = ParentSession();
    _session = session;
    _health = session.healthMonitor.state;
    _subs.add(session.healthStates.listen(_onHealth));
    _subs.add(session.remoteStreams.listen(_onRemoteStream));
    _subs.add(session.nextRetrySeconds.listen(_onRetryCountdown));
    _subs.add(session.latencies.listen(_onLatency));
    _subs.add(session.noiseAlerts.listen(_onNoiseAlert));
    await session.join(code); // never throws (NTR3)
    if (!mounted) return;
    setState(() {
      _joining = false;
      _inRoom = true;
      _roomCode = code;
    });
  }

  void _onHealth(HealthState state) {
    if (mounted) {
      setState(() {
        _health = state;
        if (state != HealthState.reconnecting) _retrySeconds = null;
      });
    }
    // Fail loudly even when backgrounded (NTR1): connection alerts reuse the
    // notification channel; CONNECTED clears them, DEGRADED stays silent.
    if (!_foregrounded) {
      unawaited(NotificationService.instance.showConnectionAlert(state));
    }
  }

  void _onRemoteStream(MediaStream stream) {
    _renderer.srcObject = stream;
    if (mounted) setState(() => _hasVideo = true);
  }

  void _onRetryCountdown(int seconds) {
    if (mounted) setState(() => _retrySeconds = seconds);
  }

  void _onLatency(int ms) {
    if (mounted) setState(() => _latencyMs = ms);
  }

  void _onNoiseAlert(NoiseAlert alert) {
    final percent = (alert.audioLevel.clamp(0.0, 1.0) * 100).round();
    if (_foregrounded) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Noise detected — the baby made a sound ($percent%)'),
          duration: const Duration(seconds: 4),
        ),
      );
    } else {
      unawaited(NotificationService.instance.showNoiseAlert(alert.audioLevel));
    }
  }

  Future<void> _leave() async {
    final session = _session;
    _session = null;
    for (final sub in _subs) {
      await sub.cancel();
    }
    _subs.clear();
    _renderer.srcObject = null;
    if (mounted) {
      setState(() {
        _inRoom = false;
        _joining = false;
        _hasVideo = false;
        _health = HealthState.connecting;
        _retrySeconds = null;
        _latencyMs = null;
      });
    }
    if (session != null) await session.leave();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    for (final sub in _subs) {
      unawaited(sub.cancel());
    }
    _subs.clear();
    final session = _session;
    _session = null;
    if (session != null) unawaited(session.leave());
    _renderer.srcObject = null;
    unawaited(_renderer.dispose());
    _codeController.dispose();
    super.dispose();
  }

  void _openHistory() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const HistoryScreen()),
    );
  }

  void _openSettings() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const SettingsScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    return _inRoom ? _buildWatch(context) : _buildJoin(context);
  }

  // --- Join flow ---

  Widget _buildJoin(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Parent unit'),
        actions: [
          IconButton(
            icon: const Icon(Icons.history),
            tooltip: 'History',
            onPressed: _openHistory,
          ),
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: 'Settings',
            onPressed: _openSettings,
          ),
          IconButton(
            icon: const Icon(Icons.swap_horiz),
            tooltip: 'Switch role',
            onPressed: widget.onSwitchRole,
          ),
        ],
      ),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Icon(Icons.crib, size: 56, color: theme.colorScheme.primary),
                  const SizedBox(height: 12),
                  Text(
                    'Join the camera',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Enter the 6-character room code shown on the '
                    'camera phone.',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                  const SizedBox(height: 24),
                  TextField(
                    controller: _codeController,
                    onChanged: (_) => setState(() {}),
                    onSubmitted: (_) => unawaited(_join()),
                    textAlign: TextAlign.center,
                    textCapitalization: TextCapitalization.characters,
                    autocorrect: false,
                    enableSuggestions: false,
                    maxLength: 6,
                    style: const TextStyle(
                      fontSize: 32,
                      letterSpacing: 10,
                      fontWeight: FontWeight.w700,
                    ),
                    inputFormatters: [
                      // Room codes are A–Z / 2–9 (no 0/O/1/I) — PROTOCOL §2.1.
                      FilteringTextInputFormatter.allow(RegExp('[a-zA-Z2-9]')),
                      LengthLimitingTextInputFormatter(6),
                      _UpperCaseTextFormatter(),
                    ],
                    decoration: InputDecoration(
                      counterText: '',
                      hintText: 'ABC234',
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                  FilledButton.icon(
                    onPressed: _canJoin ? () => unawaited(_join()) : null,
                    icon: _joining
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.play_arrow_rounded),
                    label: Text(_joining ? 'Joining…' : 'Watch'),
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  // --- Watching ---

  Widget _buildWatch(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: Text('Room $_roomCode'),
        actions: [
          IconButton(
            icon: const Icon(Icons.history),
            tooltip: 'History',
            onPressed: _openHistory,
          ),
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: 'Settings',
            onPressed: _openSettings,
          ),
          IconButton(
            icon: const Icon(Icons.logout),
            tooltip: 'Leave room',
            onPressed: () => unawaited(_leave()),
          ),
        ],
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          if (_hasVideo)
            RTCVideoView(
              _renderer,
              mirror: false,
              objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
            )
          else
            Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const CircularProgressIndicator(),
                  const SizedBox(height: 12),
                  Text(
                    'Connecting to camera…',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      HealthBadge(state: _health),
                      const Spacer(),
                      if (_latencyMs != null) _LatencyChip(ms: _latencyMs!),
                    ],
                  ),
                  if (_health == HealthState.reconnecting)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Center(
                        child: ReconnectBanner(
                          secondsRemaining: _retrySeconds,
                          onRetryNow: () =>
                              unawaited(_session?.manualReconnect()),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          if (_health == HealthState.frozen) const _FrozenOverlay(),
          if (_health == HealthState.failed)
            _FailedOverlay(
              onReconnect: () => unawaited(_session?.manualReconnect()),
            ),
          if (_health != HealthState.failed)
            Align(
              alignment: Alignment.bottomCenter,
              child: SafeArea(
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 20),
                  child: PttButton(
                    onTalkingChanged: (on) =>
                        unawaited(_session?.setTalking(on)),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Measured stream latency at connect (F1) — warn styling when it exceeds
/// [AppConfig.latencyAlertMs].
class _LatencyChip extends StatelessWidget {
  const _LatencyChip({required this.ms});

  final int ms;

  @override
  Widget build(BuildContext context) {
    final warn = ms > AppConfig.latencyAlertMs;
    final color = warn ? const Color(0xFFEF4444) : const Color(0xFF10B981);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xCC0A101F),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.6)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(warn ? Icons.warning_amber_rounded : Icons.speed,
              size: 14, color: color),
          const SizedBox(width: 6),
          Text(
            'Latency ${(ms / 1000).toStringAsFixed(1)}s',
            style: TextStyle(
              color: color,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

/// FROZEN alert (F5 AC: actionable message, not a generic error).
class _FrozenOverlay extends StatelessWidget {
  const _FrozenOverlay();

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: IgnorePointer(
        child: ColoredBox(
          color: const Color(0xB3000000),
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: const [
                Icon(Icons.ac_unit, size: 48, color: Color(0xFFEF4444)),
                SizedBox(height: 12),
                Text(
                  'Stream frozen — restarting video…',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Color(0xFFC6D0E2),
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                SizedBox(height: 6),
                Text(
                  'If this keeps happening, check the camera phone.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Color(0xFF93A1BC), fontSize: 13),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// FAILED full-screen overlay with a manual reconnect (F3 AC).
class _FailedOverlay extends StatelessWidget {
  const _FailedOverlay({required this.onReconnect});

  final VoidCallback onReconnect;

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: ColoredBox(
        color: const Color(0xF20A0E1A),
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.error_outline,
                    size: 56, color: Color(0xFFEF4444)),
                const SizedBox(height: 16),
                const Text(
                  'Connection failed',
                  style: TextStyle(
                    color: Color(0xFFC6D0E2),
                    fontSize: 22,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Automatic reconnect gave up. Make sure the camera phone '
                  'is running and online, then try again.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Color(0xFF93A1BC), fontSize: 14),
                ),
                const SizedBox(height: 24),
                FilledButton.icon(
                  onPressed: onReconnect,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Reconnect'),
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 28,
                      vertical: 14,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _UpperCaseTextFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    return newValue.copyWith(text: newValue.text.toUpperCase());
  }
}

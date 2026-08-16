/// Parent-unit screen (spec F1/F3–F7, F11–F15, docs/PROTOCOL.md §4, §5.4,
/// §7, §8).
///
/// Pre-join is a **camera picker**: trusted cameras (F12) that connect with zero
/// input, marked "nearby" when mDNS finds them on this network (F11), plus a
/// "Join with a code" fallback for guests (NTR2). Watching shows the full-screen
/// stream, health badge (F3), reconnect banner (F4), frozen/failed overlays
/// (F5/F3), hold-to-talk (F6), latency chip (F1), a quiet LAN/cloud transport
/// badge (§7) and noise alerts — snackbar when foregrounded, notification when
/// backgrounded (F7 / AT-09). A camera-key mismatch raises a blocking security
/// alert that disconnects on dismiss (§8.2).
///
/// While watching, the parent can also drive the camera itself: a full-screen
/// view with fading chrome (F14) and a control sheet for brightness, night
/// mode, the camera light and the sound filter (F13/F15) — changes travel to
/// the camera on the `health` data channel and come back as authoritative
/// state, so both units always agree.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../config/app_config.dart';
import '../core/camera_controls.dart';
import '../core/health_state.dart';
import '../core/identity.dart';
import '../services/discovery_service.dart';
import '../services/notification_service.dart';
import '../services/settings_service.dart';
import '../services/trust_service.dart';
import '../services/webrtc_service.dart';
import '../widgets/adjustable_video_view.dart';
import '../widgets/camera_controls_panel.dart';
import '../widgets/health_badge.dart';
import '../widgets/immersive.dart';
import '../widgets/ptt_button.dart';
import '../widgets/reconnect_banner.dart';
import '../widgets/security_alert_listener.dart';
import '../widgets/sound_level_meter.dart';
import 'history_screen.dart';
import 'settings_screen.dart';
import 'trusted_devices_screen.dart';

class ParentScreen extends StatefulWidget {
  const ParentScreen({
    super.key,
    required this.onSwitchRole,
    this.discoverCameras,
  });

  /// "Switch role" escape hatch — the host shows the role picker.
  final VoidCallback onSwitchRole;

  /// Test seam: how to enumerate nearby cameras. Defaults to real mDNS.
  final Future<List<DiscoveredCamera>> Function()? discoverCameras;

  @override
  State<ParentScreen> createState() => _ParentScreenState();
}

class _ParentScreenState extends State<ParentScreen>
    with WidgetsBindingObserver {
  /// Implicit LAN room for a trusted, zero-input connect (§7).
  static const String _trustedRoomId = 'LOCAL';

  /// How long the overlay stays up in full-screen before fading away (F14).
  static const Duration _chromeTimeout = Duration(seconds: 4);

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
  String _transport = 'none';
  String _roomLabel = '';
  AppLifecycleState _lifecycle = AppLifecycleState.resumed;

  Set<String> _nearby = {};
  bool _scanningNearby = false;

  /// The camera's picture + sound-filter settings (F13/F15). Until the data
  /// channel reports in, this is the neutral default.
  CameraState _cameraState = const CameraState(
    controls: CameraControls.defaults,
    capabilities: CameraCapabilities.none,
  );
  double _level = 0.0;

  /// What this phone is doing with the camera's audio (F13).
  ListenMode _listenMode = SettingsService.instance.listenMode;
  double _volume = SettingsService.instance.playbackVolume;
  bool _audible = true;

  bool _fullscreen = false;
  bool _chromeVisible = true;
  Timer? _chromeTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _lifecycle =
        WidgetsBinding.instance.lifecycleState ?? AppLifecycleState.resumed;
    final last = SettingsService.instance.lastJoinedRoom;
    _codeController = TextEditingController(
      text: (last != null && last.length == 6) ? last : '',
    );
    unawaited(_refreshNearby());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _lifecycle = state;
  }

  bool get _foregrounded => _lifecycle == AppLifecycleState.resumed;

  bool get _canJoin => _codeController.text.trim().length == 6 && !_joining;

  // --- Nearby discovery (F11) ---

  Future<List<DiscoveredCamera>> _defaultDiscover() async {
    final service = DiscoveryService();
    try {
      return await service.discover();
    } finally {
      await service.dispose();
    }
  }

  Future<void> _refreshNearby() async {
    if (_scanningNearby) return;
    setState(() => _scanningNearby = true);
    final discover = widget.discoverCameras ?? _defaultDiscover;
    List<DiscoveredCamera> cameras;
    try {
      cameras = await discover();
    } catch (_) {
      cameras = const [];
    }
    if (!mounted) return;
    setState(() {
      _nearby = {for (final c in cameras) c.deviceId};
      _scanningNearby = false;
    });
  }

  // --- Session lifecycle ---

  Future<void> _connectToCamera(TrustedDevice camera) async {
    if (_joining || _inRoom) return;
    await _startSession(
      ParentSession(cameraDeviceId: camera.deviceId),
      _trustedRoomId,
      camera.name,
    );
  }

  Future<void> _join() async {
    final code = _codeController.text.trim().toUpperCase();
    if (code.length != 6 || _joining || _inRoom) return;
    await _startSession(ParentSession(), code, 'Room $code');
  }

  Future<void> _startSession(
    ParentSession session,
    String roomId,
    String label,
  ) async {
    setState(() => _joining = true);
    // Noise alerts must reach a backgrounded parent (AT-09) — ask now, at the
    // moment the user starts monitoring.
    unawaited(NotificationService.instance.requestPermissions());
    if (!_rendererReady) {
      await _renderer.initialize();
      _rendererReady = true;
    }
    _session = session;
    _health = session.healthMonitor.state;
    _transport = 'none';
    _subs.add(session.healthStates.listen(_onHealth));
    _subs.add(session.remoteStreams.listen(_onRemoteStream));
    _subs.add(session.nextRetrySeconds.listen(_onRetryCountdown));
    _subs.add(session.latencies.listen(_onLatency));
    _subs.add(session.noiseAlerts.listen(_onNoiseAlert));
    _subs.add(session.transport.listen(_onTransport));
    _subs.add(session.cameraStates.listen(_onCameraState));
    _subs.add(session.audioLevels.listen(_onAudioLevel));
    _subs.add(session.playbackAudible.listen(_onPlaybackChanged));
    _audible = session.audible;
    await session.join(roomId); // never throws (NTR3)
    if (!mounted) return;
    setState(() {
      _joining = false;
      _inRoom = true;
      _roomLabel = label;
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

  void _onTransport(String transport) {
    if (mounted) setState(() => _transport = transport);
  }

  void _onCameraState(CameraState state) {
    if (mounted) setState(() => _cameraState = state);
  }

  void _onAudioLevel(double level) {
    if (mounted) setState(() => _level = level);
  }

  void _onPlaybackChanged(bool audible) {
    if (mounted) setState(() => _audible = audible);
  }

  // --- What this phone plays (F13) ---

  Future<void> _setListenMode(ListenMode mode) async {
    setState(() => _listenMode = mode);
    await _session?.setListenMode(mode);
    if (_session == null) await SettingsService.instance.setListenMode(mode);
  }

  Future<void> _setVolume(double volume) async {
    setState(() => _volume = volume);
    await _session?.setPlaybackVolume(volume);
  }

  /// Quick toggle in the chrome: filtered ⇆ always-on. "Muted" is deliberately
  /// *not* in the cycle — silencing a baby monitor should take more than one
  /// stray tap on a dark screen; it lives in the control sheet.
  Future<void> _toggleListenMode() => _setListenMode(
        _listenMode == ListenMode.alwaysOn
            ? ListenMode.filtered
            : ListenMode.alwaysOn,
      );

  IconData get _audioIcon => switch (_listenMode) {
        ListenMode.muted => Icons.volume_off,
        ListenMode.alwaysOn => Icons.volume_up,
        ListenMode.filtered =>
          _audible ? Icons.hearing : Icons.filter_list_outlined,
      };

  String get _audioTooltip => switch (_listenMode) {
        ListenMode.muted => 'Muted on this phone',
        ListenMode.alwaysOn => 'Playing everything — tap to filter',
        ListenMode.filtered => _audible
            ? 'Filtered: playing, the room is above the bar'
            : 'Filtered: quiet — tap to hear everything',
      };

  // --- Full screen (F14) ---

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

  void _tapVideo() {
    if (!_fullscreen) return;
    setState(() => _chromeVisible = !_chromeVisible);
    _restartChromeTimer();
  }

  // --- Camera controls (F13/F15) ---

  /// Opens the control sheet. Changes travel to the camera on the `health`
  /// data channel; the camera applies them and broadcasts the result back, so
  /// every parent — and the camera unit itself — stays in sync.
  Future<void> _openCameraControls() {
    final session = _session;
    _restartChromeTimer();
    return showCameraControlsSheet(
      context,
      initialState: _cameraState,
      states: session?.cameraStates,
      levels: session?.audioLevels,
      enabled: session?.canControlCamera ?? false,
      disabledHint: 'Waiting for the camera link — controls will work as soon '
          'as the stream is up.',
      onPreview: (controls) =>
          setState(() => _cameraState = _cameraState.copyWith(controls: controls)),
      onChanged: (controls) => session?.sendCameraControl(controls),
      listenMode: _listenMode,
      playbackVolume: _volume,
      audible: _audible,
      audibleStates: session?.playbackAudible,
      onListenModeChanged: (mode) => unawaited(_setListenMode(mode)),
      onVolumeChanged: (volume) => unawaited(_setVolume(volume)),
    );
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
    _chromeTimer?.cancel();
    _chromeTimer = null;
    if (_fullscreen) unawaited(setImmersive(false));
    if (_rendererReady) _renderer.srcObject = null;
    if (mounted) {
      setState(() {
        _inRoom = false;
        _joining = false;
        _hasVideo = false;
        _health = HealthState.connecting;
        _retrySeconds = null;
        _latencyMs = null;
        _transport = 'none';
        _fullscreen = false;
        _chromeVisible = true;
        _level = 0.0;
        _cameraState = const CameraState(
          controls: CameraControls.defaults,
          capabilities: CameraCapabilities.none,
        );
      });
      unawaited(_refreshNearby());
    }
    if (session != null) await session.leave();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _chromeTimer?.cancel();
    _chromeTimer = null;
    if (_fullscreen) unawaited(setImmersive(false));
    for (final sub in _subs) {
      unawaited(sub.cancel());
    }
    _subs.clear();
    final session = _session;
    _session = null;
    if (session != null) unawaited(session.leave());
    if (_rendererReady) _renderer.srcObject = null;
    unawaited(_renderer.dispose());
    _codeController.dispose();
    super.dispose();
  }

  void _openTrustedDevices() {
    Navigator.of(context)
        .push(
          MaterialPageRoute<void>(
            builder: (_) => const TrustedDevicesScreen(),
          ),
        )
        .then((_) => _refreshNearby());
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
    return _inRoom ? _buildWatch(context) : _buildPicker(context);
  }

  // --- Pre-join: camera picker ---

  Widget _buildPicker(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Parent unit'),
        actions: [
          IconButton(
            icon: const Icon(Icons.devices_outlined),
            tooltip: 'Trusted devices',
            onPressed: _openTrustedDevices,
          ),
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
            padding: const EdgeInsets.all(20),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  StreamBuilder<List<TrustedDevice>>(
                    stream: TrustService.instance.changes,
                    initialData: TrustService.instance.devices,
                    builder: (context, snapshot) {
                      final cameras = (snapshot.data ?? const <TrustedDevice>[])
                          .where((d) => d.role == DeviceRole.camera)
                          .toList();
                      return _buildCameraSection(theme, cameras);
                    },
                  ),
                  const SizedBox(height: 28),
                  _buildCodeSection(theme),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCameraSection(ThemeData theme, List<TrustedDevice> cameras) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Text('Your cameras', style: theme.textTheme.titleMedium),
            const Spacer(),
            IconButton(
              icon: _scanningNearby
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.refresh),
              tooltip: 'Scan for nearby cameras',
              onPressed: _scanningNearby ? null : () => unawaited(_refreshNearby()),
            ),
          ],
        ),
        const SizedBox(height: 4),
        if (cameras.isEmpty)
          _NoCamerasCard(onAdd: _openTrustedDevices)
        else
          ...cameras.map(
            (camera) => Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: _CameraTile(
                camera: camera,
                nearby: _nearby.contains(camera.deviceId),
                enabled: !_joining,
                onTap: () => unawaited(_connectToCamera(camera)),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildCodeSection(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(child: Divider(color: theme.colorScheme.outlineVariant)),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text(
                'Join with a code',
                style: theme.textTheme.labelMedium
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ),
            Expanded(child: Divider(color: theme.colorScheme.outlineVariant)),
          ],
        ),
        const SizedBox(height: 12),
        Text(
          'Enter the 6-character room code shown on the camera phone.',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 16),
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
        const SizedBox(height: 16),
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
    );
  }

  // --- Watching ---

  Widget _buildWatch(BuildContext context) {
    final theme = Theme.of(context);
    final session = _session;
    final alerts = session?.securityAlerts ?? const Stream<String>.empty();
    // In full screen the overlay fades out so nothing sits on the crib view
    // (F14); tapping the picture brings it back.
    final showChrome = !_fullscreen || _chromeVisible;
    return SecurityAlertListener(
      alerts: alerts,
      onDismiss: () => unawaited(_leave()),
      child: Scaffold(
        backgroundColor: Colors.black,
        appBar: _fullscreen
            ? null
            : AppBar(
                title: Text(_roomLabel),
                actions: [
                  _AudioButton(
                    mode: _listenMode,
                    audible: _audible,
                    onPressed: () => unawaited(_toggleListenMode()),
                  ),
                  IconButton(
                    icon: const Icon(Icons.tune),
                    tooltip: 'Camera controls',
                    onPressed: () => unawaited(_openCameraControls()),
                  ),
                  IconButton(
                    icon: const Icon(Icons.fullscreen),
                    tooltip: 'Full screen',
                    onPressed: () => _setFullscreen(true),
                  ),
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
                    tooltip: 'Leave',
                    onPressed: () => unawaited(_leave()),
                  ),
                ],
              ),
        body: GestureDetector(
          onTap: _tapVideo,
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (_hasVideo)
                AdjustableVideoView(
                  renderer: _renderer,
                  brightness: _cameraState.controls.brightness,
                  nightMode: _cameraState.controls.nightMode,
                  // Full screen shows the whole frame — cropping the crib out
                  // of the picture is exactly what you don't want at 3 a.m.
                  objectFit: _fullscreen
                      ? RTCVideoViewObjectFit.RTCVideoViewObjectFitContain
                      : RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
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
              AnimatedOpacity(
                opacity: showChrome ? 1 : 0,
                duration: const Duration(milliseconds: 200),
                child: IgnorePointer(
                  ignoring: !showChrome,
                  child: SafeArea(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Row(
                            children: [
                              HealthBadge(state: _health),
                              const SizedBox(width: 8),
                              if (_transport == 'lan' || _transport == 'cloud')
                                _TransportBadge(transport: _transport),
                              const Spacer(),
                              if (_latencyMs != null)
                                _LatencyChip(ms: _latencyMs!),
                            ],
                          ),
                          // Room level vs the alert bar (F13) — the same view
                          // the camera unit has, so the filter can be tuned
                          // from bed.
                          Padding(
                            padding: const EdgeInsets.only(top: 10),
                            child: SizedBox(
                              width: 168,
                              child: SoundLevelMeter(
                                level: _level,
                                threshold: _cameraState.controls.sound.threshold,
                                height: 8,
                              ),
                            ),
                          ),
                          if (_fullscreen)
                            Padding(
                              padding: const EdgeInsets.only(top: 12),
                              child: Row(
                                children: [
                                  _OverlayButton(
                                    icon: _audioIcon,
                                    tooltip: _audioTooltip,
                                    onPressed: () =>
                                        unawaited(_toggleListenMode()),
                                  ),
                                  const SizedBox(width: 8),
                                  _OverlayButton(
                                    icon: Icons.tune,
                                    tooltip: 'Camera controls',
                                    onPressed: () =>
                                        unawaited(_openCameraControls()),
                                  ),
                                  const SizedBox(width: 8),
                                  _OverlayButton(
                                    icon: Icons.fullscreen_exit,
                                    tooltip: 'Exit full screen',
                                    onPressed: () => _setFullscreen(false),
                                  ),
                                ],
                              ),
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
                ),
              ),
              if (_health == HealthState.frozen) const _FrozenOverlay(),
              if (_health == HealthState.failed)
                _FailedOverlay(
                  onReconnect: () => unawaited(_session?.manualReconnect()),
                ),
              if (_health != HealthState.failed && showChrome)
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
        ),
      ),
    );
  }
}

/// App-bar button showing what this phone is playing (F13) — and, in filtered
/// mode, whether the room is currently over the bar. One tap swaps between
/// filtered and always-on; muting lives in the control sheet.
class _AudioButton extends StatelessWidget {
  const _AudioButton({
    required this.mode,
    required this.audible,
    required this.onPressed,
  });

  final ListenMode mode;
  final bool audible;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final muted = mode == ListenMode.muted;
    return IconButton(
      icon: Icon(switch (mode) {
        ListenMode.muted => Icons.volume_off,
        ListenMode.alwaysOn => Icons.volume_up,
        ListenMode.filtered =>
          audible ? Icons.hearing : Icons.filter_list_outlined,
      }),
      color: muted ? const Color(0xFFF59E0B) : null,
      tooltip: switch (mode) {
        ListenMode.muted => 'Muted on this phone',
        ListenMode.alwaysOn => 'Playing everything — tap to filter',
        ListenMode.filtered => audible
            ? 'Filtered: playing, the room is above the bar'
            : 'Filtered: quiet — tap to hear everything',
      },
      onPressed: onPressed,
    );
  }
}

/// Round translucent icon button for the full-screen video overlay (F14).
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

/// A tappable trusted camera; "nearby" badge when mDNS found it (F11/F12).
class _CameraTile extends StatelessWidget {
  const _CameraTile({
    required this.camera,
    required this.nearby,
    required this.enabled,
    required this.onTap,
  });

  final TrustedDevice camera;
  final bool nearby;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        enabled: enabled,
        onTap: onTap,
        leading: CircleAvatar(
          backgroundColor: theme.colorScheme.surfaceContainerHigh,
          child: Icon(Icons.videocam_outlined,
              color: theme.colorScheme.primary),
        ),
        title: Text(camera.name),
        subtitle: nearby
            ? const _NearbyBadge()
            : Text(
                'Tap to connect',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
        trailing: const Icon(Icons.play_circle_outline),
      ),
    );
  }
}

/// Green "nearby" pill shown on a trusted camera mDNS can see (F11).
class _NearbyBadge extends StatelessWidget {
  const _NearbyBadge();

  static const Color _green = Color(0xFF10B981);

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: const [
        Icon(Icons.wifi, size: 14, color: _green),
        SizedBox(width: 4),
        Text(
          'Nearby',
          style: TextStyle(
            color: _green,
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}

class _NoCamerasCard extends StatelessWidget {
  const _NoCamerasCard({required this.onAdd});

  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            Icon(Icons.videocam_outlined,
                size: 40, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(height: 12),
            Text('No paired cameras', style: theme.textTheme.titleMedium),
            const SizedBox(height: 6),
            Text(
              'Pair a camera once to watch with a single tap — no code, and no '
              'internet needed at home.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 14),
            FilledButton.icon(
              onPressed: onAdd,
              icon: const Icon(Icons.qr_code_scanner),
              label: const Text('Add a camera'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Quiet LAN/cloud transport indicator on the live stream (§7).
class _TransportBadge extends StatelessWidget {
  const _TransportBadge({required this.transport});

  final String transport;

  @override
  Widget build(BuildContext context) {
    final lan = transport == 'lan';
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
          Icon(lan ? Icons.wifi : Icons.cloud_outlined,
              size: 14, color: const Color(0xFF93A1BC)),
          const SizedBox(width: 6),
          Text(
            lan ? 'LAN' : 'CLOUD',
            style: const TextStyle(
              color: Color(0xFF93A1BC),
              fontSize: 12,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.8,
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

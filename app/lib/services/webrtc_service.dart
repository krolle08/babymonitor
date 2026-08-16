/// WebRTC session facades (docs/PROTOCOL.md §2, §4, §5.3, §7, §8, §9).
///
/// [CameraSession]: one `RTCPeerConnection` per joined parent (F8), local
/// capture, `health` data channels, heartbeats, noise monitoring, wakelock. It
/// runs **two signaling transports at once** — the camera-hosted LAN server
/// (golden path, started first per NTR7) and, detached and best-effort, the
/// cloud relay — feeding both into one transport-agnostic message handler. It
/// drives §8.2 camera-side auth (challenge → verify → offer, else NOT_TRUSTED)
/// and the §8.1 pairing ceremony.
///
/// [ParentSession]: single PC answering the camera's offer, health FSM wiring,
/// freeze detection → ice-restart, push-to-talk, auto-rejoin with backoff (F4)
/// over the LAN-first multi-endpoint client (§7). In trusted mode it sends
/// `auth` and verifies the camera's challenge, raising a security alert on a
/// key mismatch (§8.2).
///
/// No UI code lives here; everything is exposed as streams/getters. Failures
/// are swallowed and logged — the services never throw at the UI (NTR3).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../config/app_config.dart';
import '../core/auth_engine.dart';
import '../core/backoff_scheduler.dart';
import '../core/camera_controls.dart';
import '../core/freeze_detector.dart';
import '../core/health_monitor.dart';
import '../core/health_state.dart';
import '../core/heartbeat_tracker.dart';
import '../core/identity.dart';
import '../core/models.dart';
import 'api_client.dart';
import 'crypto_service.dart';
import 'discovery_service.dart';
import 'lan_signaling_server.dart';
import 'noise_monitor.dart';
import 'settings_service.dart';
import 'signaling_client.dart';
import 'sleep_log_service.dart';
import 'trust_service.dart';

/// Cryptographically-strong random bytes for nonces/tokens.
List<int> _secureRandomBytes(int count) {
  final rng = math.Random.secure();
  return List<int>.generate(count, (_) => rng.nextInt(256));
}

/// A noise-gate fire received by a parent (F7). Deduplicated on [tsMs]
/// between the data-channel copy and the signaling fanout copy (§2.3).
class NoiseAlert {
  const NoiseAlert({required this.tsMs, required this.audioLevel});

  /// Camera-side fire time (ms since epoch) — the dedupe key.
  final int tsMs;

  /// Sampled level 0.0–1.0 at fire time.
  final double audioLevel;

  DateTime get at => DateTime.fromMillisecondsSinceEpoch(tsMs);
}

/// A parent toggled push-to-talk (F6) — the camera may show "parent talking".
class TalkEvent {
  const TalkEvent({required this.peerId, required this.on});

  final String peerId;
  final bool on;
}

String _jsonText(Map<String, dynamic> message) => jsonEncode(message);

/// Sends on a data channel, swallowing failures (a dying channel must never
/// take the session down — NTR3).
void _channelSend(RTCDataChannel? channel, Map<String, dynamic> message) {
  if (channel == null ||
      channel.state != RTCDataChannelState.RTCDataChannelOpen) {
    return;
  }
  unawaited(
    channel.send(RTCDataChannelMessage(_jsonText(message))).catchError((e) {
      debugPrint('webrtc_service: data-channel send failed: $e');
    }),
  );
}

Map<String, dynamic>? _decodeChannelMessage(RTCDataChannelMessage message) {
  if (message.isBinary) return null;
  try {
    final decoded = jsonDecode(message.text);
    if (decoded is Map<String, dynamic> && decoded['t'] is String) {
      return decoded;
    }
  } catch (_) {
    // Malformed channel frames are ignored (forward compatibility).
  }
  return null;
}

// ---------------------------------------------------------------------------
// Camera
// ---------------------------------------------------------------------------

/// A way to reach the parents on one transport (LAN server or cloud relay).
/// [send] routes a camera-originated message; [dropPeer] force-disconnects a
/// peer if the transport supports it (LAN only).
class _CameraTransport {
  _CameraTransport({required this.name, required this.send, this.dropPeer});

  final String name; // 'lan' | 'cloud'
  final void Function(Map<String, dynamic> message) send;
  final Future<void> Function(String peerId)? dropPeer;
}

class _CameraPeer {
  _CameraPeer(this.peerId, this.transport);

  final String peerId;
  final _CameraTransport transport;
  RTCPeerConnection? pc;
  RTCDataChannel? channel;

  /// True between `auth-challenge` and a verified `auth-response` (§8.2) — no
  /// offer is sent until the parent is authenticated.
  bool awaitingAuth = false;

  /// The parent's device id once known (from auth), for revocation drops.
  String? deviceId;

  bool get channelOpen =>
      channel?.state == RTCDataChannelState.RTCDataChannelOpen;
}

/// The camera-unit session: capture, one PC per parent, heartbeats, noise.
class CameraSession {
  CameraSession({
    SignalingClient? signaling,
    ApiClient? api,
    SleepLogService? log,
    SettingsService? settings,
    CryptoService? crypto,
    TrustService? trust,
    DiscoveryService? discovery,
    DateTime Function() now = DateTime.now,
  })  : _signaling = signaling ?? SignalingClient(),
        _api = api ?? ApiClient(),
        _log = log,
        _settings = settings,
        _crypto = crypto,
        _trust = trust,
        _discovery = discovery ?? DiscoveryService(),
        _now = now;

  final SignalingClient _signaling;
  final ApiClient _api;
  final SleepLogService? _log;
  final SettingsService? _settings;
  final DiscoveryService _discovery;
  final DateTime Function() _now;

  CryptoService? _crypto;
  TrustService? _trust;
  AuthEngine? _authEngine;
  LanSignalingServer? _lan;
  _CameraTransport? _lanTx;
  _CameraTransport? _cloudTx;

  final Map<String, _CameraPeer> _peers = {};
  final StreamController<String> _warnings =
      StreamController<String>.broadcast();
  final StreamController<TalkEvent> _talk =
      StreamController<TalkEvent>.broadcast();
  final StreamController<int> _parentCount = StreamController<int>.broadcast();

  final StreamController<CameraState> _cameraStates =
      StreamController<CameraState>.broadcast();
  final StreamController<double> _audioLevels =
      StreamController<double>.broadcast();
  final StreamController<bool> _audioGate = StreamController<bool>.broadcast();

  CameraControls _controls = CameraControls.defaults;
  CameraCapabilities _capabilities = CameraCapabilities.none;

  MediaStream? _localStream;
  NoiseMonitor? _noiseMonitor;
  Timer? _hbTimer;
  StreamSubscription<double>? _levelSub;
  StreamSubscription<bool>? _gateSub;
  StreamSubscription<Map<String, dynamic>>? _cloudMsgSub;
  StreamSubscription<bool>? _cloudConnSub;
  StreamSubscription<Map<String, dynamic>>? _lanMsgSub;
  StreamSubscription<List<TrustedDevice>>? _trustSub;
  String? _roomId;
  String? _reclaimToken;
  int _hbSeq = 0;
  bool _started = false;
  bool _sessionLogged = false;

  SettingsService get _prefs => _settings ?? SettingsService.instance;

  /// Non-fatal problems the UI should surface (e.g. wakelock failure, F2).
  Stream<String> get warnings => _warnings.stream;

  /// Push-to-talk on/off events from parents (F6).
  Stream<TalkEvent> get parentTalk => _talk.stream;

  /// Emits the number of joined parents whenever it changes (F8).
  Stream<int> get parentCount => _parentCount.stream;

  /// Image + sound-filter settings, whenever they change from either unit
  /// (F13/F15). The same value is broadcast to every parent.
  Stream<CameraState> get cameraStates => _cameraStates.stream;

  /// Live sampled audio level (0.0–1.0) for the on-camera meter (F13).
  Stream<double> get audioLevels => _audioLevels.stream;

  /// Squelch transitions (F13) — what the parents are hearing right now.
  Stream<bool> get audioGate => _audioGate.stream;

  /// Whether the room currently passes the filter.
  bool get audioGateOpen => _noiseMonitor?.gateOpen ?? false;

  /// Current image + sound-filter settings.
  CameraControls get controls => _controls;

  /// What this camera's hardware supports (torch, …).
  CameraCapabilities get capabilities => _capabilities;

  CameraState get cameraState => CameraState(
        controls: _controls,
        capabilities: _capabilities,
        gateOpen: _noiseMonitor?.gateOpen ?? false,
      );

  /// The 6-char cloud room code once `room-created` arrives (null on pure LAN).
  String? get roomId => _roomId;

  /// Local capture stream, for an on-screen preview.
  MediaStream? get localStream => _localStream;

  int get joinedParents => _peers.length;

  /// Whether pairing mode is active (§8.1).
  bool get pairingActive => _lan?.pairingActive ?? false;

  /// Starts capture, wakelock, the LAN signaling endpoint and monitoring, then
  /// registers with the cloud in a detached best-effort task (NTR7 order:
  /// media → wakelock → LAN + advertise → cloud). Never throws for recoverable
  /// problems — those surface on [warnings]. Media/permission failures DO
  /// throw: without a camera there is no session.
  Future<void> start() async {
    if (_started) return;
    _started = true;

    // 0. Saved image + sound-filter settings (F13/F15) drive the capture
    //    profile below, so night mode is already on at the first frame.
    _controls = _prefs.cameraControls;

    // 1. Capture: back camera, 640x480 at the profile's frame rate — stays
    //    within the TR5 camera-device CPU budget; audio processing on for
    //    talk-back (F6).
    _localStream = await navigator.mediaDevices.getUserMedia({
      'audio': {
        'echoCancellation': true,
        'noiseSuppression': true,
        'autoGainControl': true,
      },
      'video': _videoConstraints(night: _controls.nightMode),
    });
    await _refreshCapabilities();
    await _applyExposurePoint(); // a saved metering point survives a restart

    // 2. Wakelock (F2) — failure is surfaced, not fatal.
    try {
      await WakelockPlus.enable();
      final enabled = await WakelockPlus.enabled;
      if (!enabled) {
        _warn('Could not keep the screen awake — the stream may stop when '
            'the screen locks. Keep the device plugged in and unlocked.');
      }
    } catch (e) {
      debugPrint('CameraSession: wakelock failed: $e');
      _warn('Could not keep the screen awake — the stream may stop when '
          'the screen locks. Keep the device plugged in and unlocked.');
    }

    // 3. Golden path, all local: LAN signaling endpoint + mDNS advertise. The
    //    camera is now fully watchable at home even with the internet down.
    await _startLan();

    // 4. Heartbeats to every parent (F3, §4).
    _hbTimer =
        Timer.periodic(AppConfig.heartbeatInterval, (_) => _sendHeartbeat());

    // 5. Noise monitoring (F7/F13) — NoiseGate inside NoiseMonitor is the
    //    single decision point; the filter follows settings live, from this
    //    unit or from any watching parent.
    final monitor = NoiseMonitor(
      sampleLevel: _sampleAudioLevel,
      filter: _controls.sound,
      onNoise: _onNoise,
      now: _now,
    );
    _noiseMonitor = monitor;
    _levelSub = monitor.levels.listen((level) {
      if (!_audioLevels.isClosed) _audioLevels.add(level);
    });
    // The squelch (F13): tell every parent the moment the room becomes worth
    // listening to, and the moment it stops being.
    _gateSub = monitor.gateStates.listen(_onGateChanged);
    monitor.start();
    _emitCameraState();

    // 6. In parallel, detached: cloud registration for remote viewers. Never
    //    awaited by start() — a cloud outage must not delay the golden path.
    _startCloudDetached();
  }

  Future<void> _startLan() async {
    try {
      final crypto = _crypto ??= CryptoService.instance;
      final trust = _trust ??= TrustService.instance;
      final engine = _authEngine = AuthEngine(
        sign: crypto.signer,
        verify: crypto.verifier,
        randomBytes: _secureRandomBytes,
        identity: crypto.identity(_prefs.deviceName),
      );
      final lan = LanSignalingServer(authEngine: engine, trust: trust)
        ..allowCodeJoins = _prefs.allowCodeJoins
        ..roomCode = _roomId;
      final tx = _lanTx = _CameraTransport(
        name: 'lan',
        send: lan.send,
        dropPeer: lan.dropPeer,
      );
      _lanMsgSub = lan.messages.listen((m) => _onSignal(m, tx));
      await lan.start();
      _lan = lan;
      // Revoked devices are dropped on the next auth and, if live, right away.
      _trustSub = trust.changes.listen((_) => _enforceTrust());

      // Advertise the LAN endpoint via mDNS (§7).
      final port = lan.port;
      if (port != null) {
        await _discovery.advertise(
          deviceId: crypto.deviceId,
          name: _prefs.deviceName,
          port: port,
        );
      }
    } catch (e) {
      // The camera still streams to cloud viewers; log and continue (NTR7:
      // one degraded capability, never a golden-path failure).
      debugPrint('CameraSession: LAN endpoint start failed: $e');
      _warn('Local network monitoring is unavailable on this device. '
          'Parents on the same WiFi may need the internet to connect.');
    }
  }

  void _startCloudDetached() {
    final tx = _cloudTx = _CameraTransport(name: 'cloud', send: _signaling.send);
    _cloudMsgSub = _signaling.messages.listen((m) => _onSignal(m, tx));
    _cloudConnSub = _signaling.connected.listen((up) {
      if (up) _sendCreateRoom(); // re-sent on every reconnect (server forgets)
    });
    // Detached: never awaited by start(); its own backoff drives retries.
    unawaited(_signaling.connect());
  }

  // --- Camera image + sound controls (F13/F15) ---

  Map<String, dynamic> _videoConstraints({required bool night}) {
    final cameraId = _controls.cameraId;
    return {
      // An explicit lens wins; otherwise the rear camera, which is the one
      // pointed at the crib in every normal setup (F15).
      if (cameraId != null && cameraId.isNotEmpty)
        'deviceId': cameraId
      else
        'facingMode': 'environment',
      'width': {'ideal': 640},
      'height': {'ideal': 480},
      // A lower frame rate lets the sensor expose each frame for longer,
      // which is what actually makes a dark nursery visible (F15).
      'frameRate': {
        'ideal': night
            ? _controls.nightFrameRate.clamp(
                AppConfig.minNightFrameRate, AppConfig.maxNightFrameRate)
            : AppConfig.captureFrameRate,
      },
    };
  }

  MediaStreamTrack? get _videoTrack {
    final tracks = _localStream?.getVideoTracks();
    if (tracks == null || tracks.isEmpty) return null;
    return tracks.first;
  }

  /// Re-reads what the current capture track supports (torch) and which lenses
  /// this phone has. Failures leave the capability off — the UI then greys the
  /// control out instead of lying about it.
  Future<void> _refreshCapabilities() async {
    var torch = false;
    try {
      final track = _videoTrack;
      if (track != null) torch = await track.hasTorch();
    } catch (e) {
      debugPrint('CameraSession: hasTorch() failed: $e');
    }
    var cameras = _capabilities.cameras;
    try {
      // Only meaningful after getUserMedia has run once (the platform hides
      // labels until camera permission is granted).
      final devices = await navigator.mediaDevices.enumerateDevices();
      cameras = [
        for (final device in devices)
          if (device.kind == 'videoinput')
            CameraOption(
              deviceId: device.deviceId,
              label: device.label,
              facing: CameraOption.facingFromLabel(device.label),
            ),
      ];
    } catch (e) {
      debugPrint('CameraSession: enumerateDevices() failed: $e');
    }
    _capabilities = CameraCapabilities(torch: torch, cameras: cameras);
  }

  /// Applies image + sound settings live, from this unit or from a parent
  /// (F13/F15), persists them and tells every parent the new state. Never
  /// throws: a control that the hardware refuses is logged and reverted in the
  /// broadcast state, the stream is untouched (NTR3).
  Future<void> applyControls(CameraControls next) async {
    final previous = _controls;
    _controls = next;

    if (next.sound != previous.sound) {
      _noiseMonitor?.applyFilter(next.sound);
    }
    // Anything that changes the capture format needs a new track: a different
    // lens, night mode on or off, or a new night frame rate while night mode
    // is running.
    final recaptured = next.cameraId != previous.cameraId ||
        next.nightMode != previous.nightMode ||
        (next.nightMode && next.nightFrameRate != previous.nightFrameRate);
    if (recaptured) await _recaptureVideo(previous);
    if (next.light != previous.light || (recaptured && next.light)) {
      await _applyTorch(next.light);
    }
    if (next.exposurePoint != previous.exposurePoint || recaptured) {
      await _applyExposurePoint();
    }

    unawaited(_prefs.setCameraControls(_controls));
    _emitCameraState();
  }

  /// Applies a partial `camera-control` patch (§4) — used by the data-channel
  /// handler and by the UI sheets.
  Future<void> applyControlPatch(Map<String, dynamic> patch) =>
      applyControls(_controls.patch(patch));

  /// Points the auto-exposure at the crib, or hands metering back to the
  /// camera when there is no point set (F15). Unsupported hardware just logs —
  /// the picture is unchanged, which is the safe outcome.
  Future<void> _applyExposurePoint() async {
    final track = _videoTrack;
    if (track == null) return;
    final point = _controls.exposurePoint;
    try {
      // Deliberately *not* CameraExposureMode.locked: locking freezes the
      // current exposure, which would ignore the region we just set. What we
      // want is auto-exposure that meters here — the region, not a lock.
      await Helper.setExposurePoint(
        track,
        point == null ? null : math.Point<double>(point.x, point.y),
      );
    } catch (e) {
      debugPrint('CameraSession: setExposurePoint failed: $e');
    }
  }

  Future<void> _applyTorch(bool on) async {
    final track = _videoTrack;
    if (track == null) return;
    if (on && !_capabilities.torch) {
      _controls = _controls.copyWith(light: false);
      return;
    }
    try {
      await track.setTorch(on);
    } catch (e) {
      debugPrint('CameraSession: setTorch($on) failed: $e');
      _controls = _controls.copyWith(light: false);
      _capabilities = const CameraCapabilities(torch: false);
    }
  }

  /// Swaps the capture track for one matching the current lens + night-mode
  /// profile and hands it to every parent's sender. The old track is stopped
  /// first: most phones will not open a second capture session on the same
  /// camera.
  ///
  /// If the new settings cannot be captured — a lens that will not open, a
  /// frame rate the sensor refuses — it falls back to [previous] rather than
  /// leaving the crib dark.
  Future<void> _recaptureVideo(CameraControls previous) async {
    final stream = _localStream;
    if (stream == null) return;
    final old = stream.getVideoTracks();
    for (final track in old) {
      try {
        await track.stop();
        await stream.removeTrack(track);
      } catch (e) {
        debugPrint('CameraSession: releasing old capture track failed: $e');
      }
    }
    MediaStreamTrack? fresh;
    try {
      fresh = await _captureVideoTrack(night: _controls.nightMode);
    } catch (e) {
      debugPrint('CameraSession: recapture failed: $e');
    }
    if (fresh == null && _controls != previous) {
      _controls = previous; // back to what was demonstrably working
      try {
        fresh = await _captureVideoTrack(night: previous.nightMode);
      } catch (e) {
        debugPrint('CameraSession: fallback recapture failed: $e');
      }
    }
    if (fresh == null) {
      _warn('The camera could not be restarted after that change. '
          'Stop and start monitoring to get the picture back.');
      return;
    }
    final track = fresh;
    await stream.addTrack(track);
    for (final peer in _peers.values) {
      final pc = peer.pc;
      if (pc == null) continue;
      try {
        for (final sender in await pc.getSenders()) {
          if (sender.track?.kind == 'video') await sender.replaceTrack(track);
        }
      } catch (e) {
        debugPrint('CameraSession: replaceTrack(${peer.peerId}) failed: $e');
      }
    }
    await _refreshCapabilities(); // torch belongs to the new track
  }

  Future<MediaStreamTrack?> _captureVideoTrack({required bool night}) async {
    final captured = await navigator.mediaDevices.getUserMedia({
      'audio': false,
      'video': _videoConstraints(night: night),
    });
    final tracks = captured.getVideoTracks();
    return tracks.isEmpty ? null : tracks.first;
  }

  /// The squelch opened or closed (F13): every parent is told at once so what
  /// the filter ignores is never played, and the tail of a real event is.
  /// Sent on the data channel *and* stamped into every heartbeat, so a parent
  /// that missed the edge resyncs within one heartbeat.
  void _onGateChanged(bool open) {
    if (!_audioGate.isClosed) _audioGate.add(open);
    final message = {
      't': 'audio-gate',
      'open': open,
      'ts': _now().millisecondsSinceEpoch,
    };
    for (final peer in _peers.values) {
      _channelSend(peer.channel, message);
    }
  }

  /// Publishes the current state locally (camera UI) and to every parent that
  /// has an open `health` channel (§4).
  void _emitCameraState() {
    final state = cameraState;
    if (!_cameraStates.isClosed) _cameraStates.add(state);
    final message = {'t': 'camera-state', ...state.toJson()};
    for (final peer in _peers.values) {
      _channelSend(peer.channel, message);
    }
  }

  // --- Pairing (§8.1) ---

  /// Enters pairing mode and returns the QR payload string to display, or null
  /// if the LAN endpoint is unavailable. The token is valid 5 minutes (§8.1).
  Future<String?> startPairing() async {
    final lan = _lan;
    final engine = _authEngine;
    final crypto = _crypto;
    if (lan == null || engine == null || crypto == null) return null;
    final token = engine.issuePairingToken();
    lan.pairingActive = true;
    final addrs = await lan.localAddresses();
    final payload = PairingPayload(
      deviceId: crypto.deviceId,
      name: _prefs.deviceName,
      pk: crypto.publicKeyBase64,
      port: lan.port ?? kLanSignalingPort,
      addrs: addrs,
      token: token,
    );
    return payload.serialize();
  }

  /// Leaves pairing mode and invalidates any outstanding token.
  Future<void> stopPairing() async {
    _authEngine?.clearPairingTokens();
    _lan?.pairingActive = false;
  }

  void _sendCreateRoom() {
    final roomId = _roomId ?? _prefs.lastRoomId;
    final token = _reclaimToken ?? _prefs.reclaimToken;
    if (roomId != null && token != null) {
      _signaling.send(
          {'type': 'create-room', 'roomId': roomId, 'reclaimToken': token});
    } else {
      _signaling.send({'type': 'create-room'});
    }
  }

  void _onSignal(Map<String, dynamic> msg, _CameraTransport transport) {
    try {
      switch (msg['type']) {
        case 'room-created':
          _onRoomCreated(msg);
        case 'peer-joined':
          _onPeerJoined(msg, transport);
        case 'peer-left':
          final peerId = msg['peerId'];
          if (peerId is String) unawaited(_disposePeer(peerId));
        case 'auth-response':
          unawaited(_onAuthResponse(msg));
        case 'answer':
          unawaited(_onAnswer(msg));
        case 'ice':
          unawaited(_onRemoteIce(msg));
        case 'ice-restart':
          final peerId = msg['peerId'];
          if (peerId is String) unawaited(_restartIce(peerId));
        case 'error':
          _onSignalError(msg);
        default:
          break; // unknown types ignored (§2, forward compatibility)
      }
    } catch (e) {
      debugPrint('CameraSession: signal ${msg['type']} failed: $e');
    }
  }

  void _onRoomCreated(Map<String, dynamic> msg) {
    final roomId = msg['roomId'];
    final token = msg['reclaimToken'];
    if (roomId is! String || token is! String) return;
    _roomId = roomId;
    _reclaimToken = token;
    _lan?.roomCode = roomId; // enable guest code-joins on LAN too (§7)
    unawaited(_prefs.setCameraRoom(roomId, token));
    if (!_sessionLogged) {
      _sessionLogged = true;
      _log?.logSessionStart(roomId); // fire-and-forget (F9)
    } else {
      // Reclaim after a signaling drop — that's a reconnect worth logging.
      _log?.logEvent(SleepEvent(
          type: 'reconnect', at: _now(), data: {'reason': 'room-reclaimed'}));
    }
  }

  void _onSignalError(Map<String, dynamic> msg) {
    final code = msg['code'];
    debugPrint('CameraSession: signaling error $code: ${msg['message']}');
    if (code == 'BAD_RECLAIM') {
      // Old room is gone (grace period expired) — start a fresh one.
      _roomId = null;
      _reclaimToken = null;
      _lan?.roomCode = null;
      unawaited(_prefs.clearCameraRoom());
      _warn('Previous room expired — a new room code was created. '
          'Parents must join with the new code.');
      _signaling.send({'type': 'create-room'});
    }
  }

  void _onPeerJoined(Map<String, dynamic> msg, _CameraTransport transport) {
    final peerId = msg['peerId'];
    if (peerId is! String) return;
    // Rejoin/reclaim: drop any stale PC for this parent first (§2.1). The map
    // removal inside _disposePeer is synchronous, so the fresh peer below wins.
    if (_peers.containsKey(peerId)) unawaited(_disposePeer(peerId));
    final peer = _CameraPeer(peerId, transport);
    _peers[peerId] = peer;
    _emitParentCount();

    final auth = msg['auth'];
    if (auth is Map<String, dynamic>) {
      // Trusted-device path (§8.2): challenge before any offer.
      unawaited(_challengePeer(peer, ParentJoinAuth.fromJson(auth)));
    } else if (_prefs.allowCodeJoins) {
      // Guest bootstrap (§8.2 bottom): the room code was the authorization.
      unawaited(_startOffer(peerId));
    } else {
      transport.send({
        'type': 'error',
        'code': 'NOT_TRUSTED',
        'peerId': peerId,
        'message': 'Pair this device to watch',
      });
      unawaited(_disposePeer(peerId));
    }
  }

  Future<void> _challengePeer(_CameraPeer peer, ParentJoinAuth parentAuth) async {
    final engine = _authEngine;
    if (engine == null) {
      // No keypair available — cannot authenticate a trusted join.
      peer.transport.send({
        'type': 'error',
        'code': 'NOT_TRUSTED',
        'peerId': peer.peerId,
        'message': 'Authentication unavailable',
      });
      await _disposePeer(peer.peerId);
      return;
    }
    peer.awaitingAuth = true;
    try {
      final challenge =
          await engine.buildChallenge(parentAuth: parentAuth, peerId: peer.peerId);
      if (_peers[peer.peerId] != peer) return; // left mid-handshake
      peer.transport.send({'type': 'auth-challenge', ...challenge.toJson()});
    } catch (e) {
      debugPrint('CameraSession: buildChallenge(${peer.peerId}) failed: $e');
    }
  }

  Future<void> _onAuthResponse(Map<String, dynamic> msg) async {
    final peerId = msg['peerId'];
    final deviceId = msg['deviceId'];
    final pk = msg['pk'];
    final sig = msg['sig'];
    if (peerId is! String ||
        deviceId is! String ||
        pk is! String ||
        sig is! String) {
      return;
    }
    final peer = _peers[peerId];
    final engine = _authEngine;
    if (peer == null || engine == null || !peer.awaitingAuth) return;
    final nonce = engine.issuedNonceFor(peerId);
    if (nonce == null) {
      await _rejectPeer(peer, 'stale challenge');
      return;
    }
    final verdict = await engine.verifyAuthResponse(
      response:
          AuthResponse(peerId: peerId, deviceId: deviceId, pk: pk, sig: sig),
      nonceIssued: nonce,
      trustedPkLookup: (id) => _trust?.trustedPk(id),
    );
    if (_peers[peerId] != peer) return; // left mid-verify
    if (verdict == AuthVerdict.authenticated) {
      peer.awaitingAuth = false;
      peer.deviceId = deviceId;
      await _startOffer(peerId);
    } else {
      debugPrint('CameraSession: auth failed for $peerId: $verdict');
      await _rejectPeer(peer, 'not a trusted device');
    }
  }

  Future<void> _rejectPeer(_CameraPeer peer, String message) async {
    peer.transport.send({
      'type': 'error',
      'code': 'NOT_TRUSTED',
      'peerId': peer.peerId,
      'message': message,
    });
    await _disposePeer(peer.peerId);
  }

  Future<void> _startOffer(String peerId) async {
    final peer = _peers[peerId];
    if (peer == null) return;
    try {
      // LAN peers share a subnet: host candidates suffice, so skip the
      // ICE-config fetch entirely (NTR7). Cloud peers may need STUN/TURN.
      final iceServers = peer.transport.name == 'lan'
          ? const <Map<String, dynamic>>[]
          : await _api.fetchIceConfig();
      final pc = await createPeerConnection({'iceServers': iceServers});
      if (_peers[peerId] != peer) {
        // Peer left (or rejoined) while we were setting up.
        await pc.dispose();
        return;
      }
      peer.pc = pc;

      pc.onIceCandidate = (candidate) {
        if (candidate.candidate == null) return;
        peer.transport.send({
          'type': 'ice',
          'peerId': peerId,
          'candidate': {
            'candidate': candidate.candidate,
            'sdpMid': candidate.sdpMid,
            'sdpMLineIndex': candidate.sdpMLineIndex,
          },
        });
      };
      pc.onConnectionState = (state) {
        debugPrint('CameraSession: peer $peerId -> $state');
      };
      // Parent talk-back audio (F6): play it as soon as it arrives. On
      // mobile, a live remote audio track is routed to the output
      // automatically; we just make sure it is enabled.
      pc.onTrack = (event) {
        if (event.track.kind == 'audio') {
          event.track.enabled = true;
        }
      };

      final stream = _localStream;
      if (stream == null) return; // stopped concurrently
      for (final track in stream.getTracks()) {
        await pc.addTrack(track, stream);
      }
      // Dedicated receive-only slot for the parent's push-to-talk mic (F6).
      await pc.addTransceiver(
        kind: RTCRtpMediaType.RTCRtpMediaTypeAudio,
        init: RTCRtpTransceiverInit(direction: TransceiverDirection.RecvOnly),
      );

      // Health channel: ordered + reliable (§4 — defaults give reliability).
      final channel = await pc.createDataChannel(
          'health', RTCDataChannelInit()..ordered = true);
      peer.channel = channel;
      channel.onMessage = (message) => _onChannelMessage(peerId, message);
      // Tell the parent what the camera is set to as soon as it can hear us
      // (F15) — it renders with the same brightness/night curve.
      channel.onDataChannelState = (state) {
        if (state == RTCDataChannelState.RTCDataChannelOpen) {
          _channelSend(channel, {'t': 'camera-state', ...cameraState.toJson()});
        }
      };

      final offer = await pc.createOffer();
      await pc.setLocalDescription(offer);
      peer.transport.send({
        'type': 'offer',
        'peerId': peerId,
        'sdp': offer.sdp,
        'sdpType': 'offer',
      });
    } catch (e) {
      debugPrint('CameraSession: starting offer for $peerId failed: $e');
    }
  }

  Future<void> _onAnswer(Map<String, dynamic> msg) async {
    final peerId = msg['peerId'];
    final sdp = msg['sdp'];
    if (peerId is! String || sdp is! String) return;
    final pc = _peers[peerId]?.pc;
    if (pc == null) return;
    try {
      await pc.setRemoteDescription(RTCSessionDescription(sdp, 'answer'));
    } catch (e) {
      debugPrint('CameraSession: setRemoteDescription($peerId) failed: $e');
    }
  }

  Future<void> _onRemoteIce(Map<String, dynamic> msg) async {
    final peerId = msg['peerId'];
    final candidate = msg['candidate'];
    if (peerId is! String || candidate is! Map) return;
    final pc = _peers[peerId]?.pc;
    if (pc == null) return;
    try {
      await pc.addCandidate(RTCIceCandidate(
        candidate['candidate'] as String?,
        candidate['sdpMid'] as String?,
        (candidate['sdpMLineIndex'] as num?)?.toInt(),
      ));
    } catch (e) {
      debugPrint('CameraSession: addCandidate($peerId) failed: $e');
    }
  }

  /// Parent detected FROZEN (F5) — ICE restart + new offer for that peer.
  Future<void> _restartIce(String peerId) async {
    final peer = _peers[peerId];
    final pc = peer?.pc;
    if (peer == null || pc == null) return;
    _log?.logEvent(
        SleepEvent(type: 'freeze', at: _now(), data: {'peerId': peerId}));
    try {
      final offer = await pc.createOffer({'iceRestart': true});
      await pc.setLocalDescription(offer);
      peer.transport.send({
        'type': 'offer',
        'peerId': peerId,
        'sdp': offer.sdp,
        'sdpType': 'offer',
      });
      _log?.logEvent(SleepEvent(
          type: 'reconnect',
          at: _now(),
          data: {'peerId': peerId, 'reason': 'ice-restart'}));
    } catch (e) {
      debugPrint('CameraSession: ICE restart for $peerId failed: $e');
    }
  }

  void _onChannelMessage(String peerId, RTCDataChannelMessage message) {
    final msg = _decodeChannelMessage(message);
    if (msg == null) return;
    switch (msg['t']) {
      case 'talk':
        if (msg['on'] is bool && !_talk.isClosed) {
          _talk.add(TalkEvent(peerId: peerId, on: msg['on'] as bool));
        }
      case 'camera-control':
        // A parent turned a knob (F13/F15). Applying it re-broadcasts the
        // state to every parent, so all units stay in sync.
        final patch = msg['controls'];
        if (patch is Map<String, dynamic>) {
          unawaited(applyControlPatch(patch));
        }
      case 'get-camera-state':
        _channelSend(
            _peers[peerId]?.channel, {'t': 'camera-state', ...cameraState.toJson()});
      default:
        break; // unknown types ignored (§4, forward compatibility)
    }
  }

  void _sendHeartbeat() {
    _hbSeq++;
    final ts = _now().millisecondsSinceEpoch;
    final level = _noiseMonitor?.lastLevel ?? 0.0;
    final gateOpen = _noiseMonitor?.gateOpen ?? false;
    final channelMsg = {
      't': 'hb',
      'seq': _hbSeq,
      'ts': ts,
      'audioLevel': level,
      'gateOpen': gateOpen,
    };
    // §2.3: fall back to signaling relay per transport whose peers lack an open
    // data channel (each transport fans out to its own parents).
    final fallbackTx = <String, _CameraTransport>{};
    for (final peer in _peers.values) {
      if (peer.channelOpen) {
        _channelSend(peer.channel, channelMsg);
      } else {
        fallbackTx[peer.transport.name] = peer.transport;
      }
    }
    if (fallbackTx.isNotEmpty) {
      final sigMsg = {
        'type': 'hb',
        'seq': _hbSeq,
        'ts': ts,
        'audioLevel': level,
        'gateOpen': gateOpen,
      };
      for (final tx in fallbackTx.values) {
        tx.send(sigMsg);
      }
    }
  }

  /// Outbound audio level from `getStats()` media-source (0.0 fallback).
  Future<double> _sampleAudioLevel() async {
    for (final peer in _peers.values) {
      final pc = peer.pc;
      if (pc == null) continue;
      try {
        final stats = await pc.getStats();
        for (final report in stats) {
          if (report.type != 'media-source') continue;
          final kind = report.values['kind'] ?? report.values['mediaType'];
          if (kind != 'audio') continue;
          final level = report.values['audioLevel'];
          if (level is num) return level.toDouble();
        }
      } catch (_) {
        // Try the next peer.
      }
    }
    return 0.0; // no connected peer / no stats yet
  }

  /// Noise gate fired (F7): alert every parent on both paths + log it.
  void _onNoise(double level) {
    final ts = _now().millisecondsSinceEpoch;
    final channelMsg = {'t': 'noise', 'ts': ts, 'audioLevel': level};
    for (final peer in _peers.values) {
      _channelSend(peer.channel, channelMsg);
    }
    // Always also via signaling (§2.3) on every transport — parents dedupe on ts.
    final sigMsg = {'type': 'noise', 'ts': ts, 'audioLevel': level};
    _lanTx?.send(sigMsg);
    _cloudTx?.send(sigMsg);
    _log?.logEvent(
        SleepEvent(type: 'noise', at: _now(), data: {'audioLevel': level}));
  }

  /// Drops any live peer whose device was revoked from the trust store (F12).
  void _enforceTrust() {
    final trust = _trust;
    if (trust == null) return;
    for (final peer in _peers.values.toList()) {
      final deviceId = peer.deviceId;
      if (deviceId != null && !trust.isTrusted(deviceId)) {
        final drop = peer.transport.dropPeer;
        if (drop != null) {
          unawaited(drop(peer.peerId));
        } else {
          peer.transport.send({
            'type': 'error',
            'code': 'NOT_TRUSTED',
            'peerId': peer.peerId,
            'message': 'This device was removed',
          });
        }
        unawaited(_disposePeer(peer.peerId));
      }
    }
  }

  Future<void> _disposePeer(String peerId) async {
    final peer = _peers.remove(peerId);
    if (peer == null) return;
    _authEngine?.forgetPeer(peerId);
    _emitParentCount();
    try {
      await peer.channel?.close();
    } catch (_) {}
    try {
      await peer.pc?.close();
      await peer.pc?.dispose();
    } catch (_) {}
  }

  /// Ends the session: leaves the room, releases every resource (F2 AC:
  /// wakelock released cleanly) and closes the sleep-log session.
  Future<void> stop() async {
    if (!_started) return;
    _started = false;

    _hbTimer?.cancel();
    _hbTimer = null;
    await _levelSub?.cancel();
    _levelSub = null;
    await _gateSub?.cancel();
    _gateSub = null;
    final monitor = _noiseMonitor;
    _noiseMonitor = null;
    await monitor?.dispose();

    // Never leave the torch burning over a stopped session (F15).
    if (_controls.light) {
      _controls = _controls.copyWith(light: false);
      await _applyTorch(false);
    }

    _log?.logSessionEnd();

    await stopPairing();
    await _trustSub?.cancel();
    _trustSub = null;

    // LAN transport teardown (golden path).
    await _lanMsgSub?.cancel();
    _lanMsgSub = null;
    await _discovery.stopAdvertising();
    await _lan?.stop();
    _lan = null;
    _lanTx = null;

    // Cloud transport teardown.
    _signaling.send({'type': 'leave'});
    await _cloudMsgSub?.cancel();
    _cloudMsgSub = null;
    await _cloudConnSub?.cancel();
    _cloudConnSub = null;
    _cloudTx = null;
    await _signaling.close();

    for (final peerId in _peers.keys.toList()) {
      await _disposePeer(peerId);
    }

    final stream = _localStream;
    _localStream = null;
    if (stream != null) {
      try {
        for (final track in stream.getTracks()) {
          await track.stop();
        }
        await stream.dispose();
      } catch (e) {
        debugPrint('CameraSession: releasing media failed: $e');
      }
    }

    try {
      await WakelockPlus.disable();
    } catch (e) {
      debugPrint('CameraSession: wakelock release failed: $e');
    }

    await _prefs.clearCameraRoom();
    _roomId = null;
    _reclaimToken = null;
    _authEngine = null;
    _sessionLogged = false;
    _hbSeq = 0;
  }

  /// [stop] plus stream-controller teardown. The session is unusable after.
  Future<void> dispose() async {
    await stop();
    await _discovery.dispose();
    await _warnings.close();
    await _talk.close();
    await _parentCount.close();
    await _cameraStates.close();
    await _audioLevels.close();
    await _audioGate.close();
  }

  void _warn(String message) {
    debugPrint('CameraSession: $message');
    if (!_warnings.isClosed) _warnings.add(message);
  }

  void _emitParentCount() {
    if (!_parentCount.isClosed) _parentCount.add(_peers.length);
  }
}

// ---------------------------------------------------------------------------
// Parent
// ---------------------------------------------------------------------------

/// The parent-unit session: watches one camera room.
class ParentSession {
  ParentSession({
    SignalingClient? signaling,
    ApiClient? api,
    SettingsService? settings,
    CryptoService? crypto,
    TrustService? trust,
    DiscoveryService? discovery,
    String? cameraDeviceId,
    HealthMonitor? healthMonitor,
    BackoffScheduler? backoff,
    DateTime Function() now = DateTime.now,
  })  : _api = api ?? ApiClient(),
        _settings = settings,
        _crypto = crypto,
        _trust = trust,
        _discovery = discovery ?? DiscoveryService(),
        _cameraDeviceId = cameraDeviceId,
        _backoff = backoff ?? BackoffScheduler(),
        _now = now,
        healthMonitor = healthMonitor ?? HealthMonitor(now: now) {
    _signaling = signaling ??
        SignalingClient(
          lanCandidates: _lanCandidates,
          discoverLan: _discoverLanUrls,
        );
    _freezeDetector = FreezeDetector(
      onFrozen: _onFrozen,
      onRecovered: _onFreezeRecovered,
    );
    _healthSub = this.healthMonitor.states.listen((state) {
      // Missed heartbeats drove the FSM to RECONNECTING (F3/F4): start the
      // rejoin loop (debounced inside _startReconnect).
      if (state == HealthState.reconnecting) {
        _startReconnect('missed-heartbeats');
      }
    });
  }

  late final SignalingClient _signaling;
  final ApiClient _api;
  final SettingsService? _settings;
  final DiscoveryService _discovery;
  final String? _cameraDeviceId;
  final BackoffScheduler _backoff;
  final DateTime Function() _now;

  CryptoService? _crypto;
  TrustService? _trust;
  AuthEngine? _authEngine;
  String? _myNonce;
  bool _securityAlerted = false;

  /// The F3 FSM. Bind its [HealthMonitor.states] to the UI.
  final HealthMonitor healthMonitor;

  /// Last-seen heartbeat bookkeeping (seq + arrival time).
  final HeartbeatTracker heartbeatTracker = HeartbeatTracker();

  late final FreezeDetector _freezeDetector;
  StreamSubscription<HealthState>? _healthSub;

  final StreamController<MediaStream> _remoteStreams =
      StreamController<MediaStream>.broadcast();
  final StreamController<NoiseAlert> _noiseAlerts =
      StreamController<NoiseAlert>.broadcast();
  final StreamController<int> _retryCountdown = StreamController<int>.broadcast();
  final StreamController<int> _latencies = StreamController<int>.broadcast();
  final StreamController<String> _securityAlerts =
      StreamController<String>.broadcast();
  final StreamController<CameraState> _cameraStates =
      StreamController<CameraState>.broadcast();
  final StreamController<double> _audioLevels =
      StreamController<double>.broadcast();
  final StreamController<bool> _playback = StreamController<bool>.broadcast();
  final Set<int> _seenNoiseTs = <int>{};

  CameraState? _cameraState;

  /// What this phone does with the camera's audio (F13). Local to the device:
  /// one parent can filter while the other listens to everything.
  late ListenMode _listenMode = _prefs.listenMode;

  /// Last squelch state the camera reported, and when it said so. Unknown or
  /// stale means *audible* — a parent must never go silently deaf (NTR1).
  bool _gateOpen = true;
  DateTime? _gateAt;
  bool _audible = true;

  RTCPeerConnection? _pc;
  RTCDataChannel? _channel;
  MediaStream? _remoteStream;
  MediaStream? _micStream;
  final List<RTCIceCandidate> _pendingCandidates = [];
  bool _remoteDescriptionSet = false;

  StreamSubscription<Map<String, dynamic>>? _msgSub;
  StreamSubscription<bool>? _connSub;
  Timer? _tickTimer;
  Timer? _statsTimer;
  Completer<void>? _joinCompleter;

  String? _roomId;
  String? _peerId;
  bool _joinedRoom = false;
  bool _joinInFlight = false;
  bool _left = false;
  bool _reconnecting = false;
  bool _immediateRetry = false;
  bool _talking = false;
  bool _latencyMeasured = false;
  int? _lastLatencyMs;

  SettingsService get _prefs => _settings ?? SettingsService.instance;

  /// Emits the camera's stream whenever a (new) PC delivers it.
  Stream<MediaStream> get remoteStreams => _remoteStreams.stream;

  /// Latest remote stream, if any.
  MediaStream? get remoteStream => _remoteStream;

  /// Noise alerts, deduped across data-channel + signaling copies (§2.3).
  Stream<NoiseAlert> get noiseAlerts => _noiseAlerts.stream;

  /// Health FSM states for UI binding (F3 AC).
  Stream<HealthState> get healthStates => healthMonitor.states;

  /// Seconds until the next reconnect attempt (counts down to 0) — for the
  /// "Reconnecting in Ns" banner (F4).
  Stream<int> get nextRetrySeconds => _retryCountdown.stream;

  /// The transport currently carrying signaling (`'lan'`|`'cloud'`|`'none'`).
  Stream<String> get transport => _signaling.transport;

  /// Fired when the camera's key no longer matches the trusted one (§8.2) —
  /// the UI must show a hard "re-pair" alert (possible MITM / reinstall).
  Stream<String> get securityAlerts => _securityAlerts.stream;

  /// The camera's image + sound-filter settings and hardware capabilities
  /// (F13/F15) — pushed when the channel opens and on every change.
  Stream<CameraState> get cameraStates => _cameraStates.stream;

  /// Last known camera state, or null before the channel reported one.
  CameraState? get cameraState => _cameraState;

  /// The camera's audio level (0.0–1.0) as it arrives on the heartbeat, for
  /// the live meter under the sound-filter bar (F13).
  Stream<double> get audioLevels => _audioLevels.stream;

  /// Whether camera controls can be changed right now: they travel P2P on the
  /// `health` channel (§4), so they need an open channel, not just a picture.
  bool get canControlCamera =>
      _channel?.state == RTCDataChannelState.RTCDataChannelOpen;

  // --- Audio playback (F13 squelch) ---

  /// Emits whenever the speaker starts or stops playing the room, so the UI
  /// can say *why* it is quiet instead of looking broken.
  Stream<bool> get playbackAudible => _playback.stream;

  /// Whether the camera's audio is reaching this phone's speaker right now.
  bool get audible => _audible;

  /// This device's listen mode.
  ListenMode get listenMode => _listenMode;

  /// The camera's squelch as last reported (true when unknown — fail loud).
  bool get gateOpen => _gateOpen;

  /// Switches what this phone plays (F13). Takes effect immediately.
  Future<void> setListenMode(ListenMode mode) async {
    _listenMode = mode;
    await _prefs.setListenMode(mode);
    _applyPlayback();
  }

  /// Playback volume for the camera's audio on this phone, 0.0–1.0.
  Future<void> setPlaybackVolume(double volume) async {
    final value = volume.clamp(0.0, 1.0).toDouble();
    await _prefs.setPlaybackVolume(value);
    await _applyVolume(value);
  }

  void _onGateMessage(Object? open) {
    if (open is! bool) return;
    _gateOpen = open;
    _gateAt = _now();
    _applyPlayback();
  }

  /// True when the camera's squelch news is too old to trust — a dead data
  /// channel must open the audio, never silence it.
  bool get _gateStale {
    final at = _gateAt;
    if (at == null) return true;
    return _now().difference(at) > AppConfig.audioGateStaleAfter;
  }

  /// Mutes or unmutes the incoming audio track. Disabling a *received* track
  /// stops it reaching the speaker while the stream itself keeps flowing, so
  /// re-opening is instant — no renegotiation, nothing to miss.
  void _applyPlayback({bool force = false}) {
    final audible = switch (_listenMode) {
      ListenMode.alwaysOn => true,
      ListenMode.muted => false,
      ListenMode.filtered => _gateOpen || _gateStale,
    };
    if (audible == _audible && !force) return; // nothing to do (called at 1 Hz)
    final stream = _remoteStream;
    if (stream != null) {
      try {
        for (final track in stream.getAudioTracks()) {
          track.enabled = audible;
        }
      } catch (e) {
        debugPrint('ParentSession: toggling playback failed: $e');
      }
    }
    if (audible != _audible) {
      _audible = audible;
      if (!_playback.isClosed) _playback.add(audible);
    }
  }

  Future<void> _applyVolume(double volume) async {
    final stream = _remoteStream;
    if (stream == null) return;
    try {
      for (final track in stream.getAudioTracks()) {
        await Helper.setVolume(volume, track);
      }
    } catch (e) {
      debugPrint('ParentSession: setVolume failed: $e');
    }
  }

  /// Stream latency measured at connect: heartbeat `ts` vs local clock,
  /// clamped >= 0 (F1 — alert when it exceeds [AppConfig.latencyAlertMs]).
  /// Note: clock skew between the two phones biases this measurement; it is
  /// logged locally (the parent has no REST session id to attach it to).
  Stream<int> get latencies => _latencies.stream;

  int? get lastLatencyMs => _lastLatencyMs;

  /// True when the measured latency exceeds the F1 alert threshold.
  bool get latencyAlert =>
      _lastLatencyMs != null && _lastLatencyMs! > AppConfig.latencyAlertMs;

  bool get talking => _talking;

  String? get peerId => _peerId;

  /// Whether this session authenticates with device keys. True only for an
  /// explicit, trusted target camera (the "tap a paired camera" path) — a bare
  /// code-typed join stays a guest (§8.2 bottom) even when other cameras are
  /// trusted, so it never false-alarms on an unrelated camera's key.
  bool get _trustedMode {
    final target = _cameraDeviceId;
    final trust = _trust;
    return _authEngine != null &&
        target != null &&
        trust != null &&
        trust.isTrusted(target);
  }

  /// Wires the keypair + trust store if they are available; silently stays in
  /// guest mode otherwise.
  void _ensureAuth() {
    if (_authEngine != null) return;
    try {
      final crypto = _crypto ??= CryptoService.instance;
      _trust ??= TrustService.instance;
      _authEngine = AuthEngine(
        sign: crypto.signer,
        verify: crypto.verifier,
        randomBytes: _secureRandomBytes,
        identity: crypto.identity(_prefs.deviceName),
      );
    } catch (_) {
      // CryptoService/TrustService not loaded — guest mode only.
    }
  }

  List<String> _lanCandidates() {
    final urls = <String>[];
    final target = _cameraDeviceId;
    if (target != null) {
      final address = _prefs.lastLanAddress(target);
      if (address != null) urls.add(address);
      return urls;
    }
    final trust = _trust;
    if (trust != null) {
      for (final camera in trust.cameras) {
        final address = _prefs.lastLanAddress(camera.deviceId);
        if (address != null) urls.add(address);
      }
    }
    return urls;
  }

  Future<List<String>> _discoverLanUrls() async {
    final cameras = await _discovery.discover();
    final urls = <String>[];
    for (final camera in cameras) {
      // Remember the address so the next connect tries it first (§7 step 1).
      unawaited(_prefs.setLastLanAddress(camera.deviceId, camera.wsUrl));
      if (_cameraDeviceId == null || camera.deviceId == _cameraDeviceId) {
        urls.add(camera.wsUrl);
      }
    }
    return urls;
  }

  /// Joins [roomId] and keeps the session healthy until [leave].
  Future<void> join(String roomId) async {
    if (_left) return; // a session object is single-use after leave()
    _roomId = roomId;
    _ensureAuth();

    _msgSub ??= _signaling.messages.listen(_onSignal);
    _connSub ??= _signaling.connected.listen((up) {
      if (up) {
        _requestJoin(); // server forgot us on socket loss — re-join (§2.1)
      } else {
        _joinedRoom = false;
        _joinInFlight = false;
      }
    });
    _tickTimer ??= Timer.periodic(const Duration(seconds: 1), (_) {
      healthMonitor.tick();
      // Re-evaluates the squelch: if the camera's gate news went stale the
      // audio opens back up here (NTR1 — never silently deaf). No-op when
      // nothing changed.
      _applyPlayback();
    });
    _statsTimer ??= Timer.periodic(AppConfig.freezeSampleInterval, (_) {
      unawaited(_sampleStats());
    });

    await _signaling.connect();
    _requestJoin();
  }

  void _requestJoin() {
    if (_left || _joinedRoom || _joinInFlight) return;
    if (!_signaling.isConnected) return; // retried when `connected` fires
    final roomId = _roomId;
    if (roomId == null) return;
    _joinInFlight = true;
    // Rejoin with the previous peerId so the camera replaces the right PC.
    final reusePeerId = _peerId ??
        (_prefs.lastJoinedRoom == roomId ? _prefs.lastPeerId : null);
    final message = <String, dynamic>{
      'type': 'join-room',
      'roomId': roomId,
      'peerId': ?reusePeerId,
    };
    if (_trustedMode) {
      // Fresh challenge for the camera each connection (§8.2 step 1).
      final auth = _authEngine!.makeParentJoinAuth();
      _myNonce = auth.nonce;
      message['auth'] = auth.toJson();
    }
    _signaling.send(message);
    // If no room-joined lands, allow another request later.
    Timer(const Duration(seconds: 10), () {
      if (!_joinedRoom) _joinInFlight = false;
    });
  }

  void _onSignal(Map<String, dynamic> msg) {
    try {
      switch (msg['type']) {
        case 'room-joined':
          _onRoomJoined(msg);
        case 'auth-challenge':
          unawaited(_onAuthChallenge(msg));
        case 'offer':
          final sdp = msg['sdp'];
          if (sdp is String) unawaited(_onOffer(sdp));
        case 'ice':
          unawaited(_onRemoteIce(msg));
        case 'camera-left':
          // Camera's socket dropped. Media may still flow P2P; the retry
          // loop re-joins so the reclaimed camera finds us (F4, §2.1).
          _startReconnect('camera-left');
        case 'hb':
          final seq = msg['seq'];
          final ts = msg['ts'];
          if (seq is num && ts is num) _onHeartbeat(seq.toInt(), ts.toInt());
          _onAudioLevel(msg['audioLevel']);
          _onGateMessage(msg['gateOpen']);
        case 'noise':
          final ts = msg['ts'];
          final level = msg['audioLevel'];
          if (ts is num && level is num) {
            _onNoiseMessage(ts.toInt(), level.toDouble());
          }
        case 'error':
          _onSignalError(msg);
        default:
          break; // unknown types ignored (§2)
      }
    } catch (e) {
      debugPrint('ParentSession: signal ${msg['type']} failed: $e');
    }
  }

  void _onSignalError(Map<String, dynamic> msg) {
    final code = msg['code'];
    debugPrint('ParentSession: signaling error $code: ${msg['message']}');
    if (code == 'NOT_TRUSTED') {
      // The camera rejected this device (revoked, or code-joins disabled).
      _joinInFlight = false;
      if (!_securityAlerts.isClosed) {
        _securityAlerts.add(
            'This device is not allowed to watch. Pair it with the camera '
            'or ask for the room code.');
      }
    }
  }

  Future<void> _onAuthChallenge(Map<String, dynamic> msg) async {
    final engine = _authEngine;
    final trust = _trust;
    final myNonce = _myNonce;
    final peerId = msg['peerId'];
    final nonce = msg['nonce'];
    final sig = msg['sig'];
    if (engine == null ||
        trust == null ||
        myNonce == null ||
        peerId is! String ||
        nonce is! String ||
        sig is! String) {
      return;
    }
    final trustedPk =
        _cameraDeviceId == null ? null : trust.trustedPk(_cameraDeviceId);
    if (trustedPk == null) return; // not in trusted mode for a known camera
    final challenge = AuthChallenge(peerId: peerId, nonce: nonce, sig: sig);
    final verified = await engine.verifyCameraChallenge(
      challenge: challenge,
      myNonce: myNonce,
      trustedCameraPk: trustedPk,
    );
    if (!verified) {
      // §8.2 step 2: the camera key changed — disconnect + hard alert (MITM /
      // reinstall). Deduped so a reconnect loop does not spam the user.
      if (!_securityAlerted) {
        _securityAlerted = true;
        if (!_securityAlerts.isClosed) {
          _securityAlerts.add(
              'Camera identity changed — re-pair to continue watching.');
        }
      }
      return; // do not answer the challenge
    }
    final response = await engine.buildAuthResponse(challenge: challenge);
    _signaling.send({'type': 'auth-response', ...response.toJson()});
  }

  void _onRoomJoined(Map<String, dynamic> msg) {
    final peerId = msg['peerId'];
    final roomId = msg['roomId'];
    if (peerId is! String) return;
    _peerId = peerId;
    _joinedRoom = true;
    _joinInFlight = false;
    if (roomId is String) unawaited(_prefs.setParentRoom(roomId, peerId));
    _joinCompleter?.complete();
    _joinCompleter = null;
    _backoff.reset();
    healthMonitor.onReconnected(); // no-op unless we were RECONNECTING
  }

  Future<void> _onOffer(String sdp) async {
    try {
      final description = RTCSessionDescription(sdp, 'offer');
      var pc = _pc;
      if (pc == null) {
        pc = await _createPc();
        await pc.setRemoteDescription(description);
      } else {
        // ICE-restart offers renegotiate our existing PC (F5). An offer from
        // a brand-new camera PC (camera restarted / reclaimed) has a new
        // DTLS identity and is rejected — rebuild ours and retry.
        try {
          await pc.setRemoteDescription(description);
        } catch (e) {
          debugPrint('ParentSession: renegotiation failed ($e) — rebuilding PC');
          await _disposePc();
          pc = await _createPc();
          await pc.setRemoteDescription(description);
        }
      }
      _remoteDescriptionSet = true;
      _drainPendingCandidates();

      // Push-to-talk mic (F6): audio-only, muted until setTalking(true).
      final mic = _micStream ??= await navigator.mediaDevices
          .getUserMedia({'audio': true, 'video': false});
      for (final track in mic.getAudioTracks()) {
        track.enabled = _talking;
      }
      final senders = await pc.getSenders();
      final hasAudioSender = senders.any((s) => s.track?.kind == 'audio');
      if (!hasAudioSender) {
        for (final track in mic.getAudioTracks()) {
          await pc.addTrack(track, mic);
        }
      }

      final answer = await pc.createAnswer();
      await pc.setLocalDescription(answer);
      _signaling.send({
        'type': 'answer',
        'peerId': _peerId,
        'sdp': answer.sdp,
        'sdpType': 'answer',
      });
    } catch (e) {
      debugPrint('ParentSession: handling offer failed: $e');
    }
  }

  Future<RTCPeerConnection> _createPc() async {
    // On a LAN transport, host candidates suffice on the shared subnet — skip
    // the ICE-config fetch entirely (NTR7). Cloud sessions fetch STUN/TURN
    // (STUN-only fallback, §6).
    final iceServers = _signaling.activeTransport == 'lan'
        ? const <Map<String, dynamic>>[]
        : await _api.fetchIceConfig();
    final pc = await createPeerConnection({'iceServers': iceServers});
    _pc = pc;
    _remoteDescriptionSet = false;
    _pendingCandidates.clear();
    _freezeDetector.reset();
    _latencyMeasured = false; // measure latency at (re)connect (F1)

    pc.onIceCandidate = (candidate) {
      if (candidate.candidate == null) return;
      _signaling.send({
        'type': 'ice',
        'peerId': _peerId,
        'candidate': {
          'candidate': candidate.candidate,
          'sdpMid': candidate.sdpMid,
          'sdpMLineIndex': candidate.sdpMLineIndex,
        },
      });
    };
    pc.onTrack = (event) {
      if (event.streams.isEmpty) return;
      final stream = event.streams.first;
      if (event.track.kind == 'video') {
        _remoteStream = stream;
        if (!_remoteStreams.isClosed) _remoteStreams.add(stream);
      } else if (event.track.kind == 'audio') {
        // The squelch (F13) lives here: a received audio track that is not
        // enabled never reaches the speaker.
        _remoteStream ??= stream;
        _applyPlayback(force: true);
        unawaited(_applyVolume(_prefs.playbackVolume));
      }
    };
    pc.onDataChannel = (channel) {
      if (channel.label != 'health') return;
      _channel = channel;
      channel.onMessage = _onChannelMessage;
      // Ask for the camera's current controls (F15). The camera also pushes
      // them when its side opens; whichever lands first wins, both are cheap.
      _channelSend(channel, {'t': 'get-camera-state'});
      channel.onDataChannelState = (state) {
        if (state == RTCDataChannelState.RTCDataChannelOpen) {
          _channelSend(channel, {'t': 'get-camera-state'});
        }
      };
    };
    pc.onConnectionState = (state) {
      debugPrint('ParentSession: pc -> $state');
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateDisconnected ||
          state == RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
        _startReconnect('pc-$state');
      }
    };
    return pc;
  }

  Future<void> _onRemoteIce(Map<String, dynamic> msg) async {
    final candidateMap = msg['candidate'];
    if (candidateMap is! Map) return;
    final candidate = RTCIceCandidate(
      candidateMap['candidate'] as String?,
      candidateMap['sdpMid'] as String?,
      (candidateMap['sdpMLineIndex'] as num?)?.toInt(),
    );
    final pc = _pc;
    if (pc == null || !_remoteDescriptionSet) {
      _pendingCandidates.add(candidate); // trickled before the offer landed
      return;
    }
    try {
      await pc.addCandidate(candidate);
    } catch (e) {
      debugPrint('ParentSession: addCandidate failed: $e');
    }
  }

  void _drainPendingCandidates() {
    final pc = _pc;
    if (pc == null) return;
    final drained = List<RTCIceCandidate>.of(_pendingCandidates);
    _pendingCandidates.clear();
    for (final candidate in drained) {
      unawaited(pc.addCandidate(candidate).catchError((e) {
        debugPrint('ParentSession: queued addCandidate failed: $e');
      }));
    }
  }

  void _onChannelMessage(RTCDataChannelMessage message) {
    final msg = _decodeChannelMessage(message);
    if (msg == null) return;
    switch (msg['t']) {
      case 'hb':
        final seq = msg['seq'];
        final ts = msg['ts'];
        if (seq is num && ts is num) _onHeartbeat(seq.toInt(), ts.toInt());
        _onAudioLevel(msg['audioLevel']);
        _onGateMessage(msg['gateOpen']); // resync the squelch every 3 s
      case 'audio-gate':
        _onGateMessage(msg['open']);
      case 'camera-state':
        _onCameraState(msg);
      case 'noise':
        final ts = msg['ts'];
        final level = msg['audioLevel'];
        if (ts is num && level is num) {
          _onNoiseMessage(ts.toInt(), level.toDouble());
        }
      default:
        break;
    }
  }

  void _onHeartbeat(int seq, int tsMs) {
    final now = _now();
    heartbeatTracker.onHeartbeat(seq, now);
    healthMonitor.onHeartbeat(seq);
    if (!_latencyMeasured) {
      _latencyMeasured = true;
      final ms = math.max(0, now.millisecondsSinceEpoch - tsMs);
      _lastLatencyMs = ms;
      if (!_latencies.isClosed) _latencies.add(ms);
      debugPrint('ParentSession: latency at connect ${ms}ms'
          '${ms > AppConfig.latencyAlertMs ? ' — EXCEEDS ${AppConfig.latencyAlertMs}ms (F1 alert)' : ''}');
    }
  }

  void _onAudioLevel(Object? value) {
    if (value is! num) return;
    final level = value.toDouble();
    if (!level.isFinite) return;
    if (!_audioLevels.isClosed) {
      _audioLevels.add(level.clamp(0.0, 1.0).toDouble());
    }
  }

  void _onCameraState(Map<String, dynamic> msg) {
    final state = CameraState.fromJson(msg);
    _cameraState = state;
    if (!_cameraStates.isClosed) _cameraStates.add(state);
    if (msg['gateOpen'] is bool) _onGateMessage(msg['gateOpen']);
  }

  /// Sends a camera-control change to the camera (F13/F15). The camera is the
  /// single source of truth: it applies what it can and broadcasts the result
  /// back on [cameraStates], so a knob the hardware refuses snaps back.
  void sendCameraControl(CameraControls controls) {
    _channelSend(_channel, {'t': 'camera-control', 'controls': controls.toJson()});
  }

  void _onNoiseMessage(int tsMs, double audioLevel) {
    // Dedupe: the camera sends noise on the data channel AND signaling (§2.3).
    if (!_seenNoiseTs.add(tsMs)) return;
    if (_seenNoiseTs.length > 128) _seenNoiseTs.clear(); // keep it bounded
    if (!_noiseAlerts.isClosed) {
      _noiseAlerts.add(NoiseAlert(tsMs: tsMs, audioLevel: audioLevel));
    }
  }

  /// Feeds `framesDecoded` into the freeze detector (F5, TR4).
  Future<void> _sampleStats() async {
    final pc = _pc;
    if (pc == null) return;
    try {
      final stats = await pc.getStats();
      for (final report in stats) {
        if (report.type != 'inbound-rtp') continue;
        final kind = report.values['kind'] ?? report.values['mediaType'];
        if (kind != 'video') continue;
        final frames = report.values['framesDecoded'];
        if (frames is num) {
          _freezeDetector.feed(frames.toInt());
          return;
        }
      }
    } catch (e) {
      debugPrint('ParentSession: getStats failed: $e');
    }
  }

  void _onFrozen() {
    healthMonitor.onFreezeDetected();
    // Ask the camera for an ICE restart on our PC (F5, §2.2).
    _signaling.send({'type': 'ice-restart', 'peerId': _peerId});
  }

  void _onFreezeRecovered() {
    healthMonitor.onFreezeRecovered();
  }

  /// Push-to-talk (F6): toggles the mic track and tells the camera.
  Future<void> setTalking(bool on) async {
    _talking = on;
    final mic = _micStream;
    if (mic != null) {
      for (final track in mic.getAudioTracks()) {
        track.enabled = on;
      }
    }
    _channelSend(_channel, {'t': 'talk', 'on': on});
  }

  // --- Reconnect (F4) ---

  void _startReconnect(String reason) {
    if (_left || _reconnecting) return; // debounce (F4 AC)
    if (healthMonitor.state == HealthState.failed) return; // manual only
    if (_backoff.exhausted) {
      healthMonitor.onReconnectExhausted();
      return;
    }
    _reconnecting = true;
    unawaited(_reconnectLoop(reason));
  }

  Future<void> _reconnectLoop(String reason) async {
    debugPrint('ParentSession: reconnect loop started ($reason)');
    try {
      while (!_left) {
        if (_backoff.exhausted) {
          healthMonitor.onReconnectExhausted(); // -> FAILED (F4)
          break;
        }
        if (_immediateRetry) {
          _immediateRetry = false;
        } else {
          final delay = _backoff.nextDelay();
          for (var s = delay.inSeconds; s > 0 && !_left; s--) {
            if (!_retryCountdown.isClosed) _retryCountdown.add(s);
            await Future<void>.delayed(const Duration(seconds: 1));
          }
        }
        if (_left) break;
        if (!_retryCountdown.isClosed) _retryCountdown.add(0);
        final ok = await _attemptRejoin();
        if (ok) {
          _backoff.reset();
          healthMonitor.onReconnected();
          debugPrint('ParentSession: rejoined');
          break;
        }
      }
    } finally {
      _reconnecting = false;
    }
  }

  Future<bool> _attemptRejoin() async {
    try {
      _joinedRoom = false;
      _joinInFlight = false;
      if (!_signaling.isConnected) {
        // Re-runs the full LAN→cloud order (§7) on every attempt.
        await _signaling.connect();
        if (!_signaling.isConnected) return false; // its own backoff runs
      }
      final completer = Completer<void>();
      _joinCompleter = completer;
      _requestJoin();
      await completer.future.timeout(const Duration(seconds: 8));
      return true;
    } catch (_) {
      _joinCompleter = null;
      return false;
    }
  }

  /// User-initiated recovery from FAILED (or a stuck state): resets the FSM
  /// and the backoff, then retries immediately.
  Future<void> manualReconnect() async {
    if (_left) return;
    _backoff.reset();
    _securityAlerted = false; // allow a fresh identity check after re-pairing
    healthMonitor.manualReset();
    _immediateRetry = true;
    _startReconnect('manual');
  }

  /// Leaves the room and releases everything. The object is done after this.
  Future<void> leave() async {
    if (_left) return;
    _left = true;

    _tickTimer?.cancel();
    _tickTimer = null;
    _statsTimer?.cancel();
    _statsTimer = null;
    await _healthSub?.cancel();
    _healthSub = null;

    _signaling.send({'type': 'leave'});
    await _msgSub?.cancel();
    _msgSub = null;
    await _connSub?.cancel();
    _connSub = null;
    await _signaling.close();
    await _discovery.dispose();

    await _disposePc();

    final mic = _micStream;
    _micStream = null;
    if (mic != null) {
      try {
        for (final track in mic.getTracks()) {
          await track.stop();
        }
        await mic.dispose();
      } catch (e) {
        debugPrint('ParentSession: releasing mic failed: $e');
      }
    }

    healthMonitor.dispose();
    await _remoteStreams.close();
    await _noiseAlerts.close();
    await _retryCountdown.close();
    await _latencies.close();
    await _securityAlerts.close();
    await _cameraStates.close();
    await _audioLevels.close();
    await _playback.close();
  }

  Future<void> _disposePc() async {
    final channel = _channel;
    _channel = null;
    try {
      await channel?.close();
    } catch (_) {}
    final pc = _pc;
    _pc = null;
    _remoteDescriptionSet = false;
    _pendingCandidates.clear();
    if (pc != null) {
      try {
        await pc.close();
        await pc.dispose();
      } catch (e) {
        debugPrint('ParentSession: disposing PC failed: $e');
      }
    }
    _remoteStream = null;
  }
}

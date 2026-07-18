/// WebRTC session facades (docs/PROTOCOL.md §2, §4, §5.3).
///
/// [CameraSession]: one `RTCPeerConnection` per joined parent (F8, max
/// enforced server-side), local capture, `health` data channels, heartbeats,
/// noise monitoring, wakelock, room create/reclaim.
///
/// [ParentSession]: single PC answering the camera's offer, health FSM
/// wiring, freeze detection -> ice-restart, push-to-talk, auto-rejoin with
/// backoff (F4).
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
import '../core/backoff_scheduler.dart';
import '../core/freeze_detector.dart';
import '../core/health_monitor.dart';
import '../core/health_state.dart';
import '../core/heartbeat_tracker.dart';
import '../core/models.dart';
import 'api_client.dart';
import 'noise_monitor.dart';
import 'settings_service.dart';
import 'signaling_client.dart';
import 'sleep_log_service.dart';

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

class _CameraPeer {
  _CameraPeer(this.peerId);

  final String peerId;
  RTCPeerConnection? pc;
  RTCDataChannel? channel;

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
    DateTime Function() now = DateTime.now,
  })  : _signaling = signaling ?? SignalingClient(),
        _api = api ?? ApiClient(),
        _log = log,
        _settings = settings,
        _now = now;

  final SignalingClient _signaling;
  final ApiClient _api;
  final SleepLogService? _log;
  final SettingsService? _settings;
  final DateTime Function() _now;

  final Map<String, _CameraPeer> _peers = {};
  final StreamController<String> _warnings =
      StreamController<String>.broadcast();
  final StreamController<TalkEvent> _talk =
      StreamController<TalkEvent>.broadcast();
  final StreamController<int> _parentCount = StreamController<int>.broadcast();

  MediaStream? _localStream;
  NoiseMonitor? _noiseMonitor;
  Timer? _hbTimer;
  StreamSubscription<Map<String, dynamic>>? _msgSub;
  StreamSubscription<bool>? _connSub;
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

  /// The 6-char room code once `room-created` arrives.
  String? get roomId => _roomId;

  /// Local capture stream, for an on-screen preview.
  MediaStream? get localStream => _localStream;

  int get joinedParents => _peers.length;

  /// Starts capture, wakelock, signaling and monitoring. Never throws for
  /// recoverable problems — those surface on [warnings]. Media/permission
  /// failures DO throw: without a camera there is no session.
  Future<void> start() async {
    if (_started) return;
    _started = true;

    // 1. Capture: back camera, 640x480@15 target — stays within the TR5
    //    camera-device CPU budget; audio processing on for talk-back (F6).
    _localStream = await navigator.mediaDevices.getUserMedia({
      'audio': {
        'echoCancellation': true,
        'noiseSuppression': true,
        'autoGainControl': true,
      },
      'video': {
        'facingMode': 'environment',
        'width': {'ideal': 640},
        'height': {'ideal': 480},
        'frameRate': {'ideal': 15},
      },
    });

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

    // 3. Signaling: create (or reclaim) the room. Re-sent on every signaling
    //    reconnect because the server forgets a closed socket's session.
    _msgSub = _signaling.messages.listen(_onSignal);
    _connSub = _signaling.connected.listen((up) {
      if (up) _sendCreateRoom();
    });
    await _signaling.connect();

    // 4. Heartbeats to every parent (F3, §4).
    _hbTimer =
        Timer.periodic(AppConfig.heartbeatInterval, (_) => _sendHeartbeat());

    // 5. Noise monitoring (F7) — NoiseGate inside NoiseMonitor is the single
    //    decision point; threshold follows settings live.
    final monitor = NoiseMonitor(
      sampleLevel: _sampleAudioLevel,
      threshold: _prefs.noiseThreshold,
      onNoise: _onNoise,
      now: _now,
    );
    _noiseMonitor = monitor;
    monitor.start();
  }

  /// Applies a new sensitivity ('low'|'medium'|'high') live (F7 AC).
  void setNoiseSensitivity(String sensitivity) {
    final threshold = AppConfig.noiseThresholds[sensitivity];
    if (threshold == null) return;
    unawaited(_prefs.setNoiseSensitivity(sensitivity));
    _noiseMonitor?.threshold = threshold;
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

  void _onSignal(Map<String, dynamic> msg) {
    try {
      switch (msg['type']) {
        case 'room-created':
          _onRoomCreated(msg);
        case 'peer-joined':
          final peerId = msg['peerId'];
          if (peerId is String) unawaited(_createPeer(peerId));
        case 'peer-left':
          final peerId = msg['peerId'];
          if (peerId is String) unawaited(_disposePeer(peerId));
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
      unawaited(_prefs.clearCameraRoom());
      _warn('Previous room expired — a new room code was created. '
          'Parents must join with the new code.');
      _signaling.send({'type': 'create-room'});
    }
  }

  Future<void> _createPeer(String peerId) async {
    // Rejoin/reclaim: drop any stale PC for this parent first (§2.1).
    await _disposePeer(peerId);
    final peer = _CameraPeer(peerId);
    _peers[peerId] = peer;
    _emitParentCount();
    try {
      // ICE servers fetched per join; falls back to STUN-only (NTR3/§6).
      final iceServers = await _api.fetchIceConfig();
      final pc = await createPeerConnection({'iceServers': iceServers});
      if (_peers[peerId] != peer) {
        // Peer left (or rejoined) while we were setting up.
        await pc.dispose();
        return;
      }
      peer.pc = pc;

      pc.onIceCandidate = (candidate) {
        if (candidate.candidate == null) return;
        _signaling.send({
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
      final channel =
          await pc.createDataChannel('health', RTCDataChannelInit()..ordered = true);
      peer.channel = channel;
      channel.onMessage = (message) => _onChannelMessage(peerId, message);

      final offer = await pc.createOffer();
      await pc.setLocalDescription(offer);
      _signaling.send({
        'type': 'offer',
        'peerId': peerId,
        'sdp': offer.sdp,
        'sdpType': 'offer',
      });
    } catch (e) {
      debugPrint('CameraSession: creating peer $peerId failed: $e');
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
    final pc = _peers[peerId]?.pc;
    if (pc == null) return;
    _log?.logEvent(
        SleepEvent(type: 'freeze', at: _now(), data: {'peerId': peerId}));
    try {
      final offer = await pc.createOffer({'iceRestart': true});
      await pc.setLocalDescription(offer);
      _signaling.send({
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
    if (msg['t'] == 'talk' && msg['on'] is bool) {
      if (!_talk.isClosed) {
        _talk.add(TalkEvent(peerId: peerId, on: msg['on'] as bool));
      }
    }
  }

  void _sendHeartbeat() {
    _hbSeq++;
    final ts = _now().millisecondsSinceEpoch;
    final level = _noiseMonitor?.lastLevel ?? 0.0;
    final channelMsg = {'t': 'hb', 'seq': _hbSeq, 'ts': ts, 'audioLevel': level};
    var needFallback = false;
    for (final peer in _peers.values) {
      if (peer.channelOpen) {
        _channelSend(peer.channel, channelMsg);
      } else {
        needFallback = true;
      }
    }
    // §2.3: signaling relay when a data channel is not open (server fans out
    // to all parents; duplicates are harmless — same seq).
    if (needFallback) {
      _signaling.send(
          {'type': 'hb', 'seq': _hbSeq, 'ts': ts, 'audioLevel': level});
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
    // Always also via signaling (§2.3) — parents dedupe on ts.
    _signaling.send({'type': 'noise', 'ts': ts, 'audioLevel': level});
    _log?.logEvent(
        SleepEvent(type: 'noise', at: _now(), data: {'audioLevel': level}));
  }

  Future<void> _disposePeer(String peerId) async {
    final peer = _peers.remove(peerId);
    if (peer == null) return;
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
    _noiseMonitor?.stop();
    _noiseMonitor = null;

    _log?.logSessionEnd();

    _signaling.send({'type': 'leave'});
    await _msgSub?.cancel();
    _msgSub = null;
    await _connSub?.cancel();
    _connSub = null;
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
    _sessionLogged = false;
    _hbSeq = 0;
  }

  /// [stop] plus stream-controller teardown. The session is unusable after.
  Future<void> dispose() async {
    await stop();
    await _warnings.close();
    await _talk.close();
    await _parentCount.close();
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
    HealthMonitor? healthMonitor,
    BackoffScheduler? backoff,
    DateTime Function() now = DateTime.now,
  })  : _signaling = signaling ?? SignalingClient(),
        _api = api ?? ApiClient(),
        _settings = settings,
        _backoff = backoff ?? BackoffScheduler(),
        _now = now,
        healthMonitor = healthMonitor ?? HealthMonitor(now: now) {
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

  final SignalingClient _signaling;
  final ApiClient _api;
  final SettingsService? _settings;
  final BackoffScheduler _backoff;
  final DateTime Function() _now;

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
  final Set<int> _seenNoiseTs = <int>{};

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

  /// Joins [roomId] and keeps the session healthy until [leave].
  Future<void> join(String roomId) async {
    if (_left) return; // a session object is single-use after leave()
    _roomId = roomId;

    _msgSub ??= _signaling.messages.listen(_onSignal);
    _connSub ??= _signaling.connected.listen((up) {
      if (up) {
        _requestJoin(); // server forgot us on socket loss — re-join (§2.1)
      } else {
        _joinedRoom = false;
        _joinInFlight = false;
      }
    });
    _tickTimer ??= Timer.periodic(
        const Duration(seconds: 1), (_) => healthMonitor.tick());
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
    _signaling.send({
      'type': 'join-room',
      'roomId': roomId,
      'peerId': ?reusePeerId,
    });
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
        case 'noise':
          final ts = msg['ts'];
          final level = msg['audioLevel'];
          if (ts is num && level is num) {
            _onNoiseMessage(ts.toInt(), level.toDouble());
          }
        case 'error':
          debugPrint(
              'ParentSession: signaling error ${msg['code']}: ${msg['message']}');
        default:
          break; // unknown types ignored (§2)
      }
    } catch (e) {
      debugPrint('ParentSession: signal ${msg['type']} failed: $e');
    }
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
      final mic = _micStream ??=
          await navigator.mediaDevices.getUserMedia({'audio': true, 'video': false});
      for (final track in mic.getAudioTracks()) {
        track.enabled = _talking;
      }
      final senders = await pc.getSenders();
      final hasAudioSender =
          senders.any((s) => s.track?.kind == 'audio');
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
    final iceServers = await _api.fetchIceConfig(); // STUN-only fallback (§6)
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
      if (event.streams.isNotEmpty && event.track.kind == 'video') {
        _remoteStream = event.streams.first;
        if (!_remoteStreams.isClosed) _remoteStreams.add(event.streams.first);
      }
    };
    pc.onDataChannel = (channel) {
      if (channel.label != 'health') return;
      _channel = channel;
      channel.onMessage = _onChannelMessage;
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

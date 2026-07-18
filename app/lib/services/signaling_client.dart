/// WebSocket signaling client (docs/PROTOCOL.md §2, §5.3, §7).
///
/// Wraps [WebSocketChannel] with auto-reconnect driven by [BackoffScheduler]
/// (jitterless [Timer]s — the schedule is exactly 3s/6s/12s/30s…). It never
/// throws to callers (NTR3): connection failures surface on the [connected]
/// stream, malformed inbound frames are ignored, and [send] silently drops
/// when the socket is down (callers re-establish room state on reconnect —
/// the server forgets a socket's room session when it closes).
///
/// F11 connection order: on every initial connect **and every reconnect
/// attempt** it tries, in order, the last-known LAN address of a trusted
/// camera → mDNS-discovered LAN endpoints (2 s budget) → the cloud URL. The
/// first that connects wins, so the same-network case never depends on the
/// internet (§7). Which transport is live is published on [transport]
/// (`'lan'`|`'cloud'`|`'none'`). The rest of the API is unchanged for callers.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:web_socket_channel/status.dart' as ws_status;
import 'package:web_socket_channel/web_socket_channel.dart';

import '../core/backoff_scheduler.dart';
import 'settings_service.dart';

class _Candidate {
  const _Candidate(this.url, this.kind);
  final String url;
  final String kind; // 'lan' | 'cloud'
}

class SignalingClient {
  SignalingClient({
    String Function()? urlProvider,
    List<String> Function()? lanCandidates,
    Future<List<String>> Function()? discoverLan,
    BackoffScheduler? backoff,
    this.connectTimeout = const Duration(seconds: 10),
    this.lanConnectTimeout = const Duration(seconds: 2),
  })  : _urlProvider = urlProvider,
        _lanCandidates = lanCandidates,
        _discoverLan = discoverLan,
        _backoff = backoff ?? BackoffScheduler();

  final String Function()? _urlProvider;

  /// Last-known LAN `ws://…/ws` URLs to try first (§7 step 1).
  final List<String> Function()? _lanCandidates;

  /// mDNS discovery producing LAN `ws://…/ws` URLs (§7 step 2, 2 s budget).
  final Future<List<String>> Function()? _discoverLan;

  final BackoffScheduler _backoff;
  final Duration connectTimeout;
  final Duration lanConnectTimeout;

  final StreamController<Map<String, dynamic>> _messages =
      StreamController<Map<String, dynamic>>.broadcast();
  final StreamController<bool> _connected = StreamController<bool>.broadcast();
  final StreamController<String> _transport =
      StreamController<String>.broadcast();

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _subscription;
  Timer? _reconnectTimer;
  bool _isConnected = false;
  bool _connecting = false;
  bool _closed = false;
  bool _disposed = false;
  String _activeTransport = 'none';

  /// Every valid inbound JSON object frame ({"type": ...}). Broadcast.
  Stream<Map<String, dynamic>> get messages => _messages.stream;

  /// true on (re)connect, false on loss. Broadcast; also see [isConnected].
  Stream<bool> get connected => _connected.stream;

  /// The live transport: `'lan'`, `'cloud'` or `'none'`. Broadcast.
  Stream<String> get transport => _transport.stream;

  /// Whether the socket is currently open.
  bool get isConnected => _isConnected;

  /// The currently-active transport (`'lan'`|`'cloud'`|`'none'`).
  String get activeTransport => _activeTransport;

  String get _cloudUrl =>
      _urlProvider?.call() ?? SettingsService.instance.signalingUrl;

  /// Opens the socket and keeps it open: on loss it reconnects on the backoff
  /// schedule, re-running the full LAN→cloud order each time, until [close] is
  /// called. Never throws.
  Future<void> connect() async {
    if (_disposed) return;
    _closed = false;
    await _open();
  }

  Future<List<_Candidate>> _buildCandidates() async {
    final candidates = <_Candidate>[];
    final seen = <String>{};
    void add(String url, String kind) {
      if (url.isNotEmpty && seen.add(url)) {
        candidates.add(_Candidate(url, kind));
      }
    }

    final lan = _lanCandidates;
    if (lan != null) {
      try {
        for (final url in lan()) {
          add(url, 'lan');
        }
      } catch (e) {
        debugPrint('SignalingClient: lanCandidates failed: $e');
      }
    }
    final discover = _discoverLan;
    if (discover != null) {
      try {
        for (final url in await discover()) {
          add(url, 'lan');
        }
      } catch (e) {
        debugPrint('SignalingClient: mDNS discovery failed: $e');
      }
    }
    add(_cloudUrl, 'cloud');
    return candidates;
  }

  Future<void> _open() async {
    if (_closed || _disposed || _connecting || _isConnected) return;
    _connecting = true;
    try {
      final candidates = await _buildCandidates();
      for (final candidate in candidates) {
        if (_closed || _disposed) return;
        final channel = WebSocketChannel.connect(Uri.parse(candidate.url));
        try {
          await channel.ready.timeout(
              candidate.kind == 'lan' ? lanConnectTimeout : connectTimeout);
        } catch (e) {
          debugPrint(
              'SignalingClient: ${candidate.kind} ${candidate.url} failed: $e');
          try {
            await channel.sink.close();
          } catch (_) {}
          continue; // try the next candidate in the order
        }
        _channel = channel;
        _subscription = channel.stream.listen(
          _onFrame,
          onError: (Object e) {
            debugPrint('SignalingClient: socket error: $e');
            _onDisconnected();
          },
          onDone: _onDisconnected,
          cancelOnError: false,
        );
        _isConnected = true;
        _backoff.reset();
        _setTransport(candidate.kind);
        _emitConnected(true);
        debugPrint('SignalingClient: connected via ${candidate.kind} '
            '(${candidate.url})');
        return;
      }
      // Nothing connected — back off and re-run the whole order.
      _setTransport('none');
      _scheduleReconnect();
    } finally {
      _connecting = false;
    }
  }

  void _onFrame(dynamic frame) {
    // Malformed frames are ignored; unknown types pass through — consumers
    // ignore types they don't know (PROTOCOL §2, forward compatibility).
    if (frame is! String) return;
    dynamic decoded;
    try {
      decoded = jsonDecode(frame);
    } catch (_) {
      return;
    }
    if (decoded is! Map<String, dynamic> || decoded['type'] is! String) return;
    if (!_messages.isClosed) _messages.add(decoded);
  }

  void _onDisconnected() {
    if (_channel == null && !_isConnected) return; // already handled
    _subscription?.cancel();
    _subscription = null;
    _channel = null;
    if (_isConnected) {
      _isConnected = false;
      _emitConnected(false);
    }
    _setTransport('none');
    if (!_closed && !_disposed) _scheduleReconnect();
  }

  void _scheduleReconnect() {
    if (_closed || _disposed) return;
    _reconnectTimer?.cancel();
    // Transport-level reconnect never gives up (the last backoff entry
    // repeats): room-level retry/FAILED semantics live in the sessions (F4).
    final delay = _backoff.nextDelay();
    debugPrint(
        'SignalingClient: reconnecting in ${delay.inSeconds}s (attempt ${_backoff.attempts})');
    _reconnectTimer = Timer(delay, _open);
  }

  /// Sends one JSON message. Drops (with a debug log) when the socket is not
  /// open — signaling messages are only meaningful on a live room session.
  void send(Map<String, dynamic> message) {
    final channel = _channel;
    if (!_isConnected || channel == null) {
      debugPrint("SignalingClient: dropped ${message['type']} (not connected)");
      return;
    }
    try {
      channel.sink.add(jsonEncode(message));
    } catch (e) {
      debugPrint("SignalingClient: send ${message['type']} failed: $e");
    }
  }

  /// Graceful close: stops reconnecting and closes the socket. The client can
  /// be reused with a later [connect].
  Future<void> close() async {
    _closed = true;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    await _subscription?.cancel();
    _subscription = null;
    final channel = _channel;
    _channel = null;
    if (channel != null) {
      try {
        await channel.sink.close(ws_status.normalClosure);
      } catch (_) {
        // Socket already dead — nothing to do.
      }
    }
    if (_isConnected) {
      _isConnected = false;
      _emitConnected(false);
    }
    _setTransport('none');
    _backoff.reset();
  }

  /// Close permanently and release the stream controllers.
  Future<void> dispose() async {
    if (_disposed) return;
    await close();
    _disposed = true;
    await _messages.close();
    await _connected.close();
    await _transport.close();
  }

  void _emitConnected(bool value) {
    if (!_connected.isClosed) _connected.add(value);
  }

  void _setTransport(String value) {
    if (_activeTransport == value) return;
    _activeTransport = value;
    if (!_transport.isClosed) _transport.add(value);
  }
}

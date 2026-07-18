/// WebSocket signaling client (docs/PROTOCOL.md §2, §5.3).
///
/// Wraps [WebSocketChannel] with auto-reconnect driven by [BackoffScheduler]
/// (jitterless [Timer]s — the schedule is exactly 3s/6s/12s/30s…). It never
/// throws to callers (NTR3): connection failures surface on the [connected]
/// stream, malformed inbound frames are ignored, and [send] silently drops
/// when the socket is down (callers re-establish room state on reconnect —
/// the server forgets a socket's room session when it closes).
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:web_socket_channel/status.dart' as ws_status;
import 'package:web_socket_channel/web_socket_channel.dart';

import '../core/backoff_scheduler.dart';
import 'settings_service.dart';

class SignalingClient {
  SignalingClient({
    String Function()? urlProvider,
    BackoffScheduler? backoff,
    this.connectTimeout = const Duration(seconds: 10),
  })  : _urlProvider = urlProvider,
        _backoff = backoff ?? BackoffScheduler();

  final String Function()? _urlProvider;
  final BackoffScheduler _backoff;
  final Duration connectTimeout;

  final StreamController<Map<String, dynamic>> _messages =
      StreamController<Map<String, dynamic>>.broadcast();
  final StreamController<bool> _connected = StreamController<bool>.broadcast();

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _subscription;
  Timer? _reconnectTimer;
  bool _isConnected = false;
  bool _connecting = false;
  bool _closed = false;
  bool _disposed = false;

  /// Every valid inbound JSON object frame ({"type": ...}). Broadcast.
  Stream<Map<String, dynamic>> get messages => _messages.stream;

  /// true on (re)connect, false on loss. Broadcast; also see [isConnected].
  Stream<bool> get connected => _connected.stream;

  /// Whether the socket is currently open.
  bool get isConnected => _isConnected;

  String get _url =>
      _urlProvider?.call() ?? SettingsService.instance.signalingUrl;

  /// Opens the socket and keeps it open: on loss it reconnects on the
  /// backoff schedule until [close] is called. Never throws.
  Future<void> connect() async {
    if (_disposed) return;
    _closed = false;
    await _open();
  }

  Future<void> _open() async {
    if (_closed || _disposed || _connecting || _isConnected) return;
    _connecting = true;
    try {
      final channel = WebSocketChannel.connect(Uri.parse(_url));
      await channel.ready.timeout(connectTimeout);
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
      _emitConnected(true);
    } catch (e) {
      debugPrint('SignalingClient: connect to $_url failed: $e');
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
    _backoff.reset();
  }

  /// Close permanently and release the stream controllers.
  Future<void> dispose() async {
    if (_disposed) return;
    await close();
    _disposed = true;
    await _messages.close();
    await _connected.close();
  }

  void _emitConnected(bool value) {
    if (!_connected.isClosed) _connected.add(value);
  }
}

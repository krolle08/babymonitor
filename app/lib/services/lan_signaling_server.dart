/// Camera-hosted LAN signaling server (docs/PROTOCOL.md §7, F11).
///
/// A `dart:io` [HttpServer] with a WebSocket upgrade at `/ws` (default port
/// 47800; falls back to an ephemeral port if taken — the reported [port] is
/// authoritative). The camera plays the §2 server role for a single implicit
/// room ("LOCAL"): it mints peerIds, relays `answer`/`ice`/`ice-restart` and
/// `auth-response` to the [CameraSession] in the **same message shape the cloud
/// `SignalingClient` produces**, fans out `hb`/`noise`, and handles the §8.1
/// `pair-request` ceremony itself (token check → trust add → `pair-response`).
///
/// Guest gating (§7): a `join-room` without `auth` is accepted only when
/// pairing mode is active or the join carries the camera's current room code
/// (with [allowCodeJoins] on); otherwise it is rejected `NOT_TRUSTED`. Joins
/// *with* `auth` are forwarded to the session, which drives §8.2.
///
/// Never throws to the session (NTR3): socket and parse errors are logged and
/// isolated to the offending connection.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart' show debugPrint;

import '../config/app_config.dart';
import '../core/auth_engine.dart';
import 'trust_service.dart';

/// Default LAN signaling port (§7).
const int kLanSignalingPort = 47800;

class _LanClient {
  _LanClient(this.socket);

  final WebSocket socket;
  String? peerId;
  bool joined = false;
  String? deviceId; // set from auth / pairing, used for revocation drops
}

class LanSignalingServer {
  LanSignalingServer({
    required AuthEngine authEngine,
    required TrustService trust,
    this.desiredPort = kLanSignalingPort,
  })  : _auth = authEngine,
        _trust = trust;

  final AuthEngine _auth;
  final TrustService _trust;
  final int desiredPort;

  HttpServer? _server;
  final Map<String, _LanClient> _clients = {}; // peerId -> client
  final Set<_LanClient> _pending = {}; // connected, not yet joined
  final StreamController<Map<String, dynamic>> _incoming =
      StreamController<Map<String, dynamic>>.broadcast();

  /// Guest config (§7), updated live by the [CameraSession].
  bool allowCodeJoins = true;
  String? roomCode;
  bool pairingActive = false;

  /// Server→camera messages, shaped exactly like the cloud transport so the
  /// session logic is transport-agnostic (peer-joined / answer / ice /
  /// ice-restart / auth-response / peer-left).
  Stream<Map<String, dynamic>> get messages => _incoming.stream;

  /// The bound port (authoritative). Null until [start] succeeds.
  int? get port => _server?.port;

  /// Number of parents currently in the room.
  int get joinedCount => _clients.length;

  /// Binds the server. Tries [desiredPort] first, then an ephemeral port.
  /// Never throws — logs and leaves [port] null on total failure.
  Future<void> start() async {
    if (_server != null) return;
    HttpServer? server;
    try {
      server = await HttpServer.bind(InternetAddress.anyIPv4, desiredPort);
    } catch (e) {
      debugPrint('LanSignalingServer: port $desiredPort busy ($e) — '
          'binding an ephemeral port');
      try {
        server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
      } catch (e2) {
        debugPrint('LanSignalingServer: bind failed: $e2');
        return;
      }
    }
    _server = server;
    server.listen(_handleRequest, onError: (Object e) {
      debugPrint('LanSignalingServer: http error: $e');
    });
    debugPrint('LanSignalingServer: listening on ws://0.0.0.0:${server.port}/ws');
  }

  Future<void> _handleRequest(HttpRequest request) async {
    try {
      if (request.uri.path == '/ws' &&
          WebSocketTransformer.isUpgradeRequest(request)) {
        final socket = await WebSocketTransformer.upgrade(request);
        _handleSocket(socket);
      } else {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
      }
    } catch (e) {
      debugPrint('LanSignalingServer: request handling failed: $e');
    }
  }

  void _handleSocket(WebSocket socket) {
    final client = _LanClient(socket);
    _pending.add(client);
    socket.listen(
      (dynamic frame) => _onFrame(client, frame),
      onError: (Object e) {
        debugPrint('LanSignalingServer: socket error: $e');
        _onSocketClosed(client);
      },
      onDone: () => _onSocketClosed(client),
      cancelOnError: false,
    );
  }

  void _onFrame(_LanClient client, dynamic frame) {
    if (frame is! String) return;
    Map<String, dynamic> msg;
    try {
      final decoded = jsonDecode(frame);
      if (decoded is! Map<String, dynamic> || decoded['type'] is! String) return;
      msg = decoded;
    } catch (_) {
      return; // malformed — ignore (forward compatibility)
    }
    try {
      switch (msg['type']) {
        case 'join-room':
          _onJoinRoom(client, msg);
        case 'answer':
          _relayFromPeer(client, {
            'type': 'answer',
            'sdp': msg['sdp'],
            'sdpType': 'answer',
          });
        case 'ice':
          _relayFromPeer(client, {'type': 'ice', 'candidate': msg['candidate']});
        case 'ice-restart':
          _relayFromPeer(client, {'type': 'ice-restart'});
        case 'auth-response':
          if (msg['deviceId'] is String) client.deviceId = msg['deviceId'] as String;
          _relayFromPeer(client, {
            'type': 'auth-response',
            'deviceId': msg['deviceId'],
            'pk': msg['pk'],
            'sig': msg['sig'],
          });
        case 'pair-request':
          unawaited(_onPairRequest(client, msg));
        case 'leave':
          unawaited(_close(client));
        default:
          break; // unknown types ignored (§2)
      }
    } catch (e) {
      debugPrint('LanSignalingServer: frame ${msg['type']} failed: $e');
    }
  }

  void _onJoinRoom(_LanClient client, Map<String, dynamic> msg) {
    // Capacity (§2.1): 1 camera + max parents.
    if (!client.joined && _clients.length >= AppConfig.maxParentsPerRoom) {
      _sendRaw(client, {
        'type': 'error',
        'code': 'ROOM_FULL',
        'message': 'The room is full',
      });
      unawaited(_close(client));
      return;
    }

    // peerId reuse on rejoin (§2.1), else mint a fresh one.
    final requested = msg['peerId'];
    var peerId = client.peerId;
    if (peerId == null) {
      if (requested is String && !_clients.containsKey(requested)) {
        peerId = requested;
      } else {
        peerId = _mintPeerId();
      }
    }

    final auth = msg['auth'];
    final requestedRoom = msg['roomId'];

    if (auth is Map<String, dynamic>) {
      // Trusted-device path: forward to the session, which drives §8.2.
      _register(client, peerId);
      _emit({'type': 'peer-joined', 'peerId': peerId, 'auth': auth});
      _sendRaw(client,
          {'type': 'room-joined', 'roomId': requestedRoom ?? 'LOCAL', 'peerId': peerId});
      return;
    }

    // Guest path (§7): allowed only during pairing or with a matching code.
    final code = roomCode;
    final guestAllowed = pairingActive ||
        (allowCodeJoins && code != null && requestedRoom == code);
    if (!guestAllowed) {
      _sendRaw(client, {
        'type': 'error',
        'code': 'NOT_TRUSTED',
        'message': 'Pair this device or enter the room code',
      });
      unawaited(_close(client));
      return;
    }
    _register(client, peerId);
    // No auth → the session offers directly (guest mode, §8.2 bottom).
    _emit({'type': 'peer-joined', 'peerId': peerId});
    _sendRaw(client,
        {'type': 'room-joined', 'roomId': requestedRoom ?? 'LOCAL', 'peerId': peerId});
  }

  void _register(_LanClient client, String peerId) {
    client.peerId = peerId;
    client.joined = true;
    _pending.remove(client);
    _clients[peerId] = client;
  }

  Future<void> _onPairRequest(_LanClient client, Map<String, dynamic> msg) async {
    // Pairing is a LAN-only ceremony (§7/§8.1).
    final deviceId = msg['deviceId'];
    final name = msg['name'];
    final pk = msg['pk'];
    final proof = msg['proof'];
    if (deviceId is! String ||
        name is! String ||
        pk is! String ||
        proof is! String) {
      _sendRaw(client, {
        'type': 'pair-response',
        'accepted': false,
        'reason': 'malformed pair-request',
      });
      return;
    }
    final outcome = await _auth.verifyPairRequest(PairRequest(
      deviceId: deviceId,
      name: name,
      pk: pk,
      proof: proof,
    ));
    if (outcome.accepted && outcome.device != null) {
      await _trust.add(outcome.device!);
      client.deviceId = deviceId;
      final id = _auth.identity;
      _sendRaw(client, {
        'type': 'pair-response',
        'accepted': true,
        'deviceId': id.deviceId,
        'name': id.name,
        'pk': id.publicKey,
      });
      debugPrint('LanSignalingServer: paired $name ($deviceId)');
    } else {
      _sendRaw(client, {
        'type': 'pair-response',
        'accepted': false,
        'reason': outcome.reason ?? 'pairing failed',
      });
    }
  }

  void _relayFromPeer(_LanClient client, Map<String, dynamic> body) {
    final peerId = client.peerId;
    if (peerId == null) return; // not joined yet
    _emit({...body, 'peerId': peerId});
  }

  void _onSocketClosed(_LanClient client) {
    _pending.remove(client);
    final peerId = client.peerId;
    if (peerId != null && _clients.remove(peerId) != null) {
      _auth.forgetPeer(peerId);
      _emit({'type': 'peer-left', 'peerId': peerId});
    }
  }

  // --- Camera → parent (called by the session's transport bridge) ---

  /// Routes a camera-originated message. Messages carrying a `peerId`
  /// (`offer`/`ice`/`auth-challenge`/`error`) go to that peer; `hb`/`noise`
  /// fan out to every joined parent. A routed `NOT_TRUSTED` error also drops
  /// the socket (§8.2 step 4).
  void send(Map<String, dynamic> message) {
    final type = message['type'];
    if (type == 'leave') return; // camera-level; handled by stop()
    final peerId = message['peerId'];
    if (peerId is String) {
      final client = _clients[peerId];
      if (client == null) return;
      _sendRaw(client, message);
      if (type == 'error' && message['code'] == 'NOT_TRUSTED') {
        unawaited(_close(client));
      }
      return;
    }
    if (type == 'hb' || type == 'noise') {
      for (final client in _clients.values.toList()) {
        _sendRaw(client, message);
      }
    }
  }

  /// Forcibly drops a live peer (e.g. its device was revoked, §8/F12).
  Future<void> dropPeer(String peerId) async {
    final client = _clients[peerId];
    if (client == null) return;
    _sendRaw(client, {
      'type': 'error',
      'code': 'NOT_TRUSTED',
      'message': 'This device was removed',
      'peerId': peerId,
    });
    await _close(client);
  }

  void _sendRaw(_LanClient client, Map<String, dynamic> message) {
    try {
      client.socket.add(jsonEncode(message));
    } catch (e) {
      debugPrint('LanSignalingServer: send ${message['type']} failed: $e');
    }
  }

  Future<void> _close(_LanClient client) async {
    try {
      await client.socket.close();
    } catch (_) {}
    _onSocketClosed(client);
  }

  void _emit(Map<String, dynamic> message) {
    if (!_incoming.isClosed) _incoming.add(message);
  }

  String _mintPeerId() {
    final r = Random.secure();
    final bytes = List<int>.generate(16, (_) => r.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40; // v4
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    String hex(int i) => bytes[i].toRadixString(16).padLeft(2, '0');
    final b = StringBuffer();
    for (var i = 0; i < 16; i++) {
      b.write(hex(i));
      if (i == 3 || i == 5 || i == 7 || i == 9) b.write('-');
    }
    return b.toString();
  }

  /// This device's non-loopback IPv4 addresses, for the pairing payload (§8.1)
  /// and the last-known-LAN-address hint (§7).
  Future<List<String>> localAddresses() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      return [
        for (final ni in interfaces)
          for (final addr in ni.addresses) addr.address,
      ];
    } catch (e) {
      debugPrint('LanSignalingServer: localAddresses failed: $e');
      return const [];
    }
  }

  /// Stops the server and closes every connection.
  Future<void> stop() async {
    final server = _server;
    _server = null;
    for (final client in [..._clients.values, ..._pending]) {
      try {
        await client.socket.close();
      } catch (_) {}
    }
    _clients.clear();
    _pending.clear();
    if (server != null) {
      try {
        await server.close(force: true);
      } catch (e) {
        debugPrint('LanSignalingServer: close failed: $e');
      }
    }
  }

  Future<void> dispose() async {
    await stop();
    await _incoming.close();
  }
}

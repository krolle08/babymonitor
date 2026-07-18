/// Parent-side pairing ceremony client (docs/PROTOCOL.md §8.1, F12).
///
/// After the parent scans the camera's QR ([PairingPayload]), this opens the
/// camera's LAN signaling endpoint directly (`ws://<addr>:<port>/ws`, §7),
/// sends a `pair-request` proving possession of the parent's private key over
/// the one-time token (`AuthEngine.buildPairRequest`), and awaits the camera's
/// `pair-response`. Pairing is a **LAN-only** ceremony — never relayed by the
/// cloud (§7). On success the camera is added to the trust store using the QR's
/// public key (obtained optically = MITM-proof, §8.1 step 2), and its address
/// is remembered so later connects try LAN first (§7 step 1).
///
/// Never throws to the UI (NTR3): connection, parse and timeout failures come
/// back as a [PairingResult.failed].
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:web_socket_channel/web_socket_channel.dart';

import '../core/auth_engine.dart';
import '../core/identity.dart';
import 'crypto_service.dart';
import 'settings_service.dart';
import 'trust_service.dart';

/// Cryptographically-strong random bytes (for the injected [AuthEngine]).
List<int> _secureRandomBytes(int count) {
  final rng = math.Random.secure();
  return List<int>.generate(count, (_) => rng.nextInt(256));
}

/// Outcome of a pairing attempt. On [success] the camera has been added to the
/// trust store and is returned as [camera]; otherwise [reason] is a
/// user-facing explanation.
class PairingResult {
  const PairingResult._(this.success, this.camera, this.reason);

  factory PairingResult.paired(TrustedDevice camera) =>
      PairingResult._(true, camera, null);

  factory PairingResult.failed(String reason) =>
      PairingResult._(false, null, reason);

  final bool success;
  final TrustedDevice? camera;
  final String? reason;
}

class PairingClient {
  PairingClient({
    CryptoService? crypto,
    TrustService? trust,
    SettingsService? settings,
    AuthEngine? authEngine,
    this.connectTimeout = const Duration(seconds: 4),
    this.responseTimeout = const Duration(seconds: 10),
  })  : _crypto = crypto,
        _trust = trust,
        _settings = settings,
        _authEngine = authEngine;

  final Duration connectTimeout;
  final Duration responseTimeout;

  CryptoService? _crypto;
  TrustService? _trust;
  SettingsService? _settings;
  AuthEngine? _authEngine;

  SettingsService get _prefs => _settings ??= SettingsService.instance;
  TrustService get _trustStore => _trust ??= TrustService.instance;

  AuthEngine get _engine {
    final existing = _authEngine;
    if (existing != null) return existing;
    final crypto = _crypto ??= CryptoService.instance;
    return _authEngine = AuthEngine(
      sign: crypto.signer,
      verify: crypto.verifier,
      randomBytes: _secureRandomBytes,
      identity: crypto.identity(_prefs.deviceName),
    );
  }

  /// Runs the §8.1 ceremony against the camera described by [payload]. Tries
  /// each advertised address in turn; the first reachable one is used.
  Future<PairingResult> pair(PairingPayload payload) async {
    // Sign `token ∥ deviceId_parent` → the pair-request proof (§8.1 step 2).
    final PairRequest request;
    try {
      request = await _engine.buildPairRequest(payload.token);
    } catch (e) {
      debugPrint('PairingClient: buildPairRequest failed: $e');
      return PairingResult.failed('Could not sign the pairing request.');
    }

    final urls = _candidateUrls(payload);
    if (urls.isEmpty) {
      return PairingResult.failed(
          'The camera did not share a reachable address.');
    }
    for (final url in urls) {
      final result = await _pairOver(url, payload, request);
      if (result != null) {
        if (result.success) {
          // Try this LAN address first on every later connect (§7 step 1).
          unawaited(_prefs.setLastLanAddress(payload.deviceId, url));
        }
        return result;
      }
      // null → this address was unreachable; fall through to the next.
    }
    return PairingResult.failed(
        'Could not reach the camera on the local network. Make sure both '
        'phones are on the same WiFi and pairing is still open.');
  }

  List<String> _candidateUrls(PairingPayload payload) {
    final urls = <String>[];
    for (final addr in payload.addrs) {
      if (addr.trim().isEmpty) continue;
      final host = addr.contains(':') ? '[$addr]' : addr; // bracket IPv6
      urls.add('ws://$host:${payload.port}/ws');
    }
    return urls;
  }

  /// Runs the ceremony over one endpoint. Returns a [PairingResult] once the
  /// camera answers (accept/reject) or the exchange times out; returns `null`
  /// when the endpoint could not be reached so the caller tries the next.
  Future<PairingResult?> _pairOver(
    String url,
    PairingPayload payload,
    PairRequest request,
  ) async {
    WebSocketChannel channel;
    try {
      channel = WebSocketChannel.connect(Uri.parse(url));
      await channel.ready.timeout(connectTimeout);
    } catch (e) {
      debugPrint('PairingClient: connect $url failed: $e');
      return null;
    }

    final completer = Completer<({bool accepted, String? reason})>();
    StreamSubscription<dynamic>? sub;
    try {
      sub = channel.stream.listen(
        (frame) {
          final parsed = _parsePairResponse(frame);
          if (parsed != null && !completer.isCompleted) {
            completer.complete(parsed);
          }
        },
        onError: (Object e) {
          debugPrint('PairingClient: socket error on $url: $e');
          if (!completer.isCompleted) {
            completer.complete((accepted: false, reason: 'connection dropped'));
          }
        },
        onDone: () {
          if (!completer.isCompleted) {
            completer.complete(
                (accepted: false, reason: 'the camera closed the connection'));
          }
        },
        cancelOnError: false,
      );

      channel.sink.add(jsonEncode({'type': 'pair-request', ...request.toJson()}));

      final answer = await completer.future.timeout(
        responseTimeout,
        onTimeout: () =>
            (accepted: false, reason: 'the camera did not respond in time'),
      );

      if (answer.accepted) {
        // Trust the camera by the QR's key — optical = MITM-proof (§8.1 step 2).
        final camera = TrustedDevice(
          deviceId: payload.deviceId,
          name: payload.name,
          pk: payload.pk,
          role: DeviceRole.camera,
          addedAt: DateTime.now(),
        );
        await _trustStore.add(camera);
        return PairingResult.paired(camera);
      }
      return PairingResult.failed(_humanize(answer.reason));
    } finally {
      await sub?.cancel();
      try {
        await channel.sink.close();
      } catch (_) {}
    }
  }

  /// Parses a frame, returning the accept/reject verdict, or `null` for any
  /// frame that is not a well-formed `pair-response` (ignored, forward-compat).
  ({bool accepted, String? reason})? _parsePairResponse(dynamic frame) {
    if (frame is! String) return null;
    Map<String, dynamic> msg;
    try {
      final decoded = jsonDecode(frame);
      if (decoded is! Map<String, dynamic>) return null;
      msg = decoded;
    } catch (_) {
      return null;
    }
    if (msg['type'] != 'pair-response') return null;
    if (msg['accepted'] == true) return (accepted: true, reason: null);
    final reason = msg['reason'];
    return (accepted: false, reason: reason is String ? reason : null);
  }

  String _humanize(String? reason) {
    if (reason == null || reason.trim().isEmpty) {
      return 'The camera rejected the pairing request.';
    }
    // The camera's reasons are already short and human-readable (§8.1).
    final trimmed = reason.trim();
    final capitalized = trimmed[0].toUpperCase() + trimmed.substring(1);
    return capitalized.endsWith('.') ? capitalized : '$capitalized.';
  }
}

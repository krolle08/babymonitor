/// REST client for the sleep-log backend (docs/PROTOCOL.md §3, §6).
///
/// Every method throws a typed [ApiException] on non-2xx / network failure —
/// EXCEPT [fetchIceConfig], which falls back to the default STUN-only config
/// on any failure (NTR3: the stream must never depend on the API being up).
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config/app_config.dart';
import '../core/models.dart';
import 'settings_service.dart';

/// Typed error for any non-2xx response or transport failure.
class ApiException implements Exception {
  const ApiException({this.statusCode, required this.code, required this.message});

  /// HTTP status, or null for transport-level failures (timeout, refused…).
  final int? statusCode;

  /// Server error code (`error.code` from PROTOCOL §3.4) or a synthetic one:
  /// `TIMEOUT`, `NETWORK`, `BAD_RESPONSE`.
  final String code;

  final String message;

  @override
  String toString() => 'ApiException(${statusCode ?? '-'} $code): $message';
}

/// `GET /api/sessions/:id` result — the session plus its full event list.
class SessionDetail {
  const SessionDetail({required this.session, required this.events});

  final SleepSession session;
  final List<SleepEvent> events;
}

/// Thin wrapper over the PROTOCOL §3 endpoints. Bearer token and base URL are
/// read live from [SettingsService] so Settings-screen edits apply instantly.
class ApiClient {
  ApiClient({http.Client? httpClient, SettingsService? settings})
      : _http = httpClient ?? http.Client(),
        _settings = settings;

  /// Short timeout — a slow backend must never stall callers (NTR3).
  static const Duration timeout = Duration(seconds: 10);

  final http.Client _http;
  final SettingsService? _settings;

  SettingsService get _prefs => _settings ?? SettingsService.instance;

  Uri _uri(String path, [Map<String, String>? query]) {
    final base = _prefs.apiBaseUrl.replaceAll(RegExp(r'/+$'), '');
    final uri = Uri.parse('$base$path');
    return (query == null || query.isEmpty)
        ? uri
        : uri.replace(queryParameters: query);
  }

  /// Performs a request and returns the decoded JSON body (null for empty
  /// bodies, e.g. 204). Throws [ApiException] on any failure.
  Future<dynamic> _request(
    String method,
    String path, {
    Object? body,
    Map<String, String>? query,
  }) async {
    try {
      final request = http.Request(method, _uri(path, query));
      request.headers['Authorization'] = 'Bearer ${_prefs.familyToken}';
      if (body != null) {
        request.headers['Content-Type'] = 'application/json; charset=utf-8';
        request.body = jsonEncode(body);
      }
      final streamed = await _http.send(request).timeout(timeout);
      final response = await http.Response.fromStream(streamed).timeout(timeout);

      if (response.statusCode < 200 || response.statusCode >= 300) {
        var code = 'HTTP_${response.statusCode}';
        var message = 'Request failed with status ${response.statusCode}';
        try {
          final decoded = jsonDecode(response.body);
          final error = (decoded as Map<String, dynamic>)['error'];
          if (error is Map) {
            code = error['code']?.toString() ?? code;
            message = error['message']?.toString() ?? message;
          }
        } catch (_) {
          // Not the PROTOCOL §3.4 envelope — keep the synthetic code/message.
        }
        throw ApiException(
            statusCode: response.statusCode, code: code, message: message);
      }

      if (response.body.isEmpty) return null;
      try {
        return jsonDecode(response.body);
      } catch (_) {
        throw const ApiException(
            code: 'BAD_RESPONSE', message: 'Response body is not valid JSON');
      }
    } on ApiException {
      rethrow;
    } on TimeoutException {
      throw ApiException(
          code: 'TIMEOUT', message: '$method $path timed out after ${timeout.inSeconds}s');
    } catch (e) {
      throw ApiException(code: 'NETWORK', message: '$method $path failed: $e');
    }
  }

  static int _asId(dynamic json) {
    final id = (json as Map<String, dynamic>)['id'];
    if (id is num) return id.toInt();
    throw const ApiException(
        code: 'BAD_RESPONSE', message: 'Missing integer "id" in response');
  }

  // --- Sleep sessions (§3.1) ---

  /// `POST /api/sessions` — returns the new server session id.
  Future<int> createSession({
    required String deviceId,
    required String roomId,
    required DateTime startedAt,
  }) async {
    final json = await _request('POST', '/api/sessions', body: {
      'deviceId': deviceId,
      'roomId': roomId,
      'startedAt': startedAt.toUtc().toIso8601String(),
    });
    return _asId(json);
  }

  /// `PATCH /api/sessions/:id` — close a session.
  Future<void> endSession(int id, DateTime endedAt) async {
    await _request('PATCH', '/api/sessions/$id',
        body: {'endedAt': endedAt.toUtc().toIso8601String()});
  }

  // --- Session events (§3.2) ---

  /// `POST /api/sessions/:id/events` — batch upload; returns inserted count.
  Future<int> postEvents(int sessionId, List<SleepEvent> events) async {
    final json = await _request('POST', '/api/sessions/$sessionId/events',
        body: events.map((e) => e.toJson()).toList());
    final inserted = (json as Map<String, dynamic>)['inserted'];
    return inserted is num ? inserted.toInt() : events.length;
  }

  /// `GET /api/sessions?from&to` — sessions with event counts.
  Future<List<SleepSession>> getSessions({DateTime? from, DateTime? to}) async {
    final json = await _request('GET', '/api/sessions', query: {
      if (from != null) 'from': from.toUtc().toIso8601String(),
      if (to != null) 'to': to.toUtc().toIso8601String(),
    });
    return (json as List<dynamic>)
        .map((e) => SleepSession.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// `GET /api/sessions/:id` — session plus its full event list.
  Future<SessionDetail> getSessionDetail(int id) async {
    final json = await _request('GET', '/api/sessions/$id');
    final map = json as Map<String, dynamic>;
    final events = (map['events'] as List<dynamic>? ?? const [])
        .map((e) => SleepEvent.fromJson(e as Map<String, dynamic>))
        .toList();
    return SessionDetail(session: SleepSession.fromJson(map), events: events);
  }

  // --- Flags (§3.3) ---

  /// `POST /api/flags` — returns the new flag id.
  Future<int> addFlag(SleepFlag flag) async {
    final json = await _request('POST', '/api/flags', body: {
      'date': flag.date,
      'label': flag.label,
      if (flag.note != null) 'note': flag.note,
    });
    return _asId(json);
  }

  /// `GET /api/flags?from&to` — dates are `YYYY-MM-DD` strings.
  Future<List<SleepFlag>> getFlags({String? from, String? to}) async {
    final json = await _request('GET', '/api/flags', query: {
      'from': ?from,
      'to': ?to,
    });
    return (json as List<dynamic>)
        .map((e) => SleepFlag.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// `DELETE /api/flags/:id`.
  Future<void> deleteFlag(int id) async {
    await _request('DELETE', '/api/flags/$id');
  }

  // --- ICE config (§6) ---

  /// `GET /api/ice-config`. NEVER throws: on any failure it returns the
  /// default STUN-only config so a dead backend cannot block the stream
  /// (NTR3; TURN is then unavailable, but P2P still works).
  Future<List<Map<String, dynamic>>> fetchIceConfig() async {
    try {
      final json = await _request('GET', '/api/ice-config');
      final servers = (json as Map<String, dynamic>)['iceServers'];
      if (servers is List && servers.isNotEmpty) {
        return servers
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList();
      }
    } catch (_) {
      // Fall through to the STUN-only default.
    }
    return [
      {'urls': AppConfig.defaultStunUrl},
    ];
  }

  /// Release the underlying HTTP client.
  void dispose() {
    _http.close();
  }
}

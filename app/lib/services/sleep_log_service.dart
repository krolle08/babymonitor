/// Offline-resilient sleep logger (F9, docs/PROTOCOL.md §3.1–3.2, NTR3).
///
/// Sessions and events are recorded in an in-memory queue that is mirrored to
/// a JSON file (path_provider) so nothing is lost across restarts. A
/// background loop flushes the queue to the REST API in batches; failures
/// retry on the [BackoffScheduler] schedule. Every public logging method is
/// fire-and-forget: it NEVER throws and NEVER blocks the caller — a dead
/// backend must be invisible to the live stream (F9 AC).
///
/// Events logged before the session has a server id are queued against a
/// local temp id and re-targeted automatically once the id arrives.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:path_provider/path_provider.dart';

import '../config/app_config.dart';
import '../core/backoff_scheduler.dart';
import '../core/models.dart';
import 'api_client.dart';
import 'settings_service.dart';

/// One monitoring run pending upload. `serverId == null` until the first
/// successful `POST /api/sessions`.
class _PendingSession {
  _PendingSession({
    required this.localId,
    required this.deviceId,
    required this.roomId,
    required this.startedAt,
    this.serverId,
    this.endedAt,
    this.endSynced = false,
  });

  final String localId;
  final String deviceId;
  final String roomId;
  final DateTime startedAt;
  int? serverId;
  DateTime? endedAt;
  bool endSynced;

  Map<String, dynamic> toJson() => {
        'localId': localId,
        'deviceId': deviceId,
        'roomId': roomId,
        'startedAt': startedAt.toUtc().toIso8601String(),
        if (serverId != null) 'serverId': serverId,
        if (endedAt != null) 'endedAt': endedAt!.toUtc().toIso8601String(),
        'endSynced': endSynced,
      };

  static _PendingSession fromJson(Map<String, dynamic> json) => _PendingSession(
        localId: json['localId'] as String,
        deviceId: json['deviceId'] as String,
        roomId: json['roomId'] as String,
        startedAt: DateTime.parse(json['startedAt'] as String),
        serverId: (json['serverId'] as num?)?.toInt(),
        endedAt: json['endedAt'] == null
            ? null
            : DateTime.parse(json['endedAt'] as String),
        endSynced: json['endSynced'] as bool? ?? false,
      );
}

/// An event awaiting upload, attached to its session's *local* id so it can
/// be re-targeted when the server id arrives.
class _PendingEvent {
  _PendingEvent({required this.sessionLocalId, required this.event});

  final String sessionLocalId;
  final SleepEvent event;

  Map<String, dynamic> toJson() =>
      {'sessionLocalId': sessionLocalId, 'event': event.toJson()};

  static _PendingEvent fromJson(Map<String, dynamic> json) => _PendingEvent(
        sessionLocalId: json['sessionLocalId'] as String,
        event: SleepEvent.fromJson(json['event'] as Map<String, dynamic>),
      );
}

class SleepLogService {
  SleepLogService({
    ApiClient? api,
    SettingsService? settings,
    this.flushInterval = AppConfig.logFlushInterval,
    this.batchMax = AppConfig.logBatchMax,
    BackoffScheduler? backoff,
    DateTime Function() now = DateTime.now,
    Future<Directory> Function()? directoryProvider,
  })  : _api = api ?? ApiClient(),
        _settings = settings,
        _backoff = backoff ?? BackoffScheduler(),
        _now = now,
        _directoryProvider =
            directoryProvider ?? getApplicationDocumentsDirectory;

  static const String queueFileName = 'sleep_log_queue.json';

  final ApiClient _api;
  final SettingsService? _settings;
  final BackoffScheduler _backoff;
  final DateTime Function() _now;
  final Future<Directory> Function() _directoryProvider;
  final Duration flushInterval;
  final int batchMax;

  final List<_PendingSession> _sessions = [];
  final List<_PendingEvent> _events = [];
  final Random _random = Random();

  File? _queueFile;
  String? _currentLocalId;
  Timer? _flushTimer;
  bool _flushing = false;
  bool _started = false;
  bool _disposed = false;

  SettingsService get _prefs => _settings ?? SettingsService.instance;

  /// Number of items (sessions + events) still awaiting upload.
  int get pendingCount => _sessions.length + _events.length;

  /// Loads the persisted queue (queue survives restart — F9 AC) and starts
  /// the background flush loop. Never throws.
  Future<void> start() async {
    if (_started || _disposed) return;
    _started = true;
    try {
      final dir = await _directoryProvider();
      _queueFile = File('${dir.path}${Platform.pathSeparator}$queueFileName');
      await _loadQueue();
    } catch (e) {
      debugPrint('SleepLogService: queue load failed (starting empty): $e');
    }
    _scheduleFlush(Duration.zero); // drain anything left over immediately
  }

  // --- Public logging API (fire-and-forget, F9: never throw, never block) ---

  /// Records the start of a monitoring session. The local record exists
  /// immediately; the POST happens in the background and the returned server
  /// id is remembered for event uploads.
  void logSessionStart(String roomId) {
    try {
      final session = _PendingSession(
        localId: _newLocalId(),
        deviceId: _prefs.deviceId,
        roomId: roomId,
        startedAt: _now(),
      );
      _sessions.add(session);
      _currentLocalId = session.localId;
      _persistSoon();
      _scheduleFlush(Duration.zero);
    } catch (e) {
      debugPrint('SleepLogService: logSessionStart failed: $e');
    }
  }

  /// Queues one event on the current session. Dropped (with a debug log) if
  /// no session is open.
  void logEvent(SleepEvent event) {
    try {
      final localId = _currentLocalId;
      if (localId == null) {
        debugPrint('SleepLogService: dropped ${event.type} (no open session)');
        return;
      }
      _events.add(_PendingEvent(sessionLocalId: localId, event: event));
      _persistSoon();
    } catch (e) {
      debugPrint('SleepLogService: logEvent failed: $e');
    }
  }

  /// Marks the current session ended; the PATCH happens in the background.
  void logSessionEnd() {
    try {
      final localId = _currentLocalId;
      _currentLocalId = null;
      if (localId == null) return;
      for (final session in _sessions) {
        if (session.localId == localId) {
          session.endedAt = _now();
          break;
        }
      }
      _persistSoon();
      _scheduleFlush(Duration.zero);
    } catch (e) {
      debugPrint('SleepLogService: logSessionEnd failed: $e');
    }
  }

  /// Triggers an immediate flush attempt (also used by tests). Never throws.
  Future<void> flushNow() => _flush();

  /// Stops the flush loop and persists whatever is still queued.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _flushTimer?.cancel();
    _flushTimer = null;
    await _persist();
  }

  // --- Flush loop ---

  void _scheduleFlush(Duration delay) {
    if (_disposed || !_started) return;
    _flushTimer?.cancel();
    _flushTimer = Timer(delay, () {
      unawaited(_flush());
    });
  }

  /// One flush pass. Reschedules itself: on success every [flushInterval],
  /// on failure on the backoff schedule (last entry repeats — the queue keeps
  /// draining whenever connectivity returns, F9 AC).
  Future<void> _flush() async {
    if (_flushing || _disposed) return;
    _flushing = true;
    var ok = true;
    try {
      ok = await _flushOnce();
    } catch (e) {
      ok = false;
      debugPrint('SleepLogService: flush failed: $e');
    } finally {
      _flushing = false;
      if (ok) {
        _backoff.reset();
        _scheduleFlush(flushInterval);
      } else {
        final delay = _backoff.nextDelay();
        debugPrint(
            'SleepLogService: retrying flush in ${delay.inSeconds}s (attempt ${_backoff.attempts})');
        _scheduleFlush(delay);
      }
    }
  }

  /// Returns false when the backend is unreachable (retry later).
  Future<bool> _flushOnce() async {
    var dirty = false;
    try {
      for (final session in List<_PendingSession>.of(_sessions)) {
        // 1. Ensure the session has a server id (POST /api/sessions).
        if (session.serverId == null) {
          try {
            session.serverId = await _api.createSession(
              deviceId: session.deviceId,
              roomId: session.roomId,
              startedAt: session.startedAt,
            );
            dirty = true;
          } on ApiException catch (e) {
            debugPrint('SleepLogService: createSession failed: $e');
            return false; // server unreachable — nothing else will work either
          }
        }
        final serverId = session.serverId!;

        // 2. Upload this session's events in batches of [batchMax] —
        //    re-targeted from the local temp id to the server id here.
        while (true) {
          final batch = _events
              .where((e) => e.sessionLocalId == session.localId)
              .take(batchMax)
              .toList();
          if (batch.isEmpty) break;
          try {
            await _api.postEvents(
                serverId, batch.map((e) => e.event).toList());
          } on ApiException catch (e) {
            debugPrint('SleepLogService: postEvents failed: $e');
            return false;
          }
          for (final sent in batch) {
            _events.remove(sent);
          }
          dirty = true;
        }

        // 3. Close the session server-side once all its events are up.
        if (session.endedAt != null && !session.endSynced) {
          try {
            await _api.endSession(serverId, session.endedAt!);
            session.endSynced = true;
            dirty = true;
          } on ApiException catch (e) {
            debugPrint('SleepLogService: endSession failed: $e');
            return false;
          }
        }

        // 4. Fully synced sessions leave the queue.
        if (session.endSynced &&
            !_events.any((e) => e.sessionLocalId == session.localId)) {
          _sessions.remove(session);
          dirty = true;
        }
      }
      return true;
    } finally {
      if (dirty) await _persist();
    }
  }

  // --- Persistence (JSON file via path_provider) ---

  Future<void> _loadQueue() async {
    final file = _queueFile;
    if (file == null || !await file.exists()) return;
    try {
      final decoded = jsonDecode(await file.readAsString());
      final map = decoded as Map<String, dynamic>;
      _sessions
        ..clear()
        ..addAll((map['sessions'] as List<dynamic>? ?? const [])
            .map((e) => _PendingSession.fromJson(e as Map<String, dynamic>)));
      _events
        ..clear()
        ..addAll((map['events'] as List<dynamic>? ?? const [])
            .map((e) => _PendingEvent.fromJson(e as Map<String, dynamic>)));
      // A session restored without an end means the app died mid-run: close
      // it at load time so the queue always drains (approximation noted in
      // the history rather than a forever-dangling open session).
      for (final session in _sessions) {
        if (session.endedAt == null) {
          session.endedAt = _now();
          debugPrint(
              'SleepLogService: closed stale session ${session.localId} from a previous run');
        }
      }
    } catch (e) {
      debugPrint('SleepLogService: corrupt queue file ignored: $e');
    }
  }

  /// Persist without making the caller wait; errors are swallowed.
  void _persistSoon() {
    unawaited(_persist());
  }

  Future<void> _lastWrite = Future<void>.value();

  /// Writes are chained so concurrent persists never interleave in the file.
  Future<void> _persist() {
    final file = _queueFile;
    if (file == null) return Future<void>.value();
    final json = jsonEncode({
      'sessions': _sessions.map((s) => s.toJson()).toList(),
      'events': _events.map((e) => e.toJson()).toList(),
    });
    return _lastWrite = _lastWrite.then((_) async {
      try {
        await file.writeAsString(json, flush: true);
      } catch (e) {
        debugPrint('SleepLogService: persist failed: $e');
      }
    });
  }

  String _newLocalId() =>
      'local-${_now().microsecondsSinceEpoch}-${_random.nextInt(0xFFFFFF)}';
}

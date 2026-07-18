/// Pure-Dart domain models for sleep logging (docs/PROTOCOL.md §3).
/// No Flutter imports allowed in lib/core (NTR5).
library;

class SleepSession {
  final int? id; // server-assigned; null until first successful POST
  final String deviceId;
  final String roomId;
  final DateTime startedAt;
  final DateTime? endedAt;
  final Map<String, int> eventCounts;

  const SleepSession({
    this.id,
    required this.deviceId,
    required this.roomId,
    required this.startedAt,
    this.endedAt,
    this.eventCounts = const {},
  });

  Map<String, dynamic> toJson() => {
        if (id != null) 'id': id,
        'deviceId': deviceId,
        'roomId': roomId,
        'startedAt': startedAt.toUtc().toIso8601String(),
        if (endedAt != null) 'endedAt': endedAt!.toUtc().toIso8601String(),
      };

  factory SleepSession.fromJson(Map<String, dynamic> json) => SleepSession(
        id: json['id'] as int?,
        deviceId: json['deviceId'] as String,
        roomId: json['roomId'] as String,
        startedAt: DateTime.parse(json['startedAt'] as String),
        endedAt: json['endedAt'] == null
            ? null
            : DateTime.parse(json['endedAt'] as String),
        eventCounts: (json['eventCounts'] as Map<String, dynamic>? ?? {})
            .map((k, v) => MapEntry(k, v as int)),
      );

  Duration? get duration => endedAt?.difference(startedAt);

  SleepSession copyWith({int? id, DateTime? endedAt}) => SleepSession(
        id: id ?? this.id,
        deviceId: deviceId,
        roomId: roomId,
        startedAt: startedAt,
        endedAt: endedAt ?? this.endedAt,
        eventCounts: eventCounts,
      );
}

/// Event types: 'noise' | 'freeze' | 'reconnect' | 'state' | 'latency'
/// (server stores unknown types verbatim — forward compatible).
class SleepEvent {
  final String type;
  final DateTime at;
  final Map<String, dynamic> data;

  const SleepEvent({required this.type, required this.at, this.data = const {}});

  Map<String, dynamic> toJson() => {
        'type': type,
        'at': at.toUtc().toIso8601String(),
        'data': data,
      };

  factory SleepEvent.fromJson(Map<String, dynamic> json) => SleepEvent(
        type: json['type'] as String,
        at: DateTime.parse(json['at'] as String),
        data: (json['data'] as Map<String, dynamic>?) ?? const {},
      );
}

/// A parent-added annotation for a date: "Teething", "Sick", "Travel"…
class SleepFlag {
  final int? id;
  final String date; // YYYY-MM-DD
  final String label;
  final String? note;

  const SleepFlag({this.id, required this.date, required this.label, this.note});

  static const suggestedLabels = [
    'Teething',
    'Sick',
    'Vaccination',
    'Travel',
    'Growth spurt',
    'New routine',
  ];

  Map<String, dynamic> toJson() => {
        if (id != null) 'id': id,
        'date': date,
        'label': label,
        if (note != null) 'note': note,
      };

  factory SleepFlag.fromJson(Map<String, dynamic> json) => SleepFlag(
        id: json['id'] as int?,
        date: json['date'] as String,
        label: json['label'] as String,
        note: json['note'] as String?,
      );
}

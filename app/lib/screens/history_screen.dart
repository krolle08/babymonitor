/// Sleep history screen (spec F9/F10, docs/PROTOCOL.md §3).
///
/// Date-range view (14 days by default) with per-night horizontal bars of
/// session spans (custom painter), noise-event dots on the bars, a session
/// list (start–end, duration, event counts) and per-date flag chips. FAB adds
/// a flag (suggested labels + free text); long-press deletes one. Pull to
/// refresh. Server down → friendly retry message, never a crash (NTR3).
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../core/models.dart';
import '../services/api_client.dart';

class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  static const int _defaultRangeDays = 14;

  final ApiClient _api = ApiClient();

  bool _loaded = false;
  String? _error;
  List<SleepSession> _sessions = const [];
  List<SleepFlag> _flags = const [];
  Map<int, List<DateTime>> _noiseTimes = const {};
  late DateTimeRange _range;

  @override
  void initState() {
    super.initState();
    final today = DateTime.now();
    _range = DateTimeRange(
      start: today.subtract(const Duration(days: _defaultRangeDays - 1)),
      end: today,
    );
    unawaited(_load());
  }

  @override
  void dispose() {
    _api.dispose();
    super.dispose();
  }

  String _dateKey(DateTime date) => DateFormat('yyyy-MM-dd').format(date);

  Future<void> _load() async {
    try {
      final from = DateTime(
        _range.start.year,
        _range.start.month,
        _range.start.day,
      );
      final to = DateTime(
        _range.end.year,
        _range.end.month,
        _range.end.day + 1,
      );
      final sessions = await _api.getSessions(from: from, to: to);
      final flags = await _api.getFlags(
        from: _dateKey(_range.start),
        to: _dateKey(_range.end),
      );
      // Noise dots need event times, which the list endpoint doesn't carry —
      // fetch details for sessions that logged noise; dots are optional, so
      // individual failures are ignored.
      final noiseTimes = <int, List<DateTime>>{};
      await Future.wait(
        sessions
            .where((s) => s.id != null && (s.eventCounts['noise'] ?? 0) > 0)
            .map((s) async {
          try {
            final detail = await _api.getSessionDetail(s.id!);
            noiseTimes[s.id!] = [
              for (final event in detail.events)
                if (event.type == 'noise') event.at.toLocal(),
            ];
          } on ApiException {
            // Bars still render without dots.
          }
        }),
      );
      if (!mounted) return;
      setState(() {
        _sessions = sessions;
        _flags = flags;
        _noiseTimes = noiseTimes;
        _error = null;
        _loaded = true;
      });
    } on ApiException catch (e) {
      _onLoadError(
        'The server could not be reached (${e.code}). Check your connection '
        'and the server settings, then try again.',
      );
    } catch (e) {
      _onLoadError('Something went wrong loading the history: $e');
    }
  }

  void _onLoadError(String message) {
    if (!mounted) return;
    if (_loaded) {
      // Keep showing the data we have; surface the refresh failure quietly.
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Couldn\'t refresh — server unreachable')),
      );
    } else {
      setState(() => _error = message);
    }
  }

  Future<void> _pickRange() async {
    final now = DateTime.now();
    final picked = await showDateRangePicker(
      context: context,
      firstDate: now.subtract(const Duration(days: 365)),
      lastDate: now,
      initialDateRange: _range,
    );
    if (picked == null || !mounted) return;
    setState(() {
      _range = picked;
      _loaded = false;
      _error = null;
    });
    await _load();
  }

  Future<void> _addFlag() async {
    final flag = await showDialog<SleepFlag>(
      context: context,
      builder: (_) => _AddFlagDialog(initialDate: DateTime.now()),
    );
    if (flag == null || !mounted) return;
    try {
      await _api.addFlag(flag);
      if (!mounted) return;
      await _load();
    } on ApiException {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Couldn\'t save the flag — server unreachable'),
        ),
      );
    }
  }

  Future<void> _confirmDeleteFlag(SleepFlag flag) async {
    if (flag.id == null) return;
    final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Delete flag?'),
            content: Text('Remove "${flag.label}" from ${flag.date}?'),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('Delete'),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed || !mounted) return;
    try {
      await _api.deleteFlag(flag.id!);
      if (!mounted) return;
      await _load();
    } on ApiException {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Couldn\'t delete the flag — server unreachable'),
        ),
      );
    }
  }

  // --- Day aggregation ---

  double _fracOfDay(DateTime dayStart, DateTime time) {
    final frac =
        time.difference(dayStart).inSeconds / Duration.secondsPerDay;
    return frac.clamp(0.0, 1.0);
  }

  List<_DayEntry> _buildDays() {
    final map = <String, _DayEntry>{};
    _DayEntry entryFor(DateTime day) =>
        map.putIfAbsent(_dateKey(day), () => _DayEntry(day));

    final now = DateTime.now();
    for (final session in _sessions) {
      var cursor = session.startedAt.toLocal();
      final end = (session.endedAt ?? now).toLocal();
      entryFor(DateTime(cursor.year, cursor.month, cursor.day))
          .sessions
          .add(session);
      // Split the monitored span into per-calendar-date bar segments so a
      // night that crosses midnight shows up on both dates.
      while (cursor.isBefore(end)) {
        final dayStart = DateTime(cursor.year, cursor.month, cursor.day);
        final nextDay = DateTime(dayStart.year, dayStart.month, dayStart.day + 1);
        final segmentEnd = end.isBefore(nextDay) ? end : nextDay;
        entryFor(dayStart).segments.add((
          start: _fracOfDay(dayStart, cursor),
          end: _fracOfDay(dayStart, segmentEnd),
        ));
        cursor = segmentEnd;
      }
      final noise = session.id == null
          ? const <DateTime>[]
          : (_noiseTimes[session.id!] ?? const <DateTime>[]);
      for (final time in noise) {
        final dayStart = DateTime(time.year, time.month, time.day);
        entryFor(dayStart).noiseFracs.add(_fracOfDay(dayStart, time));
      }
    }
    for (final flag in _flags) {
      final parsed = DateTime.tryParse(flag.date);
      if (parsed == null) continue;
      entryFor(DateTime(parsed.year, parsed.month, parsed.day)).flags.add(flag);
    }
    return map.values.toList()..sort((a, b) => b.date.compareTo(a.date));
  }

  // --- UI ---

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('History'),
        actions: [
          IconButton(
            icon: const Icon(Icons.date_range),
            tooltip: 'Change date range',
            onPressed: () => unawaited(_pickRange()),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => unawaited(_addFlag()),
        icon: const Icon(Icons.flag_outlined),
        label: const Text('Add flag'),
      ),
      body: _buildBody(context),
    );
  }

  Widget _buildBody(BuildContext context) {
    final theme = Theme.of(context);
    if (!_loaded) {
      final error = _error;
      if (error != null) {
        return Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.cloud_off,
                  size: 48,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(height: 12),
                Text('Can\'t load history', style: theme.textTheme.titleMedium),
                const SizedBox(height: 8),
                Text(
                  error,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: () => unawaited(_load()),
                  icon: const Icon(Icons.refresh),
                  label: const Text('Try again'),
                ),
              ],
            ),
          ),
        );
      }
      return const Center(child: CircularProgressIndicator());
    }

    final days = _buildDays();
    final rangeLabel = '${DateFormat('d MMM').format(_range.start)} – '
        '${DateFormat('d MMM').format(_range.end)}';
    return RefreshIndicator(
      onRefresh: _load,
      child: days.isEmpty
          ? ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              children: [
                const SizedBox(height: 140),
                Icon(
                  Icons.bedtime_outlined,
                  size: 48,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(height: 12),
                Center(
                  child: Text(
                    'No sessions in $rangeLabel',
                    style: theme.textTheme.titleMedium,
                  ),
                ),
                const SizedBox(height: 8),
                Center(
                  child: Text(
                    'Start monitoring on the camera phone and the\n'
                    'nights will show up here.',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                ),
              ],
            )
          : ListView.builder(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 96),
              itemCount: days.length + 1,
              itemBuilder: (context, index) {
                if (index == 0) {
                  return Padding(
                    padding: const EdgeInsets.only(left: 4, bottom: 8),
                    child: Text(
                      rangeLabel,
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  );
                }
                return _DayCard(
                  entry: days[index - 1],
                  onDeleteFlag: (flag) => unawaited(_confirmDeleteFlag(flag)),
                );
              },
            ),
    );
  }
}

/// One calendar date's aggregated view.
class _DayEntry {
  _DayEntry(this.date);

  /// Local midnight of this date.
  final DateTime date;

  /// Monitored spans as 0–1 fractions of the 24 h day.
  final List<({double start, double end})> segments = [];

  /// Noise events as 0–1 fractions of the day.
  final List<double> noiseFracs = [];

  /// Sessions that started on this date.
  final List<SleepSession> sessions = [];

  final List<SleepFlag> flags = [];

  Duration get totalMonitored {
    var seconds = 0.0;
    for (final segment in segments) {
      seconds += (segment.end - segment.start) * Duration.secondsPerDay;
    }
    return Duration(seconds: seconds.round());
  }
}

String _formatDuration(Duration duration) {
  final hours = duration.inHours;
  final minutes = duration.inMinutes % 60;
  return hours > 0 ? '${hours}h ${minutes}m' : '${minutes}m';
}

class _DayCard extends StatelessWidget {
  const _DayCard({required this.entry, required this.onDeleteFlag});

  final _DayEntry entry;
  final void Function(SleepFlag flag) onDeleteFlag;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final total = entry.totalMonitored;
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  DateFormat('EEE d MMM').format(entry.date),
                  style: theme.textTheme.titleMedium,
                ),
                const Spacer(),
                if (total > Duration.zero)
                  Text(
                    _formatDuration(total),
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: scheme.onSurfaceVariant),
                  ),
              ],
            ),
            const SizedBox(height: 10),
            SizedBox(
              height: 26,
              width: double.infinity,
              child: CustomPaint(
                painter: _DayBarPainter(
                  segments: entry.segments,
                  noiseFracs: entry.noiseFracs,
                  trackColor: scheme.surfaceContainerHighest,
                  barColor: scheme.primary,
                  dotColor: const Color(0xFFF59E0B),
                  tickColor: scheme.outlineVariant,
                ),
              ),
            ),
            const SizedBox(height: 4),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                for (final label in const ['00', '06', '12', '18', '24'])
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: 10,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
            if (entry.flags.isNotEmpty) ...[
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final flag in entry.flags)
                    Tooltip(
                      message: 'Long-press to delete',
                      child: GestureDetector(
                        onLongPress: () => onDeleteFlag(flag),
                        child: Chip(
                          avatar: const Icon(
                            Icons.flag,
                            size: 14,
                            color: Color(0xFFF59E0B),
                          ),
                          label: Text(
                            (flag.note == null || flag.note!.isEmpty)
                                ? flag.label
                                : '${flag.label} — ${flag.note}',
                          ),
                          visualDensity: VisualDensity.compact,
                        ),
                      ),
                    ),
                ],
              ),
            ],
            if (entry.sessions.isNotEmpty) ...[
              const SizedBox(height: 6),
              for (final session in entry.sessions)
                _SessionRow(session: session),
            ],
          ],
        ),
      ),
    );
  }
}

class _SessionRow extends StatelessWidget {
  const _SessionRow({required this.session});

  final SleepSession session;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final start = DateFormat('HH:mm').format(session.startedAt.toLocal());
    final endedAt = session.endedAt;
    final end =
        endedAt == null ? 'ongoing' : DateFormat('HH:mm').format(endedAt.toLocal());
    final duration = session.duration;
    final span =
        duration == null ? '$start – $end' : '$start – $end · ${_formatDuration(duration)}';
    final counts = session.eventCounts;
    final countsLabel = 'noise ${counts['noise'] ?? 0} · '
        'freezes ${counts['freeze'] ?? 0} · '
        'reconnects ${counts['reconnect'] ?? 0}';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.bedtime_outlined, size: 16, color: scheme.onSurfaceVariant),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(span, style: theme.textTheme.bodyMedium),
                Text(
                  countsLabel,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 24-hour track with monitored-span bars and noise-event dots.
class _DayBarPainter extends CustomPainter {
  _DayBarPainter({
    required this.segments,
    required this.noiseFracs,
    required this.trackColor,
    required this.barColor,
    required this.dotColor,
    required this.tickColor,
  });

  final List<({double start, double end})> segments;
  final List<double> noiseFracs;
  final Color trackColor;
  final Color barColor;
  final Color dotColor;
  final Color tickColor;

  @override
  void paint(Canvas canvas, Size size) {
    final centerY = size.height / 2;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(0, centerY - 5, size.width, 10),
        const Radius.circular(5),
      ),
      Paint()..color = trackColor,
    );
    final tickPaint = Paint()
      ..color = tickColor
      ..strokeWidth = 1;
    for (final frac in const [0.25, 0.5, 0.75]) {
      final x = frac * size.width;
      canvas.drawLine(Offset(x, centerY - 8), Offset(x, centerY + 8), tickPaint);
    }
    final barPaint = Paint()..color = barColor;
    for (final segment in segments) {
      final left = segment.start * size.width;
      final right = math.max(segment.end * size.width, left + 3);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTRB(left, centerY - 5, right, centerY + 5),
          const Radius.circular(5),
        ),
        barPaint,
      );
    }
    final dotPaint = Paint()..color = dotColor;
    for (final frac in noiseFracs) {
      canvas.drawCircle(Offset(frac * size.width, centerY), 3, dotPaint);
    }
  }

  @override
  bool shouldRepaint(_DayBarPainter oldDelegate) =>
      !identical(oldDelegate.segments, segments) ||
      !identical(oldDelegate.noiseFracs, noiseFracs) ||
      oldDelegate.trackColor != trackColor ||
      oldDelegate.barColor != barColor ||
      oldDelegate.dotColor != dotColor ||
      oldDelegate.tickColor != tickColor;
}

/// Add-flag dialog (F10): date picker, suggested label chips, free-text
/// label and optional note. Pops with the [SleepFlag] to create.
class _AddFlagDialog extends StatefulWidget {
  const _AddFlagDialog({required this.initialDate});

  final DateTime initialDate;

  @override
  State<_AddFlagDialog> createState() => _AddFlagDialogState();
}

class _AddFlagDialogState extends State<_AddFlagDialog> {
  late DateTime _date = widget.initialDate;
  final TextEditingController _label = TextEditingController();
  final TextEditingController _note = TextEditingController();

  @override
  void dispose() {
    _label.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: now.subtract(const Duration(days: 365)),
      lastDate: now,
    );
    if (picked != null && mounted) setState(() => _date = picked);
  }

  @override
  Widget build(BuildContext context) {
    final canSave = _label.text.trim().isNotEmpty;
    return AlertDialog(
      title: const Text('Add flag'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            OutlinedButton.icon(
              onPressed: () => unawaited(_pickDate()),
              icon: const Icon(Icons.calendar_today, size: 16),
              label: Text(DateFormat('EEE d MMM yyyy').format(_date)),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final suggestion in SleepFlag.suggestedLabels)
                  ChoiceChip(
                    label: Text(suggestion),
                    selected: _label.text == suggestion,
                    onSelected: (selected) => setState(
                      () => _label.text = selected ? suggestion : '',
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _label,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                labelText: 'Label',
                hintText: 'e.g. Teething',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _note,
              decoration: const InputDecoration(
                labelText: 'Note (optional)',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: canSave
              ? () {
                  final note = _note.text.trim();
                  Navigator.of(context).pop(
                    SleepFlag(
                      date: DateFormat('yyyy-MM-dd').format(_date),
                      label: _label.text.trim(),
                      note: note.isEmpty ? null : note,
                    ),
                  );
                }
              : null,
          child: const Text('Save'),
        ),
      ],
    );
  }
}

/// Camera controls — picture (F15) and sound filter (F13) — in one panel.
///
/// The same widget is used on the camera unit (applies locally) and on a
/// parent unit while watching (the change travels to the camera on the
/// `health` data channel, §4). The camera is always the source of truth: it
/// applies what the hardware allows and broadcasts the result back, so a knob
/// it refuses — a phone with no torch, say — snaps back here.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../config/app_config.dart';
import '../core/camera_controls.dart';
import 'sound_level_meter.dart';

/// Opens the panel as a bottom sheet over whatever is playing.
Future<void> showCameraControlsSheet(
  BuildContext context, {
  required CameraState initialState,
  required ValueChanged<CameraControls> onChanged,
  Stream<CameraState>? states,
  Stream<double>? levels,
  ValueChanged<CameraControls>? onPreview,
  bool enabled = true,
  String? disabledHint,
  String? meterNote,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    backgroundColor: Theme.of(context).colorScheme.surfaceContainerLow,
    builder: (context) => SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.85,
        ),
        child: CameraControlsPanel(
          initialState: initialState,
          states: states,
          levels: levels,
          onChanged: onChanged,
          onPreview: onPreview,
          enabled: enabled,
          disabledHint: disabledHint,
          meterNote: meterNote,
        ),
      ),
    ),
  );
}

class CameraControlsPanel extends StatefulWidget {
  const CameraControlsPanel({
    super.key,
    required this.initialState,
    required this.onChanged,
    this.states,
    this.levels,
    this.onPreview,
    this.enabled = true,
    this.disabledHint,
    this.meterNote,
  });

  /// What the camera is set to right now.
  final CameraState initialState;

  /// Later broadcasts from the camera (authoritative).
  final Stream<CameraState>? states;

  /// Live audio level for the meter (0.0–1.0).
  final Stream<double>? levels;

  /// A settled change the camera should apply and remember.
  final ValueChanged<CameraControls> onChanged;

  /// Every intermediate value while a slider is being dragged, so the picture
  /// behind the sheet reacts immediately without spamming the camera.
  final ValueChanged<CameraControls>? onPreview;

  /// False when the controls cannot reach the camera (no data channel yet).
  final bool enabled;

  final String? disabledHint;

  /// Shown under the meter when the level reading is not live — the camera
  /// reads its level off the outbound stream, so it needs a watcher.
  final String? meterNote;

  @override
  State<CameraControlsPanel> createState() => _CameraControlsPanelState();
}

class _CameraControlsPanelState extends State<CameraControlsPanel> {
  late CameraState _state;
  StreamSubscription<CameraState>? _stateSub;
  bool _dragging = false;

  CameraControls get _controls => _state.controls;
  SoundFilter get _sound => _controls.sound;

  @override
  void initState() {
    super.initState();
    _state = widget.initialState;
    _stateSub = widget.states?.listen((state) {
      // Never yank a slider out from under a thumb that is mid-drag.
      if (!mounted || _dragging) return;
      setState(() => _state = state);
    });
  }

  @override
  void dispose() {
    unawaited(_stateSub?.cancel());
    super.dispose();
  }

  void _preview(CameraControls next) {
    setState(() => _state = CameraState(
          controls: next,
          capabilities: _state.capabilities,
        ));
    widget.onPreview?.call(next);
  }

  void _commit(CameraControls next) {
    _preview(next);
    widget.onChanged(next);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
      shrinkWrap: true,
      children: [
        Row(
          children: [
            Icon(Icons.tune, color: theme.colorScheme.primary),
            const SizedBox(width: 10),
            Text('Camera controls', style: theme.textTheme.titleMedium),
          ],
        ),
        if (!widget.enabled) ...[
          const SizedBox(height: 12),
          _Notice(
            icon: Icons.link_off,
            message: widget.disabledHint ??
                'Not connected to the camera — controls will work once the '
                    'stream is up.',
          ),
        ],
        const SizedBox(height: 20),
        _SectionLabel('Picture'),
        const SizedBox(height: 8),
        _BrightnessSlider(
          value: _controls.brightness,
          enabled: widget.enabled,
          onDragStart: () => _dragging = true,
          onPreview: (value) => _preview(_controls.copyWith(brightness: value)),
          onCommit: (value) {
            _dragging = false;
            _commit(_controls.copyWith(brightness: value));
          },
        ),
        const SizedBox(height: 4),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: _controls.nightMode,
          onChanged: widget.enabled
              ? (value) => _commit(_controls.copyWith(
                    nightMode: value,
                    // Night mode without a brightness lift is a wasted trip —
                    // start it somewhere useful, the slider still overrides.
                    brightness: value && _controls.brightness <= 0
                        ? AppConfig.nightModeBrightness
                        : _controls.brightness,
                  ))
              : null,
          secondary: const Icon(Icons.nightlight_round),
          title: const Text('Night mode'),
          subtitle: const Text(
            'Slows the capture rate so each frame is exposed longer, and '
            'brightens the picture. Restarts the camera briefly.',
          ),
          isThreeLine: true,
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: _controls.light,
          onChanged: widget.enabled && _state.capabilities.torch
              ? (value) => _commit(_controls.copyWith(light: value))
              : null,
          secondary: const Icon(Icons.flashlight_on_outlined),
          title: const Text('Camera light'),
          subtitle: Text(
            _state.capabilities.torch
                ? 'The camera phone’s torch. Bright — it will light up the '
                    'room, and the baby.'
                : 'This camera phone has no light this app can switch on.',
          ),
          isThreeLine: true,
        ),
        const SizedBox(height: 20),
        _SectionLabel('Sound filter'),
        const SizedBox(height: 4),
        Text(
          'Snoring and breathing should not wake you. Watch the meter for a '
          'moment, then put the bar just above the sounds you want ignored.',
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 14),
        _LevelMeter(
          levels: widget.levels,
          threshold: _sound.threshold,
          note: widget.meterNote,
        ),
        const SizedBox(height: 16),
        _ThresholdSlider(
          value: _sound.threshold,
          enabled: widget.enabled,
          onDragStart: () => _dragging = true,
          onPreview: (value) =>
              _preview(_controls.copyWith(sound: _sound.copyWith(threshold: value))),
          onCommit: (value) {
            _dragging = false;
            _commit(_controls.copyWith(sound: _sound.copyWith(threshold: value)));
          },
        ),
        const SizedBox(height: 8),
        _PresetRow(
          threshold: _sound.threshold,
          enabled: widget.enabled,
          onSelected: (value) =>
              _commit(_controls.copyWith(sound: _sound.copyWith(threshold: value))),
        ),
        const SizedBox(height: 16),
        _SustainSlider(
          value: _sound.sustain,
          enabled: widget.enabled,
          onDragStart: () => _dragging = true,
          onPreview: (value) =>
              _preview(_controls.copyWith(sound: _sound.copyWith(sustain: value))),
          onCommit: (value) {
            _dragging = false;
            _commit(_controls.copyWith(sound: _sound.copyWith(sustain: value)));
          },
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: _sound.ignoreSteady,
          onChanged: widget.enabled
              ? (value) => _commit(
                  _controls.copyWith(sound: _sound.copyWith(ignoreSteady: value)))
              : null,
          secondary: const Icon(Icons.graphic_eq),
          title: const Text('Ignore steady background'),
          subtitle: const Text(
            'Learns the room’s quiet level — breathing, a fan, white noise — '
            'and keeps it from creeping over the bar.',
          ),
          isThreeLine: true,
        ),
      ],
    );
  }
}

class _LevelMeter extends StatelessWidget {
  const _LevelMeter({
    required this.levels,
    required this.threshold,
    this.note,
  });

  final Stream<double>? levels;
  final double threshold;
  final String? note;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return StreamBuilder<double>(
      stream: levels,
      initialData: 0.0,
      builder: (context, snapshot) {
        final level = snapshot.data ?? 0.0;
        final alerting = level >= threshold;
        final note = this.note;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SoundLevelMeter(level: level, threshold: threshold),
            if (note != null) ...[
              const SizedBox(height: 6),
              Text(
                note,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ],
            const SizedBox(height: 6),
            Row(
              children: [
                Text(
                  'Now ${(level * 100).round()}%',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
                const Spacer(),
                Text(
                  alerting ? 'above the bar — alerts' : 'below the bar — ignored',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: alerting
                        ? const Color(0xFFF59E0B)
                        : theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ],
        );
      },
    );
  }
}

class _BrightnessSlider extends StatelessWidget {
  const _BrightnessSlider({
    required this.value,
    required this.enabled,
    required this.onDragStart,
    required this.onPreview,
    required this.onCommit,
  });

  final double value;
  final bool enabled;
  final VoidCallback onDragStart;
  final ValueChanged<double> onPreview;
  final ValueChanged<double> onCommit;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final percent = (value * 100).round();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const Icon(Icons.brightness_6_outlined, size: 20),
            const SizedBox(width: 10),
            const Text('Brightness'),
            const Spacer(),
            Text(
              percent == 0 ? 'normal' : '${percent > 0 ? '+' : ''}$percent%',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ],
        ),
        Slider(
          value: value.clamp(-1.0, 1.0),
          min: -1.0,
          max: 1.0,
          divisions: 20,
          onChangeStart: enabled ? (_) => onDragStart() : null,
          onChanged: enabled ? onPreview : null,
          onChangeEnd: enabled ? onCommit : null,
        ),
      ],
    );
  }
}

class _ThresholdSlider extends StatelessWidget {
  const _ThresholdSlider({
    required this.value,
    required this.enabled,
    required this.onDragStart,
    required this.onPreview,
    required this.onCommit,
  });

  final double value;
  final bool enabled;
  final VoidCallback onDragStart;
  final ValueChanged<double> onPreview;
  final ValueChanged<double> onCommit;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const Icon(Icons.volume_up_outlined, size: 20),
            const SizedBox(width: 10),
            const Expanded(child: Text('Ignore sounds quieter than')),
            Text(
              '${(value * 100).round()}%',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ],
        ),
        Slider(
          value: value.clamp(
              AppConfig.minNoiseThreshold, AppConfig.maxNoiseThreshold),
          min: AppConfig.minNoiseThreshold,
          max: AppConfig.maxNoiseThreshold,
          divisions: 18,
          onChangeStart: enabled ? (_) => onDragStart() : null,
          onChanged: enabled ? onPreview : null,
          onChangeEnd: enabled ? onCommit : null,
        ),
      ],
    );
  }
}

class _SustainSlider extends StatelessWidget {
  const _SustainSlider({
    required this.value,
    required this.enabled,
    required this.onDragStart,
    required this.onPreview,
    required this.onCommit,
  });

  final Duration value;
  final bool enabled;
  final VoidCallback onDragStart;
  final ValueChanged<Duration> onPreview;
  final ValueChanged<Duration> onCommit;

  static const int _maxSeconds = 15;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final seconds = value.inMilliseconds / 1000.0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const Icon(Icons.timer_outlined, size: 20),
            const SizedBox(width: 10),
            const Expanded(child: Text('Ignore sounds shorter than')),
            Text(
              seconds < 0.5 ? 'off' : '${seconds.round()}s',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ],
        ),
        Slider(
          value: seconds.clamp(0.0, _maxSeconds.toDouble()),
          max: _maxSeconds.toDouble(),
          divisions: _maxSeconds,
          onChangeStart: enabled ? (_) => onDragStart() : null,
          onChanged: enabled
              ? (v) => onPreview(Duration(seconds: v.round()))
              : null,
          onChangeEnd:
              enabled ? (v) => onCommit(Duration(seconds: v.round())) : null,
        ),
        Text(
          'A snore or a cough is over in a second or two. A baby who needs you '
          'keeps going.',
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
      ],
    );
  }
}

/// The three F7 presets, still one tap away now that the bar is a slider.
class _PresetRow extends StatelessWidget {
  const _PresetRow({
    required this.threshold,
    required this.enabled,
    required this.onSelected,
  });

  final double threshold;
  final bool enabled;
  final ValueChanged<double> onSelected;

  @override
  Widget build(BuildContext context) {
    const presets = <String, String>{
      'low': 'Only loud',
      'medium': 'Balanced',
      'high': 'Quiet too',
    };
    return Wrap(
      spacing: 8,
      children: [
        for (final entry in presets.entries)
          ChoiceChip(
            label: Text(entry.value),
            selected:
                (AppConfig.noiseThresholds[entry.key]! - threshold).abs() < 0.001,
            onSelected: enabled
                ? (_) => onSelected(AppConfig.noiseThresholds[entry.key]!)
                : null,
          ),
      ],
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Text(
      text.toUpperCase(),
      style: theme.textTheme.labelSmall?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
        letterSpacing: 1.5,
      ),
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({required this.icon, required this.message});

  final IconData icon;
  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(icon, size: 18, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }
}

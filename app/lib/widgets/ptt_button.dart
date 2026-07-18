/// Hold-to-talk microphone button (spec F6): press-down turns the mic on,
/// release (or gesture cancel) turns it off immediately, with a clear
/// pressed indicator (scale + glow + label) while transmitting.
library;

import 'package:flutter/material.dart';

class PttButton extends StatefulWidget {
  const PttButton({super.key, required this.onTalkingChanged, this.size = 84});

  /// Fired with `true` on press-down and `false` on release/cancel.
  final ValueChanged<bool> onTalkingChanged;

  /// Diameter of the round button.
  final double size;

  @override
  State<PttButton> createState() => _PttButtonState();
}

class _PttButtonState extends State<PttButton> {
  static const Color _active = Color(0xFF10B981);

  bool _pressed = false;

  void _setPressed(bool on) {
    if (_pressed == on) return;
    setState(() => _pressed = on);
    widget.onTalkingChanged(on);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        GestureDetector(
          onTapDown: (_) => _setPressed(true),
          onTapUp: (_) => _setPressed(false),
          onTapCancel: () => _setPressed(false),
          child: AnimatedScale(
            scale: _pressed ? 1.1 : 1.0,
            duration: const Duration(milliseconds: 120),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              width: widget.size,
              height: widget.size,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: _pressed ? _active : scheme.surfaceContainerHigh,
                border: Border.all(
                  color: _pressed ? _active : scheme.outline,
                  width: 2,
                ),
                boxShadow: _pressed
                    ? [
                        BoxShadow(
                          color: _active.withValues(alpha: 0.5),
                          blurRadius: 24,
                          spreadRadius: 4,
                        ),
                      ]
                    : const [],
              ),
              child: Icon(
                _pressed ? Icons.mic : Icons.mic_none,
                size: widget.size * 0.42,
                color: _pressed
                    ? const Color(0xFF06281D)
                    : scheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          _pressed ? 'Talking…' : 'Hold to talk',
          style: TextStyle(
            color: _pressed ? _active : scheme.onSurfaceVariant,
            fontSize: 12,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.5,
          ),
        ),
      ],
    );
  }
}

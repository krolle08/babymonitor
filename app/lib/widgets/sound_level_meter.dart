/// Live sound-level meter with the alert bar drawn on it (F13).
///
/// The point of the filter UI is that you can *see* what you are ignoring:
/// let the baby snore, watch where the bar sits, drag it above the snore.
library;

import 'package:flutter/material.dart';

class SoundLevelMeter extends StatelessWidget {
  const SoundLevelMeter({
    super.key,
    required this.level,
    required this.threshold,
    this.height = 16,
  });

  /// Latest sampled level, 0.0–1.0.
  final double level;

  /// Where the alert bar currently sits, 0.0–1.0.
  final double threshold;

  final double height;

  static const Color _quiet = Color(0xFF3B82F6);
  static const Color _loud = Color(0xFFF59E0B);
  static const Color _bar = Color(0xFFE2E8F0);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final value = level.clamp(0.0, 1.0);
    final mark = threshold.clamp(0.0, 1.0);
    final over = value >= mark;
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        return SizedBox(
          height: height,
          child: Stack(
            children: [
              // Track.
              ClipRRect(
                borderRadius: BorderRadius.circular(height / 2),
                child: ColoredBox(
                  color: scheme.surfaceContainerHighest,
                  child: SizedBox(width: width, height: height),
                ),
              ),
              // Level.
              ClipRRect(
                borderRadius: BorderRadius.circular(height / 2),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 250),
                  curve: Curves.easeOut,
                  width: width * value,
                  height: height,
                  color: over ? _loud : _quiet,
                ),
              ),
              // The bar itself.
              Positioned(
                left: (width * mark).clamp(0.0, width - 2),
                top: 0,
                bottom: 0,
                child: Container(width: 2, color: _bar),
              ),
            ],
          ),
        );
      },
    );
  }
}

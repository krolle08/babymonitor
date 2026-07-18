/// Compact health-state pill (spec F3): colored dot + state label.
///
/// DEGRADED is deliberately shown as nothing more than this badge changing
/// color — no banner, no alert (F3 AC: "DEGRADED produces no visible UI
/// change" beyond silent indication).
library;

import 'package:flutter/material.dart';

import '../core/health_state.dart';

class HealthBadge extends StatelessWidget {
  const HealthBadge({super.key, required this.state});

  final HealthState state;

  /// Spec'd status colors (F3 table).
  static const Map<HealthState, Color> colors = {
    HealthState.connecting: Color(0xFF9CA3AF), // grey
    HealthState.connected: Color(0xFF10B981), // green
    HealthState.degraded: Color(0xFFF59E0B), // yellow — silent
    HealthState.reconnecting: Color(0xFFF97316), // orange
    HealthState.frozen: Color(0xFFEF4444), // red
    HealthState.failed: Color(0xFFEF4444), // red
  };

  /// The label rendered inside the pill for [state].
  static String label(HealthState state) => state.name.toUpperCase();

  @override
  Widget build(BuildContext context) {
    final color = colors[state]!;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xCC0A101F),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.6)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 8),
          Text(
            label(state),
            style: TextStyle(
              color: color,
              fontSize: 12,
              fontWeight: FontWeight.w600,
              letterSpacing: 1.2,
            ),
          ),
        ],
      ),
    );
  }
}

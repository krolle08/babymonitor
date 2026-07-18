/// Baby monitor entry point (spec.md, docs/PROTOCOL.md §5.4).
///
/// Dark, calm, night-friendly Material 3 theme — deep navy / near-black
/// surfaces, no bright whites. Parents look at this at 3 a.m.
library;

import 'package:flutter/material.dart';

import 'screens/camera_screen.dart';
import 'screens/parent_screen.dart';
import 'screens/role_picker_screen.dart';
import 'services/notification_service.dart';
import 'services/settings_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SettingsService.load();
  await NotificationService.instance.init();
  runApp(const BabyMonitorApp());
}

class BabyMonitorApp extends StatelessWidget {
  const BabyMonitorApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Baby Monitor',
      debugShowCheckedModeBanner: false,
      theme: _buildTheme(),
      home: const HomeGate(),
    );
  }
}

ThemeData _buildTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: const Color(0xFF6C8CFF),
    brightness: Brightness.dark,
  ).copyWith(
    surface: const Color(0xFF0B1222),
    onSurface: const Color(0xFFC6D0E2), // soft slate — no bright white
    surfaceContainerLowest: const Color(0xFF060A14),
    surfaceContainerLow: const Color(0xFF0E1526),
    surfaceContainer: const Color(0xFF111A2E),
    surfaceContainerHigh: const Color(0xFF152036),
    surfaceContainerHighest: const Color(0xFF1A2740),
    onSurfaceVariant: const Color(0xFF93A1BC),
    outline: const Color(0xFF3A4A68),
    outlineVariant: const Color(0xFF25314A),
  );
  return ThemeData(
    colorScheme: scheme,
    scaffoldBackgroundColor: const Color(0xFF070D19),
    appBarTheme: AppBarTheme(
      backgroundColor: const Color(0xFF070D19),
      foregroundColor: scheme.onSurface,
      elevation: 0,
    ),
    cardTheme: CardThemeData(
      color: scheme.surfaceContainerLow,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: scheme.outlineVariant),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: scheme.surfaceContainerHigh,
      contentTextStyle: TextStyle(color: scheme.onSurface),
    ),
    dividerTheme: DividerThemeData(color: scheme.outlineVariant),
  );
}

/// Shows the remembered role's screen (TR8: role picked once), the role
/// picker otherwise. Both role screens expose a "switch role" escape hatch
/// that leads back to the picker.
class HomeGate extends StatefulWidget {
  const HomeGate({super.key});

  @override
  State<HomeGate> createState() => _HomeGateState();
}

class _HomeGateState extends State<HomeGate> {
  String? _role;

  @override
  void initState() {
    super.initState();
    _role = SettingsService.instance.role;
  }

  void _setRole(String role) => setState(() => _role = role);

  void _showPicker() => setState(() => _role = null);

  @override
  Widget build(BuildContext context) {
    return switch (_role) {
      'camera' => CameraScreen(onExit: _showPicker),
      'parent' => ParentScreen(onSwitchRole: _showPicker),
      _ => RolePickerScreen(onRoleSelected: _setRole),
    };
  }
}

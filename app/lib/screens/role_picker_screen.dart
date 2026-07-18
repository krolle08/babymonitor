/// First-launch role picker (TR8): one Flutter codebase, the user chooses
/// whether this phone is the camera unit or a parent unit. The choice is
/// persisted; both role screens offer a "switch role" escape hatch back here.
library;

import 'package:flutter/material.dart';

import '../services/settings_service.dart';
import 'settings_screen.dart';

class RolePickerScreen extends StatelessWidget {
  const RolePickerScreen({super.key, required this.onRoleSelected});

  /// Called with `'camera'` or `'parent'` after the choice is persisted.
  final ValueChanged<String> onRoleSelected;

  Future<void> _pick(String role) async {
    await SettingsService.instance.setRole(role);
    onRoleSelected(role);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Baby monitor'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: 'Settings',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const SettingsScreen()),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 8),
              Text('Which phone is this?', style: theme.textTheme.titleLarge),
              const SizedBox(height: 4),
              Text(
                'Pick a role for this device — you can switch later.',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: 20),
              Expanded(
                child: _RoleCard(
                  icon: Icons.videocam_outlined,
                  title: 'Camera unit',
                  subtitle: 'Point at baby',
                  onTap: () => _pick('camera'),
                ),
              ),
              const SizedBox(height: 16),
              Expanded(
                child: _RoleCard(
                  icon: Icons.visibility_outlined,
                  title: 'Parent unit',
                  subtitle: 'Watch the feed',
                  onTap: () => _pick('parent'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RoleCard extends StatelessWidget {
  const _RoleCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 64, color: theme.colorScheme.primary),
              const SizedBox(height: 16),
              Text(title, style: theme.textTheme.headlineSmall),
              const SizedBox(height: 6),
              Text(
                subtitle,
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Settings screen (docs/PROTOCOL.md §5.4): server endpoints + family token
/// (TR7 shared-secret auth — typed once, no accounts, NTR2), the sound filter
/// (F7/F13: the alert bar, plus what to ignore) and an About section.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../config/app_config.dart';
import '../core/camera_controls.dart';
import '../services/settings_service.dart';
import 'trusted_devices_screen.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  static const String _appVersion = '1.0.0';

  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  late final TextEditingController _signalingUrl;
  late final TextEditingController _apiBaseUrl;
  late final TextEditingController _familyToken;
  late final TextEditingController _deviceName;
  late SoundFilter _filter;
  late String? _role;
  late bool _allowCodeJoins;
  bool _obscureToken = true;
  bool _saving = false;

  bool get _isCamera => _role == 'camera';

  @override
  void initState() {
    super.initState();
    final settings = SettingsService.instance;
    _signalingUrl = TextEditingController(text: settings.signalingUrl);
    _apiBaseUrl = TextEditingController(text: settings.apiBaseUrl);
    _familyToken = TextEditingController(text: settings.familyToken);
    _deviceName = TextEditingController(text: settings.deviceName);
    _filter = settings.soundFilter;
    _role = settings.role;
    _allowCodeJoins = settings.allowCodeJoins;
  }

  @override
  void dispose() {
    _signalingUrl.dispose();
    _apiBaseUrl.dispose();
    _familyToken.dispose();
    _deviceName.dispose();
    super.dispose();
  }

  String? _validateUrl(String? value, List<String> schemes, String hint) {
    final trimmed = value?.trim() ?? '';
    if (trimmed.isEmpty) return 'Required';
    final schemeOk = schemes.any((scheme) => trimmed.startsWith('$scheme://'));
    if (!schemeOk) return 'Must start with $hint';
    if (Uri.tryParse(trimmed) == null) return 'Not a valid URL';
    return null;
  }

  Future<void> _save() async {
    if (_saving) return;
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() => _saving = true);
    final settings = SettingsService.instance;
    await settings.setSignalingUrl(_signalingUrl.text.trim());
    await settings.setApiBaseUrl(_apiBaseUrl.text.trim());
    await settings.setFamilyToken(_familyToken.text.trim());
    await settings.setSoundFilter(_filter);
    final name = _deviceName.text.trim();
    if (name.isNotEmpty) await settings.setDeviceName(name);
    await settings.setAllowCodeJoins(_allowCodeJoins);
    if (!mounted) return;
    setState(() => _saving = false);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Settings saved')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const _SectionHeader('Device'),
            TextFormField(
              controller: _deviceName,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(
                labelText: 'Device name',
                helperText: 'Shown to the other phone when pairing',
                hintText: 'e.g. Mom’s phone',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            Card(
              child: Column(
                children: [
                  ListTile(
                    leading: Icon(_isCamera
                        ? Icons.videocam_outlined
                        : Icons.smartphone),
                    title: const Text('Role'),
                    subtitle: Text(_isCamera
                        ? 'Camera unit'
                        : _role == 'parent'
                            ? 'Parent unit'
                            : 'Not chosen yet'),
                  ),
                  const Divider(height: 1),
                  ListTile(
                    leading: const Icon(Icons.devices_outlined),
                    title: const Text('Trusted devices'),
                    subtitle: const Text('Manage paired phones and cameras'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const TrustedDevicesScreen(),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            if (_isCamera) ...[
              const SizedBox(height: 12),
              Card(
                child: SwitchListTile(
                  value: _allowCodeJoins,
                  onChanged: (value) =>
                      setState(() => _allowCodeJoins = value),
                  title: const Text('Allow room-code joins'),
                  subtitle: const Text(
                    'When off, only paired devices can watch — a guessed code '
                    'is rejected.',
                  ),
                ),
              ),
            ],
            const SizedBox(height: 24),
            const _SectionHeader('Server'),
            TextFormField(
              controller: _signalingUrl,
              autocorrect: false,
              enableSuggestions: false,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(
                labelText: 'Signaling URL',
                hintText: 'wss://example.fly.dev/ws',
                border: OutlineInputBorder(),
              ),
              validator: (value) =>
                  _validateUrl(value, const ['ws', 'wss'], 'ws:// or wss://'),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _apiBaseUrl,
              autocorrect: false,
              enableSuggestions: false,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(
                labelText: 'API base URL',
                hintText: 'https://example.fly.dev',
                border: OutlineInputBorder(),
              ),
              validator: (value) => _validateUrl(
                value,
                const ['http', 'https'],
                'http:// or https://',
              ),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _familyToken,
              obscureText: _obscureToken,
              autocorrect: false,
              enableSuggestions: false,
              decoration: InputDecoration(
                labelText: 'Family token',
                helperText: 'Shared secret set on the server (FAMILY_TOKEN)',
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  icon: Icon(
                    _obscureToken
                        ? Icons.visibility_outlined
                        : Icons.visibility_off_outlined,
                  ),
                  tooltip: _obscureToken ? 'Show token' : 'Hide token',
                  onPressed: () =>
                      setState(() => _obscureToken = !_obscureToken),
                ),
              ),
            ),
            const SizedBox(height: 24),
            const _SectionHeader('Sound filter'),
            _SoundFilterCard(
              filter: _filter,
              onChanged: (filter) => setState(() => _filter = filter),
            ),
            const SizedBox(height: 8),
            Text(
              'Applies when this phone is the camera unit. While watching, a '
              'parent can also change all of this live from Camera controls — '
              'with a level meter to aim at.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
            const SizedBox(height: 24),
            const _SectionHeader('About'),
            const Card(
              child: Column(
                children: [
                  ListTile(
                    leading: Icon(Icons.info_outline),
                    title: Text('Baby Monitor'),
                    subtitle: Text('Version $_appVersion'),
                  ),
                  ListTile(
                    leading: Icon(Icons.favorite_outline),
                    title: Text('Credits'),
                    subtitle: Text(
                      'Built with Flutter, WebRTC (flutter_webrtc) and a tiny '
                      'Node.js signaling server. Made for tired parents.',
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: _saving ? null : () => unawaited(_save()),
              icon: const Icon(Icons.save_outlined),
              label: Text(_saving ? 'Saving…' : 'Save settings'),
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 16),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The F7 bar plus the F13 filters: how loud, how long, and whether steady
/// background sound (snoring, breathing, a fan) counts at all.
class _SoundFilterCard extends StatelessWidget {
  const _SoundFilterCard({required this.filter, required this.onChanged});

  final SoundFilter filter;
  final ValueChanged<SoundFilter> onChanged;

  static const int _maxSustainSeconds = 15;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final seconds = filter.sustain.inMilliseconds / 1000.0;
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Expanded(child: Text('Ignore sounds quieter than')),
                Text(
                  '${(filter.threshold * 100).round()}%',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
              ],
            ),
            Slider(
              value: filter.threshold.clamp(
                  AppConfig.minNoiseThreshold, AppConfig.maxNoiseThreshold),
              min: AppConfig.minNoiseThreshold,
              max: AppConfig.maxNoiseThreshold,
              divisions: 18,
              onChanged: (value) =>
                  onChanged(filter.copyWith(threshold: value)),
            ),
            Wrap(
              spacing: 8,
              children: [
                for (final entry in const {
                  'low': 'Only loud',
                  'medium': 'Balanced',
                  'high': 'Quiet too',
                }.entries)
                  ChoiceChip(
                    label: Text(entry.value),
                    selected: (AppConfig.noiseThresholds[entry.key]! -
                                filter.threshold)
                            .abs() <
                        0.001,
                    onSelected: (_) => onChanged(filter.copyWith(
                        threshold: AppConfig.noiseThresholds[entry.key]!)),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                const Expanded(child: Text('Ignore sounds shorter than')),
                Text(
                  seconds < 0.5 ? 'off' : '${seconds.round()}s',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
              ],
            ),
            Slider(
              value: seconds.clamp(0.0, _maxSustainSeconds.toDouble()),
              max: _maxSustainSeconds.toDouble(),
              divisions: _maxSustainSeconds,
              onChanged: (value) => onChanged(
                  filter.copyWith(sustain: Duration(seconds: value.round()))),
            ),
            Text(
              'Snoring, a cough or a creaking floorboard is over in a second '
              'or two. A baby who needs you keeps going.',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: filter.ignoreSteady,
              onChanged: (value) =>
                  onChanged(filter.copyWith(ignoreSteady: value)),
              title: const Text('Ignore steady background'),
              subtitle: const Text(
                'Learns the room’s quiet level — breathing, a fan, white '
                'noise — and keeps it from creeping over the bar.',
              ),
              isThreeLine: true,
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 8),
      child: Text(
        title.toUpperCase(),
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
          letterSpacing: 1.5,
        ),
      ),
    );
  }
}

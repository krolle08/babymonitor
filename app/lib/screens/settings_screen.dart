/// Settings screen (docs/PROTOCOL.md §5.4): server endpoints + family token
/// (TR7 shared-secret auth — typed once, no accounts, NTR2), noise-alert
/// sensitivity (F7 AC: configurable low/medium/high) and an About section.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../services/settings_service.dart';

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
  late String _sensitivity;
  bool _obscureToken = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final settings = SettingsService.instance;
    _signalingUrl = TextEditingController(text: settings.signalingUrl);
    _apiBaseUrl = TextEditingController(text: settings.apiBaseUrl);
    _familyToken = TextEditingController(text: settings.familyToken);
    _sensitivity = settings.noiseSensitivity;
  }

  @override
  void dispose() {
    _signalingUrl.dispose();
    _apiBaseUrl.dispose();
    _familyToken.dispose();
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
    await settings.setNoiseSensitivity(_sensitivity);
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
            const _SectionHeader('Alerts'),
            Card(
              child: RadioGroup<String>(
                groupValue: _sensitivity,
                onChanged: (value) {
                  if (value != null) setState(() => _sensitivity = value);
                },
                child: const Column(
                  children: [
                    RadioListTile<String>(
                      value: 'low',
                      title: Text('Low sensitivity'),
                      subtitle: Text('Only loud sounds trigger an alert'),
                    ),
                    RadioListTile<String>(
                      value: 'medium',
                      title: Text('Medium sensitivity'),
                      subtitle: Text('Balanced — recommended'),
                    ),
                    RadioListTile<String>(
                      value: 'high',
                      title: Text('High sensitivity'),
                      subtitle: Text('Quiet sounds trigger an alert'),
                    ),
                  ],
                ),
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

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../model/models.dart';
import '../../vpn/vpn_controller.dart';
import '../theme.dart';

class ServerEditPage extends StatefulWidget {
  final ServerProfile? existing;
  const ServerEditPage({super.key, this.existing});

  @override
  State<ServerEditPage> createState() => _ServerEditPageState();
}

class _ServerEditPageState extends State<ServerEditPage> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _host;
  late final TextEditingController _port;
  late final TextEditingController _keyId;
  late final TextEditingController _keySecret;
  late final TextEditingController _usernamePrefix;
  bool _obscureSecret = true;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _name = TextEditingController(text: e?.name ?? '');
    _host = TextEditingController(text: e?.host ?? '');
    _port = TextEditingController(text: (e?.port ?? 25565).toString());
    _keyId = TextEditingController(text: e?.keyIdHex ?? '');
    _keySecret = TextEditingController(text: e?.keySecretHex ?? '');
    _usernamePrefix = TextEditingController(text: e?.usernamePrefix ?? 'mcvpn_');
  }

  @override
  void dispose() {
    _name.dispose();
    _host.dispose();
    _port.dispose();
    _keyId.dispose();
    _keySecret.dispose();
    _usernamePrefix.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final editing = widget.existing != null;
    return Scaffold(
      appBar: AppBar(
        title: Text(editing ? 'Edit server' : 'New server'),
        actions: [
          TextButton.icon(
            onPressed: _importFromClipboard,
            icon: const Icon(Icons.content_paste_rounded, size: 18),
            label: const Text('Import config'),
          ),
        ],
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 40),
          children: [
            _field(_name, 'Name', hint: 'My mcvpn server',
                icon: Icons.badge_outlined),
            _field(_host, 'Server host',
                hint: 'play.example.com', icon: Icons.language),
            _field(_port, 'Server port',
                icon: Icons.numbers,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly]),
            const SizedBox(height: 8),
            const _SectionLabel('Credential (from the admin panel)'),
            _field(_keyId, 'key_id',
                hint: '32 hex characters',
                icon: Icons.key_outlined,
                mono: true),
            _field(_keySecret, 'key_secret',
                hint: '64 hex characters',
                icon: Icons.password_outlined,
                mono: true,
                obscure: _obscureSecret,
                suffix: IconButton(
                  icon: Icon(_obscureSecret
                      ? Icons.visibility_outlined
                      : Icons.visibility_off_outlined),
                  onPressed: () =>
                      setState(() => _obscureSecret = !_obscureSecret),
                )),
            const SizedBox(height: 8),
            const _SectionLabel('Advanced'),
            _field(_usernamePrefix, 'Username prefix',
                icon: Icons.person_outline),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: _save,
              child: Text(editing ? 'Save changes' : 'Add server'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _field(
    TextEditingController controller,
    String label, {
    String? hint,
    IconData? icon,
    bool mono = false,
    bool obscure = false,
    Widget? suffix,
    TextInputType? keyboardType,
    List<TextInputFormatter>? inputFormatters,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: TextFormField(
        controller: controller,
        obscureText: obscure,
        keyboardType: keyboardType,
        inputFormatters: inputFormatters,
        style: mono
            ? const TextStyle(fontFamily: 'monospace', fontSize: 13)
            : null,
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          prefixIcon: icon == null ? null : Icon(icon, size: 20),
          suffixIcon: suffix,
        ),
        validator: (v) => _validate(label, v),
      ),
    );
  }

  String? _validate(String label, String? v) {
    final value = (v ?? '').trim();
    switch (label) {
      case 'Name':
        return value.isEmpty ? 'Required' : null;
      case 'Server host':
        return value.isEmpty ? 'Required' : null;
      case 'Server port':
        final p = int.tryParse(value);
        return (p == null || p < 1 || p > 65535) ? '1–65535' : null;
      case 'key_id':
        return _hexLen(value, 16) ? null : '32 hex characters';
      case 'key_secret':
        return _hexLen(value, 32) ? null : '64 hex characters';
      default:
        return null;
    }
  }

  bool _hexLen(String s, int bytes) =>
      s.length == bytes * 2 && RegExp(r'^[0-9a-fA-F]+$').hasMatch(s);

  Future<void> _importFromClipboard() async {
    final data = await Clipboard.getData('text/plain');
    final text = data?.text;
    if (text == null || text.trim().isEmpty) {
      _snack('Clipboard is empty');
      return;
    }
    final map = _parseToml(text);
    var applied = 0;
    void apply(TextEditingController ctrl, String? val) {
      if (val != null && val.isNotEmpty) {
        ctrl.text = val;
        applied++;
      }
    }

    apply(_host, map['server_host']);
    apply(_port, map['server_port']);
    apply(_keyId, map['key_id']);
    apply(_keySecret, map['key_secret']);
    apply(_usernamePrefix, map['username_prefix']);
    if (_name.text.trim().isEmpty && map['server_host'] != null) {
      _name.text = map['server_host']!;
      applied++;
    }
    setState(() {});
    _snack(applied > 0
        ? 'Imported $applied field(s) from config'
        : 'No mcvpn config fields found in clipboard');
  }

  Map<String, String> _parseToml(String text) {
    final out = <String, String>{};
    for (final raw in text.split('\n')) {
      final line = raw.trim();
      if (line.isEmpty || line.startsWith('#') || !line.contains('=')) continue;
      final idx = line.indexOf('=');
      final key = line.substring(0, idx).trim();
      var val = line.substring(idx + 1).trim();
      final comment = val.indexOf('#');
      if (comment >= 0) val = val.substring(0, comment).trim();
      if (val.length >= 2 &&
          ((val.startsWith('"') && val.endsWith('"')) ||
              (val.startsWith("'") && val.endsWith("'")))) {
        val = val.substring(1, val.length - 1);
      }
      out[key] = val;
    }
    return out;
  }

  void _save() {
    if (!_formKey.currentState!.validate()) return;
    final c = context.read<VpnController>();
    final id = widget.existing?.id ??
        'p_${DateTime.now().microsecondsSinceEpoch.toRadixString(16)}';
    final profile = ServerProfile(
      id: id,
      name: _name.text.trim(),
      host: _host.text.trim(),
      port: int.parse(_port.text.trim()),
      keyIdHex: _keyId.text.trim(),
      keySecretHex: _keySecret.text.trim(),
      usernamePrefix: _usernamePrefix.text.trim().isEmpty
          ? 'mcvpn_'
          : _usernamePrefix.text.trim(),
    );
    c.upsertProfile(profile);
    Navigator.of(context).pop();
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg)));
  }
}

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10, top: 4),
      child: Text(
        text.toUpperCase(),
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.8,
          color: AppColors.accent.withValues(alpha: 0.9),
        ),
      ),
    );
  }
}

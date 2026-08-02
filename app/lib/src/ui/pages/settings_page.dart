import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../vpn/vpn_controller.dart';
import '../theme.dart';

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final c = context.watch<VpnController>();
    final p = c.proxySettings;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
        automaticallyImplyLeading: Navigator.of(context).canPop(),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
        children: [
          const _Header('Local proxy'),
          GlassCard(
            child: Column(
              children: [
                _PortRow(
                  label: 'HTTP CONNECT port',
                  icon: Icons.http,
                  value: p.httpPort,
                  enabled: !c.isActive,
                  onChanged: (v) =>
                      c.updateProxySettings(p.copyWith(httpPort: v)),
                ),
                const Divider(height: 24),
                _PortRow(
                  label: 'SOCKS5 port',
                  icon: Icons.electrical_services,
                  value: p.socksPort,
                  enabled: !c.isActive,
                  onChanged: (v) =>
                      c.updateProxySettings(p.copyWith(socksPort: v)),
                ),
                const Divider(height: 24),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Allow LAN connections'),
                  subtitle: Text(
                    p.allowLan
                        ? 'Bound to 0.0.0.0 — reachable from your network'
                        : 'Bound to 127.0.0.1 — this device only',
                    style: const TextStyle(fontSize: 12),
                  ),
                  value: p.allowLan,
                  activeThumbColor: AppColors.accent,
                  onChanged: c.isActive
                      ? null
                      : (v) => c.updateProxySettings(p.copyWith(allowLan: v)),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          const _Header('How to use'),
          GlassCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _HowToRow(
                  icon: Icons.hub_outlined,
                  title: 'Local proxy ports',
                  body:
                      'Always on regardless of mode below: point an app\'s HTTP(S) '
                      'proxy at 127.0.0.1:${p.httpPort}, or its SOCKS5 proxy at '
                      '127.0.0.1:${p.socksPort}, to carry just that app\'s TCP '
                      'traffic through the tunnel.',
                ),
                const SizedBox(height: 14),
                const _HowToRow(
                  icon: Icons.public,
                  title: 'System proxy mode',
                  body: 'Points the OS-wide proxy setting at the ports above, so '
                      'apps without their own proxy setting (browsers, etc.) get '
                      'routed automatically. Apps that ignore the system proxy '
                      'still go direct.',
                ),
                const SizedBox(height: 14),
                _HowToRow(
                  icon: Icons.vpn_lock_outlined,
                  title: 'Full tunnel mode',
                  body: c.tunSupported
                      ? 'Captures all device traffic via the system VPN and '
                          'routes it through the tunnel. Grant the elevation '
                          'prompt when asked.'
                      : 'Whole-device tunnelling isn\'t available on macOS/iOS yet '
                          '(needs a signed system extension). Use System proxy '
                          'instead.',
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          const _Header('About'),
          GlassCard(
            child: Column(
              children: [
                _row(context, 'App', 'mcvpn client 1.0.0'),
                const Divider(height: 20),
                _row(context, 'Transport', 'Minecraft 1.20.1 (protocol 763)'),
                const Divider(height: 20),
                _row(context, 'Crypto',
                    'X25519 · HKDF-SHA256 · ChaCha20-Poly1305'),
              ],
            ),
          ),
          const SizedBox(height: 20),
          Center(
            child: Text(
              'Traffic looks like an ordinary Minecraft session.',
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.4),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _row(BuildContext context, String k, String v) {
    return Row(
      children: [
        Text(k,
            style: TextStyle(
                color:
                    Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.55))),
        const Spacer(),
        Flexible(
          child: Text(v,
              textAlign: TextAlign.right,
              style: const TextStyle(fontWeight: FontWeight.w600)),
        ),
      ],
    );
  }
}

class _PortRow extends StatelessWidget {
  final String label;
  final IconData icon;
  final int value;
  final bool enabled;
  final ValueChanged<int> onChanged;

  const _PortRow({
    required this.label,
    required this.icon,
    required this.value,
    required this.enabled,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 20, color: AppColors.accent),
        const SizedBox(width: 12),
        Expanded(child: Text(label)),
        SizedBox(
          width: 92,
          child: TextFormField(
            enabled: enabled,
            initialValue: value.toString(),
            textAlign: TextAlign.center,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: const InputDecoration(
              isDense: true,
              contentPadding: EdgeInsets.symmetric(vertical: 10),
            ),
            onChanged: (v) {
              final p = int.tryParse(v);
              if (p != null && p >= 1 && p <= 65535) onChanged(p);
            },
          ),
        ),
      ],
    );
  }
}

class _HowToRow extends StatelessWidget {
  final IconData icon;
  final String title;
  final String body;
  const _HowToRow(
      {required this.icon, required this.title, required this.body});

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 22, color: AppColors.accent),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title,
                  style: const TextStyle(
                      fontWeight: FontWeight.w700, fontSize: 14)),
              const SizedBox(height: 4),
              Text(body,
                  style: TextStyle(
                      fontSize: 12.5,
                      height: 1.4,
                      color: Theme.of(context)
                          .colorScheme
                          .onSurface
                          .withValues(alpha: 0.6))),
            ],
          ),
        ),
      ],
    );
  }
}

class _Header extends StatelessWidget {
  final String text;
  const _Header(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(6, 8, 6, 10),
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

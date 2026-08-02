import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../model/models.dart';
import '../../vpn/vpn_controller.dart';
import '../format.dart';
import '../theme.dart';
import '../widgets/connect_button.dart';
import '../widgets/mode_selector.dart';
import '../widgets/stat_tile.dart';
import 'servers_page.dart';

class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) {
    final c = context.watch<VpnController>();
    final profile = c.selectedProfile;

    return CustomScrollView(
      slivers: [
        SliverAppBar(
          floating: true,
          title: const Text('mcvpn'),
          actions: [
            IconButton(
              tooltip: 'Status',
              icon: _StatusDot(state: c.state),
              onPressed: () {},
            ),
            const SizedBox(width: 8),
          ],
        ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
            child: Column(
              children: [
                _StatusHeadline(c: c),
                const SizedBox(height: 24),
                ConnectButton(
                  state: c.state,
                  onTap: () => _onTap(context, c),
                ),
                const SizedBox(height: 24),
                _SessionLine(c: c),
                const SizedBox(height: 28),
                if (profile == null)
                  _NoServerCard()
                else
                  _ServerCard(profile: profile),
                const SizedBox(height: 16),
                ModeSelector(
                  mode: c.mode,
                  systemProxySupported: c.systemProxySupported,
                  tunSupported: c.tunSupported,
                  enabled: !c.isActive,
                  onChanged: (m) => c.setMode(m),
                ),
                const SizedBox(height: 20),
                _StatsGrid(c: c),
              ],
            ),
          ),
        ),
      ],
    );
  }

  void _onTap(BuildContext context, VpnController c) {
    if (c.isActive) {
      c.disconnect();
    } else {
      if (c.selectedProfile == null) {
        Navigator.of(context).push(
          MaterialPageRoute<void>(builder: (_) => const ServersPage()),
        );
        return;
      }
      c.connect();
    }
  }
}

class _StatusHeadline extends StatelessWidget {
  final VpnController c;
  const _StatusHeadline({required this.c});

  @override
  Widget build(BuildContext context) {
    String title;
    Color color;
    switch (c.state) {
      case AppState.connected:
        title = 'Protected';
        color = AppColors.accent;
        break;
      case AppState.connecting:
        title = 'Connecting…';
        color = AppColors.warn;
        break;
      case AppState.reconnecting:
        title = 'Reconnecting…';
        color = AppColors.warn;
        break;
      case AppState.disconnecting:
        title = 'Disconnecting…';
        color = AppColors.warn;
        break;
      case AppState.error:
        title = 'Connection failed';
        color = AppColors.danger;
        break;
      case AppState.disconnected:
        title = 'Not connected';
        color = Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6);
    }
    return Column(
      children: [
        Text(
          title,
          style: TextStyle(
            fontSize: 26,
            fontWeight: FontWeight.w800,
            letterSpacing: -0.5,
            color: color,
          ),
        ),
        if (c.state == AppState.error && c.statusDetail != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              c.statusDetail!,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13,
                color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6),
              ),
            ),
          ),
      ],
    );
  }
}

class _SessionLine extends StatelessWidget {
  final VpnController c;
  const _SessionLine({required this.c});

  @override
  Widget build(BuildContext context) {
    final onSurface = Theme.of(context).colorScheme.onSurface;
    if (c.state == AppState.connected) {
      return Column(
        children: [
          Text(
            formatDuration(c.stats.uptime),
            style: TextStyle(
              fontFeatures: const [FontFeature.tabularFigures()],
              fontSize: 32,
              fontWeight: FontWeight.w300,
              color: onSurface,
            ),
          ),
          if (c.sessionUsername != null)
            Text(
              'disguised as ${c.sessionUsername}',
              style: TextStyle(fontSize: 12, color: onSurface.withValues(alpha: 0.5)),
            ),
        ],
      );
    }
    final subtitle = switch (c.mode) {
      VpnMode.tun => 'Full-device tunnel over Minecraft',
      VpnMode.systemProxy => 'System proxy over Minecraft',
    };
    return Text(
      subtitle,
      style: TextStyle(fontSize: 13, color: onSurface.withValues(alpha: 0.5)),
    );
  }
}

class _StatsGrid extends StatelessWidget {
  final VpnController c;
  const _StatsGrid({required this.c});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: StatTile(
            icon: Icons.arrow_upward_rounded,
            label: 'Upload',
            value: formatRate(c.stats.upBytesPerSec),
            sub: formatBytes(c.stats.bytesUp),
            color: AppColors.accent,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: StatTile(
            icon: Icons.arrow_downward_rounded,
            label: 'Download',
            value: formatRate(c.stats.downBytesPerSec),
            sub: formatBytes(c.stats.bytesDown),
            color: AppColors.gradientB,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: StatTile(
            icon: Icons.lan_rounded,
            label: 'Streams',
            value: '${c.stats.activeStreams}',
            sub: '${c.stats.totalStreams} total',
            color: AppColors.warn,
          ),
        ),
      ],
    );
  }
}

class _ServerCard extends StatelessWidget {
  final ServerProfile profile;
  const _ServerCard({required this.profile});

  @override
  Widget build(BuildContext context) {
    final c = context.read<VpnController>();
    return GlassCard(
      onTap: c.isActive
          ? null
          : () => Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => const ServersPage()),
              ),
      child: Row(
        children: [
          Container(
            width: 46,
            height: 46,
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [AppColors.gradientA, AppColors.gradientB],
              ),
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Icon(Icons.dns_rounded, color: Colors.white),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  profile.name,
                  style: const TextStyle(
                      fontWeight: FontWeight.w700, fontSize: 16),
                ),
                const SizedBox(height: 2),
                Text(
                  '${profile.host}:${profile.port}',
                  style: TextStyle(
                    fontSize: 13,
                    color:
                        Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.55),
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
          ),
          if (!c.isActive)
            Icon(Icons.chevron_right_rounded,
                color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.4)),
        ],
      ),
    );
  }
}

class _NoServerCard extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return GlassCard(
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => const ServersPage()),
      ),
      child: const Row(
        children: [
          Icon(Icons.add_circle_outline_rounded,
              color: AppColors.accent, size: 28),
          SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Add a server',
                    style:
                        TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
                SizedBox(height: 2),
                Text('Paste the key_id / key_secret from the admin panel',
                    style: TextStyle(fontSize: 12)),
              ],
            ),
          ),
          Icon(Icons.chevron_right_rounded),
        ],
      ),
    );
  }
}

class _StatusDot extends StatelessWidget {
  final AppState state;
  const _StatusDot({required this.state});

  @override
  Widget build(BuildContext context) {
    Color color;
    switch (state) {
      case AppState.connected:
        color = AppColors.accent;
        break;
      case AppState.connecting:
      case AppState.reconnecting:
      case AppState.disconnecting:
        color = AppColors.warn;
        break;
      case AppState.error:
        color = AppColors.danger;
        break;
      case AppState.disconnected:
        color = Colors.grey;
    }
    return Container(
      width: 12,
      height: 12,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(color: color.withValues(alpha: 0.6), blurRadius: 8, spreadRadius: 1)
        ],
      ),
    );
  }
}

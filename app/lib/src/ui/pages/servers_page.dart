import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../model/models.dart';
import '../../vpn/vpn_controller.dart';
import '../theme.dart';
import 'server_edit_page.dart';

class ServersPage extends StatelessWidget {
  const ServersPage({super.key});

  @override
  Widget build(BuildContext context) {
    final c = context.watch<VpnController>();
    final profiles = c.profiles;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Servers'),
        automaticallyImplyLeading: Navigator.of(context).canPop(),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _edit(context, null),
        backgroundColor: AppColors.accent,
        foregroundColor: const Color(0xFF06231A),
        icon: const Icon(Icons.add),
        label: const Text('Add server'),
      ),
      body: profiles.isEmpty
          ? _Empty(onAdd: () => _edit(context, null))
          : ListView.separated(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
              itemCount: profiles.length,
              separatorBuilder: (_, __) => const SizedBox(height: 10),
              itemBuilder: (context, i) {
                final p = profiles[i];
                final selected = c.selectedProfile?.id == p.id;
                return GlassCard(
                  onTap: () => c.selectProfile(p.id),
                  border: selected ? AppColors.accent : null,
                  child: Row(
                    children: [
                      _RadioDot(selected: selected),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(p.name,
                                style: const TextStyle(
                                    fontWeight: FontWeight.w700, fontSize: 16)),
                            const SizedBox(height: 2),
                            Text('${p.host}:${p.port}',
                                style: TextStyle(
                                    fontSize: 13,
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onSurface
                                        .withValues(alpha: 0.55))),
                          ],
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.edit_outlined),
                        onPressed: () => _edit(context, p),
                      ),
                      IconButton(
                        icon: const Icon(Icons.delete_outline,
                            color: AppColors.danger),
                        onPressed: () => _confirmDelete(context, c, p),
                      ),
                    ],
                  ),
                );
              },
            ),
    );
  }

  void _edit(BuildContext context, ServerProfile? profile) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ServerEditPage(existing: profile),
      ),
    );
  }

  void _confirmDelete(
      BuildContext context, VpnController c, ServerProfile p) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete server?'),
        content: Text('“${p.name}” will be removed.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok == true) c.deleteProfile(p.id);
  }
}

class _RadioDot extends StatelessWidget {
  final bool selected;
  const _RadioDot({required this.selected});

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      width: 22,
      height: 22,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(
          color: selected
              ? AppColors.accent
              : Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.3),
          width: 2,
        ),
        color: selected ? AppColors.accent : Colors.transparent,
      ),
      child: selected
          ? const Icon(Icons.check, size: 14, color: Color(0xFF06231A))
          : null,
    );
  }
}

class _Empty extends StatelessWidget {
  final VoidCallback onAdd;
  const _Empty({required this.onAdd});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.dns_outlined, size: 64, color: AppColors.accent),
            const SizedBox(height: 16),
            const Text('No servers yet',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            Text(
              'Create a user in the mcvpn admin panel, download its '
              'config, and paste the key_id / key_secret here.',
              textAlign: TextAlign.center,
              style: TextStyle(
                  color: Theme.of(context)
                      .colorScheme
                      .onSurface
                      .withValues(alpha: 0.55)),
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: onAdd,
              icon: const Icon(Icons.add),
              label: const Text('Add your first server'),
            ),
          ],
        ),
      ),
    );
  }
}

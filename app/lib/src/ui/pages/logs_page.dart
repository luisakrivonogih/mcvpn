import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../vpn/vpn_controller.dart';
import '../format.dart';
import '../theme.dart';

class LogsPage extends StatelessWidget {
  const LogsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final c = context.watch<VpnController>();
    final logs = c.logs.reversed.toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Logs'),
        automaticallyImplyLeading: Navigator.of(context).canPop(),
        actions: [
          IconButton(
            tooltip: 'Copy all',
            icon: const Icon(Icons.copy_all_outlined),
            onPressed: logs.isEmpty
                ? null
                : () {
                    Clipboard.setData(ClipboardData(
                        text: c.logs
                            .map((e) => '${formatTime(e.time)}  ${e.message}')
                            .join('\n')));
                    ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Logs copied')));
                  },
          ),
          IconButton(
            tooltip: 'Clear',
            icon: const Icon(Icons.delete_sweep_outlined),
            onPressed: logs.isEmpty ? null : c.clearLogs,
          ),
        ],
      ),
      body: logs.isEmpty
          ? Center(
              child: Text('No activity yet',
                  style: TextStyle(
                      color: Theme.of(context)
                          .colorScheme
                          .onSurface
                          .withValues(alpha: 0.4))),
            )
          : ListView.builder(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
              itemCount: logs.length,
              itemBuilder: (context, i) {
                final e = logs[i];
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        formatTime(e.time),
                        style: TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 12,
                          color: AppColors.accent.withValues(alpha: 0.8),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          e.message,
                          style: TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 12,
                            color: Theme.of(context)
                                .colorScheme
                                .onSurface
                                .withValues(alpha: 0.8),
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
    );
  }
}

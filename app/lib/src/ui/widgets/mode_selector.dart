import 'package:flutter/material.dart';

import '../../model/models.dart';
import '../theme.dart';

/// A segmented Proxy / Full-tunnel switch.
class ModeSelector extends StatelessWidget {
  final VpnMode mode;
  final bool systemProxySupported;
  final bool tunSupported;
  final bool enabled;
  final ValueChanged<VpnMode> onChanged;

  const ModeSelector({
    super.key,
    required this.mode,
    required this.systemProxySupported,
    required this.tunSupported,
    required this.enabled,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      padding: const EdgeInsets.all(6),
      child: Row(
        children: [
          _segment(
            context,
            label: 'System proxy',
            icon: Icons.public,
            selected: mode == VpnMode.systemProxy,
            disabledHint: systemProxySupported ? null : 'Desktop only',
            onTap: (enabled && systemProxySupported)
                ? () => onChanged(VpnMode.systemProxy)
                : null,
          ),
          _segment(
            context,
            label: 'Full tunnel',
            icon: Icons.vpn_lock_outlined,
            selected: mode == VpnMode.tun,
            disabledHint: tunSupported ? null : 'Not on macOS/iOS',
            onTap: (enabled && tunSupported)
                ? () => onChanged(VpnMode.tun)
                : null,
          ),
        ],
      ),
    );
  }

  Widget _segment(
    BuildContext context, {
    required String label,
    required IconData icon,
    required bool selected,
    String? disabledHint,
    VoidCallback? onTap,
  }) {
    final onSurface = Theme.of(context).colorScheme.onSurface;
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOut,
          padding: const EdgeInsets.symmetric(vertical: 14),
          decoration: BoxDecoration(
            gradient: selected
                ? const LinearGradient(
                    colors: [AppColors.gradientA, AppColors.gradientB])
                : null,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Column(
            children: [
              Icon(
                icon,
                size: 20,
                color: selected
                    ? Colors.white
                    : onSurface.withValues(alpha: onTap == null ? 0.25 : 0.7),
              ),
              const SizedBox(height: 6),
              Text(
                label,
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 13,
                  color: selected
                      ? Colors.white
                      : onSurface.withValues(alpha: onTap == null ? 0.3 : 0.8),
                ),
              ),
              if (disabledHint != null)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    disabledHint,
                    style: TextStyle(
                        fontSize: 10, color: onSurface.withValues(alpha: 0.35)),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../vpn/vpn_controller.dart';
import 'pages/home_page.dart';
import 'pages/logs_page.dart';
import 'pages/servers_page.dart';
import 'pages/settings_page.dart';
import 'theme.dart';

class McVpnApp extends StatelessWidget {
  const McVpnApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'mcvpn',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: ThemeMode.dark,
      home: const HomeShell(),
    );
  }
}

/// Responsive navigation: a bottom bar on narrow screens, a side rail on wide
/// ones (tablets / desktop).
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 0;
  late final AppLifecycleListener _lifecycleListener;

  @override
  void initState() {
    super.initState();
    // Without this, closing the window / Cmd+Q / Alt+F4 kills the process
    // immediately and skips VpnController.disconnect() entirely, leaving the
    // system proxy (or TUN routes) pointed at ports that no longer exist and
    // breaking the user's internet until they notice and fix it by hand.
    _lifecycleListener = AppLifecycleListener(onExitRequested: _onExitRequested);
  }

  Future<AppExitResponse> _onExitRequested() async {
    final controller = context.read<VpnController>();
    try {
      await controller.disconnect().timeout(const Duration(seconds: 8));
    } catch (_) {
      // Best-effort: don't block the user from quitting just because
      // cleanup couldn't finish in time.
    }
    return AppExitResponse.exit;
  }

  @override
  void dispose() {
    _lifecycleListener.dispose();
    super.dispose();
  }

  static const _destinations = [
    _Dest('Connect', Icons.shield_outlined, Icons.shield),
    _Dest('Servers', Icons.dns_outlined, Icons.dns),
    _Dest('Logs', Icons.terminal_outlined, Icons.terminal),
    _Dest('Settings', Icons.tune_outlined, Icons.tune),
  ];

  Widget _pageFor(int i) {
    switch (i) {
      case 0:
        return const HomePage();
      case 1:
        return const ServersPage();
      case 2:
        return const LogsPage();
      default:
        return const SettingsPage();
    }
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final wide = width >= 720;

    final page = AnimatedSwitcher(
      duration: const Duration(milliseconds: 250),
      switchInCurve: Curves.easeOutCubic,
      transitionBuilder: (child, anim) => FadeTransition(
        opacity: anim,
        child: SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0, 0.02),
            end: Offset.zero,
          ).animate(anim),
          child: child,
        ),
      ),
      child: KeyedSubtree(key: ValueKey(_index), child: _pageFor(_index)),
    );

    if (wide) {
      return Scaffold(
        body: Row(
          children: [
            NavigationRail(
              selectedIndex: _index,
              onDestinationSelected: (i) => setState(() => _index = i),
              labelType: NavigationRailLabelType.all,
              backgroundColor: Theme.of(context).brightness == Brightness.dark
                  ? AppColors.surfaceDark
                  : Colors.white,
              leading: const Padding(
                padding: EdgeInsets.symmetric(vertical: 18),
                child: _Logo(),
              ),
              destinations: [
                for (final d in _destinations)
                  NavigationRailDestination(
                    icon: Icon(d.icon),
                    selectedIcon: Icon(d.selected),
                    label: Text(d.label),
                  ),
              ],
            ),
            const VerticalDivider(width: 1),
            Expanded(child: SafeArea(child: page)),
          ],
        ),
      );
    }

    return Scaffold(
      body: SafeArea(bottom: false, child: page),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        height: 66,
        destinations: [
          for (final d in _destinations)
            NavigationDestination(
              icon: Icon(d.icon),
              selectedIcon: Icon(d.selected),
              label: d.label,
            ),
        ],
      ),
    );
  }
}

class _Dest {
  final String label;
  final IconData icon;
  final IconData selected;
  const _Dest(this.label, this.icon, this.selected);
}

class _Logo extends StatelessWidget {
  const _Logo();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [AppColors.gradientA, AppColors.gradientB],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(12),
      ),
      child: const Icon(Icons.bolt, color: Colors.white, size: 24),
    );
  }
}

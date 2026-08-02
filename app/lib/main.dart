import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'src/store/settings_store.dart';
import 'src/ui/app.dart';
import 'src/vpn/vpn_controller.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final store = await SettingsStore.load();
  final controller = VpnController(store);
  await controller.init();

  runApp(
    ChangeNotifierProvider<VpnController>.value(
      value: controller,
      child: const McVpnApp(),
    ),
  );
}

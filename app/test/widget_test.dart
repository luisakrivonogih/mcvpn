import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mcvpn/src/store/settings_store.dart';
import 'package:mcvpn/src/ui/app.dart';
import 'package:mcvpn/src/vpn/vpn_controller.dart';

void main() {
  testWidgets('app boots to the Connect screen', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final store = await SettingsStore.load();
    final controller = VpnController(store);
    await controller.init();

    await tester.pumpWidget(
      ChangeNotifierProvider<VpnController>.value(
        value: controller,
        child: const McVpnApp(),
      ),
    );
    await tester.pump();

    // The disconnected headline and both mode segments should be present.
    expect(find.text('Not connected'), findsOneWidget);
    expect(find.text('Proxy'), findsWidgets);
    expect(find.text('Full tunnel'), findsWidgets);
  });
}

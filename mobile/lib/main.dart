import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'core/app_state.dart';
import 'core/fixture.dart';
import 'screens/scan_detail_screen.dart';
import 'screens/connect_screen.dart';
import 'screens/explore_screen.dart';
import 'screens/intro_screen.dart';
import 'screens/library_screen.dart';
import 'screens/scan_setup_screen.dart';
import 'screens/settings_screen.dart';
import 'ui/style.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AppState.I.init();
  runApp(const FieldScanApp());
}

class FieldScanApp extends StatelessWidget {
  const FieldScanApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Field Scan',
      debugShowCheckedModeBanner: false,
      theme: fieldScanTheme(),
      themeMode: ThemeMode.light,
      // first launch: two-page intro, then the tabs (debug screenshot runs with FS_START skip it)
      home: AppState.I.introSeen || (kDebugMode && const String.fromEnvironment('FS_START').isNotEmpty)
          ? const HomeTabs()
          : const IntroScreen(),
    );
  }
}

class HomeTabs extends StatefulWidget {
  const HomeTabs({super.key});
  @override
  State<HomeTabs> createState() => _HomeTabsState();
}

class _HomeTabsState extends State<HomeTabs> {
  int _i = 0;

  // Debug builds only: `--dart-define=FS_START=library|explore|connect|settings|detail` opens that screen
  // (detail = a SYNTHETIC fixture scan). Used for simulator screenshots; ignored in release builds.
  static const _start = String.fromEnvironment('FS_START');

  @override
  void initState() {
    super.initState();
    if (kDebugMode && _start.isNotEmpty) {
      _i = const {'library': 1, 'explore': 2, 'connect': 3, 'settings': 4}[_start] ?? 0;
      if (_start == 'detail') {
        WidgetsBinding.instance.addPostFrameCallback((_) async {
          final r = AppState.I.scans.where((s) => s.synthetic).firstOrNull ?? await writeSyntheticScan(AppState.I.library);
          await AppState.I.refresh();
          if (mounted) Navigator.of(context).push(MaterialPageRoute(builder: (_) => ScanDetailScreen(record: r)));
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final pages = [const ScanSetupScreen(), const LibraryScreen(), const ExploreScreen(), const ConnectScreen(), const SettingsScreen()];
    return Scaffold(
      body: IndexedStack(index: _i, children: pages),
      // iOS reserves 34 pt for the home indicator; the labels only need ~16 pt of it, so the bar sits lower
      bottomNavigationBar: MediaQuery(
        data: MediaQuery.of(context).copyWith(
          // top: 0, or the bar inherits the status-bar inset and grows by 62 pt
          padding: MediaQuery.of(context).padding
              .copyWith(top: 0, bottom: (MediaQuery.of(context).padding.bottom - 18).clamp(0, double.infinity)),
        ),
        child: NavigationBar(
          selectedIndex: _i,
          onDestinationSelected: (i) {
            setState(() => _i = i);
            if (i == 1) AppState.I.refresh();
          },
          destinations: const [
            NavigationDestination(
              icon: Icon(Icons.center_focus_weak_rounded),
              selectedIcon: Icon(Icons.center_focus_strong_rounded),
              label: 'Scan',
            ),
            NavigationDestination(icon: Icon(Icons.layers_outlined), selectedIcon: Icon(Icons.layers_rounded), label: 'Library'),
            NavigationDestination(icon: Icon(Icons.public_outlined), selectedIcon: Icon(Icons.public_rounded), label: 'Explore'),
            NavigationDestination(
              icon: Icon(Icons.bluetooth_rounded),
              selectedIcon: Icon(Icons.bluetooth_connected_rounded),
              label: 'Connect',
            ),
            NavigationDestination(icon: Icon(Icons.tune_rounded), selectedIcon: Icon(Icons.tune_rounded), label: 'Settings'),
          ],
        ),
      ),
    );
  }
}

import 'dart:io';

import 'package:flutter/material.dart';

import 'screens/about_screen.dart';
import 'screens/analysis_screen.dart';
import 'screens/capture_screen.dart';
import 'screens/devices_screen.dart';
import 'screens/library_screen.dart';
import 'screens/pairing_screen.dart';
import 'screens/viewer_screen.dart';
import 'service/app_state.dart';
import 'widgets/common.dart';
import 'widgets/honesty_banner.dart';

class FieldStationApp extends StatelessWidget {
  const FieldStationApp({super.key, required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    return AppScope(
      state: state,
      child: MaterialApp(
        title: 'Field Station',
        debugShowCheckedModeBanner: false,
        theme: buildTheme(Brightness.light),
        darkTheme: buildTheme(Brightness.dark),
        themeMode: switch (Platform.environment['FIELDSTATION_THEME']) {
          'light' => ThemeMode.light,
          'dark' => ThemeMode.dark,
          _ => ThemeMode.system,
        },
        home: const Shell(),
      ),
    );
  }
}

class Shell extends StatelessWidget {
  const Shell({super.key});

  static const _dest = [
    (Section.devices, Icons.usb_outlined, Icons.usb, 'Devices'),
    (Section.capture, Icons.videocam_outlined, Icons.videocam, 'Capture'),
    (Section.viewer, Icons.view_in_ar_outlined, Icons.view_in_ar, 'Viewer'),
    (Section.analysis, Icons.straighten_outlined, Icons.straighten, 'Analysis'),
    (Section.library, Icons.folder_outlined, Icons.folder, 'Library'),
    (Section.pairing, Icons.bluetooth_outlined, Icons.bluetooth, 'Pairing'),
    (Section.about, Icons.info_outline, Icons.info, 'About'),
  ];

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    final t = Theme.of(context);
    final idx = _dest.indexWhere((d) => d.$1 == s.section);
    final st = s.status;
    return Scaffold(
      body: Row(children: [
        NavigationRail(
          selectedIndex: idx,
          labelType: NavigationRailLabelType.all,
          minWidth: 84,
          leading: Padding(
            padding: const EdgeInsets.only(top: 8, bottom: 16),
            child: Column(children: [
              Icon(Icons.terrain_outlined, color: t.colorScheme.primary, size: 28),
              const SizedBox(height: 4),
              Text('Field\nStation', textAlign: TextAlign.center, style: t.textTheme.labelSmall?.copyWith(fontWeight: FontWeight.w700)),
            ]),
          ),
          trailing: Expanded(
            child: Align(
              alignment: Alignment.bottomCenter,
              child: Padding(padding: const EdgeInsets.only(bottom: 16), child: _ConnDot(state: s)),
            ),
          ),
          destinations: [
            for (final d in _dest) NavigationRailDestination(icon: Icon(d.$2), selectedIcon: Icon(d.$3), label: Text(d.$4)),
          ],
          onDestinationSelected: (i) => s.go(_dest[i].$1),
        ),
        const VerticalDivider(width: 1),
        Expanded(
          child: Column(children: [
            if (st['origin'] != null && st['state'] != 'idle' && !const {Section.viewer, Section.analysis, Section.library}.contains(s.section))
              HonestyBanner(
                origin: st['origin'] as String?,
                isRealSensor: st['is_real_sensor'] as bool?,
                replayOf: (st['device'] is Map) ? (st['device'] as Map)['replay_of_scan_id'] as String? : null,
                compact: true,
              ),
            if (s.launcher.error != null) _ServiceDown(state: s),
            Expanded(child: _body(s)),
          ]),
        ),
      ]),
    );
  }

  Widget _body(AppState s) {
    if (s.api == null) {
      if (s.launcher.starting) {
        return const EmptyState(icon: Icons.hourglass_empty, title: 'Starting the local service…', body: 'Loading the sensor and analysis libraries.');
      }
      if (s.launcher.error == null) return const SizedBox.shrink();
      return const EmptyState(icon: Icons.power_off_outlined, title: 'The local service is not running', body: 'Capture, analysis and the library need it.');
    }
    switch (s.section) {
      case Section.devices:
        return const DevicesScreen();
      case Section.capture:
        return const CaptureScreen();
      case Section.viewer:
        return const ViewerScreen();
      case Section.analysis:
        return const AnalysisScreen();
      case Section.library:
        return const LibraryScreen();
      case Section.pairing:
        return const PairingScreen();
      case Section.about:
        return const AboutScreen();
    }
  }
}

class _ConnDot extends StatelessWidget {
  const _ConnDot({required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final ok = state.connected && state.eventsConnected;
    return Tooltip(
      message: ok ? 'Local service connected (offline, loopback only)' : 'Local service not connected',
      child: Column(children: [
        Icon(Icons.circle, size: 10, color: ok ? t.colorScheme.primary : t.colorScheme.error),
        const SizedBox(height: 4),
        Text(ok ? 'service' : 'no service', style: t.textTheme.labelSmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
      ]),
    );
  }
}

class _ServiceDown extends StatelessWidget {
  const _ServiceDown({required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Container(
      width: double.infinity,
      color: t.colorScheme.errorContainer,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(children: [
        Icon(Icons.error_outline, color: t.colorScheme.onErrorContainer),
        const SizedBox(width: 10),
        Expanded(child: Text(state.launcher.error!, style: TextStyle(color: t.colorScheme.onErrorContainer))),
        FilledButton.tonal(
          onPressed: state.launcher.starting ? null : () => state.restartService(),
          child: const Text('Restart service'),
        ),
      ]),
    );
  }
}

import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';

import 'app.dart';
import 'service/app_state.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final state = AppState();
  // Stop the child service when the app quits.
  AppLifecycleListener(onExitRequested: () async {
    state.shutdown();
    return AppExitResponse.exit;
  });
  ProcessSignal.sigterm.watch().listen((_) {
    state.shutdown();
    exit(0);
  });
  state.boot();
  runApp(FieldStationApp(state: state));
}

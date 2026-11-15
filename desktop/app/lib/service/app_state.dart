// Draft written with AI assistance (Claude, Anthropic); disclosed per the Space Apps AI policy.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';

import 'api.dart';
import 'ble_bridge.dart';
import 'events.dart';
import 'models.dart';
import 'service_launcher.dart';

enum Section { devices, capture, viewer, analysis, library, pairing, about }

/// App-wide state: service connection, live status, event log, selection. Plain ChangeNotifier.
class AppState extends ChangeNotifier {
  AppState() {
    launcher = ServiceLauncher(onLog: log);
    launcher.addListener(_onLauncher);
    ble.addListener(notifyListeners);
  }

  late final ServiceLauncher launcher;
  final BleBridge ble = BleBridge();
  EventStream? _events;
  bool eventsConnected = false;

  Map<String, dynamic> health = {};
  Map<String, dynamic> adapters = {};
  Map<String, dynamic> status = {};
  final List<Map<String, dynamic>> events = [];
  final List<String> diagnostics = [];
  int scansVersion = 0; // bumped when the library should refresh

  Section section = Section.devices;
  String? selectedScanId;
  String? lastSessionId;
  final Set<String> repeatSelection = {};
  Map<String, dynamic>? pendingRoi; // last ROI used in Analysis, reused for repeatability
  bool fixturesSetting = false;

  ApiClient? get api => launcher.api;
  bool get connected => launcher.running;

  static File get _settingsFile {
    if (Platform.isWindows) {
      final appData = Platform.environment['APPDATA'] ?? Platform.environment['USERPROFILE'] ?? '.';
      return File('$appData/FieldStation/ui_settings.json');
    }
    final home = Platform.environment['HOME'] ?? '.';
    return File('$home/Library/Application Support/FieldStation/ui_settings.json');
  }

  Future<void> boot() async {
    try {
      final f = _settingsFile;
      if (f.existsSync()) fixturesSetting = asMap(jsonDecode(f.readAsStringSync()))['fixtures'] == true;
    } catch (_) {}
    // Optional start position (rehearsal / screenshots): FIELDSTATION_UI_SECTION=viewer FIELDSTATION_UI_SCAN=<scan id>
    final sec = Platform.environment['FIELDSTATION_UI_SECTION'];
    if (sec != null) section = Section.values.firstWhere((e) => e.name == sec, orElse: () => section);
    selectedScanId = Platform.environment['FIELDSTATION_UI_SCAN'] ?? selectedScanId;
    final envFix = Platform.environment['FIELDSTATION_FIXTURES'] == '1';
    await launcher.start(withFixtures: envFix || fixturesSetting);
  }

  Future<void> setFixtures(bool v) async {
    fixturesSetting = v;
    try {
      _settingsFile.parent.createSync(recursive: true);
      _settingsFile.writeAsStringSync(jsonEncode({'fixtures': v}));
    } catch (e) {
      log('could not save settings: $e');
    }
    notifyListeners();
    await restartService();
  }

  Future<void> restartService() async {
    await _events?.close();
    _events = null;
    await launcher.restart(withFixtures: fixturesSetting || Platform.environment['FIELDSTATION_FIXTURES'] == '1');
  }

  void _onLauncher() {
    final a = launcher.api;
    if (a != null && launcher.error == null && _events == null) {
      _events = EventStream(
        a,
        onEvent: _onEvent,
        onConnection: (c) {
          eventsConnected = c;
          notifyListeners();
        },
      )..start();
      ble.attach(a);
      unawaited(refreshBasics());
    }
    if (launcher.error != null) {
      _events?.close();
      _events = null;
      eventsConnected = false;
    }
    notifyListeners();
  }

  Future<void> refreshBasics() async {
    final a = api;
    if (a == null) return;
    try {
      health = asMap(await a.getJson('/api/health'));
      adapters = asMap(await a.getJson('/api/adapters'));
      status = asMap(await a.getJson('/api/status'));
    } catch (e) {
      log('refresh failed: $e');
    }
    notifyListeners();
  }

  /// Automatic iPhone import over USB (service: usb_sync.py). Updated by "usb_sync" events.
  Map<String, dynamic> usbSync = {};

  void _onEvent(Map<String, dynamic> ev) {
    final t = ev['type'];
    if (t == 'status') {
      status = ev;
      notifyListeners();
      return;
    }
    if (t == 'ble_tx') {
      ble.forwardTx(ev);
      return;
    }
    if (t == 'usb_sync') {
      usbSync = ev;
      notifyListeners();
      return;
    }
    events.add(ev);
    if (events.length > 400) events.removeRange(0, events.length - 400);
    if (t == 'scan_processed' || t == 'scan_imported' || t == 'recording_stopped' || t == 'processing_error') scansVersion++;
    if (t == 'recording_started') {
      lastSessionId = null; // re-read from the start response
    }
    notifyListeners();
  }

  void log(String line) {
    final ts = DateTime.now().toIso8601String().substring(11, 19);
    diagnostics.add('$ts  $line');
    if (diagnostics.length > 2000) diagnostics.removeRange(0, diagnostics.length - 2000);
    notifyListeners();
  }

  void go(Section s, {String? scanId}) {
    section = s;
    if (scanId != null) selectedScanId = scanId;
    notifyListeners();
  }

  void selectScan(String? id) {
    selectedScanId = id;
    notifyListeners();
  }

  void toggleRepeat(String id) {
    if (!repeatSelection.remove(id)) repeatSelection.add(id);
    notifyListeners();
  }

  void bumpScans() {
    scansVersion++;
    notifyListeners();
  }

  Map<String, dynamic> get capture => asMap(status['capture']);
  String get deviceState => asStr(status['state'], 'idle');

  void shutdown() {
    _events?.close();
    launcher.killNow();
  }
}

/// Inherited access to the AppState from any widget.
class AppScope extends InheritedNotifier<AppState> {
  const AppScope({super.key, required AppState state, required super.child}) : super(notifier: state);

  static AppState of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<AppScope>()!.notifier!;
  static AppState read(BuildContext context) => context.getInheritedWidgetOfExactType<AppScope>()!.notifier!;
}

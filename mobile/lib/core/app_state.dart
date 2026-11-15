import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'ble_link.dart';
import 'ble_protocol.dart';
import 'scan_record.dart';
import 'scanner.dart';

/// App-wide state: the scan library, user defaults and the Bluetooth link.
class AppState extends ChangeNotifier {
  static final AppState I = AppState._();
  AppState._();

  late ScanLibrary library;
  late Directory docs;
  Map<String, dynamic> caps = {};
  List<ScanRecord> scans = [];
  final BleLink ble = BleLink();

  /// One field session per app launch (a hike or a demo); every scan taken in it shares this id.
  final String fieldSessionId = newId();

  // defaults (persisted in settings.json)
  String displayName = '';
  bool defaultLocation = false;
  bool rigSpeech = true;
  bool rigSound = true;
  bool allowRemoteControl = true;
  String defaultPreset = 'handheld';
  String phoneId = '';
  bool introSeen = false;

  // Keep the screen awake while a capture screen is open, or while paired with remote control on (a phone on the
  // rig must not auto-lock: a locked phone suspends the app, which drops Bluetooth and stops ARKit).
  int _captureScreens = 0;
  bool? _awake;
  void captureScreenOpen(bool open) {
    _captureScreens = (_captureScreens + (open ? 1 : -1)).clamp(0, 99);
    updateAwake(force: true);
  }

  /// Re-applies the keep-awake state. [force] after the native side may have changed it (it clears it when a
  /// recording stops).
  void updateAwake({bool force = false}) {
    final on = _captureScreens > 0 || (ble.paired && allowRemoteControl);
    if (!force && on == _awake) return;
    _awake = on;
    Scanner.keepAwake(on).catchError((_) {});
  }

  Future<void> init() async {
    ble.addListener(updateAwake);
    docs = await getApplicationDocumentsDirectory();
    library = ScanLibrary(Directory('${docs.path}/scans'));
    await _loadSettings();
    caps = await Scanner.capabilities();
    await refresh();
  }

  Future<void> refresh() async {
    scans = await library.list();
    notifyListeners();
  }

  File get _settingsFile => File('${docs.path}/settings.json');

  Future<void> _loadSettings() async {
    try {
      final j = jsonDecode(await _settingsFile.readAsString()) as Map<String, dynamic>;
      displayName = j['displayName'] ?? '';
      defaultLocation = j['defaultLocation'] ?? false;
      rigSpeech = j['rigSpeech'] ?? true;
      rigSound = j['rigSound'] ?? true;
      allowRemoteControl = j['allowRemoteControl'] ?? true;
      defaultPreset = j['defaultPreset'] ?? 'handheld';
      phoneId = j['phoneId'] ?? '';
      introSeen = j['introSeen'] ?? false;
    } catch (_) {}
    if (phoneId.isEmpty) {
      phoneId = newId();
      await saveSettings();
    }
  }

  Future<void> saveSettings() async {
    await _settingsFile.writeAsString(jsonEncode({
      'displayName': displayName,
      'defaultLocation': defaultLocation,
      'rigSpeech': rigSpeech,
      'rigSound': rigSound,
      'allowRemoteControl': allowRemoteControl,
      'defaultPreset': defaultPreset,
      'phoneId': phoneId,
      'introSeen': introSeen,
    }));
    updateAwake();
    notifyListeners();
  }

  bool get hasLidar => caps['sceneDepth'] == true;
  bool get hasArkit => caps['arkit'] == true;
  String get deviceModel => modelName('${caps['modelIdentifier'] ?? 'unknown'}');
}

/// Signal that the capture screen listens to (remote commands from the paired Mac).
class RemoteCommands {
  static final ValueNotifier<Map<String, dynamic>?> last = ValueNotifier(null);
}

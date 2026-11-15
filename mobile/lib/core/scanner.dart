// Dart side of the native ARKit scanner (ios/Runner/FieldScanner.swift).
import 'dart:async';

import 'package:flutter/services.dart';

class CapturePreset {
  final String id, label, description;
  final Map<String, dynamic> trigger;
  final Map<String, dynamic> fuse;
  final Map<String, dynamic> limits;
  const CapturePreset(this.id, this.label, this.description, this.trigger, this.fuse, this.limits);
}

/// Presets are team choices for overlap and file size, not validated optima.
const presets = [
  CapturePreset(
    'handheld',
    'Handheld scan',
    'A keyframe every 10 cm or 10° of movement. Walk slowly around the feature at 0.5–2 m.',
    {'mode': 'movement', 'moveM': 0.10, 'turnDeg': 10.0, 'intervalS': 1.0, 'minGapS': 0.35, 'maxBlurPx': 2.0, 'steadyWaitS': 1.5, 'photoEvery': 4},
    {'enabled': true, 'voxelM': 0.01, 'minConfidence': 1, 'minRangeM': 0.15, 'maxRangeM': 4.0, 'hz': 3.0, 'minSamples': 2},
    {'maxKeyframes': 600, 'maxSeconds': 0, 'minFreeMB': 500},
  ),
  CapturePreset(
    'rig',
    'FieldKit rig (hands-free)',
    'Phone on the rig, screen hidden. A photo every 0.5 m or 15° of turn, or every 3 s while standing. Spoken prompts.',
    {'mode': 'both', 'moveM': 0.5, 'turnDeg': 15.0, 'intervalS': 3.0, 'minGapS': 0.5, 'maxBlurPx': 2.5, 'steadyWaitS': 2.0, 'photoEvery': 1},
    {'enabled': true, 'voxelM': 0.02, 'minConfidence': 1, 'minRangeM': 0.3, 'maxRangeM': 5.0, 'hz': 2.0, 'minSamples': 2},
    {'maxKeyframes': 900, 'maxSeconds': 1800, 'minFreeMB': 800},
  ),
  CapturePreset(
    'interval',
    'Fixed interval',
    'A keyframe every second whatever the movement.',
    {'mode': 'interval', 'moveM': 10.0, 'turnDeg': 360.0, 'intervalS': 1.0, 'minGapS': 0.35, 'maxBlurPx': 2.0, 'steadyWaitS': 1.0, 'photoEvery': 5},
    {'enabled': true, 'voxelM': 0.01, 'minConfidence': 1, 'minRangeM': 0.15, 'maxRangeM': 4.0, 'hz': 3.0, 'minSamples': 2},
    {'maxKeyframes': 600, 'maxSeconds': 0, 'minFreeMB': 500},
  ),
  CapturePreset(
    'manual',
    'Manual shutter',
    'Keyframes only when you (or the paired Mac) press the shutter. Depth fusion still runs.',
    {'mode': 'manual', 'moveM': 10.0, 'turnDeg': 360.0, 'intervalS': 1.0, 'minGapS': 0.2, 'maxBlurPx': 2.0, 'steadyWaitS': 0.0, 'photoEvery': 1},
    {'enabled': true, 'voxelM': 0.01, 'minConfidence': 1, 'minRangeM': 0.15, 'maxRangeM': 4.0, 'hz': 3.0, 'minSamples': 2},
    {'maxKeyframes': 600, 'maxSeconds': 0, 'minFreeMB': 500},
  ),
];

CapturePreset presetById(String id) => presets.firstWhere((p) => p.id == id, orElse: () => presets.first);

class Scanner {
  static const _ch = MethodChannel('field_scan/scanner');
  static const _ev = EventChannel('field_scan/scanner/events');
  static final Stream<Map<String, dynamic>> events =
      _ev.receiveBroadcastStream().map((e) => Map<String, dynamic>.from(e as Map)).asBroadcastStream();

  static Map<String, dynamic>? _caps;

  static Future<Map<String, dynamic>> capabilities() async {
    try {
      _caps = Map<String, dynamic>.from(await _ch.invokeMethod('capabilities') as Map);
    } on MissingPluginException {
      _caps = {'arkit': false, 'sceneDepth': false, 'mesh': false, 'highResFrames': false, 'modelIdentifier': 'unknown'};
    }
    return _caps!;
  }

  static Future<Map<String, dynamic>> prepare({bool mesh = true, bool hiRes = true}) async =>
      Map<String, dynamic>.from(await _ch.invokeMethod('prepare', {'mesh': mesh, 'hiRes': hiRes}) as Map);

  static Future<Map<String, dynamic>> startRecording({
    required String dir,
    required String scanId,
    required CapturePreset preset,
    bool sound = false,
    bool speech = false,
    bool location = false,
  }) async =>
      Map<String, dynamic>.from(await _ch.invokeMethod('startRecording', {
        'dir': dir,
        'scanId': scanId,
        'trigger': preset.trigger,
        'fuse': preset.fuse,
        'limits': preset.limits,
        'sound': sound,
        'speech': speech,
        'location': location,
      }) as Map);

  static Future<Map<String, dynamic>> stopRecording([String reason = 'user']) async =>
      Map<String, dynamic>.from(await _ch.invokeMethod('stopRecording', {'reason': reason}) as Map);

  static Future<void> pause() => _ch.invokeMethod('pause');
  static Future<void> resume() => _ch.invokeMethod('resume');
  static Future<void> captureNow() => _ch.invokeMethod('captureNow');
  static Future<void> stopSession() => _ch.invokeMethod('stopSession');
  static Future<void> keepAwake(bool on) => _ch.invokeMethod('keepAwake', {'on': on});
  static Future<double> setBrightness(double v) async => (await _ch.invokeMethod('setBrightness', {'value': v}) as num).toDouble();
  static Future<double> brightness() async => (await _ch.invokeMethod('setBrightness', {}) as num).toDouble();
  static Future<void> speak(String t) => _ch.invokeMethod('speak', {'text': t});
  static Future<void> cue(String name) => _ch.invokeMethod('cue', {'name': name});
  static Future<int> freeSpaceMB() async {
    try {
      return (await _ch.invokeMethod('freeSpaceMB') as num).toInt();
    } on MissingPluginException {
      return -1;
    }
  }
}

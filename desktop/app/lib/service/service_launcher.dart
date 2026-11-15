import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'api.dart';

/// Finds, starts and supervises the headless Python service (desktop/service).
///
/// FIELDSTATION_URL + FIELDSTATION_TOKEN: connect to an already-running service instead.
/// FIELDSTATION_SERVICE_DIR: where the service lives; otherwise searched upward from the executable.
class ServiceLauncher extends ChangeNotifier {
  ServiceLauncher({required this.onLog});

  final void Function(String line) onLog;

  Process? _proc;
  ApiClient? api;
  String? error;
  String? home;
  bool external = false;
  bool fixtures = false;
  bool starting = false;
  String? serviceDir;
  int? exitCode;

  bool get running => api != null && error == null;

  static String? findServiceDir() {
    final env = Platform.environment['FIELDSTATION_SERVICE_DIR'];
    if (env != null && File('$env/fieldstation/server.py').existsSync()) return env;
    final starts = <Directory>[File(Platform.resolvedExecutable).parent, Directory.current];
    for (final s in starts) {
      Directory d = s.absolute;
      for (int i = 0; i < 14; i++) {
        if (File('${d.path}/service/fieldstation/server.py').existsSync()) return '${d.path}/service';
        if (File('${d.path}/desktop/service/fieldstation/server.py').existsSync()) return '${d.path}/desktop/service';
        final p = d.parent;
        if (p.path == d.path) break;
        d = p;
      }
    }
    return null;
  }

  Future<void> start({required bool withFixtures}) async {
    if (starting) return;
    starting = true;
    error = null;
    exitCode = null;
    fixtures = withFixtures;
    notifyListeners();
    try {
      final envUrl = Platform.environment['FIELDSTATION_URL'];
      final envTok = Platform.environment['FIELDSTATION_TOKEN'];
      if (envUrl != null && envTok != null) {
        external = true;
        api = ApiClient(Uri.parse(envUrl), envTok);
        onLog('Connecting to external service $envUrl (not started by this app)');
        final h = await api!.getJson('/api/health');
        home = (h as Map)['home'] as String?;
        fixtures = h['fixtures'] == true;
        return;
      }
      external = false;
      serviceDir = findServiceDir();
      if (serviceDir == null) {
        throw StateError('Could not find desktop/service. Set FIELDSTATION_SERVICE_DIR to the folder that contains fieldstation/server.py.');
      }
      final py = '$serviceDir/.venv/bin/python';
      if (!File(py).existsSync()) {
        throw StateError('Python environment missing at $py. Create it: cd desktop/service && python3.13 -m venv .venv && .venv/bin/pip install -r requirements.txt');
      }
      final args = ['-m', 'fieldstation.server', '--port', '0', if (withFixtures) '--fixtures'];
      onLog('Starting service: $py ${args.join(' ')} (cwd $serviceDir)');
      final env = Map<String, String>.from(Platform.environment)..remove('FIELDSTATION_TOKEN');
      final p = await Process.start(py, args, workingDirectory: serviceDir, environment: env);
      _proc = p;
      final ready = Completer<Map<String, dynamic>>();
      p.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
        if (!ready.isCompleted && line.trim().startsWith('{')) {
          try {
            final m = jsonDecode(line) as Map<String, dynamic>;
            if (m['event'] == 'ready') {
              ready.complete(m);
              onLog('service ready on port ${m['port']}');
              return;
            }
          } catch (_) {}
        }
        onLog('[service] $line');
      });
      p.stderr.transform(utf8.decoder).transform(const LineSplitter()).listen((line) => onLog('[service:err] $line'));
      unawaited(p.exitCode.then((code) {
        if (_proc != p) return;
        exitCode = code;
        _proc = null;
        error = 'The local service stopped (exit code $code). See About › Diagnostics.';
        if (!ready.isCompleted) ready.completeError(StateError(error!));
        onLog(error!);
        notifyListeners();
      }));
      final m = await ready.future.timeout(const Duration(seconds: 60));
      api = ApiClient(Uri.parse('http://127.0.0.1:${m['port']}'), m['token'] as String);
      home = m['home'] as String?;
    } catch (e) {
      error = e is StateError ? e.message : '$e';
      onLog('service start failed: $error');
      await stop();
      error ??= 'service start failed';
    } finally {
      starting = false;
      notifyListeners();
    }
  }

  Future<void> stop() async {
    final p = _proc;
    _proc = null;
    api?.close();
    api = null;
    if (p != null) {
      p.kill(ProcessSignal.sigterm);
      try {
        await p.exitCode.timeout(const Duration(seconds: 4));
      } catch (_) {
        p.kill(ProcessSignal.sigkill);
      }
    }
  }

  Future<void> restart({required bool withFixtures}) async {
    await stop();
    error = null;
    await start(withFixtures: withFixtures);
  }

  /// Synchronous best-effort kill for app shutdown.
  void killNow() {
    _proc?.kill(ProcessSignal.sigterm);
    _proc = null;
  }
}

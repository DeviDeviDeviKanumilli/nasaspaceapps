import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'api.dart';
import 'models.dart';

/// Bridges the CoreBluetooth peripheral (Swift, in the macOS runner) and the protocol in the Python service.
/// The radio is a dumb pipe: written chunks go to POST /api/ble/rx, and "ble_tx" events from the service go to notify().
class BleBridge extends ChangeNotifier {
  BleBridge();

  static const _method = MethodChannel('fieldstation/ble');
  static const _events = EventChannel('fieldstation/ble/events');

  ApiClient? api;
  StreamSubscription? _sub;
  bool available = true;
  String? unavailableReason;
  String bluetooth = 'unknown';
  bool advertising = false;
  final Set<String> centrals = {};
  String? lastError;
  Future<void> _txChain = Future.value();
  int txFailures = 0;

  void attach(ApiClient? client) {
    api = client;
    if (_sub != null || !available) return;
    try {
      _sub = _events.receiveBroadcastStream().listen(
        _onRadioEvent,
        onError: (Object e) {
          _markUnavailable(e);
        },
      );
      unawaited(refreshState());
    } catch (e) {
      _markUnavailable(e);
    }
  }

  void _markUnavailable(Object e) {
    if (e is MissingPluginException) {
      available = false;
      unavailableReason = 'Bluetooth bridge unavailable in this build';
    } else {
      lastError = '$e';
    }
    notifyListeners();
  }

  Future<void> refreshState() async {
    try {
      final r = asMap(await _method.invokeMethod('state'));
      bluetooth = asStr(r['bluetooth'], 'unknown');
      advertising = r['advertising'] == true;
      centrals
        ..clear()
        ..addAll(asList(r['centrals']).map((e) => '$e'));
      notifyListeners();
    } catch (e) {
      _markUnavailable(e);
    }
  }

  void _onRadioEvent(dynamic raw) {
    final ev = asMap(raw);
    final t = ev['type'];
    final a = api;
    switch (t) {
      case 'state':
        bluetooth = asStr(ev['bluetooth'], bluetooth);
        advertising = ev['advertising'] == true;
        break;
      case 'subscribed':
        centrals.add(asStr(ev['central']));
        break;
      case 'unsubscribed':
        centrals.remove(asStr(ev['central']));
        a?.postJson('/api/ble/disconnected', {'central': ev['central']}).catchError((Object e) {
          lastError = '$e';
          return null;
        });
        break;
      case 'rx':
        a?.postJson('/api/ble/rx', {'central': ev['central'], 'data_b64': ev['data_b64'], 'max_chunk': ev['max_chunk'] ?? 182}).catchError((
          Object e,
        ) {
          lastError = 'rx forward failed: $e';
          notifyListeners();
          return null;
        });
        return;
      case 'error':
        lastError = asStr(ev['message']);
        break;
    }
    notifyListeners();
  }

  /// Called for every service event of type "ble_tx"; notifications are serialised to keep chunk order.
  void forwardTx(Map<String, dynamic> ev) {
    if (!available) return;
    _txChain = _txChain.then((_) async {
      try {
        final ok = await _method.invokeMethod('notify', {'central': ev['central'], 'data_b64': ev['data_b64']});
        if (ok != true) txFailures++;
      } catch (e) {
        txFailures++;
        lastError = 'notify failed: $e';
      }
    });
  }

  /// "Pair a phone": open a pairing window in the service, publish the new info, start advertising.
  Future<Map<String, dynamic>> pairPhone() async {
    final a = api;
    if (a == null) throw ApiException(0, 'service not running');
    final code = asMap(await a.postJson('/api/ble/pairing/open'));
    final info = asMap(await a.getJson('/api/ble/info'));
    if (available) {
      try {
        await _method.invokeMethod('setInfo', {'info_b64': info['info_b64']});
        if (!advertising) {
          final started = await _method.invokeMethod('start', {
            'info_b64': info['info_b64'],
            'local_name': asStr(asMap(info['info'])['name'], 'Field Station'),
          });
          advertising = started == true;
        }
      } catch (e) {
        _markUnavailable(e);
      }
    }
    notifyListeners();
    return code;
  }

  Future<void> stopAdvertising() async {
    try {
      await _method.invokeMethod('stop');
      advertising = false;
    } catch (e) {
      _markUnavailable(e);
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }
}

// Phone side (BLE central) of contracts/BLE_PROTOCOL_V1.md, using flutter_blue_plus under its nonprofit /
// educational licence tier. Tested over the air with Field Station (iPhone 17 Pro + MacBook Air M4, 2026-11-15).
//
// For a phone mounted on a rig, nothing here needs a touch after pairing: a start command opens the capture
// screen if it is not open (see [openForRemote]), and a dropped link reconnects by itself with the same session
// key until the session expires.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import 'ble_protocol.dart';

enum LinkState { idle, scanning, connecting, awaitingCode, pairing, paired, error }

class FoundDesktop {
  final BluetoothDevice device;
  final String name;
  final int rssi;
  FoundDesktop(this.device, this.name, this.rssi);
}

class BleLink extends ChangeNotifier {
  LinkState state = LinkState.idle;
  String? error;
  List<FoundDesktop> found = [];
  Map<String, dynamic>? desktopInfo;
  Map<String, dynamic>? desktopCaptureState;
  final List<String> log = [];

  /// Remote commands addressed to the phone (start_capture / stop_capture / capture_now with target phone).
  final _commands = StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get commands => _commands.stream;

  /// Set by the app shell: opens the capture screen for a remote start_capture that arrives while it is closed.
  /// Returns null when it took the command (the capture screen will ack it), or the reason it refused.
  String? Function(Map<String, dynamic> cmd)? openForRemote;

  /// True while the link is down and the phone is trying to get it back (the session is kept).
  bool reconnecting = false;
  bool _userDisconnect = false;

  BluetoothDevice? _dev;
  BluetoothCharacteristic? _rx, _tx, _info;
  StreamSubscription? _notifySub, _connSub, _scanSub;
  final _framer = Framer();
  final _deframer = Deframer();
  SecureChannel? _chan;
  String? _code, _nd, _np, _phoneId;
  Completer<bool>? _pairDone;
  final Map<String, Completer<Map<String, dynamic>>> _acks = {};
  DateTime? _expires;

  bool get paired => state == LinkState.paired && _chan != null;

  void _log(String s) {
    log.insert(0, '${DateTime.now().toIso8601String().substring(11, 19)}  $s');
    if (log.length > 100) log.removeLast();
    notifyListeners();
  }

  void _set(LinkState s, [String? err]) {
    state = s;
    error = err;
    notifyListeners();
  }

  Future<void> scan() async {
    try {
      if (await FlutterBluePlus.isSupported == false) {
        _set(LinkState.error, 'Bluetooth LE is not supported on this device.');
        return;
      }
      // the first reported state can be 'unknown' while CoreBluetooth starts up
      final st = await FlutterBluePlus.adapterState
          .firstWhere((s) => s != BluetoothAdapterState.unknown)
          .timeout(const Duration(seconds: 3), onTimeout: () => BluetoothAdapterState.unknown);
      final problem = switch (st) {
        BluetoothAdapterState.on => null,
        BluetoothAdapterState.unauthorized => 'Bluetooth permission denied. Allow it in Settings > Field Scan.',
        BluetoothAdapterState.off || BluetoothAdapterState.turningOff => 'Bluetooth is off. Turn it on in Control Center.',
        BluetoothAdapterState.unavailable => 'This device has no usable Bluetooth (the iOS Simulator has none).',
        _ => 'Bluetooth is not available right now. (If this is the iOS Simulator: it has no Bluetooth.)',
      };
      if (problem != null) {
        _set(LinkState.error, problem);
        return;
      }
      found = [];
      _set(LinkState.scanning);
      await _scanSub?.cancel();
      _scanSub = FlutterBluePlus.scanResults.listen((rs) {
        found = [
          for (final r in rs)
            FoundDesktop(r.device, r.advertisementData.advName.isNotEmpty ? r.advertisementData.advName : r.device.platformName, r.rssi)
        ];
        notifyListeners();
      });
      await FlutterBluePlus.startScan(withServices: [Guid(bleServiceUuid)], timeout: const Duration(seconds: 12));
      await FlutterBluePlus.isScanning.where((s) => !s).first;
      if (state == LinkState.scanning) _set(LinkState.idle);
    } catch (e) {
      _set(LinkState.error, 'Scan failed: $e');
    }
  }

  /// Connects and reads the desktop's info (nonce, name). Then [pair] with the code shown on the Mac.
  Future<void> connect(FoundDesktop d, String phoneId) async {
    _phoneId = phoneId;
    _userDisconnect = false;
    _chan = null;
    _set(LinkState.connecting);
    try {
      await FlutterBluePlus.stopScan();
      await _connSub?.cancel();
      _dev = d.device;
      await _dev!.connect(license: License.nonprofit, timeout: const Duration(seconds: 15));
      _connSub = _dev!.connectionState.listen((s) {
        if (s != BluetoothConnectionState.disconnected) return;
        _log('disconnected');
        final sessionOk = _chan != null && (_expires == null || DateTime.now().isBefore(_expires!));
        if (sessionOk && !_userDisconnect) {
          _reconnect(d.name);
          return;
        }
        _chan = null;
        if (state != LinkState.idle) _set(LinkState.error, 'Disconnected from ${d.name}. Pair again when back in range.');
      });
      await _attach();
      desktopInfo = jsonDecode(utf8.decode(await _info!.read())) as Map<String, dynamic>;
      _nd = desktopInfo!['nonce'] as String?;
      _log('connected to ${desktopInfo!['name'] ?? d.name}');
      _set(LinkState.awaitingCode);
    } catch (e) {
      _set(LinkState.error, 'Could not connect: $e');
    }
  }

  /// Finds the service and characteristics on the connected Mac and subscribes to notifications.
  Future<void> _attach() async {
    final services = await _dev!.discoverServices();
    final svc = services.firstWhere((s) => s.uuid == Guid(bleServiceUuid));
    BluetoothCharacteristic ch(String u) => svc.characteristics.firstWhere((c) => c.uuid == Guid(u));
    _info = ch(bleInfoUuid);
    _rx = ch(bleRxUuid);
    _tx = ch(bleTxUuid);
    await _notifySub?.cancel();
    await _tx!.setNotifyValue(true);
    _notifySub = _tx!.onValueReceived.listen(_onChunk);
  }

  /// The link dropped while paired: keep the session key and reconnect to the same Mac. The Mac recognises the
  /// session from the message MAC (the phone may come back with a new Bluetooth identity), so nobody has to
  /// type a code on a phone that is mounted on the rig.
  Future<void> _reconnect(String name) async {
    if (reconnecting) return;
    reconnecting = true;
    _set(LinkState.connecting, 'Connection to $name lost. Reconnecting…');
    var attempt = 0;
    while (_chan != null && !_userDisconnect && _dev != null) {
      if (_expires != null && DateTime.now().isAfter(_expires!)) break;
      attempt++;
      try {
        await _dev!.connect(license: License.nonprofit, timeout: const Duration(seconds: 10));
        await _attach();
        reconnecting = false;
        _log('reconnected (attempt $attempt)');
        _set(LinkState.paired);
        send({'type': 'hello', 'role': 'phone', 'capabilities': ['arkit_lidar', 'arkit_camera']});
        return;
      } catch (e) {
        _log('reconnect attempt $attempt failed: $e');
        await Future<void>.delayed(Duration(seconds: attempt < 5 ? 2 : 5));
      }
    }
    reconnecting = false;
    if (_userDisconnect) return;
    _chan = null;
    _set(LinkState.error, 'Could not reconnect to $name (session expired or Mac gone). Pair again.');
  }

  Future<bool> pair(String code) async {
    if (_nd == null || _rx == null) return false;
    _code = code.trim();
    // Re-read the nonce: the Mac makes a new one each time "Pair a phone" is pressed, which may have happened
    // after we connected (e.g. the 120 s code window ran out). A stale nonce would look like a wrong code.
    try {
      desktopInfo = jsonDecode(utf8.decode(await _info!.read())) as Map<String, dynamic>;
      _nd = desktopInfo!['nonce'] as String? ?? _nd;
    } catch (e) {
      _log('could not re-read desktop info: $e');
    }
    _np = Pairing.newNonce();
    _set(LinkState.pairing);
    _pairDone = Completer();
    await _sendRaw(jsonEncode({
      'v': 1,
      'type': 'pair_request',
      'phone_id': _phoneId,
      'phone_name': 'Field Scan iPhone',
      'nonce_phone': _np,
      'proof': Pairing.phoneProof(_code!, _nd!, _np!, _phoneId!),
    }));
    final ok = await _pairDone!.future.timeout(const Duration(seconds: 10), onTimeout: () => false);
    if (!ok && state == LinkState.pairing) _set(LinkState.awaitingCode, 'Pairing failed or timed out. Check the code on the Mac.');
    return ok;
  }

  void _onChunk(List<int> chunk) {
    final msg = _deframer.add(chunk);
    if (msg == null) return;
    try {
      final o = jsonDecode(msg) as Map<String, dynamic>;
      if (_chan == null) {
        _handlePairing(o);
        return;
      }
      if (_expires != null && DateTime.now().isAfter(_expires!)) {
        _chan = null;
        _set(LinkState.error, 'Pairing expired. Pair again.');
        return;
      }
      if (o['type'] == 'error' && o['code'] == 'not_paired') {
        // The Mac no longer has our session (its service restarted, or the session expired there).
        _chan = null;
        _set(LinkState.error, 'The Mac no longer recognises this phone (Field Station restarted?). Pair again.');
        return;
      }
      final m = _chan!.unwrap(msg);
      if (m != null) _handle(m);
    } on SecurityException catch (e) {
      _log('dropped message: ${e.message}');
    } catch (e) {
      _log('bad message: $e');
    }
  }

  void _handlePairing(Map<String, dynamic> o) {
    if (o['type'] == 'pair_accept') {
      final expect = Pairing.desktopProof(_code!, _np!, _nd!);
      if (!constantTimeEquals(expect, '${o['proof']}')) {
        _log('desktop proof invalid: not paired');
        _pairDone?.complete(false);
        return;
      }
      _chan = SecureChannel(Pairing.sessionKey(_code!, _nd!, _np!));
      _expires = DateTime.now().add(Duration(seconds: (o['expires_s'] as num?)?.toInt() ?? 3600));
      _code = null; // not kept after the key is derived
      _log('paired');
      _set(LinkState.paired);
      _pairDone?.complete(true);
      send({'type': 'hello', 'role': 'phone', 'capabilities': ['arkit_lidar', 'arkit_camera']});
    } else if (o['type'] == 'pair_reject') {
      _log('pairing rejected: ${o['reason']}');
      _pairDone?.complete(false);
    }
  }

  void _handle(Map<String, dynamic> m) {
    final type = m['type'];
    if (m['_duplicate'] == true) {
      if (type != 'ack') {
        // repeat the original outcome so a failed command is still reported as failed
        final prev = _ackResults[m['id']];
        if (prev == null) {
          // The first copy is still with the capture screen: its ack is on the way, so stay quiet rather than
          // claim an outcome we don't know yet. Anything else was never handled: say so (never a false "ok").
          if (_inFlight.contains(m['id'])) return;
          send({'type': 'ack', 'ref': m['id'], 'ok': false, 'error': 'duplicate of a command this phone did not handle'});
        } else {
          send({'type': 'ack', 'ref': m['id'], 'ok': prev.$1, 'error': prev.$2 ?? 'duplicate: already handled'});
        }
      }
      return;
    }
    if (type == 'ack') {
      _acks.remove(m['ref'])?.complete(m);
      return;
    }
    if (type == 'capture_state' || type == 'capture_complete') {
      desktopCaptureState = m;
      notifyListeners();
      return;
    }
    if (type == 'hello') {
      _log('desktop hello: ${m['capabilities']}');
      return;
    }
    if (type == 'start_capture' || type == 'stop_capture' || type == 'capture_now') {
      if ((m['target'] ?? 'phone') == 'phone' || type == 'capture_now') {
        _log('remote $type');
        if (!_commands.hasListener) {
          // Only the capture screen can obey (it owns the AR session). A start opens it (rig use: nobody touches
          // the phone); anything else is refused with the reason instead of being dropped.
          if (type == 'start_capture') {
            final refused = openForRemote == null ? 'phone app cannot open the scanner by itself' : openForRemote!(m);
            if (refused == null) {
              _inFlight.add('${m['id']}');
              return; // the capture screen acks once the camera is ready and recording has started
            }
            ack(m, false, refused);
          } else {
            ack(m, false, 'not recording (the scanner is not open on the phone)');
          }
          return;
        }
        _inFlight.add('${m['id']}');
        _commands.add(m);
        return; // the capture screen sends the ack (it knows whether it obeyed)
      }
    }
    if (type == 'disconnect') {
      _log('desktop disconnected: ${m['reason']}');
      disconnect(sendMessage: false);
      return;
    }
    _log('unhandled ${m['type']}');
  }

  Future<void> _sendRaw(String s) async {
    final mtu = _dev?.mtuNow ?? 23;
    for (final c in _framer.split(s, mtu)) {
      await _rx!.write(c, withoutResponse: false);
    }
  }

  /// Sends an authenticated message; for commands, waits for the ack (re-sent once after 5 s).
  Future<Map<String, dynamic>?> send(Map<String, dynamic> inner, {bool wantAck = false}) async {
    if (_chan == null) return null;
    inner['id'] ??= newId();
    final id = inner['id'] as String;
    final wire = _chan!.wrap(inner);
    if (!wantAck) {
      await _sendRaw(wire);
      return null;
    }
    for (int attempt = 0; attempt < 2; attempt++) {
      final c = Completer<Map<String, dynamic>>();
      _acks[id] = c;
      // the re-send keeps the same id but needs a fresh seq, so re-wrap
      await _sendRaw(attempt == 0 ? wire : _chan!.wrap(Map.of(inner)));
      try {
        return await c.future.timeout(const Duration(seconds: 5));
      } on TimeoutException {
        _log('no ack for ${inner['type']} (attempt ${attempt + 1})');
      }
    }
    _acks.remove(id);
    return {'ok': false, 'error': 'timeout'};
  }

  /// Outcome of each command this phone acknowledged, so a re-sent duplicate gets the same answer.
  final Map<String, (bool, String?)> _ackResults = {};

  /// Commands handed to the capture screen whose ack has not been sent yet.
  final Set<String> _inFlight = {};

  Future<void> ack(Map<String, dynamic> m, bool ok, [String? err]) {
    _inFlight.remove('${m['id']}');
    _ackResults['${m['id']}'] = (ok, err);
    if (_ackResults.length > 200) _ackResults.remove(_ackResults.keys.first);
    return send({'type': 'ack', 'ref': m['id'], 'ok': ok, if (err != null) 'error': err});
  }

  Future<void> disconnect({bool sendMessage = true}) async {
    _userDisconnect = true;
    try {
      if (sendMessage && _chan != null) await send({'type': 'disconnect', 'reason': 'user'});
    } catch (_) {}
    await _notifySub?.cancel();
    await _connSub?.cancel();
    try {
      await _dev?.disconnect();
    } catch (_) {}
    _chan = null;
    _dev = null;
    desktopInfo = null;
    desktopCaptureState = null;
    _set(LinkState.idle);
  }
}

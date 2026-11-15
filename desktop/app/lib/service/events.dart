import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'api.dart';

/// WebSocket /ws/events with automatic reconnect. Emits decoded JSON maps.
class EventStream {
  EventStream(this.api, {required this.onEvent, required this.onConnection});

  final ApiClient api;
  final void Function(Map<String, dynamic> ev) onEvent;
  final void Function(bool connected) onConnection;
  WebSocket? _ws;
  bool _closed = false;
  Timer? _retry;

  void start() => _connect();

  Future<void> _connect() async {
    if (_closed) return;
    try {
      final ws = await WebSocket.connect(api.wsUrl('/ws/events').toString()).timeout(const Duration(seconds: 5));
      if (_closed) {
        await ws.close();
        return;
      }
      _ws = ws;
      onConnection(true);
      ws.listen(
        (data) {
          if (data is String) {
            try {
              final m = jsonDecode(data);
              if (m is Map) onEvent(m.cast<String, dynamic>());
            } catch (_) {}
          }
        },
        onDone: _dropped,
        onError: (_) => _dropped(),
        cancelOnError: true,
      );
    } catch (_) {
      _dropped();
    }
  }

  void _dropped() {
    _ws = null;
    onConnection(false);
    if (_closed) return;
    _retry?.cancel();
    _retry = Timer(const Duration(seconds: 2), _connect);
  }

  Future<void> close() async {
    _closed = true;
    _retry?.cancel();
    await _ws?.close();
    _ws = null;
  }
}

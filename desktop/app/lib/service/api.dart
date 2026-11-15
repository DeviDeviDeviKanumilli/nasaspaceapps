// Draft written with AI assistance (Claude, Anthropic); disclosed per the Space Apps AI policy.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Error returned by the local service (FastAPI `{"detail": ...}`), shown verbatim in the UI.
class ApiException implements Exception {
  ApiException(this.status, this.message);
  final int status;
  final String message;
  @override
  String toString() => status > 0 ? '$message (HTTP $status)' : message;
}

class ApiBytes {
  ApiBytes(this.status, this.bytes, this.headers);
  final int status;
  final Uint8List bytes;
  final Map<String, String> headers;
}

/// Thin client for the loopback Field Station service. Every request carries the per-launch token.
class ApiClient {
  ApiClient(this.base, this.token) {
    _http.connectionTimeout = const Duration(seconds: 5);
    _http.idleTimeout = const Duration(seconds: 15);
  }

  final Uri base;
  final String token;
  final HttpClient _http = HttpClient();

  /// URL with the token in the query string, for Image.network and WebSocket.
  Uri url(String path, [Map<String, String>? query]) {
    return base.replace(path: path, queryParameters: {...?query, 'token': token});
  }

  Uri wsUrl(String path) {
    return base.replace(scheme: base.scheme == 'https' ? 'wss' : 'ws', path: path, queryParameters: {'token': token});
  }

  Future<dynamic> getJson(String path, {Map<String, String>? query, Duration timeout = const Duration(seconds: 30)}) =>
      _json('GET', path, query: query, timeout: timeout);

  Future<dynamic> postJson(String path, [Object? body, Duration timeout = const Duration(seconds: 120)]) =>
      _json('POST', path, body: body ?? <String, dynamic>{}, timeout: timeout);

  Future<dynamic> patchJson(String path, Object body) => _json('PATCH', path, body: body);

  Future<dynamic> _json(
    String method,
    String path, {
    Map<String, String>? query,
    Object? body,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final r = await _send(method, path, query: query, body: body, timeout: timeout);
    final text = utf8.decode(r.bytes);
    if (r.status >= 400) {
      String msg = text;
      try {
        final d = jsonDecode(text);
        if (d is Map && d['detail'] != null) msg = d['detail'] is String ? d['detail'] as String : jsonEncode(d['detail']);
      } catch (_) {}
      throw ApiException(r.status, msg);
    }
    if (text.isEmpty) return null;
    return jsonDecode(text);
  }

  Future<ApiBytes> getBytes(String path, {Map<String, String>? query, Duration timeout = const Duration(seconds: 60)}) async {
    final r = await _send('GET', path, query: query, timeout: timeout);
    if (r.status >= 400) {
      String msg = utf8.decode(r.bytes, allowMalformed: true);
      try {
        final d = jsonDecode(msg);
        if (d is Map && d['detail'] != null) msg = '${d['detail']}';
      } catch (_) {}
      throw ApiException(r.status, msg);
    }
    return r;
  }

  Future<ApiBytes> _send(String method, String path, {Map<String, String>? query, Object? body, required Duration timeout}) async {
    final uri = base.replace(path: path, queryParameters: query);
    try {
      final req = await _http.openUrl(method, uri).timeout(timeout);
      req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      if (body != null) {
        final data = utf8.encode(jsonEncode(body));
        req.headers.contentType = ContentType.json;
        req.contentLength = data.length;
        req.add(data);
      }
      final res = await req.close().timeout(timeout);
      final builder = BytesBuilder(copy: false);
      await for (final chunk in res.timeout(timeout)) {
        builder.add(chunk);
      }
      final headers = <String, String>{};
      res.headers.forEach((k, v) => headers[k.toLowerCase()] = v.join(','));
      return ApiBytes(res.statusCode, builder.takeBytes(), headers);
    } on TimeoutException {
      throw ApiException(0, 'The local service did not answer within ${timeout.inSeconds} s ($method $path)');
    } on SocketException catch (e) {
      throw ApiException(0, 'Cannot reach the local service: ${e.message}');
    } on HttpException catch (e) {
      throw ApiException(0, 'Connection to the local service failed: ${e.message}');
    }
  }

  void close() => _http.close(force: true);
}

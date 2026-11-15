// Draft written with AI assistance (Claude, Anthropic); disclosed per the Space Apps AI policy.

import 'dart:typed_data';

/// Helpers to read loosely-typed JSON from the service without crashing on missing keys.
Map<String, dynamic> asMap(Object? o) => o is Map ? o.cast<String, dynamic>() : <String, dynamic>{};
List<dynamic> asList(Object? o) => o is List ? o : const [];
double? asDouble(Object? o) => o is num ? o.toDouble() : (o is String ? double.tryParse(o) : null);
int? asInt(Object? o) => o is num ? o.toInt() : (o is String ? int.tryParse(o) : null);
String asStr(Object? o, [String fallback = '']) => o == null ? fallback : '$o';

/// Honesty classification of where data came from.
enum OriginKind { realD435, replay, synthetic, iphone, unknownImport, other }

OriginKind originKind(String? origin) {
  switch (origin) {
    case 'realsense_d435':
      return OriginKind.realD435;
    case 'replay':
      return OriginKind.replay;
    case 'synthetic_fixture':
      return OriginKind.synthetic;
    case 'iphone_arkit_lidar':
    case 'iphone_arkit_camera':
      return OriginKind.iphone;
    case 'unknown_import':
      return OriginKind.unknownImport;
    default:
      return OriginKind.other;
  }
}

String originBadge(String? origin) {
  switch (originKind(origin)) {
    case OriginKind.realD435:
      return 'REAL D435';
    case OriginKind.replay:
      return 'REPLAY';
    case OriginKind.synthetic:
      return 'SYNTHETIC';
    case OriginKind.iphone:
      return origin == 'iphone_arkit_camera' ? 'iPhone camera' : 'iPhone ARKit';
    case OriginKind.unknownImport:
      return 'Unknown import';
    case OriginKind.other:
      return origin ?? 'unknown';
  }
}

class ScanSummary {
  ScanSummary(this.raw);
  final Map<String, dynamic> raw;
  String get id => asStr(raw['scan_id']);
  String? get sessionId => raw['session_id'] as String?;
  String? get origin => raw['origin'] as String?;
  bool get isRealSensor => raw['is_real_sensor'] == true;
  String get status => asStr(raw['status'], 'unknown');
  String? get statusReason => raw['status_reason'] as String?;
  String get title => (raw['title'] as String?)?.trim().isNotEmpty == true ? raw['title'] as String : 'Untitled scan';
  String? get featureType => raw['feature_type'] as String?;
  String? get capturedAt => raw['captured_at_utc'] as String?;
  int? get frames => asInt(raw['frames']);
  int get measurementCount => asInt(raw['measurement_count']) ?? 0;
  String? get publication => raw['publication_status'] as String?;
  bool get hasThumbnail => raw['has_thumbnail'] == true;
  String? get deviceModel => raw['device_model'] as String?;
}

/// One measurement record (contracts/SCAN_BUNDLE_V1.md measurements[]).
class Measurement {
  Measurement(this.raw);
  final Map<String, dynamic> raw;
  String get id => asStr(raw['id']);
  String get name => asStr(raw['name']);
  String get label => asStr(raw['label']);
  Object? get value => raw['value'];
  String get unit => asStr(raw['unit']);
  String get status => asStr(raw['status'], 'measured');
  String get method => asStr(raw['method']);
  String get frame => asStr(raw['frame']);
  Map<String, dynamic> get roi => asMap(raw['roi']);
  Map<String, dynamic> get extra => asMap(raw['extra']);
  Map<String, dynamic> get uncertainty => asMap(raw['uncertainty']);
  List<String> get validity => asList(raw['validity']).map((e) => '$e').toList();
  String? get sourceArtifact => raw['source_artifact'] as String?;

  /// Value with units, e.g. "4.66 mm" for metres below 0.1 m.
  String get displayValue => formatValue(value, unit);

  static List<Measurement> listFrom(Object? o) => asList(o).map((e) => Measurement(asMap(e))).toList();
}

String formatValue(Object? v, String unit) {
  if (v == null) return '—';
  if (v is List) return v.map((e) => formatValue(e, unit)).join(' × ');
  final d = asDouble(v);
  if (d == null) return '$v $unit';
  if (unit == 'm') return formatMetres(d);
  if (unit == 'deg') return '${d.toStringAsFixed(2)}°';
  return '${_trim(d)} $unit';
}

String formatMetres(double m) {
  final a = m.abs();
  if (a < 0.1) return '${(m * 1000).toStringAsFixed(a < 0.01 ? 2 : 1)} mm';
  return '${m.toStringAsFixed(3)} m';
}

String _trim(double d) {
  if (d == d.roundToDouble() && d.abs() < 1e9) return d.toStringAsFixed(0);
  return d.toStringAsPrecision(4);
}

String prettyName(String snake) {
  if (snake.isEmpty) return snake;
  final s = snake.replaceAll('_', ' ');
  return s[0].toUpperCase() + s.substring(1);
}

/// Decoded /cloud.bin payload: uint32 N | N*3 float32 xyz | N*3 uint8 rgb (little-endian).
class CloudData {
  CloudData({required this.xyz, required this.rgb, required this.count, this.total, this.frame, this.sourceFile, this.origin, this.step});
  final Float32List xyz;
  final Uint8List rgb;
  final int count;
  final int? total;
  final String? frame;
  final String? sourceFile;
  final String? origin;
  final int? step;

  static CloudData parse(Uint8List bytes, [Map<String, String> headers = const {}]) {
    if (bytes.length < 4) throw const FormatException('cloud.bin too short');
    final bd = ByteData.sublistView(bytes);
    final n = bd.getUint32(0, Endian.little);
    final need = 4 + n * 12 + n * 3;
    if (bytes.length < need) throw FormatException('cloud.bin truncated: need $need bytes, have ${bytes.length}');
    final xyz = Float32List(n * 3);
    for (int i = 0; i < n * 3; i++) {
      xyz[i] = bd.getFloat32(4 + i * 4, Endian.little);
    }
    final rgb = Uint8List.fromList(bytes.sublist(4 + n * 12, need));
    return CloudData(
      xyz: xyz,
      rgb: rgb,
      count: n,
      total: int.tryParse(headers['x-points-total'] ?? ''),
      frame: headers['x-frame'],
      sourceFile: headers['x-source-file'],
      origin: headers['x-origin'],
      step: int.tryParse(headers['x-decimation-step'] ?? ''),
    );
  }
}

const featureTypes = ['rock_face', 'boulder', 'boulder_field', 'outcrop', 'ground', 'other'];

String statusExplanation(String status) {
  switch (status) {
    case 'at_noise_floor':
      return 'Residual RMS is under 2× the expected sensor noise at this range: surface roughness is not resolved.';
    case 'not_measured':
      return 'Not measured: the required reference or data is missing.';
    default:
      return '';
  }
}

// The scan.json envelope (contracts/SCAN_BUNDLE_V1.md) and the on-phone library of scan folders.
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

const schemaVersion = '1.0';
const appName = 'Field Scan';
const appVersion = '0.1.0';
const pipelineVersion = 'fs-1.0';

const featureTypes = {
  'rock_face': 'Rock face',
  'boulder': 'Boulder',
  'boulder_field': 'Boulder field',
  'outcrop': 'Outcrop',
  'ground': 'Ground / terrain',
  'other': 'Other',
};

const _models = {
  'iPhone18,1': 'iPhone 17 Pro',
  'iPhone18,2': 'iPhone 17 Pro Max',
  'iPhone18,3': 'iPhone 17',
  'iPhone18,4': 'iPhone Air',
  'iPhone17,1': 'iPhone 16 Pro',
  'iPhone17,2': 'iPhone 16 Pro Max',
  'iPhone16,1': 'iPhone 15 Pro',
  'iPhone16,2': 'iPhone 15 Pro Max',
  'iPhone15,2': 'iPhone 14 Pro',
  'iPhone15,3': 'iPhone 14 Pro Max',
  'iPhone14,2': 'iPhone 13 Pro',
  'iPhone14,3': 'iPhone 13 Pro Max',
  'iPhone13,3': 'iPhone 12 Pro',
  'iPhone13,4': 'iPhone 12 Pro Max',
};

String modelName(String id) => (id == 'arm64' || id == 'x86_64') ? 'iOS Simulator' : (_models[id] ?? id);

String utcNow() => DateTime.now().toUtc().toIso8601String();

/// What the user types before a scan. Annotation only: nothing here is detected by the app.
class ScanSetup {
  String title;
  String featureType;
  String notes;
  String fieldSiteId;
  String candidateId;
  String candidateRunId;
  bool collectLocation;
  bool rigMode;
  String preset;
  ScanSetup({
    this.title = '',
    this.featureType = 'rock_face',
    this.notes = '',
    this.fieldSiteId = '',
    this.candidateId = '',
    this.candidateRunId = '',
    this.collectLocation = false,
    this.rigMode = false,
    this.preset = 'handheld',
  });
}

List<String> baseLimitations({required bool depth, required bool mesh}) => [
      'Geometry only: this scan does not measure mineralogy, chemistry or rock age.',
      if (depth) "Depth is ARKit's processed sceneDepth estimate, not raw LiDAR returns.",
      if (!depth) 'No depth sensor on this device: keyframes hold RGB images and ARKit camera poses only.',
      'Coordinates are a local ARKit session frame (metres, +Y up along gravity); not geodetic, and tracking can drift.',
      'Only surfaces seen by the camera are present; hidden sides are missing, not inferred.',
      if (mesh) 'The ARKit mesh is a smoothed surface approximation; its surface classes describe rooms (wall, floor), not geology.',
      'A centimetre-to-metre scan cannot validate kilometre-scale planetary terrain comparisons.',
      'Field observations by users are not peer-reviewed and are not certified planetary analogs.',
    ];

/// Builds scan.json from the native capture summary and the user's setup.
Map<String, dynamic> buildEnvelope(Map<String, dynamic> s, ScanSetup setup, {required String sessionId}) {
  final depth = s['depth'] == true;
  final mesh = s['mesh'] == true && s['meshVertices'] != null;
  final loc = s['location'] as Map?;
  final fuse = Map<String, dynamic>.from(s['fuse'] as Map? ?? {});
  return {
    'schema_version': schemaVersion,
    'scan_id': s['scanId'],
    'session_id': sessionId,
    'status': 'complete',
    'status_reason': s['stopReason'],
    'is_real_sensor': true,
    'origin': depth ? 'iphone_arkit_lidar' : 'iphone_arkit_camera',
    'platform': 'ios',
    'device': {
      'manufacturer': 'Apple',
      'model': modelName('${s['modelIdentifier']}'),
      'model_identifier': s['modelIdentifier'],
      'os_version': s['osVersion'],
    },
    'app': {'name': appName, 'version': appVersion, 'pipeline_version': pipelineVersion},
    'captured_at_utc': {'start': s['startUTC'], 'end': s['endUTC']},
    'capture': {
      'depth_type': depth ? 'sceneDepth' : 'none',
      'depth_units': 'm',
      'smoothed_depth_used': false,
      'confidence_present': depth,
      'mesh_present': mesh,
      'tracking_poses_present': true,
      'keyframes': s['keyframes'],
      'frames_recorded': s['keyframes'],
      'photos': s['photos'],
      'trigger': s['trigger'],
      'rig_mode': setup.rigMode,
      'preset': setup.preset,
    },
    'coordinate_frame': {
      'name': 'arkit_session_world',
      'units': 'm',
      'handedness': 'right',
      'up': '+Y along measured gravity (ARKit worldAlignment.gravity)',
      'origin': 'phone position and heading when the AR session started',
      'camera_convention': 'ARKit camera: +X right, +Y up, -Z forward, for the sensor-native landscape image',
      'pixel_convention': 'u right, v down; depth pixel centre (i+0.5)*s-0.5 in RGB pixels, s = image_w/depth_w',
      'matrix_storage': 'column-major 4x4, camera_to_world',
    },
    'location': {
      'sharing': 'hidden',
      'collected': loc != null,
      'latitude': loc?['latitude'],
      'longitude': loc?['longitude'],
      'uncertainty_m': loc?['horizontal_accuracy_m'],
      'fix_utc': loc?['fix_utc'],
    },
    'field_site_id': setup.fieldSiteId.isEmpty ? null : setup.fieldSiteId,
    'candidate_id': setup.candidateId.isEmpty ? null : setup.candidateId,
    'candidate_run_id': setup.candidateRunId.isEmpty ? null : setup.candidateRunId,
    'observation': {
      'title': setup.title,
      'feature_type': setup.featureType,
      'feature_type_note': 'chosen by the user; not detected by the app',
      'notes': setup.notes,
      'claims': <Map<String, dynamic>>[],
    },
    'quality': {
      'keyframes': s['keyframes'],
      'photos': s['photos'],
      'depth': s['depthStats'],
      'fused_points': s['points'],
      'fused_frames': s['fusedFrames'],
      'fusion_capped': s['capped'],
      'mesh_vertices': s['meshVertices'],
      'mesh_faces': s['meshFaces'],
      'mesh_anchors': s['meshAnchors'],
      'tracking_limited_s': s['trackingLimitedS'],
      'tracking_limited_episodes': s['trackingLimitedEpisodes'],
      'camera_path_length_m': s['pathLengthM'],
      'keyframes_with_blur_risk': s['blurRiskKeyframes'],
      'blur_estimate_note': 'rotation-only estimate (angular speed x exposure x focal length); a heuristic',
      'interruptions': s['interruptions'],
    },
    'measurements': <Map<String, dynamic>>[],
    'files': [
      for (final f in (s['files'] as List? ?? []))
        {
          ...Map<String, dynamic>.from(f as Map),
          'kind': '${(f)['role']}'.startsWith('derived') || f['role'] == 'thumbnail' ? 'derived' : 'raw',
          'coordinate_frame': '${f['role']}'.contains('point_cloud') || '${f['role']}'.contains('mesh') ? 'arkit_session_world' : null,
        }
    ],
    'processing': {
      'pipeline_version': pipelineVersion,
      'operations': [
        if (fuse['enabled'] == true)
          {
            'op': 'voxel_fuse',
            'input': 'ARFrame.sceneDepth + confidenceMap + capturedImage, sampled at hz while tracking was normal',
            'params': fuse,
            'output': 'point_cloud_fused.ply',
            'note': 'a voxel position is the mean of its depth samples; colour is the mean RGB; nothing is interpolated',
          },
        if (mesh) {'op': 'arkit_scene_reconstruction', 'output': 'mesh_arkit.ply', 'note': 'latest revision of each ARMeshAnchor'},
        {'op': 'keyframe_capture', 'params': s['trigger']},
      ],
    },
    'publication': {'status': 'local_private', 'license': null, 'consent_obtained': false},
    'limitations': baseLimitations(depth: depth, mesh: mesh),
    'revisions': [
      {'utc': utcNow(), 'change': 'created on phone'}
    ],
  };
}

class ScanRecord {
  final Directory dir;
  Map<String, dynamic> json;
  ScanRecord(this.dir, this.json);

  String get id => '${json['scan_id']}';
  String get title {
    final t = '${json['observation']?['title'] ?? ''}';
    return t.isEmpty ? 'Untitled scan' : t;
  }

  String get status => '${json['status'] ?? 'complete'}';
  String get publication => '${json['publication']?['status'] ?? 'local_private'}';
  bool get synthetic => json['origin'] == 'synthetic_fixture';
  DateTime? get start => DateTime.tryParse('${json['captured_at_utc']?['start']}');
  File file(String rel) => File('${dir.path}/$rel');
  bool has(String rel) => file(rel).existsSync();
  List<Map<String, dynamic>> get measurements =>
      [for (final m in (json['measurements'] as List? ?? [])) Map<String, dynamic>.from(m as Map)];

  Future<void> save(String change) async {
    (json['revisions'] as List? ?? (json['revisions'] = [])).add({'utc': utcNow(), 'change': change});
    final tmp = File('${dir.path}/scan.json.tmp');
    await tmp.writeAsString(const JsonEncoder.withIndent(' ').convert(json), flush: true);
    await tmp.rename('${dir.path}/scan.json');
  }
}

class ScanLibrary {
  final Directory root;
  ScanLibrary(this.root);

  Directory newScanDir(String scanId) => Directory('${root.path}/scan-$scanId');

  /// Lists scans newest first. A folder with capture files but no scan.json (app killed mid-scan) is listed
  /// as an incomplete scan with a minimal envelope written for it, so the raw keyframes are not lost.
  Future<List<ScanRecord>> list() async {
    if (!root.existsSync()) root.createSync(recursive: true);
    final out = <ScanRecord>[];
    for (final e in root.listSync().whereType<Directory>()) {
      final name = e.path.split('/').last;
      if (!name.startsWith('scan-')) continue;
      final f = File('${e.path}/scan.json');
      if (f.existsSync()) {
        try {
          out.add(ScanRecord(e, jsonDecode(await f.readAsString()) as Map<String, dynamic>));
        } catch (_) {
          out.add(ScanRecord(e, _incomplete(e, name.substring(5), 'scan.json unreadable')));
        }
      } else if (File('${e.path}/keyframes.jsonl').existsSync()) {
        final r = ScanRecord(e, _incomplete(e, name.substring(5), 'capture ended without saving (app closed or crashed)'));
        await r.save('marked incomplete on startup');
        out.add(r);
      }
    }
    out.sort((a, b) => (b.start ?? DateTime(0)).compareTo(a.start ?? DateTime(0)));
    return out;
  }

  Map<String, dynamic> _incomplete(Directory d, String id, String reason) {
    final kf = File('${d.path}/keyframes.jsonl');
    final n = kf.existsSync() ? kf.readAsLinesSync().where((l) => l.contains('"keyframe"')).length : 0;
    final files = <Map<String, dynamic>>[];
    for (final f in d.listSync(recursive: true).whereType<File>()) {
      final rel = f.path.substring(d.path.length + 1);
      if (rel.startsWith('scan.json')) continue;
      final bytes = f.readAsBytesSync();
      files.add({'path': rel, 'bytes': bytes.length, 'sha256': sha256.convert(bytes).toString(), 'role': 'recovered'});
    }
    return {
      'schema_version': schemaVersion,
      'scan_id': id,
      'status': 'incomplete',
      'status_reason': reason,
      'is_real_sensor': true,
      'origin': 'iphone_arkit_lidar',
      'captured_at_utc': {'start': d.statSync().modified.toUtc().toIso8601String(), 'end': null},
      'capture': {'keyframes': n},
      'coordinate_frame': {'name': 'arkit_session_world', 'units': 'm', 'handedness': 'right', 'up': '+Y along measured gravity (ARKit worldAlignment.gravity)'},
      'observation': {'title': 'Recovered scan', 'feature_type': 'other', 'notes': '', 'claims': []},
      'quality': {'keyframes': n},
      'measurements': [],
      'files': files,
      'publication': {'status': 'local_private', 'license': null, 'consent_obtained': false},
      'limitations': ['Incomplete capture: no fused cloud or mesh was written; raw keyframes are kept.'],
      'revisions': [],
    };
  }

  Future<void> delete(ScanRecord r) async => r.dir.delete(recursive: true);
}

/// Verifies every listed file's size and SHA-256. Returns a list of problems (empty = all good).
Future<List<String>> verifyFiles(ScanRecord r) async {
  final problems = <String>[];
  for (final f in (r.json['files'] as List? ?? [])) {
    final rel = '${f['path']}';
    final file = r.file(rel);
    if (!file.existsSync()) {
      problems.add('$rel missing');
      continue;
    }
    final bytes = await file.readAsBytes();
    if (bytes.length != f['bytes']) problems.add('$rel size ${bytes.length} != ${f['bytes']}');
    if (sha256.convert(bytes).toString() != f['sha256']) problems.add('$rel SHA-256 mismatch');
  }
  return problems;
}

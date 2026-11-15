import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../core/app_state.dart';
import '../core/ble_protocol.dart';
import '../core/geometry.dart';
import '../core/ply.dart';
import '../core/scan_record.dart';
import '../ui/style.dart';
import '../widgets/cloud_viewer.dart';
import 'contribute_screen.dart';

PointCloud _parseFull(Uint8List b) => parsePly(b);
PointCloud _parseDisplay(Uint8List b) => parsePly(b, maxPoints: 120000);

enum _Tool { look, distance, roi }

class ScanDetailScreen extends StatefulWidget {
  final ScanRecord record;
  final bool justCaptured;
  const ScanDetailScreen({super.key, required this.record, this.justCaptured = false});
  @override
  State<ScanDetailScreen> createState() => _ScanDetailScreenState();
}

class _ScanDetailScreenState extends State<ScanDetailScreen> {
  ScanRecord get r => widget.record;
  PointCloud? full, display, mesh;
  bool showMesh = false;
  String? loadError;
  ColorMode mode = ColorMode.rgb;
  double pointSize = 2;
  _Tool tool = _Tool.look;
  final List<Vec3> picks = [];
  Vec3? roiCenter;
  double roiRadius = 0.15;
  bool robust = false;
  PlaneFit? fit;
  List<Vec3> cameraPath = [];
  Vec3? meanCamera;
  List<String>? verify;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      if (r.has('point_cloud_fused.ply')) {
        final b = await r.file('point_cloud_fused.ply').readAsBytes();
        final d = await compute(_parseDisplay, b);
        setState(() => display = d);
        final f = await compute(_parseFull, b);
        setState(() => full = f);
      }
      if (r.has('keyframes.jsonl')) {
        final path = <Vec3>[];
        for (final l in await r.file('keyframes.jsonl').readAsLines()) {
          if (!l.contains('"keyframe"')) continue;
          final m = jsonDecode(l) as Map<String, dynamic>;
          final t = (m['camera_to_world'] as List).cast<num>();
          path.add(Vec3(t[12].toDouble(), t[13].toDouble(), t[14].toDouble()));
        }
        setState(() {
          cameraPath = path;
          if (path.isNotEmpty) meanCamera = path.reduce((a, b) => a + b) * (1 / path.length);
        });
      }
    } catch (e) {
      setState(() => loadError = '$e');
    }
  }

  Future<void> _toggleMesh(bool v) async {
    if (v && mesh == null && r.has('mesh_arkit.ply')) {
      final b = await r.file('mesh_arkit.ply').readAsBytes();
      final m = await compute(_parseFull, b);
      setState(() => mesh = m);
    }
    setState(() {
      showMesh = v;
      mode = v ? ColorMode.shaded : ColorMode.rgb;
    });
  }

  void _onPick(Vec3 p) {
    setState(() {
      if (tool == _Tool.distance) {
        if (picks.length >= 2) picks.clear();
        picks.add(p);
      } else if (tool == _Tool.roi) {
        roiCenter = p;
        _refit();
      }
    });
  }

  void _refit() {
    if (roiCenter == null || full == null) return;
    final idx = pointsInSphere(full!.xyz, roiCenter!, roiRadius);
    fit = fitPlane(full!.xyz, idx, robust: robust, towards: meanCamera);
  }

  double get voxel {
    for (final o in (r.json['processing']?['operations'] as List? ?? const [])) {
      if (o is Map && o['op'] == 'voxel_fuse') {
        final v = (o['params'] as Map?)?['voxel_m'];
        if (v is num) return v.toDouble();
      }
    }
    return 0.01;
  }

  Future<String?> _askLabel(String suggestion) async {
    final c = TextEditingController(text: suggestion);
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Label this measurement'),
        content: TextField(controller: c, autofocus: true, decoration: const InputDecoration(helperText: 'Use the same label on repeat scans to compare them')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, c.text.trim()), child: const Text('Save')),
        ],
      ),
    );
  }

  Map<String, dynamic> _m(String label, String name, double value, String method, Map<String, dynamic> roi,
          {Map<String, dynamic> extra = const {}, List<String> validity = const []}) =>
      {
        'id': newId(),
        'label': label,
        'name': name,
        'value': value,
        'unit': name.contains('tilt') ? 'deg' : 'm',
        'status': 'measured',
        'method': method,
        'source_artifact': 'point_cloud_fused.ply',
        'frame': 'arkit_session_world',
        'roi': roi,
        'extra': extra,
        'uncertainty': {'method': 'none from a single scan; compare repeat scans with the same label', 'n': 1},
        'validity': [
          'partial view: only surfaces seen by the camera',
          'voxel size ${(voxel * 100).toStringAsFixed(1)} cm averages finer relief',
          ...validity,
        ],
        'created_utc': utcNow(),
      };

  Future<void> _saveDistance() async {
    if (picks.length < 2) return;
    final label = await _askLabel('distance ${r.measurements.length + 1}');
    if (label == null || label.isEmpty) return;
    final d = distance(picks[0], picks[1]);
    r.json['measurements'] = [
      ...r.measurements,
      _m(label, 'distance', d, 'straight-line distance between two picked fused points',
          {'kind': 'points', 'points': [picks[0].toList(), picks[1].toList()]},
          validity: ['picked points snap to the nearest displayed voxel; error includes picking error'])
    ];
    await r.save('added distance measurement');
    setState(() {});
  }

  Future<void> _saveRoi() async {
    final f = fit;
    if (f == null || roiCenter == null) return;
    final label = await _askLabel('ROI ${r.measurements.length + 1}');
    if (label == null || label.isEmpty) return;
    final roi = {'kind': 'sphere', 'center': roiCenter!.toList(), 'radius_m': roiRadius, 'n_points': f.nInput, 'n_used': f.nUsed};
    final method = 'total least squares plane (PCA) on fused points within radius_m of centre${robust ? '; robust: points beyond 3 RMS removed and refit (up to 3 passes)' : ''}';
    final tracking = (r.json['quality']?['tracking_limited_s'] as num?) ?? 0;
    r.json['measurements'] = [
      ...r.measurements,
      _m(label, 'plane_fit_roughness', f.rmsResidual, '$method; RMS of orthogonal residuals', roi,
          extra: {'residual_p95_m': f.p95AbsResidual, 'rejected_points': f.rejected, 'robust': robust}),
      _m(label, 'plane_tilt_from_horizontal', f.tiltFromHorizontalDeg, '$method; angle between plane and horizontal (ARKit gravity)', roi,
          validity: ['gravity from ARKit world alignment; tracking limited for ${tracking.toStringAsFixed(1)} s in this scan']),
      _m(label, 'protrusion_above_plane', f.maxAbove, '$method; largest residual toward the camera side', roi,
          extra: {'max_below_m': f.maxBelow}, validity: ['single extreme point: sensitive to outliers']),
    ];
    await r.save('added ROI plane-fit measurements');
    setState(() {});
  }

  Future<void> _saveExtents() async {
    if (full == null) return;
    final label = await _askLabel('whole scan');
    if (label == null || label.isEmpty) return;
    final idx = List<int>.generate(full!.length, (i) => i);
    final e = extents(full!.xyz, idx, trim: 0.01);
    const v = ['extent of observed points, not the size of a whole object', 'ends trimmed by 1% of points per axis'];
    final roi = {'kind': 'all_points', 'n_points': e.n, 'trim_fraction': 0.01};
    r.json['measurements'] = [
      ...r.measurements,
      _m(label, 'extent_vertical', e.vertical, 'range of Y (gravity up)', roi, validity: v),
      _m(label, 'extent_horizontal_major', e.horizontalMajor, 'range along the major horizontal principal axis', roi, validity: v),
      _m(label, 'extent_horizontal_minor', e.horizontalMinor, 'range along the minor horizontal principal axis', roi, validity: v),
    ];
    await r.save('added extents');
    setState(() {});
  }

  Future<void> _export() async {
    final tmp = await getTemporaryDirectory();
    final path = '${tmp.path}/scan-${r.id}.zip';
    final f = File(path);
    if (f.existsSync()) f.deleteSync();
    if (!mounted) return;
    showDialog(context: context, barrierDismissible: false, builder: (_) => const Center(child: CircularProgressIndicator()));
    try {
      await ZipFileEncoder().zipDirectory(r.dir, filename: path, level: 1);
    } finally {
      if (mounted) Navigator.of(context).pop();
    }
    if (!mounted) return;
    final box = context.findRenderObject() as RenderBox?;
    await SharePlus.instance.share(ShareParams(
      files: [XFile(path, mimeType: 'application/zip')],
      subject: 'Field Scan ${r.title}',
      sharePositionOrigin: box == null ? null : box.localToGlobal(Offset.zero) & box.size,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final cloud = showMesh ? mesh : display;
    final markers = <Marker>[
      for (int i = 0; i < picks.length; i++) Marker(picks[i], Fs.record, i == 0 ? 'A' : 'B'),
      if (roiCenter != null) Marker(roiCenter!, Fs.blue, 'ROI', radiusM: roiRadius),
    ];
    return Scaffold(
      appBar: subBar(context, r.title, actions: [
        RoundIconButton(icon: Icons.ios_share_rounded, tooltip: 'Export / AirDrop', onPressed: _export),
      ]),
      body: ListView(children: [
        if (r.synthetic)
          const Padding(
            padding: EdgeInsets.fromLTRB(Fs.side, 4, Fs.side, 8),
            child: Note(
              kind: TagKind.special,
              leading: Icon(Icons.science_outlined, color: Fs.purpleInk),
              child: Text('SYNTHETIC TEST FIXTURE — generated by the app, not a real scan.', style: TextStyle(fontWeight: FontWeight.w800)),
            ),
          ),
        if (r.status != 'complete')
          Padding(
            padding: const EdgeInsets.fromLTRB(Fs.side, 4, Fs.side, 8),
            child: Note(kind: TagKind.warn, child: Text('Incomplete scan: ${r.json['status_reason'] ?? ''}')),
          ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: Fs.side),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(24),
            child: AspectRatio(
              aspectRatio: 1,
              child: cloud == null
                  ? _noCloud(t)
                  : CloudViewer(cloud: cloud, mode: mode, pointSize: pointSize, markers: markers, cameraPath: cameraPath, onPick: _onPick),
            ),
          ),
        ),
        if (display != null) _viewerControls(t),
        if (display != null) _tools(t),
        _section(t, 'Measurements', _measurementList(t)),
        _section(t, 'Capture quality', _quality(t)),
        _section(t, 'Observation', _observation(t)),
        _section(t, 'Files and integrity', _files(t)),
        _section(t, 'Limitations', Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          for (final l in (r.json['limitations'] as List? ?? [])) Padding(padding: const EdgeInsets.only(bottom: 4), child: Text('• $l', style: t.textTheme.bodySmall)),
        ])),
        Padding(
          padding: const EdgeInsets.fromLTRB(Fs.side, 24, Fs.side, 8),
          child: Row(children: [
            Expanded(
              child: OutlinedButton.icon(
                icon: const Icon(Icons.public_rounded),
                label: const Text('Prepare contribution'),
                onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => ContributeScreen(record: r))).then((_) => setState(() {})),
              ),
            ),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(Fs.side, 0, Fs.side, 32),
          child: TextButton.icon(
            style: TextButton.styleFrom(foregroundColor: Fs.redInk),
            icon: const Icon(Icons.delete_outline_rounded),
            label: const Text('Delete scan from this phone'),
            onPressed: () async {
              final ok = await showDialog<bool>(
                context: context,
                builder: (c) => AlertDialog(
                  title: const Text('Delete this scan?'),
                  content: const Text('All raw keyframes, photos and derived files on this phone are removed. Exports you already sent are not affected.'),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
                    FilledButton(
                      style: FilledButton.styleFrom(backgroundColor: Fs.redInk, minimumSize: const Size(88, 44)),
                      onPressed: () => Navigator.pop(c, true),
                      child: const Text('Delete'),
                    ),
                  ],
                ),
              );
              if (ok == true) {
                await AppState.I.library.delete(r);
                await AppState.I.refresh();
                if (context.mounted) Navigator.of(context).pop();
              }
            },
          ),
        ),
      ]),
    );
  }

  Widget _noCloud(ThemeData t) {
    if (loadError != null) return Center(child: Text('Could not read the point cloud: $loadError'));
    if (r.has('point_cloud_fused.ply')) return const Center(child: CircularProgressIndicator());
    // camera-only scan: show keyframe images
    final dir = Directory('${r.dir.path}/keyframes');
    final imgs = dir.existsSync() ? (dir.listSync().whereType<File>().where((f) => f.path.endsWith('.jpg')).toList()..sort((a, b) => a.path.compareTo(b.path))) : <File>[];
    if (imgs.isEmpty) return const Center(child: Text('No point cloud and no keyframes in this scan.'));
    return Column(children: [
      Padding(
        padding: const EdgeInsets.all(8),
        child: Text('No depth on this device: ${imgs.length} keyframe photos with ARKit poses (usable for photogrammetry on the Mac).', style: t.textTheme.bodySmall),
      ),
      Expanded(
        child: GridView.count(crossAxisCount: 3, mainAxisSpacing: 2, crossAxisSpacing: 2, children: [
          for (final f in imgs.take(60)) Image.file(f, fit: BoxFit.cover, cacheWidth: 300),
        ]),
      ),
    ]);
  }

  Widget _viewerControls(ThemeData t) => Padding(
        padding: const EdgeInsets.fromLTRB(Fs.side, 12, Fs.side, 0),
        child: Wrap(spacing: 8, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
          SegmentedButton<String>(
            showSelectedIcon: false,
            segments: [
              const ButtonSegment(value: 'cloud', label: Text('Points')),
              if (r.has('mesh_arkit.ply')) const ButtonSegment(value: 'mesh', label: Text('ARKit mesh')),
            ],
            selected: {showMesh ? 'mesh' : 'cloud'},
            onSelectionChanged: (s) => _toggleMesh(s.first == 'mesh'),
          ),
          if (!showMesh)
            DropdownButton<ColorMode>(
              value: mode,
              underline: const SizedBox(),
              borderRadius: BorderRadius.circular(16),
              style: const TextStyle(fontFamily: Fs.body, fontSize: 14, fontWeight: FontWeight.w700, color: Fs.ink),
              items: const [
                DropdownMenuItem(value: ColorMode.rgb, child: Text('Colour')),
                DropdownMenuItem(value: ColorMode.height, child: Text('Height')),
                DropdownMenuItem(value: ColorMode.confidence, child: Text('Confidence')),
              ],
              onChanged: (m) => setState(() => mode = m!),
            ),
          IconButton(
            tooltip: 'Point size',
            icon: const Icon(Icons.grain_rounded),
            onPressed: () => setState(() => pointSize = pointSize >= 4 ? 1 : pointSize + 1),
          ),
          Text(
            '${display!.length} shown${full != null && full!.length != display!.length ? ' of ${full!.length}' : ''} · double-tap to recentre',
            style: t.textTheme.bodySmall,
          ),
        ]),
      );

  Widget _tools(ThemeData t) {
    final f = fit;
    return Padding(
      padding: const EdgeInsets.fromLTRB(Fs.side, 12, Fs.side, 0),
      child: FsCard(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(
            width: double.infinity,
            child: SegmentedButton<_Tool>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: _Tool.look, label: Text('Look')),
              ButtonSegment(value: _Tool.distance, label: Text('Distance')),
              ButtonSegment(value: _Tool.roi, label: Text('Surface')),
            ],
            selected: {tool},
            onSelectionChanged: (s) => setState(() {
              tool = s.first;
              picks.clear();
              roiCenter = null;
              fit = null;
            }),
          ),
          ),
          const SizedBox(height: 10),
          if (full == null && tool != _Tool.look) const Text('Loading the full-resolution cloud for measuring…'),
          if (tool == _Tool.look)
            Row(children: [
              Expanded(child: Text('Drag to orbit, pinch to zoom, two fingers to pan.', style: t.textTheme.bodySmall)),
              TextButton(onPressed: full == null ? null : _saveExtents, child: const Text('Save extents')),
            ]),
          if (tool == _Tool.distance) ...[
            Text(picks.length < 2 ? 'Tap two points (A, then B). Use a ruler or object of known size to check scale.' : '', style: t.textTheme.bodySmall),
            if (picks.length == 2)
              Row(children: [
                Text('${(distance(picks[0], picks[1]) * 100).toStringAsFixed(1)} cm', style: t.textTheme.headlineSmall),
                const SizedBox(width: 8),
                Text('between picked points', style: t.textTheme.bodySmall),
                const Spacer(),
                FilledButton(style: FilledButton.styleFrom(minimumSize: const Size(88, 44)), onPressed: _saveDistance, child: const Text('Save')),
              ]),
          ],
          if (tool == _Tool.roi) ...[
            Text('Tap the surface to centre a sphere; a plane is fitted to the points inside it.', style: t.textTheme.bodySmall),
            Row(children: [
              const Text('Radius'),
              Expanded(
                child: Slider(
                  value: roiRadius,
                  min: 0.03,
                  max: 1.0,
                  divisions: 97,
                  label: '${(roiRadius * 100).round()} cm',
                  onChanged: (v) => setState(() {
                    roiRadius = v;
                    _refit();
                  }),
                ),
              ),
              Text('${(roiRadius * 100).round()} cm'),
            ]),
            SwitchListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: const Text('Robust fit (drop points beyond 3× RMS)'),
              value: robust,
              onChanged: (v) => setState(() {
                robust = v;
                _refit();
              }),
            ),
            if (roiCenter != null && f == null) const Text('Too few points in this sphere (need 10). Make it bigger.'),
            if (f != null) ...[
              _kv('Roughness (RMS of plane residuals)', '${(f.rmsResidual * 1000).toStringAsFixed(1)} mm'),
              _kv('95th percentile |residual|', '${(f.p95AbsResidual * 1000).toStringAsFixed(1)} mm'),
              _kv('Tilt from horizontal (ARKit gravity)', '${f.tiltFromHorizontalDeg.toStringAsFixed(1)}°'),
              _kv('Highest point above plane (camera side)', '${(f.maxAbove * 100).toStringAsFixed(1)} cm'),
              _kv('In-plane extent of points', '${(f.majorExtent * 100).toStringAsFixed(0)} × ${(f.minorExtent * 100).toStringAsFixed(0)} cm'),
              _kv('Points used', '${f.nUsed}${f.rejected > 0 ? ' (${f.rejected} dropped)' : ''}'),
              const SizedBox(height: 6),
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton(style: FilledButton.styleFrom(minimumSize: const Size(88, 44)), onPressed: _saveRoi, child: const Text('Save')),
              ),
            ],
          ],
        ]),
      ),
    );
  }

  Widget _kv(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(child: Text(k, style: const TextStyle(fontSize: 14, color: Fs.ink2))),
          const SizedBox(width: 12),
          Text(v, style: const TextStyle(fontSize: 14, fontFeatures: [FontFeature.tabularFigures()], fontWeight: FontWeight.w800)),
        ]),
      );

  Widget _section(ThemeData t, String title, Widget child) => Padding(
        padding: const EdgeInsets.fromLTRB(Fs.side, 24, Fs.side, 0),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: t.textTheme.titleMedium),
          const SizedBox(height: 8),
          FsCard(child: child),
        ]),
      );

  String _fmtVal(Map<String, dynamic> m) {
    final v = (m['value'] as num?)?.toDouble();
    if (v == null) return m['status'] ?? '–';
    if (m['unit'] == 'deg') return '${v.toStringAsFixed(1)}°';
    if (m['name'] == 'plane_fit_roughness') return '${(v * 1000).toStringAsFixed(1)} mm';
    return v < 1 ? '${(v * 100).toStringAsFixed(1)} cm' : '${v.toStringAsFixed(2)} m';
  }

  Widget _measurementList(ThemeData t) {
    final ms = r.measurements;
    if (ms.isEmpty) {
      return Text(r.has('point_cloud_fused.ply') ? 'None yet. Use Distance or Surface above.' : 'Needs a depth scan.', style: t.textTheme.bodySmall);
    }
    return Column(children: [
      for (final m in ms)
        ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: Text('${m['label']} · ${'${m['name']}'.replaceAll('_', ' ')}'),
          subtitle: Text('${m['method']}', maxLines: 2, overflow: TextOverflow.ellipsis),
          trailing: Text(_fmtVal(m), style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800)),
          onLongPress: () async {
            r.json['measurements'] = ms.where((x) => x['id'] != m['id']).toList();
            await r.save('removed measurement ${m['id']}');
            setState(() {});
          },
        ),
      Text('Long-press a measurement to remove it. Compare repeat scans from the Library.', style: t.textTheme.bodySmall),
    ]);
  }

  Widget _quality(ThemeData t) {
    final q = r.json['quality'] as Map? ?? {};
    final d = q['depth'] as Map?;
    final cf = d?['confidence_fractions'] as Map?;
    String pct(dynamic v) => v == null ? '–' : '${((v as num) * 100).toStringAsFixed(0)}%';
    final cap = r.json['capture'] as Map? ?? {};
    return Column(children: [
      _kv('Device', '${r.json['device']?['model'] ?? '–'} · iOS ${r.json['device']?['os_version'] ?? '–'}'),
      _kv('Keyframes / full-res photos', '${q['keyframes'] ?? 0} / ${q['photos'] ?? 0}'),
      _kv('Trigger', '${cap['trigger']?['mode'] ?? '–'}${cap['rig_mode'] == true ? ' (rig)' : ''}'),
      if (d != null) _kv('Valid depth pixels', pct(d['valid_fraction'])),
      if (cf != null) _kv('ARKit confidence low / med / high', '${pct(cf['low'])} / ${pct(cf['medium'])} / ${pct(cf['high'])}'),
      if (q['fused_points'] != null) _kv('Fused points (${(voxel * 100).toStringAsFixed(0)} cm voxels)', '${q['fused_points']}${q['fusion_capped'] == true ? ' (cap reached)' : ''}'),
      if (q['mesh_faces'] != null) _kv('ARKit mesh', '${q['mesh_vertices']} vertices, ${q['mesh_faces']} faces'),
      _kv('Tracking limited', '${((q['tracking_limited_s'] as num?) ?? 0).toStringAsFixed(1)} s in ${q['tracking_limited_episodes'] ?? 0} episodes'),
      _kv('Camera path', '${((q['camera_path_length_m'] as num?) ?? 0).toStringAsFixed(2)} m'),
      _kv('Keyframes with blur risk', '${q['keyframes_with_blur_risk'] ?? 0} (heuristic)'),
      _kv('Interruptions', '${q['interruptions'] ?? 0}'),
      const SizedBox(height: 4),
      Text('Counts and fractions only. ARKit confidence is an ordinal API level, not a probability; no accuracy percentage is claimed.',
          style: t.textTheme.bodySmall),
    ]);
  }

  Widget _observation(ThemeData t) {
    final o = r.json['observation'] as Map? ?? {};
    final claims = (o['claims'] as List? ?? []);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _kv('Feature (your label)', featureTypes[o['feature_type']] ?? '${o['feature_type']}'),
      if (r.json['field_site_id'] != null) _kv('Field site', '${r.json['field_site_id']}'),
      if (r.json['candidate_id'] != null) _kv('Website candidate', '${r.json['candidate_id']}'),
      _kv('Location', r.json['location']?['collected'] == true ? 'saved privately (±${((r.json['location']?['uncertainty_m'] as num?) ?? 0).round()} m)' : 'not collected'),
      const SizedBox(height: 6),
      Text((o['notes'] ?? '').toString().isEmpty ? 'No notes.' : '${o['notes']}'),
      for (final c in claims) Text('• [${c['kind']}] ${c['text']}', style: t.textTheme.bodySmall),
      TextButton.icon(
        style: TextButton.styleFrom(padding: EdgeInsets.zero),
        onPressed: _editNotes,
        icon: const Icon(Icons.edit_note_rounded),
        label: const Text('Edit notes / add observation'),
      ),
    ]);
  }

  Future<void> _editNotes() async {
    final o = Map<String, dynamic>.from(r.json['observation'] as Map? ?? {});
    final notes = TextEditingController(text: '${o['notes'] ?? ''}');
    final claim = TextEditingController();
    String kind = 'observed';
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, set) => AlertDialog(
          title: const Text('Notes and observations'),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(controller: notes, maxLines: 4, decoration: const InputDecoration(labelText: 'Field notes')),
              const SizedBox(height: 12),
              TextField(controller: claim, decoration: const InputDecoration(labelText: 'Add an observation (optional)', hintText: 'e.g. layered grey-black shale at base')),
              const SizedBox(height: 8),
              SegmentedButton<String>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: 'observed', label: Text('Seen')),
                  ButtonSegment(value: 'interpreted', label: Text('Interpreted')),
                  ButtonSegment(value: 'user_reported', label: Text('Told / read')),
                ],
                selected: {kind},
                onSelectionChanged: (s) => set(() => kind = s.first),
              ),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Save')),
          ],
        ),
      ),
    );
    if (ok != true) return;
    o['notes'] = notes.text.trim();
    if (claim.text.trim().isNotEmpty) {
      o['claims'] = [
        ...(o['claims'] as List? ?? []),
        {'text': claim.text.trim(), 'kind': kind, 'source': 'user', 'utc': utcNow()}
      ];
    }
    r.json['observation'] = o;
    await r.save('edited notes');
    setState(() {});
  }

  Widget _files(ThemeData t) {
    final files = (r.json['files'] as List? ?? []);
    int total = 0;
    final byRole = <String, int>{};
    for (final f in files) {
      total += (f['bytes'] as num? ?? 0).toInt();
      byRole['${f['role']}'] = (byRole['${f['role']}'] ?? 0) + 1;
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _kv('Files', '${files.length} · ${(total / 1e6).toStringAsFixed(1)} MB'),
      for (final e in byRole.entries) Text('${e.key.replaceAll('_', ' ')}: ${e.value}', style: t.textTheme.bodySmall),
      const SizedBox(height: 6),
      Row(children: [
        OutlinedButton(
          style: OutlinedButton.styleFrom(minimumSize: const Size(0, 44)),
          onPressed: () async {
            setState(() => verify = null);
            final p = await verifyFiles(r);
            setState(() => verify = p);
          },
          child: const Text('Verify SHA-256'),
        ),
        const SizedBox(width: 12),
        if (verify != null)
          Expanded(
            child: Text(verify!.isEmpty ? 'All ${files.length} files match their hashes.' : verify!.take(3).join('; '),
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: verify!.isEmpty ? Fs.mossInk : Fs.redInk)),
          ),
      ]),
      const SizedBox(height: 4),
      Text('Export sends the whole private folder (including any saved location) as a zip: AirDrop it to the Field Station Mac or save it to Files. '
          'scan.json lists every file with its SHA-256.', style: t.textTheme.bodySmall),
      Text('Scan ID ${r.id}', style: t.textTheme.bodySmall?.copyWith(fontFamily: 'Menlo')),
    ]);
  }
}

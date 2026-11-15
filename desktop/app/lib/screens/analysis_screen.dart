import 'package:flutter/material.dart';

import '../service/app_state.dart';
import '../service/models.dart';
import '../widgets/common.dart';
import '../widgets/honesty_banner.dart';
import '../widgets/measurement_table.dart';
import '../widgets/scan_picker.dart';

enum PickMode { roughness, protrusionObject, protrusionReference, distance }

class AnalysisScreen extends StatefulWidget {
  const AnalysisScreen({super.key});
  @override
  State<AnalysisScreen> createState() => _AnalysisScreenState();
}

class _AnalysisScreenState extends State<AnalysisScreen> {
  String? _loadedFor;
  int _loadedVersion = -1;
  Map<String, dynamic> _detail = {};
  bool _loading = false;
  String? _error;

  PickMode _mode = PickMode.roughness;
  List<double>? _rect; // depth px [u0,v0,u1,v1]
  List<double>? _objRect;
  List<double>? _refRect;
  final List<Offset> _pts = []; // depth px
  Offset? _dragStart;
  Offset? _dragNow;
  bool _robust = false;
  bool _busy = false;
  String? _msg;
  List<Measurement> _last = [];
  final _label = TextEditingController();
  Map<String, dynamic>? _repeat;

  @override
  void dispose() {
    _label.dispose();
    super.dispose();
  }

  Future<void> _load(String id, AppState s) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    _loadedFor = id;
    _loadedVersion = s.scansVersion;
    try {
      _detail = asMap(await s.api!.getJson('/api/scans/$id'));
    } catch (e) {
      _error = errText(e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _run(AppState s, String id, Map<String, dynamic> body) async {
    setState(() {
      _busy = true;
      _msg = null;
    });
    try {
      final label = _label.text.trim();
      final r = asMap(await s.api!.postJson('/api/scans/$id/analyze', {...body, if (label.isNotEmpty) 'label': label}));
      if (r['saved'] == false) {
        _msg = 'Not measured: ${r['reason'] ?? r['status']}';
        _last = [];
      } else {
        _last = Measurement.listFrom(r['measurements']);
      }
      s.bumpScans();
      await _load(id, s);
    } catch (e) {
      _msg = errText(e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<List<double>?> _depthPoint(AppState s, String id, Offset p) async {
    final r = asMap(await s.api!.getJson('/api/scans/$id/depth_point', query: {'u': p.dx.toStringAsFixed(1), 'v': p.dy.toStringAsFixed(1)}));
    if (r['valid'] != true) return null;
    return asList(r['point_m']).map((e) => asDouble(e)!).toList();
  }

  Future<void> _distance(AppState s, String id) async {
    if (_pts.length < 2) return;
    setState(() => _busy = true);
    try {
      final p1 = await _depthPoint(s, id, _pts[0]);
      final p2 = await _depthPoint(s, id, _pts[1]);
      if (p1 == null || p2 == null) {
        setState(() => _msg = 'No valid depth at one of the picked pixels; pick on a surface with depth (not black in the depth view).');
        return;
      }
      await _run(s, id, {
        'kind': 'distance',
        'p1': p1,
        'p2': p2,
        'source_artifact': 'depth_filtered.png',
        'note': 'each end = median of filtered depth in a 5x5 pixel window',
      });
    } catch (e) {
      setState(() => _msg = errText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Map<String, dynamic> _rectRoi(List<double> r) => {'kind': 'pixel_rect', 'rect_px': r.map((e) => e.round()).toList()};

  Future<void> _repeatability(AppState s) async {
    final roi = _rect != null ? _rectRoi(_rect!) : s.pendingRoi;
    if (roi == null || s.repeatSelection.length < 2) return;
    setState(() => _busy = true);
    try {
      _repeat = asMap(await s.api!.postJson('/api/repeatability', {'scan_ids': s.repeatSelection.toList(), 'roi': roi, 'robust': _robust}));
    } catch (e) {
      _msg = errText(e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    final id = s.selectedScanId;
    if (id != null && (_loadedFor != id || _loadedVersion != s.scansVersion) && !_loading) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && (_loadedFor != id || _loadedVersion != s.scansVersion)) {
          if (_loadedFor != id) {
            _rect = _objRect = _refRect = null;
            _pts.clear();
            _last = [];
            _msg = null;
          }
          _load(id, s);
        }
      });
    }
    final man = asMap(_detail['manifest']);
    return DefaultTabController(
      length: 5,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
          child: Row(children: [
            ScanPicker(selected: id, onChanged: s.selectScan),
            const SizedBox(width: 12),
            if (man.isNotEmpty) OriginChip(man['origin'] as String?),
            const Spacer(),
          ]),
        ),
        if (man.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: HonestyBanner(origin: man['origin'] as String?, isRealSensor: man['is_real_sensor'] as bool?, compact: true),
          ),
        const TabBar(isScrollable: true, tabAlignment: TabAlignment.start, tabs: [
          Tab(text: 'Measure'),
          Tab(text: 'All measurements'),
          Tab(text: 'Capture quality'),
          Tab(text: 'Repeatability'),
          Tab(text: 'Methodology'),
        ]),
        Expanded(
          child: id == null
              ? const EmptyState(icon: Icons.straighten, title: 'Choose a scan', body: 'Pick a saved scan above.')
              : _error != null
                  ? Padding(padding: const EdgeInsets.all(24), child: ErrorBox(_error!))
                  : TabBarView(children: [
                      _measureTab(s, id),
                      _allTab(),
                      _qualityTab(),
                      _repeatTab(s),
                      const _Methodology(),
                    ]),
        ),
      ]),
    );
  }

  // ------------------------------------------------------------------ Measure
  Widget _measureTab(AppState s, String id) {
    final t = Theme.of(context);
    final di = asMap(_detail['depth_image']);
    if (_detail.isEmpty) return const Center(child: CircularProgressIndicator());
    if (di.isEmpty) {
      return EmptyState(
        icon: Icons.view_in_ar_outlined,
        title: 'No organised depth image in this scan',
        body: 'Imported point clouds (e.g. iPhone ARKit) are measured with a sphere ROI in the Viewer.',
        action: FilledButton(onPressed: () => s.go(Section.viewer), child: const Text('Open Viewer')),
      );
    }
    final w = (asInt(di['width']) ?? 848).toDouble();
    final h = (asInt(di['height']) ?? 480).toDouble();
    final files = asList(asMap(_detail['manifest'])['files']).map(asMap).map((f) => f['path']).toSet();
    final colorPath = files.contains('frames/color_00000.png') ? 'frames/color_00000.png' : 'thumbnail.jpg';
    return LayoutBuilder(builder: (context, box) {
      return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 16, 12, 16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Wrap(spacing: 8, runSpacing: 8, children: [
                for (final m in PickMode.values)
                  ChoiceChip(
                    label: Text(switch (m) {
                      PickMode.roughness => 'Roughness region',
                      PickMode.protrusionObject => 'Protrusion: object',
                      PickMode.protrusionReference => 'Protrusion: reference',
                      PickMode.distance => 'Distance: 2 points',
                    }),
                    selected: _mode == m,
                    onSelected: (_) => setState(() => _mode = m),
                  ),
              ]),
              const SizedBox(height: 8),
              Text(
                _mode == PickMode.distance ? 'Click two points on surfaces with depth.' : 'Drag a rectangle on the image.',
                style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: 8),
              Expanded(
                child: Align(
                  alignment: Alignment.topCenter,
                  child: AspectRatio(
                    aspectRatio: w / h,
                    child: LayoutBuilder(builder: (context, b) {
                      final sc = b.maxWidth / w;
                      Offset toDepth(Offset p) => Offset((p.dx / sc).clamp(0, w - 1), (p.dy / sc).clamp(0, h - 1));
                      return GestureDetector(
                        onPanStart: _mode == PickMode.distance ? null : (d) => setState(() => _dragStart = _dragNow = toDepth(d.localPosition)),
                        onPanUpdate: _mode == PickMode.distance ? null : (d) => setState(() => _dragNow = toDepth(d.localPosition)),
                        onPanEnd: _mode == PickMode.distance
                            ? null
                            : (_) {
                                final a = _dragStart, b2 = _dragNow;
                                if (a != null && b2 != null && (a - b2).distance > 4) {
                                  final r = [
                                    a.dx < b2.dx ? a.dx : b2.dx,
                                    a.dy < b2.dy ? a.dy : b2.dy,
                                    a.dx < b2.dx ? b2.dx : a.dx,
                                    a.dy < b2.dy ? b2.dy : a.dy,
                                  ];
                                  setState(() {
                                    if (_mode == PickMode.roughness) _rect = r;
                                    if (_mode == PickMode.protrusionObject) _objRect = r;
                                    if (_mode == PickMode.protrusionReference) _refRect = r;
                                  });
                                }
                                setState(() => _dragStart = _dragNow = null);
                              },
                        onTapUp: _mode != PickMode.distance
                            ? null
                            : (d) => setState(() {
                                  if (_pts.length >= 2) _pts.clear();
                                  _pts.add(toDepth(d.localPosition));
                                }),
                        child: Stack(fit: StackFit.expand, children: [
                          Image.network(s.api!.url('/api/scans/$id/file/$colorPath').toString(), fit: BoxFit.fill,
                              errorBuilder: (_, e, _) => const Center(child: Text('No colour frame'))),
                          CustomPaint(
                            painter: _OverlayPainter(
                              scale: sc,
                              rect: _rect,
                              obj: _objRect,
                              ref: _refRect,
                              pts: _pts,
                              drag: _dragStart != null && _dragNow != null ? Rect.fromPoints(_dragStart!, _dragNow!) : null,
                              accent: t.colorScheme.primary,
                              warn: warnColor(context),
                            ),
                          ),
                        ]),
                      );
                    }),
                  ),
                ),
              ),
              const SizedBox(height: 6),
              Text('Colour frame ($colorPath) shown on the depth grid: approximate registration for picking. Measurements use the filtered depth image.',
                  style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
            ]),
          ),
        ),
        SizedBox(width: 380, child: _measurePanel(s, id, t)),
      ]);
    });
  }

  Widget _measurePanel(AppState s, String id, ThemeData t) {
    String rectText(List<double>? r) =>
        r == null ? 'not set' : 'u ${r[0].round()}–${r[2].round()}, v ${r[1].round()}–${r[3].round()} px';
    return ListView(padding: const EdgeInsets.fromLTRB(0, 16, 24, 24), children: [
      SectionCard(
        title: 'Measure',
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          TextField(controller: _label, decoration: const InputDecoration(labelText: 'Label (e.g. boulder A, upper face)')),
          const SizedBox(height: 12),
          Text('Roughness region: ${rectText(_rect)}', style: t.textTheme.bodySmall),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            value: _robust,
            onChanged: (v) => setState(() => _robust = v ?? false),
            title: const Text('Robust fit (reject points > 3 MAD)'),
          ),
          FilledButton(
            onPressed: _rect == null || _busy ? null : () => _run(s, id, {'kind': 'roughness', 'roi': _rectRoi(_rect!), 'robust': _robust}),
            child: const Text('Roughness, tilt and extent'),
          ),
          const Divider(height: 28),
          Text('Object: ${rectText(_objRect)}\nReference surface: ${rectText(_refRect)}', style: t.textTheme.bodySmall),
          const SizedBox(height: 8),
          OutlinedButton(
            onPressed: _objRect == null || _refRect == null || _busy
                ? null
                : () => _run(s, id, {'kind': 'protrusion', 'roi': _rectRoi(_objRect!), 'reference_roi': _rectRoi(_refRect!)}),
            child: const Text('Protrusion above reference'),
          ),
          const Divider(height: 28),
          Text(
              'Distance points: ${_pts.isEmpty ? 'none' : _pts.map((p) => '(${p.dx.round()}, ${p.dy.round()})').join(' → ')}',
              style: t.textTheme.bodySmall),
          const SizedBox(height: 8),
          OutlinedButton(onPressed: _pts.length < 2 || _busy ? null : () => _distance(s, id), child: const Text('Distance between points')),
          if (_busy) const Padding(padding: EdgeInsets.only(top: 12), child: LinearProgressIndicator()),
        ]),
      ),
      if (_msg != null) ...[const SizedBox(height: 12), ErrorBox(_msg!)],
      if (_last.isNotEmpty) ...[
        const SizedBox(height: 16),
        SectionCard(title: 'Latest result (saved)', child: MeasurementTable(measurements: _last)),
      ],
    ]);
  }

  // ------------------------------------------------------------------ other tabs
  Widget _allTab() {
    final man = asMap(_detail['manifest']);
    final metrics = asMap(_detail['metrics']);
    final def = Measurement.listFrom(asMap(metrics['default_analysis'])['measurements']);
    final defIds = def.map((m) => m.id).toSet();
    final all = Measurement.listFrom(man['measurements']).where((m) => !defIds.contains(m.id)).toList();
    return ListView(padding: const EdgeInsets.all(24), children: [
      SectionCard(
        title: 'Default analysis · ${asStr(asMap(asMap(metrics['default_analysis'])['roi'])['label'], 'central region')}',
        child: MeasurementTable(measurements: def, emptyText: 'No default analysis (imported scan or not processed).'),
      ),
      const SizedBox(height: 16),
      SectionCard(title: 'Your measurements (${all.length})', child: MeasurementTable(measurements: all.reversed.toList())),
    ]);
  }

  Widget _qualityTab() {
    final q = asMap(asMap(_detail['metrics'])['capture_quality']);
    final man = asMap(_detail['manifest']);
    final mq = q.isEmpty ? asMap(man['quality']) : q;
    final t = Theme.of(context);
    if (mq.isEmpty) return const EmptyState(icon: Icons.analytics_outlined, title: 'No capture-quality record for this scan');
    final rp = asMap(mq['range_m_percentiles']);
    return ListView(padding: const EdgeInsets.all(24), children: [
      SectionCard(
        title: 'Capture quality (measured counts only)',
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (mq['frames'] != null) KV('Frames', '${mq['frames']}'),
          if (mq['pixels_per_frame'] != null) KV('Pixels per frame', '${mq['pixels_per_frame']}'),
          if (mq['depth_valid_fraction_mean'] != null) KV('Valid depth (mean of frames)', pct(mq['depth_valid_fraction_mean'])),
          if (mq['pixels_valid_in_all_frames'] != null) KV('Valid in every frame', pct(mq['pixels_valid_in_all_frames'])),
          if (mq['filtered_valid_fraction'] != null) KV('Valid after filtering', pct(mq['filtered_valid_fraction'])),
          if (rp.isNotEmpty) KV('Range p5 / p25 / p50 / p75 / p95', ['5', '25', '50', '75', '95'].map((k) => metres(rp[k])).join(' / ')),
          if (mq['temporal_std_median_m'] != null)
            KV('Frame-to-frame noise (median per-pixel std)', formatMetres(asDouble(mq['temporal_std_median_m'])!)),
          if (mq['raw_point_cloud_points'] != null) KV('Raw cloud points', '${mq['raw_point_cloud_points']}'),
          if (mq['filtered_point_cloud_points'] != null) KV('Filtered cloud points', '${mq['filtered_point_cloud_points']}'),
          if (mq['frames_skipped_between_recorded'] != null) KV('Sensor frames skipped while recording', '${mq['frames_skipped_between_recorded']}'),
          for (final e in mq.entries.where((e) => !_knownQ.contains(e.key) && e.value is! Map && e.value is! List))
            KV(prettyName(e.key), '${e.value}'),
          const SizedBox(height: 8),
          if (mq['temporal_std_note'] != null)
            Text('${mq['temporal_std_note']}', style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
        ]),
      ),
      const SizedBox(height: 16),
      SectionCard(
        title: 'Processing applied (raw files are untouched)',
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          for (final op in asList(asMap(man['processing'])['operations']).map(asMap))
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Text('• ${asStr(op['op'])}: ${op.entries.where((e) => e.key != 'op').map((e) => '${e.key} ${e.value}').join(', ')}',
                  style: t.textTheme.bodySmall),
            ),
        ]),
      ),
    ]);
  }

  static const _knownQ = {
    'frames', 'pixels_per_frame', 'depth_valid_fraction_mean', 'pixels_valid_in_all_frames', 'filtered_valid_fraction',
    'temporal_std_median_m', 'raw_point_cloud_points', 'filtered_point_cloud_points', 'frames_skipped_between_recorded',
    'temporal_std_note', 'filtered_points',
  };

  Widget _repeatTab(AppState s) {
    final t = Theme.of(context);
    final roi = _rect != null ? _rectRoi(_rect!) : s.pendingRoi;
    final rows = asList(_repeat?['rows']).map(asMap).toList();
    final summary = asMap(_repeat?['summary']);
    return ListView(padding: const EdgeInsets.all(24), children: [
      SectionCard(
        title: 'Repeatability across repeated captures',
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(
            'Select 2 or more scans of the same stationary target in Library (tick "repeatability"). The same region is applied to each scan.',
            style: t.textTheme.bodyMedium,
          ),
          const SizedBox(height: 8),
          KV('Selected scans', s.repeatSelection.isEmpty ? 'none' : s.repeatSelection.map(shortId).join(', ')),
          KV('Region', roi == null ? 'draw a roughness region in Measure (or a sphere in Viewer)' : '${roi['kind']} ${roi['rect_px'] ?? 'r = ${roi['radius_m']} m'}'),
          const SizedBox(height: 8),
          Row(children: [
            FilledButton(
              onPressed: roi == null || s.repeatSelection.length < 2 || _busy ? null : () => _repeatability(s),
              child: const Text('Compare'),
            ),
            const SizedBox(width: 8),
            TextButton(onPressed: () => s.go(Section.library), child: const Text('Select scans in Library')),
          ]),
        ]),
      ),
      if (_repeat != null) ...[
        const SizedBox(height: 16),
        SectionCard(
          title: 'Per scan',
          child: Column(children: [
            for (final r in rows)
              KV(shortId(r['scan_id'] as String?),
                  r['error'] != null
                      ? 'error: ${r['error']}'
                      : 'RMS ${formatMetres(asDouble(r['rms_orthogonal_m'])!)} · range ${metres(r['median_range_m'])} · extent ${formatMetres(asDouble(r['extent_major_m'])!)} · ${r['n_points']} points'),
          ]),
        ),
        const SizedBox(height: 16),
        SectionCard(
          title: 'Spread',
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            for (final e in summary.entries)
              KV(prettyName(e.key), () {
                final m = asMap(e.value);
                if (m['status'] != 'measured') return 'not measured: ${m['reason']}';
                final isM = e.key.endsWith('_m');
                String f(Object? v) => isM ? formatMetres(asDouble(v)!) : '${asDouble(v)?.toStringAsFixed(1)}';
                return 'n ${m['n']} · mean ${f(m['mean'])} · std ${f(m['std'])} · range ${f(m['range'])}';
              }()),
            const SizedBox(height: 8),
            Text(asStr(_repeat?['note']), style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
          ]),
        ),
      ],
    ]);
  }
}

class _OverlayPainter extends CustomPainter {
  _OverlayPainter({required this.scale, this.rect, this.obj, this.ref, required this.pts, this.drag, required this.accent, required this.warn});
  final double scale;
  final List<double>? rect, obj, ref;
  final List<Offset> pts;
  final Rect? drag;
  final Color accent, warn;

  @override
  void paint(Canvas canvas, Size size) {
    void box(List<double>? r, Color c, String label) {
      if (r == null) return;
      final rr = Rect.fromLTRB(r[0] * scale, r[1] * scale, r[2] * scale, r[3] * scale);
      canvas.drawRect(rr, Paint()..color = c.withValues(alpha: 0.12));
      canvas.drawRect(rr, Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = c);
      final tp = TextPainter(
          text: TextSpan(text: label, style: TextStyle(color: Colors.white, fontSize: 11, backgroundColor: c)),
          textDirection: TextDirection.ltr)
        ..layout();
      tp.paint(canvas, rr.topLeft + const Offset(2, 2));
    }

    box(rect, accent, ' roughness ');
    box(obj, warn, ' object ');
    box(ref, Colors.blueGrey, ' reference ');
    if (drag != null) {
      final d = Rect.fromLTRB(drag!.left * scale, drag!.top * scale, drag!.right * scale, drag!.bottom * scale);
      canvas.drawRect(d, Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = Colors.white);
    }
    for (int i = 0; i < pts.length; i++) {
      final p = pts[i] * scale;
      canvas.drawCircle(p, 5, Paint()..color = accent);
      canvas.drawCircle(p, 5, Paint()
        ..style = PaintingStyle.stroke
        ..color = Colors.white);
      if (i == 1) {
        canvas.drawLine(pts[0] * scale, p, Paint()
          ..color = accent
          ..strokeWidth = 2);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _OverlayPainter o) => true;
}

class _Methodology extends StatelessWidget {
  const _Methodology();

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    Widget p(String head, String body) => Padding(
          padding: const EdgeInsets.only(bottom: 14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(head, style: t.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            Text(body, style: t.textTheme.bodyMedium),
          ]),
        );
    return ListView(padding: const EdgeInsets.fromLTRB(24, 24, 24, 40), children: [
      ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 820),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          p('What is measured',
              'Points come from the D435\'s calibrated depth: Z = raw × depth scale, X = (u − cx)·Z/fx, Y = (v − cy)·Z/fy, in the camera optical frame (metres, +X right, +Y down, +Z forward). Filtered depth is the per-pixel median of all recorded frames, clipped to a range and with depth-edge ("flying") pixels removed. Raw frames are stored unchanged.'),
          p('Plane-fit roughness',
              'A total-least-squares plane is fitted to the points in the region (SVD/PCA). Roughness is the RMS of orthogonal distances to that plane, in metres. With "robust", points beyond 3 MAD are rejected and refitted; the number rejected is recorded.'),
          p('Baseline dependence',
              'Roughness grows with region size. The region\'s in-plane extent (baseline) is stored with every value; compare only at similar baselines. These centimetre-to-metre values are NOT comparable with the 400–3200 m terrain descriptors used for planetary analog discovery on the website.'),
          p('Tilt is relative to the camera',
              'The D435 has no IMU and no levelling reference was recorded, so plane orientation is reported as the angle to the camera optical axis, not slope relative to horizontal. Gravity-referenced slope is marked "not measured". (iPhone ARKit scans carry a gravity-aligned frame, so their tilt from horizontal can be measured.)'),
          p('Sensor noise floor',
              'Intel\'s published D400 model gives an expected RMS depth noise of Z² × 0.08 / (fx × baseline) at range Z (typical subpixel value; not measured for this unit). When residual RMS is under twice that value, the result is flagged "at noise floor": surface roughness is not resolved at that range.'),
          p('Precision, not accuracy',
              'The per-frame spread (same region on each raw frame) and repeat-capture spread (same region across repeated scans) describe repeatability under these conditions. They are not ground-truth accuracy. Check dimensions against a ruler or known object for accuracy.'),
          p('Protrusion',
              'A robust plane is fitted to a user-chosen reference surface; object heights are distances above it toward the sensor. Only the visible side is measured. Any rover-clearance comparison is a team-defined illustration, not a NASA flight-qualified limit.'),
          p('What this does not do',
              'Nothing here identifies rock type, mineralogy or chemistry, and nothing scores planetary analog suitability. Hidden surfaces are never filled in. Planetary analog discovery and characterisation live on the website.'),
        ]),
      ),
    ]);
  }
}

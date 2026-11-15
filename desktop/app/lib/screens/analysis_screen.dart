// Draft written with AI assistance (Claude, Anthropic); disclosed per the Space Apps AI policy.

import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../service/app_state.dart';
import '../service/models.dart';
import '../widgets/common.dart';
import '../widgets/figure.dart';
import '../widgets/honesty_banner.dart';
import '../widgets/measurement_table.dart';
import '../widgets/scan_picker.dart';

enum Tool { roughness, protrusion, distance }

enum ProtrusionPart { object, reference }

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

  // Figure images, cached per scan.
  String? _imagesFor;
  Uint8List? _depthPng;
  double? _rangeLo, _rangeHi, _validFrac;
  String? _depthError;
  Uint8List? _colorImg;
  String? _colorError;
  bool _showColor = false;

  Tool _tool = Tool.roughness;
  ProtrusionPart _part = ProtrusionPart.object;
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
      if (_imagesFor != id) {
        _imagesFor = id;
        _depthPng = _colorImg = null;
        _depthError = _colorError = null;
        _rangeLo = _rangeHi = _validFrac = null; // never show the previous scan's range while this one loads or fails
        if (asMap(_detail['depth_image']).isNotEmpty) await _loadDepthFigure(s, id);
        if (_showColor && _hasColorFrame()) await _loadColor(s, id);
      }
    } catch (e) {
      _error = errText(e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _loadDepthFigure(AppState s, String id) async {
    try {
      final r = await s.api!.getBytes('/api/scans/$id/depth_figure.png');
      _depthPng = r.bytes;
      _rangeLo = double.tryParse(r.headers['x-range-lo-m'] ?? '');
      _rangeHi = double.tryParse(r.headers['x-range-hi-m'] ?? '');
      _validFrac = double.tryParse(r.headers['x-valid-fraction'] ?? '');
    } catch (e) {
      _depthError = errText(e);
    }
  }

  static const _colorPath = 'frames/color_00000.png';

  /// Only a recorded colour frame is offered as a backdrop. The thumbnail is not one (it can be the depth image, or
  /// colour and depth side by side), so scans without a colour frame are shown on depth only.
  bool _hasColorFrame() => asList(asMap(_detail['manifest'])['files']).map(asMap).any((f) => f['path'] == _colorPath);

  Future<void> _loadColor(AppState s, String id) async {
    try {
      _colorImg = (await s.api!.getBytes('/api/scans/$id/file/$_colorPath')).bytes;
    } catch (e) {
      _colorError = errText(e);
    }
  }

  Future<void> _setBackdrop(bool color) async {
    setState(() => _showColor = color);
    final s = AppScope.read(context);
    final id = s.selectedScanId;
    if (color && _colorImg == null && _colorError == null && id != null) {
      await _loadColor(s, id);
      if (mounted) setState(() {});
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
      if (body['kind'] == 'roughness') s.pendingRoi = body['roi'] as Map<String, dynamic>?;
      s.bumpScans();
      await _load(id, s);
    } catch (e) {
      _msg = errText(e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<List<double>?> _depthPoint(AppState s, String id, Offset p) async {
    final r = asMap(
      await s.api!.getJson('/api/scans/$id/depth_point', query: {'u': p.dx.toStringAsFixed(1), 'v': p.dy.toStringAsFixed(1)}),
    );
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
        setState(
          () => _msg = 'No valid depth at one of the picked pixels. Pick on a surface that has depth (not white in the depth figure).',
        );
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
    setState(() {
      _busy = true;
      _msg = null;
    });
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
            _repeat = null;
          }
          _load(id, s);
        }
      });
    }
    final man = asMap(_detail['manifest']);
    final current = man.isNotEmpty && man['scan_id'] == id;
    return DefaultTabController(
      length: 5,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PageHeader(
            'Analysis',
            inline: [ScanPicker(selected: id, onChanged: s.selectScan)],
            actions: [
              if (current) OriginTag(man['origin'] as String?),
              if (id != null) TextButton(onPressed: () => s.go(Section.viewer), child: const Text('Open in Viewer')),
            ],
          ),
          if (current && HonestyBanner.messageFor(man['origin'] as String?) != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 10),
              child: HonestyBanner(
                origin: man['origin'] as String?,
                isRealSensor: man['is_real_sensor'] as bool?,
                compact: true,
                boxed: true,
                replayOf: asMap(man['replay_of'])['scan_id'] as String?,
              ),
            ),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 24),
            child: TabBar(
              isScrollable: true,
              tabAlignment: TabAlignment.start,
              tabs: [
                Tab(text: 'Measure', height: 40),
                Tab(text: 'All measurements', height: 40),
                Tab(text: 'Capture quality', height: 40),
                Tab(text: 'Repeatability', height: 40),
                Tab(text: 'Methodology', height: 40),
              ],
            ),
          ),
          Expanded(
            child: id == null
                ? EmptyState(
                    title: 'Choose a scan',
                    body: 'Pick a saved scan above, or record one in Capture.',
                    action: OutlinedButton(onPressed: () => s.go(Section.library), child: const Text('Open Library')),
                  )
                : _error != null
                ? Padding(
                    padding: const EdgeInsets.all(24),
                    child: Align(alignment: Alignment.topLeft, child: ErrorBox(_error!)),
                  )
                : TabBarView(children: [_measureTab(s, id), _allTab(), _qualityTab(), _repeatTab(s), const _Methodology()]),
          ),
        ],
      ),
    );
  }

  // ------------------------------------------------------------------ Measure

  Widget _measureTab(AppState s, String id) {
    final t = Theme.of(context);
    final di = asMap(_detail['depth_image']);
    if (_detail.isEmpty) return const Center(child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2)));
    if (di.isEmpty) {
      return EmptyState(
        title: 'This scan has no depth image',
        body: 'Imported point clouds, such as iPhone LiDAR scans, are measured with a sphere region in the Viewer.',
        action: FilledButton(onPressed: () => s.go(Section.viewer), child: const Text('Open Viewer')),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 20),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: Align(
              alignment: Alignment.topCenter,
              child: Panel(padding: const EdgeInsets.fromLTRB(16, 12, 20, 14), child: _figurePanel(s, id, t, di)),
            ),
          ),
          const SizedBox(width: 20),
          SizedBox(width: 380, child: _measurePanel(s, id, t)),
        ],
      ),
    );
  }

  Widget _figurePanel(AppState s, String id, ThemeData t, Map<String, dynamic> di) {
    final w = (asInt(di['width']) ?? 848).toDouble();
    final h = (asInt(di['height']) ?? 480).toDouble();
    final hasColor = _hasColorFrame();
    final color = _showColor && hasColor;
    final img = color ? _colorImg : _depthPng;
    final imgError = color ? _colorError : _depthError;
    final hint = switch (_tool) {
      Tool.roughness => 'Drag a rectangle over the surface to measure.',
      Tool.protrusion =>
        _part == ProtrusionPart.object
            ? 'Drag a rectangle over the object that sticks out.'
            : 'Drag a rectangle over the surrounding reference surface.',
      Tool.distance => 'Click two points on surfaces that have depth.',
    };
    final caption = color
        ? FigureCaption(
            'Colour frame on the depth grid.',
            '$_colorPath, stretched to ${w.round()} × ${h.round()} depth pixels. Registration is approximate and for picking only; '
                'measurements use the filtered depth.',
          )
        : FigureCaption(
            'Filtered depth.',
            '${w.round()} × ${h.round()} px, per-pixel median of the recorded frames. '
                '${_rangeLo != null ? 'Coloured by depth along the camera axis, ${_rangeLo!.toStringAsFixed(2)} to ${_rangeHi!.toStringAsFixed(2)} m (2nd to 98th percentile); white' : 'White'} '
                'has no depth${_validFrac != null ? ' (${(_validFrac! * 100).toStringAsFixed(1)} % of pixels are valid)' : ''}. '
                'Regions are in depth pixels.',
          );
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(child: Text(hint, style: t.textTheme.bodyMedium)),
            const SizedBox(width: 12),
            if (hasColor)
              Segmented<bool>(value: color, options: const [(false, 'Depth'), (true, 'Colour')], onChanged: _setBackdrop)
            else
              Text('No colour frame in this scan', style: t.textTheme.bodySmall),
          ],
        ),
        const SizedBox(height: 10),
        Flexible(
          child: Figure(
            dataSize: Size(w, h),
            colorBar: !color && _rangeLo != null && _rangeHi != null
                ? ColorBarSpec(lo: _rangeLo!, hi: _rangeHi!, unit: 'depth z, m', decimals: 2)
                : null,
            caption: caption,
            overlay: LayoutBuilder(
              builder: (context, b) {
                final sc = b.maxWidth / w;
                Offset toDepth(Offset p) => Offset((p.dx / sc).clamp(0, w - 1), (p.dy / sc).clamp(0, h - 1));
                final drawing = _tool != Tool.distance;
                return MouseRegion(
                  cursor: SystemMouseCursors.precise,
                  child: GestureDetector(
                    onPanStart: drawing ? (d) => setState(() => _dragStart = _dragNow = toDepth(d.localPosition)) : null,
                    onPanUpdate: drawing ? (d) => setState(() => _dragNow = toDepth(d.localPosition)) : null,
                    onPanEnd: drawing ? (_) => _finishDrag() : null,
                    onTapUp: drawing
                        ? null
                        : (d) => setState(() {
                            if (_pts.length >= 2) _pts.clear();
                            _pts.add(toDepth(d.localPosition));
                          }),
                    child: CustomPaint(
                      size: Size.infinite,
                      painter: _OverlayPainter(
                        scale: sc,
                        rect: _tool == Tool.roughness ? _rect : null,
                        obj: _tool == Tool.protrusion ? _objRect : null,
                        ref: _tool == Tool.protrusion ? _refRect : null,
                        pts: _tool == Tool.distance ? _pts : const [],
                        drag: _dragStart != null && _dragNow != null ? Rect.fromPoints(_dragStart!, _dragNow!) : null,
                      ),
                    ),
                  ),
                );
              },
            ),
            child: img != null
                ? Image.memory(img, fit: BoxFit.fill, gaplessPlayback: true, filterQuality: FilterQuality.medium)
                : Center(
                    child: imgError != null
                        ? Padding(
                            padding: const EdgeInsets.all(16),
                            child: Text(imgError, style: t.textTheme.bodySmall),
                          )
                        : const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
                  ),
          ),
        ),
      ],
    );
  }

  void _finishDrag() {
    final a = _dragStart, b = _dragNow;
    if (a != null && b != null && (a - b).distance > 4) {
      final r = [a.dx < b.dx ? a.dx : b.dx, a.dy < b.dy ? a.dy : b.dy, a.dx < b.dx ? b.dx : a.dx, a.dy < b.dy ? b.dy : a.dy];
      if (_tool == Tool.roughness) _rect = r;
      if (_tool == Tool.protrusion) {
        if (_part == ProtrusionPart.object) {
          _objRect = r;
          if (_refRect == null) _part = ProtrusionPart.reference; // next step
        } else {
          _refRect = r;
        }
      }
    }
    setState(() => _dragStart = _dragNow = null);
  }

  static String _rectText(List<double>? r) =>
      r == null ? 'not drawn' : 'u ${r[0].round()} to ${r[2].round()}, v ${r[1].round()} to ${r[3].round()}';

  Widget _measurePanel(AppState s, String id, ThemeData t) {
    final (canRun, runLabel, run) = switch (_tool) {
      Tool.roughness => (
        _rect != null,
        'Measure roughness',
        () => _run(s, id, {'kind': 'roughness', 'roi': _rectRoi(_rect!), 'robust': _robust}),
      ),
      Tool.protrusion => (
        _objRect != null && _refRect != null,
        'Measure protrusion',
        () => _run(s, id, {'kind': 'protrusion', 'roi': _rectRoi(_objRect!), 'reference_roi': _rectRoi(_refRect!)}),
      ),
      Tool.distance => (_pts.length == 2, 'Measure distance', () => _distance(s, id)),
    };
    final rows = switch (_tool) {
      Tool.roughness => [FactRow('Region', _rectText(_rect), unit: _rect == null ? null : 'px')],
      Tool.protrusion => [
        FactRow('Object', _rectText(_objRect), unit: _objRect == null ? null : 'px'),
        FactRow('Reference surface', _rectText(_refRect), unit: _refRect == null ? null : 'px'),
      ],
      Tool.distance => [
        for (int i = 0; i < 2; i++)
          FactRow(
            'Point ${i + 1}',
            i < _pts.length ? 'u ${_pts[i].dx.round()}, v ${_pts[i].dy.round()}' : 'not picked',
            unit: i < _pts.length ? 'px' : null,
          ),
      ],
    };
    final hasAnything = _rect != null || _objRect != null || _refRect != null || _pts.isNotEmpty;
    return ListView(
      children: [
        Panel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              PanelPart(
                title: 'Tool',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Segmented<Tool>(
                      expand: true,
                      value: _tool,
                      options: const [(Tool.roughness, 'Roughness'), (Tool.protrusion, 'Protrusion'), (Tool.distance, 'Distance')],
                      onChanged: (v) => setState(() => _tool = v),
                    ),
                    const SizedBox(height: 8),
                    Text(switch (_tool) {
                      Tool.roughness => 'RMS distance of the points to a fitted plane, with tilt and extent.',
                      Tool.protrusion => 'Height of an object above a plane fitted to the surface around it.',
                      Tool.distance => 'Straight-line distance between two points in the camera frame.',
                    }, style: t.textTheme.bodySmall),
                    if (_tool == Tool.protrusion) ...[
                      const SizedBox(height: 12),
                      Text('Drawing', style: t.textTheme.labelMedium),
                      const SizedBox(height: 4),
                      Segmented<ProtrusionPart>(
                        expand: true,
                        value: _part,
                        options: const [(ProtrusionPart.object, 'Object'), (ProtrusionPart.reference, 'Reference surface')],
                        onChanged: (v) => setState(() => _part = v),
                      ),
                    ],
                    const SizedBox(height: 12),
                    FactTable(rows),
                  ],
                ),
              ),
              PanelPart(
                ruled: true,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    TextField(
                      controller: _label,
                      decoration: const InputDecoration(labelText: 'Label', hintText: 'e.g. boulder A, upper face'),
                    ),
                    if (_tool == Tool.roughness)
                      CheckboxListTile(
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                        controlAffinity: ListTileControlAffinity.leading,
                        value: _robust,
                        onChanged: (v) => setState(() => _robust = v ?? false),
                        title: const Text('Robust fit, rejecting points beyond 3 MAD'),
                      )
                    else
                      const SizedBox(height: 14),
                    Row(
                      children: [
                        Expanded(
                          child: FilledButton(
                            onPressed: !canRun || _busy ? null : run,
                            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(42)),
                            child: Text(_busy ? 'Measuring' : runLabel),
                          ),
                        ),
                        if (hasAnything) ...[
                          const SizedBox(width: 8),
                          OutlinedButton(
                            onPressed: () => setState(() {
                              _rect = _objRect = _refRect = null;
                              _pts.clear();
                              _part = ProtrusionPart.object;
                            }),
                            style: OutlinedButton.styleFrom(minimumSize: const Size(0, 42)),
                            child: const Text('Clear'),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text('Each result is saved to the scan\'s metrics.json with its method and region.', style: t.textTheme.bodySmall),
                  ],
                ),
              ),
            ],
          ),
        ),
        if (_msg != null) ...[const SizedBox(height: 12), ErrorBox(_msg!)],
        if (_last.isNotEmpty) ...[
          const SizedBox(height: 16),
          SectionCard(
            title: 'Result',
            child: MeasurementTable(measurements: _last),
          ),
        ],
      ],
    );
  }

  // ------------------------------------------------------------------ other tabs

  Widget _page(List<Widget> children, {double maxWidth = 880}) => ListView(
    padding: const EdgeInsets.fromLTRB(24, 18, 24, 32),
    children: [
      Align(
        alignment: Alignment.topLeft,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxWidth),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
        ),
      ),
    ],
  );

  Widget _allTab() {
    final man = asMap(_detail['manifest']);
    final metrics = asMap(_detail['metrics']);
    final def = Measurement.listFrom(asMap(metrics['default_analysis'])['measurements']);
    final defIds = def.map((m) => m.id).toSet();
    final all = Measurement.listFrom(man['measurements']).where((m) => !defIds.contains(m.id)).toList();
    return _page([
      SectionCard(
        title: 'Default analysis',
        subtitle: 'Computed automatically on ${asStr(asMap(asMap(metrics['default_analysis'])['roi'])['label'], 'the central region')}.',
        child: MeasurementTable(measurements: def, emptyText: 'No default analysis: the scan was imported or not processed.'),
      ),
      const SizedBox(height: 16),
      SectionCard(
        title: 'Your measurements',
        subtitle: all.isEmpty ? null : '${all.length} saved, newest first.',
        child: MeasurementTable(measurements: all.reversed.toList(), emptyText: 'None yet. Use the Measure tab.'),
      ),
    ]);
  }

  Widget _qualityTab() {
    final q = asMap(asMap(_detail['metrics'])['capture_quality']);
    final man = asMap(_detail['manifest']);
    final mq = q.isEmpty ? asMap(man['quality']) : q;
    final t = Theme.of(context);
    if (mq.isEmpty) return const EmptyState(title: 'No capture-quality record for this scan');
    final rp = asMap(mq['range_m_percentiles']);
    String p100(Object? v) => asDouble(v) == null ? '—' : (asDouble(v)! * 100).toStringAsFixed(1);
    final ops = asList(asMap(man['processing'])['operations']).map(asMap).toList();
    return _page([
      SectionCard(
        title: 'Capture quality',
        subtitle: 'Counts measured during capture. Nothing here is an accuracy figure.',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            FactTable([
              if (mq['frames'] != null) FactRow('Frames', '${mq['frames']}'),
              if (mq['pixels_per_frame'] != null) FactRow('Pixels per frame', '${mq['pixels_per_frame']}'),
              if (mq['depth_valid_fraction_mean'] != null)
                FactRow('Valid depth, mean of frames', p100(mq['depth_valid_fraction_mean']), unit: '%'),
              if (mq['pixels_valid_in_all_frames'] != null)
                FactRow('Valid in every frame', p100(mq['pixels_valid_in_all_frames']), unit: '%'),
              if (mq['filtered_valid_fraction'] != null) FactRow('Valid after filtering', p100(mq['filtered_valid_fraction']), unit: '%'),
              if (mq['temporal_std_median_m'] != null)
                FactRow('Frame-to-frame noise, median per-pixel std', formatMetres(asDouble(mq['temporal_std_median_m'])!)),
              if (mq['raw_point_cloud_points'] != null) FactRow('Raw cloud points', '${mq['raw_point_cloud_points']}'),
              if (mq['filtered_point_cloud_points'] != null) FactRow('Filtered cloud points', '${mq['filtered_point_cloud_points']}'),
              if (mq['frames_skipped_between_recorded'] != null)
                FactRow('Sensor frames skipped while recording', '${mq['frames_skipped_between_recorded']}'),
              for (final e in mq.entries.where((e) => !_knownQ.contains(e.key) && e.value is! Map && e.value is! List))
                FactRow(prettyName(e.key), '${e.value}'),
            ], unitWidth: 30),
            if (rp.isNotEmpty) ...[
              const SizedBox(height: 18),
              Text('Range from the sensor, by percentile', style: t.textTheme.titleSmall),
              const SizedBox(height: 6),
              ResultTable(
                columns: const [
                  RCol('Percentile', flex: 2),
                  RCol('5', numeric: true),
                  RCol('25', numeric: true),
                  RCol('50', numeric: true),
                  RCol('75', numeric: true),
                  RCol('95', numeric: true),
                ],
                rows: [
                  [
                    'Range, m',
                    for (final k in ['5', '25', '50', '75', '95']) asDouble(rp[k])?.toStringAsFixed(3) ?? '—',
                  ],
                ],
              ),
            ],
            if (mq['temporal_std_note'] != null) ...[
              const SizedBox(height: 10),
              Text('${mq['temporal_std_note']}', style: t.textTheme.bodySmall),
            ],
          ],
        ),
      ),
      const SizedBox(height: 16),
      SectionCard(
        title: 'Processing applied',
        subtitle: 'In order. Raw frames are stored unchanged.',
        child: ops.isEmpty
            ? Text('No processing record.', style: t.textTheme.bodyMedium?.copyWith(color: FsPalette.inkMuted))
            : ResultTable(
                columns: const [RCol('Step', flex: 2), RCol('Parameters', flex: 5)],
                rows: [
                  for (final op in ops)
                    [
                      prettyName(asStr(op['op'])),
                      op.entries.where((e) => e.key != 'op').map((e) => '${e.key.replaceAll('_', ' ')} ${e.value}').join(', '),
                    ],
                ],
              ),
      ),
    ]);
  }

  static const _knownQ = {
    'frames',
    'pixels_per_frame',
    'depth_valid_fraction_mean',
    'pixels_valid_in_all_frames',
    'filtered_valid_fraction',
    'temporal_std_median_m',
    'raw_point_cloud_points',
    'filtered_point_cloud_points',
    'frames_skipped_between_recorded',
    'temporal_std_note',
    'filtered_points',
  };

  Widget _repeatTab(AppState s) {
    final t = Theme.of(context);
    final roi = _rect != null ? _rectRoi(_rect!) : s.pendingRoi;
    final rows = asList(_repeat?['rows']).map(asMap).toList();
    final summary = asMap(_repeat?['summary']);
    String roiText(Map<String, dynamic> r) {
      if (r['kind'] == 'pixel_rect') {
        final p = asList(r['rect_px']);
        return p.length == 4 ? 'depth pixels u ${p[0]} to ${p[2]}, v ${p[1]} to ${p[3]}' : 'depth pixels $p';
      }
      return 'sphere, radius ${formatMetres(asDouble(r['radius_m']) ?? 0)}';
    }

    String m(Object? v) => asDouble(v) == null ? '—' : formatMetres(asDouble(v)!);
    return _page([
      SectionCard(
        title: 'Repeat captures',
        subtitle:
            'The same region measured on two or more scans of the same stationary target. The spread is precision under '
            'these conditions, not accuracy.',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            FactTable([
              FactRow('Scans selected', s.repeatSelection.isEmpty ? 'none' : s.repeatSelection.map(shortId).join(', ')),
              FactRow('Region', roi == null ? 'none: draw a roughness region in Measure, or a sphere in Viewer' : roiText(roi)),
            ]),
            const SizedBox(height: 12),
            Row(
              children: [
                FilledButton(
                  onPressed: roi == null || s.repeatSelection.length < 2 || _busy ? null : () => _repeatability(s),
                  child: Text(
                    _busy ? 'Comparing' : 'Compare ${s.repeatSelection.length >= 2 ? '${s.repeatSelection.length} scans' : 'scans'}',
                  ),
                ),
                const SizedBox(width: 8),
                TextButton(onPressed: () => s.go(Section.library), child: const Text('Select scans in Library')),
              ],
            ),
            if (s.repeatSelection.length < 2) ...[
              const SizedBox(height: 6),
              Text('Tick Compare on two or more scans in Library.', style: t.textTheme.bodySmall),
            ],
          ],
        ),
      ),
      if (_msg != null) ...[const SizedBox(height: 12), ErrorBox(_msg!)],
      if (_repeat != null) ...[
        const SizedBox(height: 16),
        SectionCard(
          title: 'Per scan',
          child: ResultTable(
            columns: const [
              RCol('Scan', flex: 2),
              RCol('RMS to plane', numeric: true, flex: 2),
              RCol('Median range', numeric: true, flex: 2),
              RCol('Extent', numeric: true, flex: 2),
              RCol('Points', numeric: true, flex: 2),
            ],
            rows: [
              for (final r in rows)
                r['error'] != null
                    ? [
                        shortId(r['scan_id'] as String?),
                        Text('error: ${r['error']}', style: t.textTheme.bodySmall?.copyWith(color: FsPalette.record)),
                      ]
                    : [
                        shortId(r['scan_id'] as String?),
                        m(r['rms_orthogonal_m']),
                        m(r['median_range_m']),
                        m(r['extent_major_m']),
                        '${r['n_points'] ?? '—'}',
                      ],
            ],
          ),
        ),
        const SizedBox(height: 16),
        SectionCard(
          title: 'Spread across scans',
          child: ResultTable(
            columns: const [
              RCol('Quantity', flex: 3),
              RCol('n', numeric: true),
              RCol('Mean', numeric: true, flex: 2),
              RCol('Std', numeric: true, flex: 2),
              RCol('Range', numeric: true, flex: 2),
            ],
            rows: [
              for (final e in summary.entries)
                () {
                  final v = asMap(e.value);
                  if (v['status'] != 'measured') return [prettyName(e.key), '—', 'not measured: ${v['reason']}', '', ''];
                  final isM = e.key.endsWith('_m');
                  String f(Object? x) => isM ? m(x) : (asDouble(x)?.toStringAsFixed(1) ?? '—');
                  return [prettyName(e.key), '${v['n']}', f(v['mean']), f(v['std']), f(v['range'])];
                }(),
            ],
            footnotes: [if (asStr(_repeat?['note']).isNotEmpty) asStr(_repeat?['note'])],
          ),
        ),
      ],
    ]);
  }
}

/// Regions the user drew, in field ochre with a white halo so they read on every part of the viridis scale.
class _OverlayPainter extends CustomPainter {
  _OverlayPainter({required this.scale, this.rect, this.obj, this.ref, required this.pts, this.drag});
  final double scale;
  final List<double>? rect, obj, ref;
  final List<Offset> pts;
  final Rect? drag;

  static final _halo = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = 4
    ..color = Colors.white.withValues(alpha: 0.85);
  static final _line = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = 2
    ..color = FsPalette.ochre;

  void _label(Canvas canvas, Offset at, String text) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: const TextStyle(fontFamily: fsFont, color: Colors.white, fontSize: 11, fontWeight: FontWeight.w600, height: 1.2),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final r = Rect.fromLTWH(at.dx, at.dy, tp.width + 8, tp.height + 3);
    canvas.drawRect(r, Paint()..color = FsPalette.ochre);
    tp.paint(canvas, at + const Offset(4, 1.5));
  }

  void _dashedRect(Canvas canvas, Rect r, Paint p) {
    void dash(Offset a, Offset b) {
      final len = (b - a).distance;
      if (len == 0) return;
      final dir = (b - a) / len;
      for (double d = 0; d < len; d += 10) {
        canvas.drawLine(a + dir * d, a + dir * (d + 6 > len ? len : d + 6), p);
      }
    }

    dash(r.topLeft, r.topRight);
    dash(r.topRight, r.bottomRight);
    dash(r.bottomRight, r.bottomLeft);
    dash(r.bottomLeft, r.topLeft);
  }

  @override
  void paint(Canvas canvas, Size size) {
    Rect px(List<double> r) => Rect.fromLTRB(r[0] * scale, r[1] * scale, r[2] * scale, r[3] * scale);
    void box(List<double>? r, String label, {bool dashed = false}) {
      if (r == null) return;
      final rr = px(r);
      if (dashed) {
        _dashedRect(canvas, rr, _halo);
        _dashedRect(canvas, rr, _line);
      } else {
        canvas.drawRect(rr, _halo);
        canvas.drawRect(rr, _line);
      }
      _label(canvas, rr.top >= 18 ? rr.topLeft - const Offset(0, 17) : rr.topLeft + const Offset(2, 2), label);
    }

    box(rect, 'Roughness region');
    box(ref, 'Reference surface', dashed: true);
    box(obj, 'Object');
    if (drag != null) {
      final d = Rect.fromLTRB(drag!.left * scale, drag!.top * scale, drag!.right * scale, drag!.bottom * scale);
      _dashedRect(canvas, d, _halo);
      _dashedRect(
        canvas,
        d,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..color = FsPalette.ochre,
      );
    }
    if (pts.length == 2) {
      canvas.drawLine(pts[0] * scale, pts[1] * scale, _halo);
      canvas.drawLine(pts[0] * scale, pts[1] * scale, _line);
    }
    for (int i = 0; i < pts.length; i++) {
      final p = pts[i] * scale;
      canvas.drawCircle(p, 5.5, Paint()..color = Colors.white);
      canvas.drawCircle(p, 4, Paint()..color = FsPalette.ochre);
      _label(canvas, p + const Offset(8, -20), '${i + 1}');
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
      padding: const EdgeInsets.only(bottom: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(head, style: t.textTheme.titleSmall),
          const SizedBox(height: 4),
          Text(body, style: t.textTheme.bodyMedium?.copyWith(height: 1.55)),
        ],
      ),
    );
    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 22, 24, 40),
      children: [
        Align(
          alignment: Alignment.topLeft,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 700),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                p(
                  'What is measured',
                  'Points come from the D435\'s calibrated depth: Z = raw × depth scale, X = (u − cx)·Z/fx, Y = (v − cy)·Z/fy, in the camera optical frame (metres; +X right, +Y down, +Z forward). Filtered depth is the per-pixel median of all recorded frames, clipped to a range, with depth-edge ("flying") pixels removed. Raw frames are stored unchanged.',
                ),
                p(
                  'Plane-fit roughness',
                  'A total-least-squares plane is fitted to the points in the region (SVD). Roughness is the RMS of orthogonal distances to that plane, in metres. With the robust option, points beyond 3 MAD are rejected and the plane is refitted; the number rejected is recorded.',
                ),
                p(
                  'Baseline dependence',
                  'Roughness grows with region size. The region\'s in-plane extent (baseline) is stored with every value; compare values only at similar baselines. These centimetre-to-metre values are not comparable with the 400 to 3200 m terrain descriptors used for planetary analog discovery on the website.',
                ),
                p(
                  'Tilt is relative to the camera',
                  'The D435 has no IMU and no levelling reference was recorded, so plane orientation is the angle to the camera optical axis, not slope from horizontal. Gravity-referenced slope is marked "not measured". iPhone ARKit scans carry a gravity-aligned frame, so their tilt from horizontal can be measured.',
                ),
                p(
                  'Sensor noise floor',
                  'Intel\'s published D400 model gives an expected RMS depth noise of Z² × 0.08 / (fx × baseline) at range Z (a typical subpixel value, not measured for this unit). When the residual RMS is under twice that value the result is flagged "at noise floor": surface roughness is not resolved at that range.',
                ),
                p(
                  'Precision, not accuracy',
                  'The per-frame spread (same region on each raw frame) and the repeat-capture spread (same region across repeated scans) describe repeatability under these conditions. They are not ground-truth accuracy. Check dimensions against a ruler or a known object.',
                ),
                p(
                  'Protrusion',
                  'A robust plane is fitted to a reference surface you choose; object heights are distances above it toward the sensor. Only the visible side is measured. Any rover-clearance comparison is a team-defined illustration, not a NASA flight-qualified limit.',
                ),
                p(
                  'What this does not do',
                  'Nothing here identifies rock type, mineralogy or chemistry, and nothing scores planetary analog suitability. Hidden surfaces are never filled in. Planetary analog discovery and characterisation live on the website.',
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

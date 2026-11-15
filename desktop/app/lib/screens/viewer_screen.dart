// Draft written with AI assistance (Claude, Anthropic); disclosed per the Space Apps AI policy.

import 'package:flutter/material.dart';

import '../service/app_state.dart';
import '../service/models.dart';
import '../widgets/common.dart';
import '../widgets/figure.dart';
import '../widgets/honesty_banner.dart';
import '../widgets/measurement_table.dart';
import '../widgets/point_cloud_view.dart';
import '../widgets/scan_picker.dart';

class ViewerScreen extends StatefulWidget {
  const ViewerScreen({super.key});
  @override
  State<ViewerScreen> createState() => _ViewerScreenState();
}

class _ViewerScreenState extends State<ViewerScreen> {
  final _ctl = PointCloudController();
  String? _loadedFor;
  String _kind = 'filtered';
  int _maxPoints = 150000;
  bool _loading = false;
  String? _error;
  Map<String, dynamic> _detail = {};
  bool _measuring = false;
  List<Measurement> _results = [];
  String? _resultError;
  final _label = TextEditingController();
  bool _robust = false;

  @override
  void dispose() {
    _ctl.dispose();
    _label.dispose();
    super.dispose();
  }

  Future<void> _load(String scanId) async {
    final s = AppScope.read(context);
    setState(() {
      _loading = true;
      _error = null;
      _loadedFor = '$scanId/$_kind/$_maxPoints';
      _results = [];
      _resultError = null;
    });
    try {
      _detail = asMap(await s.api!.getJson('/api/scans/$scanId'));
      final clouds = asMap(_detail['clouds']);
      if (!clouds.containsKey(_kind)) {
        _kind = clouds.containsKey('filtered') ? 'filtered' : (clouds.keys.isNotEmpty ? clouds.keys.first : 'filtered');
      }
      final r = await s.api!.getBytes('/api/scans/$scanId/cloud.bin', query: {'kind': _kind, 'max_points': '$_maxPoints'});
      final cloud = CloudData.parse(r.bytes, r.headers);
      _ctl.setCloud(cloud);
      _loadedFor = '$scanId/$_kind/$_maxPoints';
    } catch (e) {
      _error = errText(e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _measure(String scanId) async {
    final s = AppScope.read(context);
    final c = _ctl.roiCenter;
    if (c == null) return;
    setState(() {
      _measuring = true;
      _resultError = null;
    });
    try {
      final r = asMap(
        await s.api!.postJson('/api/scans/$scanId/analyze', {
          'kind': 'roughness',
          'roi': {'kind': 'sphere', 'center': c, 'radius_m': _ctl.roiRadius},
          'robust': _robust,
          'label': _label.text.trim().isEmpty ? 'viewer sphere ROI' : _label.text.trim(),
        }),
      );
      if (r['saved'] == false) {
        _resultError = 'Not measured: ${r['reason'] ?? r['status']}';
        _results = [];
      } else {
        _results = Measurement.listFrom(r['measurements']);
      }
      s.pendingRoi = {'kind': 'sphere', 'center': c, 'radius_m': _ctl.roiRadius};
      s.bumpScans();
    } catch (e) {
      _resultError = errText(e);
    } finally {
      if (mounted) setState(() => _measuring = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    final t = Theme.of(context);
    final id = s.selectedScanId;
    if (id != null && _loadedFor != '$id/$_kind/$_maxPoints' && !_loading) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _loadedFor != '$id/$_kind/$_maxPoints') _load(id);
      });
    }
    final man = asMap(_detail['manifest']);
    final clouds = asMap(_detail['clouds']);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PageHeader(
          'Viewer',
          inline: [
            ScanPicker(selected: id, onChanged: (v) => s.selectScan(v), width: 380),
            if (id != null)
              Segmented<String>(
                value: _kind,
                options: [('filtered', 'Filtered'), ('raw', 'Raw'), if (clouds.containsKey('mesh')) ('mesh', 'Mesh')],
                onChanged: (v) => setState(() => _kind = v),
              ),
          ],
          actions: [if (id != null) TextButton(onPressed: () => s.go(Section.analysis), child: const Text('Measure on the depth image'))],
        ),
        if (man.isNotEmpty && man['scan_id'] == id)
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 14),
            child: HonestyBanner(
              origin: man['origin'] as String?,
              isRealSensor: man['is_real_sensor'] as bool?,
              compact: true,
              boxed: true,
              replayOf: asMap(man['replay_of'])['scan_id'] as String?,
            ),
          ),
        Expanded(
          child: id == null
              ? EmptyState(
                  title: 'Choose a scan',
                  body: 'Pick a saved scan above, or record one in Capture.',
                  action: OutlinedButton(onPressed: () => s.go(Section.library), child: const Text('Open Library')),
                )
              : Padding(
                  padding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(
                        child: Panel(padding: const EdgeInsets.all(16), child: _figure(t)),
                      ),
                      const SizedBox(width: 20),
                      SizedBox(width: 380, child: _panel(t, id, man)),
                    ],
                  ),
                ),
        ),
      ],
    );
  }

  Widget _figure(ThemeData t) {
    return ListenableBuilder(
      listenable: _ctl,
      builder: (context, _) {
        final cloud = _ctl.cloud;
        final title = switch (_kind) {
          'raw' => 'Raw point cloud.',
          'mesh' => 'Mesh vertices.',
          _ => 'Filtered point cloud.',
        };
        final shown = cloud == null
            ? 'Loading.'
            : '${_n(cloud.count)} of ${_n(cloud.total ?? cloud.count)} points shown${(cloud.step ?? 1) > 1 ? ' (1 in ${cloud.step}, for display only)' : ''}. ';
        return Figure(
          background: FsPalette.plot,
          caption: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              FigureCaption(
                title,
                cloud == null
                    ? shown
                    : '$shown${_ctl.mapping.legend} Hidden surfaces (backs, undersides) were not measured and are not drawn. '
                          'The scale bar is exact only at the orbit centre.'
                          '${_kind == 'mesh' ? ' Derived mesh without hole filling, not raw sensor data.' : ''}',
              ),
              const SizedBox(height: 6),
              Text(
                'Drag to orbit. Shift-drag or right-drag to pan. Scroll to zoom. Click a point to centre the region of interest.',
                style: t.textTheme.bodySmall,
              ),
            ],
          ),
          child: Stack(
            children: [
              Positioned.fill(
                child: PointCloudView(controller: _ctl, accent: FsPalette.ochre, onPick: (i) => _ctl.setRoi(_ctl.pointInScanFrame(i))),
              ),
              Positioned(
                right: 10,
                top: 10,
                child: OutlinedButton(
                  onPressed: _ctl.resetView,
                  style: OutlinedButton.styleFrom(minimumSize: const Size(0, 32), padding: const EdgeInsets.symmetric(horizontal: 10)),
                  child: const Text('Reset view'),
                ),
              ),
              if (_loading) const Center(child: SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2))),
              if (_error != null)
                Center(
                  child: Padding(padding: const EdgeInsets.all(24), child: ErrorBox(_error!)),
                ),
            ],
          ),
        );
      },
    );
  }

  static String _n(int v) {
    final s = '$v';
    final b = StringBuffer();
    for (int i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) b.write(' ');
      b.write(s[i]);
    }
    return b.toString();
  }

  Widget _titleBlock(ThemeData t, Map<String, dynamic> man) {
    final obs = asMap(man['observation']);
    final cap = asMap(man['capture']);
    final cf = asMap(man['coordinate_frame']);
    final captured = man['captured_at_utc'];
    final start = captured is Map ? captured['start'] : captured;
    final k = originKind(man['origin'] as String?);
    final originColor = (k == OriginKind.realD435 || k == OriginKind.iphone)
        ? FsPalette.sensor
        : (k == OriginKind.replay || k == OriginKind.other ? FsPalette.ink : FsPalette.synthetic);
    Widget cell(String label, String value, {Color? color, bool right = false, bool bottom = true}) => Container(
      padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
      decoration: BoxDecoration(
        border: Border(
          right: right ? const BorderSide(color: FsPalette.ink) : BorderSide.none,
          bottom: bottom ? const BorderSide(color: FsPalette.ink) : BorderSide.none,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: t.textTheme.labelSmall),
          const SizedBox(height: 1),
          Text(
            value,
            style: t.textTheme.bodyMedium?.copyWith(fontSize: 13.5, color: color, fontWeight: color != null ? FontWeight.w600 : null),
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
    final cells = [
      ('Scan', shortId(asStr(man['scan_id'])), null),
      ('Session', shortId(man['session_id'] as String?), null),
      ('Captured, UTC', utcText(start), null),
      ('Frames', '${cap['frames_recorded'] ?? cap['keyframes'] ?? '—'}${cap['profile'] != null ? ', ${cap['profile']}' : ''}', null),
      ('Origin', originLabel(man['origin'] as String?), originColor),
      ('Status', asStr(man['status'], '—'), man['status'] == 'complete' ? null : FsPalette.record),
      ('Frame', asStr(cf['name'], '—'), null),
      ('Units', asStr(cf['units'], 'm') == 'm' ? 'metre' : asStr(cf['units']), null),
    ];
    final rows = <Widget>[];
    for (int i = 0; i < cells.length; i += 2) {
      final last = i + 2 >= cells.length;
      rows.add(
        IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: cell(cells[i].$1, cells[i].$2, color: cells[i].$3, right: true, bottom: !last),
              ),
              Expanded(
                child: cell(cells[i + 1].$1, cells[i + 1].$2, color: cells[i + 1].$3, bottom: !last),
              ),
            ],
          ),
        ),
      );
    }
    return Semantics(
      container: true,
      label: 'Title block',
      child: Panel(
        strong: true,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
              decoration: const BoxDecoration(
                border: Border(bottom: BorderSide(color: FsPalette.ink)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Title', style: t.textTheme.labelSmall),
                  Text(
                    asStr(obs['title']).isEmpty ? 'Untitled scan' : asStr(obs['title']),
                    style: t.textTheme.titleMedium?.copyWith(fontSize: 16),
                  ),
                ],
              ),
            ),
            ...rows,
          ],
        ),
      ),
    );
  }

  Widget _panel(ThemeData t, String id, Map<String, dynamic> man) {
    return ListenableBuilder(
      listenable: _ctl,
      builder: (context, _) {
        final hasRoi = _ctl.roiCenter != null;
        final cloud = _ctl.cloud;
        return ListView(
          children: [
            if (man.isNotEmpty && man['scan_id'] == id) ...[_titleBlock(t, man), const SizedBox(height: 16)],
            if (_resultError != null) ...[ErrorBox(_resultError!), const SizedBox(height: 12)],
            if (_results.isNotEmpty) ...[
              SectionCard(
                title: 'Result, saved to metrics.json',
                trailing: IconButton(
                  onPressed: () => setState(() => _results = []),
                  icon: const Icon(Icons.close, size: 18),
                  tooltip: 'Hide result',
                ),
                child: MeasurementTable(measurements: _results),
              ),
              const SizedBox(height: 16),
            ],
            SectionCard(
              title: 'Sphere region of interest',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (!hasRoi)
                    Text(
                      'Click a point in the cloud to place the centre.',
                      style: t.textTheme.bodyMedium?.copyWith(color: FsPalette.inkMuted),
                    )
                  else
                    FactTable([
                      FactRow('Points inside, displayed', '${_ctl.roiCount}'),
                      FactRow('Baseline, diameter', (_ctl.roiRadius * 2).toStringAsFixed(3), unit: 'm'),
                      FactRow('Centre', _ctl.roiCenter!.map((e) => e.toStringAsFixed(3)).join(', '), unit: 'm'),
                    ]),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      SizedBox(width: 56, child: Text('Radius', style: t.textTheme.bodyMedium)),
                      Expanded(
                        child: Slider(value: _ctl.roiRadius, min: 0.02, max: 1.0, onChanged: (v) => _ctl.setRoi(_ctl.roiCenter, v)),
                      ),
                      SizedBox(
                        width: 64,
                        child: Text(
                          '${_ctl.roiRadius.toStringAsFixed(3)} m',
                          textAlign: TextAlign.right,
                          style: t.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
                        ),
                      ),
                    ],
                  ),
                  Text('Roughness grows with baseline, so compare values measured at similar baselines.', style: t.textTheme.bodySmall),
                  const SizedBox(height: 14),
                  TextField(
                    controller: _label,
                    decoration: const InputDecoration(labelText: 'Label', hintText: 'e.g. boulder A, upper face'),
                  ),
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    controlAffinity: ListTileControlAffinity.leading,
                    value: _robust,
                    onChanged: (v) => setState(() => _robust = v ?? false),
                    title: const Text('Robust fit, rejecting points beyond 3 MAD'),
                  ),
                  Row(
                    children: [
                      Expanded(
                        child: FilledButton(
                          onPressed: !hasRoi || _measuring ? null : () => _measure(id),
                          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(42)),
                          child: Text(_measuring ? 'Measuring' : 'Measure roughness here'),
                        ),
                      ),
                      if (hasRoi) ...[
                        const SizedBox(width: 8),
                        OutlinedButton(
                          onPressed: () => _ctl.setRoi(null),
                          style: OutlinedButton.styleFrom(minimumSize: const Size(0, 42)),
                          child: const Text('Clear'),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text('Measured on the full filtered file, not on the displayed points.', style: t.textTheme.bodySmall),
                ],
              ),
            ),
            const SizedBox(height: 16),
            SectionCard(
              title: 'Display',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Segmented<ColorMode>(
                    expand: true,
                    value: _ctl.colorMode,
                    options: const [(ColorMode.rgb, 'Colour'), (ColorMode.range, 'Range'), (ColorMode.up, 'Up axis')],
                    onChanged: _ctl.setColorMode,
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      SizedBox(width: 72, child: Text('Point size', style: t.textTheme.bodyMedium)),
                      Expanded(
                        child: Slider(value: _ctl.pointSize, min: 1, max: 6, divisions: 10, onChanged: _ctl.setPointSize),
                      ),
                      SizedBox(
                        width: 48,
                        child: Text(
                          '${_ctl.pointSize.toStringAsFixed(1)} px',
                          textAlign: TextAlign.right,
                          style: t.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<int>(
                    initialValue: _maxPoints,
                    decoration: const InputDecoration(labelText: 'Points drawn'),
                    items: const [
                      DropdownMenuItem(value: 60000, child: Text('Up to 60 000, fastest')),
                      DropdownMenuItem(value: 150000, child: Text('Up to 150 000')),
                      DropdownMenuItem(value: 300000, child: Text('Up to 300 000, slowest')),
                    ],
                    onChanged: (v) => setState(() => _maxPoints = v ?? 150000),
                  ),
                  if (cloud != null && _ctl.colorMode == ColorMode.range) ...[
                    const SizedBox(height: 6),
                    ColorScaleStrip(
                      // D435 clouds are in the camera frame; iPhone clouds are in the ARKit session frame, whose origin is
                      // where the session started, not the phone's position at each keyframe.
                      caption: asStr(asMap(asMap(_detail['manifest'])['coordinate_frame'])['name']) == 'arkit_session_world'
                          ? 'Distance from the session origin, viridis'
                          : 'Distance from the sensor, viridis',
                      lo: '${_ctl.zMin.toStringAsFixed(2)} m',
                      hi: '${_ctl.zMax.toStringAsFixed(2)} m',
                    ),
                  ],
                  if (cloud != null && _ctl.colorMode == ColorMode.up) ...[
                    const SizedBox(height: 6),
                    ColorScaleStrip(
                      caption: _ctl.mapping.flipYZ
                          ? 'Height along the display up axis (camera −Y, not gravity), viridis'
                          : 'Height along the display up axis, viridis',
                      lo: '${_ctl.upMin.toStringAsFixed(2)} m',
                      hi: '${_ctl.upMax.toStringAsFixed(2)} m',
                    ),
                  ],
                  if (cloud != null) ...[
                    const Divider(height: 24, color: FsPalette.ruleLight),
                    KV('Source file', cloud.sourceFile ?? '—', labelWidth: 96),
                    KV('Extent', 'about ${formatMetres(_ctl.extent * 2)} across', labelWidth: 96),
                  ],
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

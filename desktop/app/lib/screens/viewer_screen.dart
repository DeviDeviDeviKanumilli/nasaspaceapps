import 'package:flutter/material.dart';

import '../service/app_state.dart';
import '../service/models.dart';
import '../widgets/common.dart';
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
      if (!clouds.containsKey(_kind)) _kind = clouds.containsKey('filtered') ? 'filtered' : (clouds.keys.isNotEmpty ? clouds.keys.first : 'filtered');
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
      final r = asMap(await s.api!.postJson('/api/scans/$scanId/analyze', {
        'kind': 'roughness',
        'roi': {'kind': 'sphere', 'center': c, 'radius_m': _ctl.roiRadius},
        'robust': _robust,
        'label': _label.text.trim().isEmpty ? 'viewer sphere ROI' : _label.text.trim(),
      }));
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
    final cloud = _ctl.cloud;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 8),
        child: Wrap(spacing: 12, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
          ScanPicker(selected: id, onChanged: (v) => s.selectScan(v)),
          SegmentedButton<String>(
            segments: [
              const ButtonSegment(value: 'filtered', label: Text('Filtered')),
              const ButtonSegment(value: 'raw', label: Text('Raw')),
              if (clouds.containsKey('mesh')) const ButtonSegment(value: 'mesh', label: Text('Derived mesh (no hole filling)')),
            ],
            selected: {_kind},
            onSelectionChanged: (v) => setState(() => _kind = v.first),
          ),
          DropdownButton<int>(
            value: _maxPoints,
            items: const [
              DropdownMenuItem(value: 60000, child: Text('60k points')),
              DropdownMenuItem(value: 150000, child: Text('150k points')),
              DropdownMenuItem(value: 300000, child: Text('300k points')),
            ],
            onChanged: (v) => setState(() => _maxPoints = v ?? 150000),
          ),
          if (man.isNotEmpty) OriginChip(man['origin'] as String?),
        ]),
      ),
      if (man.isNotEmpty) HonestyBanner(origin: man['origin'] as String?, isRealSensor: man['is_real_sensor'] as bool?, compact: true,
          replayOf: asMap(man['replay_of'])['scan_id'] as String?),
      Expanded(
        child: id == null
            ? const EmptyState(icon: Icons.view_in_ar_outlined, title: 'Choose a scan', body: 'Pick a saved scan above, or record one in Capture.')
            : Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(24, 8, 12, 16),
                    child: Container(
                      decoration: BoxDecoration(borderRadius: BorderRadius.circular(10), border: Border.all(color: t.colorScheme.outlineVariant)),
                      clipBehavior: Clip.antiAlias,
                      child: Stack(children: [
                        Positioned.fill(
                          child: PointCloudView(
                            controller: _ctl,
                            accent: t.colorScheme.primary,
                            onPick: (i) => _ctl.setRoi(_ctl.pointInScanFrame(i)),
                          ),
                        ),
                        if (_loading) const Center(child: CircularProgressIndicator()),
                        if (_error != null) Center(child: Padding(padding: const EdgeInsets.all(24), child: ErrorBox(_error!))),
                        Positioned(
                          right: 10,
                          top: 10,
                          child: IconButton.filledTonal(tooltip: 'Reset view', onPressed: _ctl.resetView, icon: const Icon(Icons.center_focus_strong)),
                        ),
                        Positioned(
                          left: 12,
                          right: 64,
                          top: 12,
                          child: Align(
                            alignment: Alignment.topLeft,
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                              decoration: BoxDecoration(color: t.colorScheme.surface.withValues(alpha: 0.85), borderRadius: BorderRadius.circular(6)),
                              child: Text(
                                'Drag: orbit · Shift/right-drag: pan · Scroll/pinch: zoom · Click a point: set ROI centre',
                                style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
                              ),
                            ),
                          ),
                        ),
                      ]),
                    ),
                  ),
                ),
                SizedBox(width: 360, child: _panel(t, id, cloud)),
              ]),
      ),
    ]);
  }

  Widget _panel(ThemeData t, String id, CloudData? cloud) {
    return ListenableBuilder(
      listenable: _ctl,
      builder: (context, _) => ListView(padding: const EdgeInsets.fromLTRB(0, 8, 24, 24), children: [
        if (_resultError != null) ...[ErrorBox(_resultError!), const SizedBox(height: 12)],
        if (_results.isNotEmpty) ...[
          SectionCard(
            title: 'Result (saved to metrics.json)',
            trailing: IconButton(onPressed: () => setState(() => _results = []), icon: const Icon(Icons.close, size: 18), tooltip: 'Hide'),
            child: MeasurementTable(measurements: _results),
          ),
          const SizedBox(height: 16),
        ],
        SectionCard(
          title: 'Display',
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            SegmentedButton<ColorMode>(
              segments: const [
                ButtonSegment(value: ColorMode.rgb, label: Text('RGB')),
                ButtonSegment(value: ColorMode.range, label: Text('Range')),
                ButtonSegment(value: ColorMode.up, label: Text('Up axis')),
              ],
              selected: {_ctl.colorMode},
              onSelectionChanged: (v) => _ctl.setColorMode(v.first),
            ),
            const SizedBox(height: 8),
            Row(children: [
              const Text('Point size'),
              Expanded(child: Slider(value: _ctl.pointSize, min: 1, max: 6, divisions: 10, onChanged: _ctl.setPointSize)),
              Text('${_ctl.pointSize.toStringAsFixed(1)} px'),
            ]),
            if (cloud != null) ...[
              KV('Points shown', '${cloud.count} of ${cloud.total ?? cloud.count}${(cloud.step ?? 1) > 1 ? ' (1 in ${cloud.step}, display only)' : ''}', labelWidth: 110),
              KV('Source file', cloud.sourceFile ?? '—', labelWidth: 110),
              if (_kind == 'mesh')
                Text('Derived mesh (no hole filling), shown as its vertices. Not raw sensor data.',
                    style: t.textTheme.bodySmall?.copyWith(color: warnColor(context))),
              KV('Extent', '≈ ${formatMetres(_ctl.extent * 2)} across', labelWidth: 110),
              const SizedBox(height: 6),
              Text(_ctl.mapping.legend, style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
              const SizedBox(height: 6),
              Text('Partial view: hidden surfaces (backs, undersides) were not measured and are not shown.',
                  style: t.textTheme.bodySmall?.copyWith(color: warnColor(context))),
            ],
          ]),
        ),
        const SizedBox(height: 16),
        SectionCard(
          title: 'Sphere region of interest',
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(
              _ctl.roiCenter == null
                  ? 'Click a point in the cloud to set the centre.'
                  : 'Centre (${_ctl.roiCenter!.map((e) => e.toStringAsFixed(3)).join(', ')}) m · ${_ctl.roiCount} displayed points inside',
              style: t.textTheme.bodySmall,
            ),
            Row(children: [
              const Text('Radius'),
              Expanded(
                child: Slider(
                  value: _ctl.roiRadius,
                  min: 0.02,
                  max: 1.0,
                  onChanged: (v) => _ctl.setRoi(_ctl.roiCenter, v),
                ),
              ),
              SizedBox(width: 64, child: Text(formatMetres(_ctl.roiRadius), textAlign: TextAlign.right)),
            ]),
            Text('Baseline (diameter) ${formatMetres(_ctl.roiRadius * 2)}. Roughness depends on it: compare at similar baselines.',
                style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
            const SizedBox(height: 8),
            TextField(controller: _label, decoration: const InputDecoration(labelText: 'Label (e.g. boulder A, upper face)')),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              value: _robust,
              onChanged: (v) => setState(() => _robust = v ?? false),
              title: const Text('Robust fit (reject points > 3 MAD)'),
            ),
            FilledButton(
              onPressed: _ctl.roiCenter == null || _measuring ? null : () => _measure(id),
              child: Text(_measuring ? 'Measuring…' : 'Measure roughness here'),
            ),
            if (_ctl.roiCenter != null)
              TextButton(onPressed: () => _ctl.setRoi(null), child: const Text('Clear ROI')),
            Text('Measured on the full filtered file in the service, not on the decimated display points.',
                style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
          ]),
        ),
      ]),
    );
  }
}

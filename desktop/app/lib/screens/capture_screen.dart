import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../service/api.dart';
import '../service/app_state.dart';
import '../service/models.dart';
import '../widgets/common.dart';

class CaptureScreen extends StatefulWidget {
  const CaptureScreen({super.key});
  @override
  State<CaptureScreen> createState() => _CaptureScreenState();
}

class _CaptureScreenState extends State<CaptureScreen> {
  String _which = 'color';
  Uint8List? _frame;
  int _frameIdx = -1;
  Timer? _timer;
  bool _inflight = false;
  ApiClient? _api;

  final _title = TextEditingController();
  final _notes = TextEditingController();
  final _site = TextEditingController();
  final _cand = TextEditingController();
  final _frames = TextEditingController();
  String _feature = 'other';
  bool _sameSession = false;
  String? _scanId; // scan started from this screen
  String? _error;
  bool _starting = false;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(milliseconds: 110), (_) => _poll());
  }

  @override
  void dispose() {
    _timer?.cancel();
    for (final c in [_title, _notes, _site, _cand, _frames]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _poll() async {
    if (_inflight || !mounted) return;
    final s = AppScope.read(context);
    _api = s.api;
    final st = s.deviceState;
    if (_api == null || !(st == 'streaming' || st == 'recording' || st == 'processing')) {
      if (_frame != null && st != 'streaming') setState(() => _frame = null);
      return;
    }
    _inflight = true;
    try {
      final r = await _api!.getBytes('/api/preview/$_which.jpg', query: {'max_w': '960'}, timeout: const Duration(seconds: 3));
      if (r.status == 200 && mounted) {
        final idx = int.tryParse(r.headers['x-frame-index'] ?? '') ?? -1;
        if (idx != _frameIdx) {
          setState(() {
            _frame = r.bytes;
            _frameIdx = idx;
          });
        }
      }
    } catch (_) {
      // transient; the status bar shows device state
    } finally {
      _inflight = false;
    }
  }

  Future<void> _start() async {
    final s = AppScope.read(context);
    setState(() {
      _starting = true;
      _error = null;
    });
    try {
      final r = asMap(await s.api!.postJson('/api/capture/start', {
        'title': _title.text.trim(),
        'feature_type': _feature,
        'notes': _notes.text.trim(),
        'field_site_id': _site.text.trim(),
        'candidate_id': _cand.text.trim(),
        if (_sameSession && s.lastSessionId != null) 'session_id': s.lastSessionId,
        if (int.tryParse(_frames.text.trim()) != null) 'frames': int.parse(_frames.text.trim()),
      }));
      _scanId = r['scan_id'] as String?;
      s.lastSessionId = r['session_id'] as String?;
    } catch (e) {
      _error = errText(e);
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  Future<void> _stop(bool cancel) async {
    final s = AppScope.read(context);
    try {
      await s.api!.postJson(cancel ? '/api/capture/cancel' : '/api/capture/stop');
    } catch (e) {
      if (mounted) showSnack(context, errText(e), error: true);
    }
  }

  Future<void> _reopen() async {
    final s = AppScope.read(context);
    final st = s.status;
    try {
      s.status = asMap(await s.api!.postJson('/api/device/open',
          {'adapter_id': st['adapter_id'], 'device_id': st['device_id'], 'profile': st['profile'] ?? 'field_static'}));
      setState(() => _error = null);
    } catch (e) {
      setState(() => _error = 'Reopen failed: ${errText(e)}');
    }
  }

  /// Outcome of the scan started here, read from the service events.
  (String, Map<String, dynamic>)? _outcome(AppState s) {
    if (_scanId == null) return null;
    for (final ev in s.events.reversed) {
      if (ev['scan_id'] != _scanId) continue;
      final t = ev['type'] as String;
      if (t == 'scan_processed' || t == 'processing_error') return (t, ev);
      if (t == 'recording_stopped' && ev['ok'] == false) return ('incomplete', ev);
      if (t == 'recording_stopped') return ('processing', ev);
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    final t = Theme.of(context);
    final st = s.status;
    final state = s.deviceState;
    final live = asMap(st['live']);
    final cap = s.capture;
    if (state == 'idle' && st['adapter_id'] == null) {
      return EmptyState(
        icon: Icons.videocam_off_outlined,
        title: 'No sensor open',
        body: 'Open a RealSense camera (or, for rehearsal, a clearly labelled replay or test scene) in Devices.',
        action: FilledButton(onPressed: () => s.go(Section.devices), child: const Text('Go to Devices')),
      );
    }
    final recording = state == 'recording';
    final outcome = _outcome(s);
    return LayoutBuilder(builder: (context, box) {
      final wide = box.maxWidth > 1050;
      final preview = _preview(t, state, st);
      final side = _side(s, t, st, live, cap, recording, outcome);
      return Padding(
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 16),
        child: wide
            ? Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(flex: 3, child: preview),
                const SizedBox(width: 20),
                SizedBox(width: 380, child: side),
              ])
            : ListView(children: [SizedBox(height: 420, child: preview), const SizedBox(height: 16), side]),
      );
    });
  }

  Widget _preview(ThemeData t, String state, Map<String, dynamic> st) {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        SegmentedButton<String>(
          segments: const [
            ButtonSegment(value: 'color', label: Text('Colour'), icon: Icon(Icons.image_outlined)),
            ButtonSegment(value: 'depth', label: Text('Depth'), icon: Icon(Icons.gradient)),
          ],
          selected: {_which},
          onSelectionChanged: (v) => setState(() {
            _which = v.first;
            _frameIdx = -1;
          }),
        ),
        const SizedBox(width: 12),
        if (_which == 'depth')
          Flexible(
            child: Text('near (warm) → far (cool), 0.2–4 m; black = no depth',
                style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant), overflow: TextOverflow.ellipsis),
          ),
        const Spacer(),
        OriginChip(st['origin'] as String?),
      ]),
      const SizedBox(height: 12),
      Expanded(
        child: Container(
          decoration: BoxDecoration(
            color: Colors.black,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: t.colorScheme.outlineVariant),
          ),
          clipBehavior: Clip.antiAlias,
          child: _frame == null
              ? Center(
                  child: Text(state == 'error' ? 'No frames: the sensor stopped.' : 'Waiting for frames…',
                      style: const TextStyle(color: Colors.white70)))
              : Image.memory(_frame!, gaplessPlayback: true, fit: BoxFit.contain),
        ),
      ),
    ]);
  }

  Widget _side(AppState s, ThemeData t, Map<String, dynamic> st, Map<String, dynamic> live, Map<String, dynamic> cap, bool recording,
      (String, Map<String, dynamic>)? outcome) {
    final err = asMap(st['error']);
    final tooClose = asDouble(live['too_close_fraction']) ?? 0;
    final valid = asDouble(live['depth_valid_fraction']);
    final cal = asMap(st['calibration_summary']);
    return ListView(children: [
      if (s.deviceState == 'error') ...[
        ErrorBox('Sensor stopped: ${err['message'] ?? 'unknown error'}. A scan that was recording is saved as INCOMPLETE, never as complete.'),
        const SizedBox(height: 8),
        FilledButton.icon(onPressed: _reopen, icon: const Icon(Icons.refresh), label: const Text('Reopen sensor')),
        const SizedBox(height: 16),
      ],
      if (outcome != null) ...[
        _outcomeCard(s, t, outcome),
        const SizedBox(height: 16),
      ],
      SectionCard(
        title: 'Live quality',
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          KV('Valid depth', pct(valid), labelWidth: 150),
          KV('Range median', metres(live['range_median_m']), labelWidth: 150),
          KV('Range p05 – p95', '${metres(live['range_p05_m'])} – ${metres(live['range_p95_m'])}', labelWidth: 150),
          KV('Frame rate', st['measured_fps'] == null ? '—' : '${st['measured_fps']} fps', labelWidth: 150),
          KV('Streams', '${cal['depth'] ?? '—'} depth · ${cal['color'] ?? '—'} colour', labelWidth: 150),
          KV('Depth scale', cal['depth_scale_m'] == null ? '—' : '${cal['depth_scale_m']} m per unit', labelWidth: 150),
          if (tooClose > 0.05)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text('${(tooClose * 100).toStringAsFixed(0)} % of the view is closer than 0.28 m: move back (D435 minimum range).',
                  style: t.textTheme.bodySmall?.copyWith(color: warnColor(context))),
            ),
          if (valid != null && valid < 0.5)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text('Less than half the pixels have depth: check range, glare, shadow or low texture.',
                  style: t.textTheme.bodySmall?.copyWith(color: warnColor(context))),
            ),
          const SizedBox(height: 4),
          Text('From the latest frame, every 4th pixel; guidance only.',
              style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
        ]),
      ),
      const SizedBox(height: 16),
      SectionCard(
        title: recording ? 'Recording' : 'New scan',
        child: recording ? _recordingPanel(t, cap) : _form(s, t),
      ),
      if (_error != null) ...[const SizedBox(height: 12), ErrorBox(_error!)],
    ]);
  }

  Widget _recordingPanel(ThemeData t, Map<String, dynamic> cap) {
    final n = asInt(cap['frames_recorded']) ?? 0;
    final req = asInt(cap['frames_requested']) ?? 0;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text('$n / $req frames · ${((asInt(cap['elapsed_ms']) ?? 0) / 1000).toStringAsFixed(1)} s',
          style: t.textTheme.titleMedium?.copyWith(fontFeatures: const [FontFeature.tabularFigures()])),
      const SizedBox(height: 8),
      LinearProgressIndicator(value: req > 0 ? n / req : null),
      const SizedBox(height: 8),
      Text('Keep the camera still: frames are combined per pixel.', style: t.textTheme.bodySmall),
      const SizedBox(height: 12),
      Row(children: [
        Expanded(child: FilledButton(onPressed: () => _stop(false), child: const Text('Stop and save'))),
        const SizedBox(width: 8),
        OutlinedButton(onPressed: () => _stop(true), child: const Text('Cancel')),
      ]),
    ]);
  }

  Widget _form(AppState s, ThemeData t) {
    final profiles = asMap(s.adapters['profiles']);
    final pf = asMap(profiles[s.status['profile']])['frames'];
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      TextField(controller: _title, decoration: const InputDecoration(labelText: 'Observation title')),
      const SizedBox(height: 10),
      DropdownButtonFormField<String>(
        initialValue: _feature,
        items: [for (final f in featureTypes) DropdownMenuItem(value: f, child: Text(prettyName(f)))],
        onChanged: (v) => setState(() => _feature = v ?? 'other'),
        decoration: const InputDecoration(labelText: 'Feature type', helperText: 'Your annotation, not an automatic classification'),
      ),
      const SizedBox(height: 10),
      TextField(controller: _notes, maxLines: 2, decoration: const InputDecoration(labelText: 'Notes')),
      const SizedBox(height: 10),
      TextField(controller: _site, decoration: const InputDecoration(labelText: 'Field site ID (optional)')),
      const SizedBox(height: 10),
      TextField(controller: _cand, decoration: const InputDecoration(labelText: 'Website candidate ID (optional)')),
      Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Text('References to the website only; nothing here scores or ranks analogs.',
            style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
      ),
      const SizedBox(height: 10),
      TextField(
        controller: _frames,
        keyboardType: TextInputType.number,
        decoration: InputDecoration(labelText: 'Frames to record', hintText: pf == null ? '' : 'profile default: $pf'),
      ),
      CheckboxListTile(
        contentPadding: EdgeInsets.zero,
        dense: true,
        value: _sameSession && s.lastSessionId != null,
        onChanged: s.lastSessionId == null ? null : (v) => setState(() => _sameSession = v ?? false),
        title: const Text('Repeat in the same session'),
        subtitle: Text(s.lastSessionId == null
            ? 'Record one scan first; repeats share a session for repeatability.'
            : 'Session ${shortId(s.lastSessionId)}: keep camera and target unchanged.'),
      ),
      const SizedBox(height: 8),
      FilledButton.icon(
        onPressed: _starting || s.deviceState != 'streaming' ? null : _start,
        icon: const Icon(Icons.fiber_manual_record),
        label: Text(s.deviceState == 'processing' ? 'Processing previous scan…' : 'Start recording'),
        style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(44)),
      ),
    ]);
  }

  Widget _outcomeCard(AppState s, ThemeData t, (String, Map<String, dynamic>) o) {
    final (kind, ev) = o;
    switch (kind) {
      case 'processing':
        return SectionCard(
          title: 'Saving',
          child: Row(children: [
            const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
            const SizedBox(width: 12),
            Expanded(child: Text('${ev['frames']} frames recorded; building point clouds and metrics…')),
          ]),
        );
      case 'scan_processed':
        final complete = ev['status'] == 'complete';
        return SectionCard(
          title: complete ? 'Scan saved' : 'Scan saved as ${ev['status']}',
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            KV('Scan', shortId(ev['scan_id'] as String?), labelWidth: 120),
            KV('Filtered points', '${ev['points'] ?? '—'}', labelWidth: 120),
            KV('Bundle size', ev['bytes'] == null ? '—' : '${((asInt(ev['bytes']) ?? 0) / 1e6).toStringAsFixed(1)} MB', labelWidth: 120),
            const SizedBox(height: 10),
            Row(children: [
              FilledButton(onPressed: () => s.go(Section.viewer, scanId: ev['scan_id'] as String?), child: const Text('Open in Viewer')),
              const SizedBox(width: 8),
              OutlinedButton(onPressed: () => s.go(Section.analysis, scanId: ev['scan_id'] as String?), child: const Text('Analyse')),
            ]),
          ]),
        );
      case 'incomplete':
        return ErrorBox('Scan ${shortId(ev['scan_id'] as String?)} is INCOMPLETE (${ev['reason']}). ${ev['frames']} frames were kept for inspection.');
      default:
        return ErrorBox('Processing failed for scan ${shortId(ev['scan_id'] as String?)}: ${ev['message']}');
    }
  }
}

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../service/api.dart';
import '../service/app_state.dart';
import '../service/models.dart';
import '../widgets/common.dart';
import '../widgets/figure.dart';

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
  Timer? _sampler;
  bool _inflight = false;
  ApiClient? _api;

  /// Valid-depth history for the trend plot: (time, percent). Real samples from the service's live status.
  final List<(DateTime, double)> _validHistory = [];

  final _title = TextEditingController();
  final _notes = TextEditingController();
  final _site = TextEditingController();
  final _cand = TextEditingController();
  final _frames = TextEditingController();
  String _feature = 'other';
  bool _sameSession = false;
  bool _moreFields = false;
  String? _scanId; // scan started from this screen
  String? _error;
  bool _starting = false;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(milliseconds: 110), (_) => _poll());
    _sampler = Timer.periodic(const Duration(seconds: 1), (_) => _sample());
  }

  @override
  void dispose() {
    _timer?.cancel();
    _sampler?.cancel();
    for (final c in [_title, _notes, _site, _cand, _frames]) {
      c.dispose();
    }
    super.dispose();
  }

  void _sample() {
    if (!mounted) return;
    final s = AppScope.read(context);
    final st = s.deviceState;
    final v = asDouble(asMap(s.status['live'])['depth_valid_fraction']);
    final now = DateTime.now();
    _validHistory.removeWhere((e) => now.difference(e.$1).inSeconds > 62);
    if (v != null && (st == 'streaming' || st == 'recording')) {
      setState(() => _validHistory.add((now, v * 100)));
    }
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
      // transient; the status footer shows device state
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
      final r = asMap(
        await s.api!.postJson('/api/capture/start', {
          'title': _title.text.trim(),
          'feature_type': _feature,
          'notes': _notes.text.trim(),
          'field_site_id': _site.text.trim(),
          'candidate_id': _cand.text.trim(),
          if (_sameSession && s.lastSessionId != null) 'session_id': s.lastSessionId,
          if (int.tryParse(_frames.text.trim()) != null) 'frames': int.parse(_frames.text.trim()),
        }),
      );
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
      s.status = asMap(
        await s.api!.postJson('/api/device/open', {
          'adapter_id': st['adapter_id'],
          'device_id': st['device_id'],
          'profile': st['profile'] ?? 'field_static',
        }),
      );
      if (mounted) setState(() => _error = null);
    } catch (e) {
      if (mounted) setState(() => _error = 'Reopen failed: ${errText(e)}');
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

  static Size? _streamSize(Object? spec) {
    final m = RegExp(r'(\d+)\s*x\s*(\d+)').firstMatch(asStr(spec));
    if (m == null) return null;
    return Size(double.parse(m.group(1)!), double.parse(m.group(2)!));
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
        title: 'No source open',
        body: 'Open a RealSense camera in Devices. For rehearsal you can open a replay or the test scene; both are labelled everywhere.',
        action: FilledButton(onPressed: () => s.go(Section.devices), child: const Text('Go to Devices')),
      );
    }
    final recording = state == 'recording';
    final outcome = _outcome(s);
    final dev = asMap(st['device']);
    final cal = asMap(st['calibration_summary']);
    final profiles = asMap(s.adapters['profiles']);
    final profileLabel = asStr(asMap(profiles[st['profile']])['label'], asStr(st['profile'])).split(',').first;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PageHeader(
          'Capture',
          inline: [
            Segmented<String>(
              value: _which,
              options: const [('color', 'Colour'), ('depth', 'Depth')],
              onChanged: (v) => setState(() {
                _which = v;
                _frameIdx = -1;
              }),
            ),
          ],
          actions: [
            Text(
              '${asStr(dev['name'], 'Source')}, profile $profileLabel, ${dims(cal[_which == 'color' ? 'color' : 'depth'])}',
              style: t.textTheme.bodySmall?.copyWith(fontSize: 13),
            ),
          ],
        ),
        Expanded(
          child: LayoutBuilder(
            builder: (context, box) {
              final wide = box.maxWidth > 980;
              final figure = Panel(padding: const EdgeInsets.fromLTRB(16, 14, 20, 14), child: _figure(t, state, st, cal));
              final side = _side(s, t, st, live, cap, recording, outcome);
              if (wide) {
                return Padding(
                  padding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(
                        child: Align(alignment: Alignment.topCenter, child: figure),
                      ),
                      const SizedBox(width: 20),
                      SizedBox(width: 380, child: ListView(children: side)),
                    ],
                  ),
                );
              }
              return ListView(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
                children: [
                  SizedBox(height: 480, child: figure),
                  const SizedBox(height: 16),
                  ...side,
                ],
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _figure(ThemeData t, String state, Map<String, dynamic> st, Map<String, dynamic> cal) {
    final depth = _which == 'depth';
    final size = _streamSize(cal[depth ? 'depth' : 'color']) ?? const Size(848, 480);
    final fps = st['measured_fps'];
    final w = size.width.round(), h = size.height.round();
    final frameText = _frameIdx >= 0 ? 'frame $_frameIdx' : 'no frame yet';
    return Figure(
      dataSize: size,
      unitX: 'px',
      colorBar: depth ? const ColorBarSpec(lo: 0.2, hi: 4.0, unit: 'range, m', decimals: 1) : null,
      caption: FigureCaption(
        depth ? 'Live depth stream.' : 'Live colour stream.',
        depth
            ? '$w × $h px, $frameText${fps != null ? ', $fps fps measured' : ''}. Coloured 0.2 to 4 m; white has no depth. '
                  'The D435 cannot measure closer than about 0.28 m.'
            : '$w × $h px, $frameText${fps != null ? ', $fps fps measured' : ''}.',
      ),
      child: _frame == null
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (state != 'error') const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
                  const SizedBox(height: 10),
                  Text(state == 'error' ? 'No frames: the sensor stopped.' : 'Waiting for frames', style: t.textTheme.bodySmall),
                ],
              ),
            )
          : Image.memory(_frame!, gaplessPlayback: true, fit: BoxFit.fill, filterQuality: FilterQuality.medium),
    );
  }

  List<Widget> _side(
    AppState s,
    ThemeData t,
    Map<String, dynamic> st,
    Map<String, dynamic> live,
    Map<String, dynamic> cap,
    bool recording,
    (String, Map<String, dynamic>)? outcome,
  ) {
    final err = asMap(st['error']);
    final tooClose = asDouble(live['too_close_fraction']) ?? 0;
    final valid = asDouble(live['depth_valid_fraction']);
    final guidance = <Widget>[
      if (tooClose > 0.05)
        Hint(
          '${(tooClose * 100).toStringAsFixed(0)} % of the view is closer than 0.28 m. Move back: that is the D435 minimum range.',
          color: FsPalette.caution,
          icon: Icons.warning_amber_rounded,
        ),
      if (valid != null && valid < 0.5)
        Hint(
          'Less than half the pixels have depth. Check range, glare, shadow or low texture.',
          color: FsPalette.caution,
          icon: Icons.warning_amber_rounded,
        ),
    ];
    final now = DateTime.now();
    final samples = [for (final (ts, v) in _validHistory) (now.difference(ts).inMilliseconds / 1000.0, v)];
    String num(Object? v, int d) => asDouble(v)?.toStringAsFixed(d) ?? '—';
    return [
      if (s.deviceState == 'error') ...[
        ErrorBox(
          'Sensor stopped: ${err['message'] ?? 'unknown error'}. A scan that was recording is saved as INCOMPLETE, never as complete.',
          action: FilledButton(onPressed: _reopen, child: const Text('Reopen sensor')),
        ),
        const SizedBox(height: 16),
      ],
      if (outcome != null) ...[_outcomeCard(s, t, outcome), const SizedBox(height: 16)],
      Panel(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            PanelPart(
              title: 'Live quality',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  FactTable([
                    FactRow(
                      'Valid depth',
                      valid == null ? '—' : (valid * 100).toStringAsFixed(1),
                      unit: '%',
                      color: valid != null && valid < 0.5 ? FsPalette.caution : null,
                    ),
                    FactRow('Median range', num(live['range_median_m'], 3), unit: 'm'),
                    FactRow('Range p05 to p95', '${num(live['range_p05_m'], 3)} to ${num(live['range_p95_m'], 3)}', unit: 'm'),
                    FactRow(
                      'Closer than 0.28 m',
                      (tooClose * 100).toStringAsFixed(1),
                      unit: '%',
                      color: tooClose > 0.05 ? FsPalette.caution : null,
                    ),
                    FactRow('Frame rate', st['measured_fps'] == null ? '—' : '${st['measured_fps']}', unit: 'fps'),
                  ]),
                  const SizedBox(height: 12),
                  TrendPlot(samples: samples, semantics: 'Valid depth over the last 60 seconds'),
                  const SizedBox(height: 4),
                  Text(
                    'Valid depth, last 60 s, one sample per second. Live values use every 4th pixel of one frame: guidance, not a measurement.',
                    style: t.textTheme.bodySmall,
                  ),
                  if (guidance.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    for (final g in guidance) Padding(padding: const EdgeInsets.only(bottom: 6), child: g),
                  ],
                ],
              ),
            ),
            PanelPart(ruled: true, title: recording ? 'Recording' : 'New scan', child: recording ? _recordingPanel(t, cap) : _form(s, t)),
          ],
        ),
      ),
      if (_error != null) ...[const SizedBox(height: 12), ErrorBox(_error!)],
    ];
  }

  Widget _recordingPanel(ThemeData t, Map<String, dynamic> cap) {
    final n = asInt(cap['frames_recorded']) ?? 0;
    final req = asInt(cap['frames_requested']) ?? 0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FactTable([
          FactRow('Frames recorded', '$n of $req', color: FsPalette.record),
          FactRow('Elapsed', ((asInt(cap['elapsed_ms']) ?? 0) / 1000).toStringAsFixed(1), unit: 's'),
        ]),
        const SizedBox(height: 10),
        LinearProgressIndicator(value: req > 0 ? n / req : null, color: FsPalette.record, minHeight: 4),
        const SizedBox(height: 10),
        const Hint('Keep the camera still: frames are combined per pixel.'),
        const SizedBox(height: 14),
        Row(
          children: [
            Expanded(
              child: FilledButton(
                onPressed: () => _stop(false),
                style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(44)),
                child: const Text('Stop and save'),
              ),
            ),
            const SizedBox(width: 8),
            OutlinedButton(
              onPressed: () => _stop(true),
              style: OutlinedButton.styleFrom(minimumSize: const Size(0, 44)),
              child: const Text('Cancel'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _form(AppState s, ThemeData t) {
    final profiles = asMap(s.adapters['profiles']);
    final pf = asInt(asMap(profiles[s.status['profile']])['frames']);
    final custom = int.tryParse(_frames.text.trim());
    final n = custom ?? pf;
    final ready = !_starting && s.deviceState == 'streaming';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: _title,
          decoration: const InputDecoration(labelText: 'Observation title', hintText: 'e.g. Boulder A, upper face'),
        ),
        const SizedBox(height: 14),
        DropdownButtonFormField<String>(
          initialValue: _feature,
          items: [for (final f in featureTypes) DropdownMenuItem(value: f, child: Text(prettyName(f)))],
          onChanged: (v) => setState(() => _feature = v ?? 'other'),
          decoration: const InputDecoration(labelText: 'Feature type, your annotation'),
        ),
        const SizedBox(height: 14),
        TextField(
          controller: _notes,
          maxLines: 2,
          decoration: const InputDecoration(labelText: 'Notes'),
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: () => setState(() => _moreFields = !_moreFields),
            icon: Icon(_moreFields ? Icons.expand_less : Icons.expand_more, size: 18),
            label: Text(_moreFields ? 'Fewer options' : 'Site, candidate and frame count'),
            style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 0, vertical: 10)),
          ),
        ),
        if (_moreFields) ...[
          TextField(
            controller: _site,
            decoration: const InputDecoration(labelText: 'Field site ID, optional'),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _cand,
            decoration: const InputDecoration(labelText: 'Website candidate ID, optional'),
          ),
          const SizedBox(height: 4),
          Text('References to the website only. Nothing here scores or ranks analogs.', style: t.textTheme.bodySmall),
          const SizedBox(height: 14),
          TextField(
            controller: _frames,
            keyboardType: TextInputType.number,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(labelText: 'Frames to record', hintText: pf == null ? '' : 'profile default: $pf'),
          ),
          const SizedBox(height: 6),
        ],
        CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          controlAffinity: ListTileControlAffinity.leading,
          value: _sameSession && s.lastSessionId != null,
          onChanged: s.lastSessionId == null ? null : (v) => setState(() => _sameSession = v ?? false),
          title: const Text('Repeat in the same session'),
          subtitle: Text(
            s.lastSessionId == null
                ? 'Record one scan first. Repeats share a session so you can compare them.'
                : 'Session ${shortId(s.lastSessionId)}. Keep camera and target unchanged so repeats can be compared.',
          ),
        ),
        const SizedBox(height: 8),
        FilledButton(
          onPressed: ready ? _start : null,
          style: FilledButton.styleFrom(
            backgroundColor: FsPalette.record,
            foregroundColor: Colors.white,
            minimumSize: const Size.fromHeight(46),
            textStyle: t.textTheme.labelLarge?.copyWith(fontSize: 15),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (_starting)
                const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
              else if (s.deviceState != 'processing')
                Container(
                  width: 11,
                  height: 11,
                  decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
                ),
              const SizedBox(width: 10),
              Text(
                s.deviceState == 'processing'
                    ? 'Processing the previous scan'
                    : (_starting ? 'Starting' : (n != null ? 'Record $n frames' : 'Record')),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Text('Hold the camera still while it records: frames are combined per pixel.', style: t.textTheme.bodySmall),
      ],
    );
  }

  Widget _outcomeCard(AppState s, ThemeData t, (String, Map<String, dynamic>) o) {
    final (kind, ev) = o;
    switch (kind) {
      case 'processing':
        return SectionCard(
          title: 'Saving',
          child: Row(
            children: [
              const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
              const SizedBox(width: 12),
              Expanded(child: Text('${ev['frames']} frames recorded. Building point clouds and metrics.')),
            ],
          ),
        );
      case 'scan_processed':
        final complete = ev['status'] == 'complete';
        return SectionCard(
          title: complete ? 'Scan saved' : 'Scan saved as ${ev['status']}',
          trailing: complete ? null : const Icon(Icons.error_outline, color: FsPalette.record),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              FactTable([
                FactRow('Scan', shortId(ev['scan_id'] as String?)),
                FactRow('Filtered points', '${ev['points'] ?? '—'}'),
                FactRow('Bundle size', ev['bytes'] == null ? '—' : ((asInt(ev['bytes']) ?? 0) / 1e6).toStringAsFixed(1), unit: 'MB'),
              ]),
              const SizedBox(height: 14),
              Row(
                children: [
                  Expanded(
                    child: FilledButton(
                      onPressed: () => s.go(Section.viewer, scanId: ev['scan_id'] as String?),
                      child: const Text('Open in Viewer'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => s.go(Section.analysis, scanId: ev['scan_id'] as String?),
                      child: const Text('Analyse'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        );
      case 'incomplete':
        return ErrorBox(
          'Scan ${shortId(ev['scan_id'] as String?)} is INCOMPLETE (${ev['reason']}). ${ev['frames']} frames were kept for inspection.',
        );
      default:
        return ErrorBox('Processing failed for scan ${shortId(ev['scan_id'] as String?)}: ${ev['message']}');
    }
  }
}

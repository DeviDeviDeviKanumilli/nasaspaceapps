import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/app_state.dart';
import '../core/ble_protocol.dart';
import '../core/scan_record.dart';
import '../core/scanner.dart';
import '../ui/rocks.dart';
import '../ui/style.dart';
import 'scan_detail_screen.dart';

/// Setup for scans started from the Mac on a mounted phone. The Mac can send a title and feature type with
/// each start; otherwise the title says when it was taken.
ScanSetup rigSetup() {
  final now = DateTime.now();
  return ScanSetup(
    title: 'Rig scan ${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}',
    featureType: 'other',
    preset: 'rig',
    rigMode: true,
    collectLocation: AppState.I.defaultLocation,
  );
}

class CaptureScreen extends StatefulWidget {
  final ScanSetup setup;

  /// Rig use, driven from the Mac: after each scan is saved the screen stays open and goes back to ready (no
  /// scan-detail page), so the next start command works without anyone touching the phone.
  final bool remoteRig;

  /// A start command from the Mac that opened this screen; carried out as soon as the camera is ready.
  final Map<String, dynamic>? pending;
  const CaptureScreen({super.key, required this.setup, this.remoteRig = false, this.pending});
  @override
  State<CaptureScreen> createState() => _CaptureScreenState();
}

enum _Phase { preparing, ready, countdown, recording, saving, failed }

class _CaptureScreenState extends State<CaptureScreen> with WidgetsBindingObserver {
  _Phase phase = _Phase.preparing;
  String? error;
  Map<String, dynamic> status = {};
  final List<String> warnings = [];
  StreamSubscription? _evSub, _cmdSub;
  Timer? _stateTimer, _unlockTimer, _holdTimer;
  int countdown = 0;
  bool paused = false;
  bool rigLocked = false;
  bool meshOverlay = true;
  double? _savedBrightness;
  String? _scanId;
  Directory? _dir;
  bool _startedRemotely = false;
  String? _lastSaved;

  CapturePreset get preset => presetById(widget.setup.preset);
  bool get rig => widget.setup.rigMode;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _evSub = Scanner.events.listen(_onEvent);
    _cmdSub = AppState.I.ble.commands.listen(_onRemote);
    _prepare();
  }

  Future<void> _prepare() async {
    try {
      AppState.I.captureScreenOpen(true);
      await Scanner.prepare(mesh: AppState.I.caps['mesh'] == true, hiRes: true);
      if (mounted) setState(() => phase = _Phase.ready);
      if (mounted && widget.pending != null) unawaited(_onRemote(widget.pending!));
    } catch (e) {
      setState(() {
        phase = _Phase.failed;
        error = 'Camera could not start: $e';
      });
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _evSub?.cancel();
    _cmdSub?.cancel();
    _stateTimer?.cancel();
    _unlockTimer?.cancel();
    _holdTimer?.cancel();
    if (_savedBrightness != null) Scanner.setBrightness(_savedBrightness!);
    AppState.I.captureScreenOpen(false);
    Scanner.stopSession();
    super.dispose();
  }

  void _onEvent(Map<String, dynamic> e) {
    if (!mounted) return;
    switch (e['type']) {
      case 'status':
        setState(() => status = e);
      case 'warning':
        setState(() => warnings.insert(0, '${e['message']}'));
      case 'autoStop':
        _warn('Stopped automatically: ${e['reason']}');
        _stop('auto:${e['reason']}');
    }
  }

  void _warn(String s) => setState(() => warnings.insert(0, s));

  // ---- remote control from the paired Mac
  Future<void> _onRemote(Map<String, dynamic> m) async {
    final link = AppState.I.ble;
    if (!AppState.I.allowRemoteControl) {
      await link.ack(m, false, 'remote control is off on the phone');
      return;
    }
    final type = m['type'];
    if (type == 'start_capture') {
      // The camera may still be starting (screen just opened, or re-arming after the last scan): wait briefly.
      for (var i = 0; i < 40 && phase == _Phase.preparing && mounted; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      if (phase == _Phase.ready) {
        final t = '${m['title'] ?? ''}'.trim();
        if (t.isNotEmpty) widget.setup.title = t;
        if (featureTypes.containsKey(m['feature_type'])) widget.setup.featureType = '${m['feature_type']}';
        // Start first, then answer: the Mac is told "started" only if recording really began.
        final err = await _start(remote: true);
        await link.ack(m, err == null, err);
      } else {
        await link.ack(m, false, 'phone not ready (${phase.name})');
      }
    } else if (type == 'stop_capture') {
      if (phase == _Phase.recording) {
        await link.ack(m, true);
        _stop('remote');
      } else {
        await link.ack(m, false, 'not recording');
      }
    } else if (type == 'capture_now') {
      if (phase == _Phase.recording) {
        await Scanner.captureNow();
        await link.ack(m, true);
      } else {
        await link.ack(m, false, 'not recording');
      }
    }
  }

  void _sendState() {
    final link = AppState.I.ble;
    if (!link.paired) return;
    link.send({
      'type': 'capture_state',
      'target': 'phone',
      'state': phase == _Phase.recording ? (paused ? 'paused' : 'recording') : (phase == _Phase.saving ? 'saving' : 'idle'),
      'elapsed_ms': ((status['elapsedS'] as num? ?? 0) * 1000).round(),
      'frames_recorded': status['keyframes'] ?? 0,
      'tracking': status['tracking'],
      'scan_id': _scanId,
    });
  }

  // ---- start / stop
  /// Starts recording. Returns null on success, or why it did not start.
  Future<String?> _start({bool remote = false}) async {
    if (phase != _Phase.ready) return 'phone not ready (${phase.name})';
    if (rig && !remote) {
      setState(() {
        phase = _Phase.countdown;
        countdown = 5;
      });
      if (AppState.I.rigSpeech) Scanner.speak('Mount the phone. Starting in 5 seconds.');
      while (countdown > 0 && mounted && phase == _Phase.countdown) {
        await Future.delayed(const Duration(seconds: 1));
        if (!mounted || phase != _Phase.countdown) return 'countdown cancelled';
        setState(() => countdown--);
      }
    }
    _scanId = newId();
    _dir = AppState.I.library.newScanDir(_scanId!);
    try {
      await Scanner.startRecording(
        dir: _dir!.path,
        scanId: _scanId!,
        preset: preset,
        sound: rig ? AppState.I.rigSound : false,
        speech: rig ? AppState.I.rigSpeech : false,
        location: widget.setup.collectLocation,
      );
    } on PlatformException catch (e) {
      setState(() {
        phase = _Phase.ready;
        warnings.insert(0, 'Could not start: ${e.message}');
      });
      return 'could not start: ${e.message}';
    }
    _startedRemotely = remote;
    setState(() {
      phase = _Phase.recording;
      paused = false;
    });
    _stateTimer = Timer.periodic(const Duration(seconds: 1), (_) => _sendState());
    if (rig) {
      _savedBrightness = await Scanner.brightness();
      await Scanner.setBrightness(0.05);
      setState(() => rigLocked = true);
    }
    return null;
  }

  Future<void> _stop(String reason) async {
    if (phase != _Phase.recording) return;
    setState(() {
      phase = _Phase.saving;
      rigLocked = false;
    });
    _stateTimer?.cancel();
    if (_savedBrightness != null) {
      await Scanner.setBrightness(_savedBrightness!);
      _savedBrightness = null;
    }
    try {
      final s = await Scanner.stopRecording(reason);
      final env = buildEnvelope(s, widget.setup, sessionId: AppState.I.fieldSessionId);
      final rec = ScanRecord(_dir!, env);
      await rec.save('capture finished');
      _sendState();
      final link = AppState.I.ble;
      if (link.paired) {
        link.send({'type': 'capture_complete', 'target': 'phone', 'scan_id': _scanId, 'keyframes': s['keyframes'], 'points': s['points'] ?? 0, 'bytes': 0});
      }
      await AppState.I.refresh();
      AppState.I.updateAwake(force: true); // the native side cleared keep-awake when recording stopped
      if (!mounted) return;
      if (widget.remoteRig || _startedRemotely) {
        // Driven from the Mac: stay here and re-arm (fresh tracking for the next scan) instead of leaving.
        _lastSaved = '${rec.title} · ${s['keyframes'] ?? 0} keyframes · saved ${DateTime.now().toIso8601String().substring(11, 19)}';
        setState(() => phase = _Phase.preparing);
        await Scanner.stopSession();
        await Scanner.prepare(mesh: AppState.I.caps['mesh'] == true, hiRes: true);
        _startedRemotely = false;
        if (mounted) setState(() => phase = _Phase.ready);
        _sendState();
        return;
      }
      Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => ScanDetailScreen(record: rec, justCaptured: true)));
    } catch (e) {
      setState(() {
        phase = _Phase.failed;
        error = 'Saving failed: $e. Raw keyframes stay in the Library as an incomplete scan.';
      });
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    if (s == AppLifecycleState.paused && phase == _Phase.recording) {
      _warn('App went to the background: ARKit pauses the camera; capture resumes when tracking is normal again.');
    }
  }

  // ---- rig lock: hold 2 s to unlock for 10 s
  void _holdStart() {
    _holdTimer?.cancel();
    _holdTimer = Timer(const Duration(seconds: 2), () {
      HapticFeedback.heavyImpact();
      setState(() => rigLocked = false);
      if (_savedBrightness != null) Scanner.setBrightness(_savedBrightness!);
      _unlockTimer?.cancel();
      _unlockTimer = Timer(const Duration(seconds: 10), () {
        if (mounted && phase == _Phase.recording && rig) {
          setState(() => rigLocked = true);
          Scanner.setBrightness(0.05);
        }
      });
    });
  }

  void _holdEnd() => _holdTimer?.cancel();

  Future<bool> _confirmLeave() async {
    if (phase != _Phase.recording) return true;
    final r = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Stop and save?'),
        content: const Text('Leaving stops the capture. Everything recorded so far is saved.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Keep scanning')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Stop and save')),
        ],
      ),
    );
    if (r == true) await _stop('user_left');
    return false;
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: phase != _Phase.recording && phase != _Phase.saving && phase != _Phase.countdown,
      onPopInvokedWithResult: (did, _) {
        if (!did) _confirmLeave();
      },
      child: Scaffold(
        backgroundColor: const Color(0xFF1E201C), // behind the camera feed
        body: Stack(fit: StackFit.expand, children: [
          if (defaultTargetPlatform == TargetPlatform.iOS && phase != _Phase.failed && AppState.I.hasArkit)
            UiKitView(
              key: ValueKey(meshOverlay),
              viewType: 'field_scan/ar_view',
              creationParams: {'mesh': meshOverlay},
              creationParamsCodec: const StandardMessageCodec(),
            ),
          SafeArea(child: _hud(context)),
          if (phase == _Phase.countdown) _countdownView(),
          if (rigLocked) _rigCover(),
          if (phase == _Phase.saving) _savingView(),
          if (phase == _Phase.failed) _failedView(),
        ]),
      ),
    );
  }

  Widget _chip(String text, {IconData? icon, bool warn = false}) => Container(
        margin: const EdgeInsets.only(right: 6, bottom: 6),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(color: warn ? Fs.amberTint : Colors.white.withValues(alpha: 0.94), borderRadius: BorderRadius.circular(12)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (icon != null) ...[Icon(icon, size: 14, color: warn ? Fs.amberInk : Fs.ink2), const SizedBox(width: 5)],
          Text(text,
              style: TextStyle(
                  color: warn ? Fs.amberInk : Fs.ink, fontSize: 12, fontWeight: FontWeight.w700, fontFeatures: const [FontFeature.tabularFigures()])),
        ]),
      );

  String _pct(dynamic v) => v == null ? '–' : '${((v as num) * 100).round()}%';

  Widget _hud(BuildContext context) {
    final tr = '${status['tracking'] ?? 'starting'}';
    final ok = tr == 'normal';
    final waiting = tr == 'starting' || tr == 'not_available' || tr == 'initializing';
    final depth = status['depth'] as Map? ?? {};
    final conf = depth['confidence_fractions'] as Map? ?? {};
    final rec = phase == _Phase.recording;
    final blur = (status['blurPx'] as num?)?.toDouble() ?? 0;
    final el = (status['elapsedS'] as num?)?.toDouble() ?? 0;
    final lidar = AppState.I.hasLidar;
    final blurry = blur > (preset.trigger['maxBlurPx'] as num);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Fs.side),
      child: Column(children: [
        const SizedBox(height: 8),
        Row(children: [
          RoundIconButton(
            icon: Icons.close_rounded,
            tooltip: 'Close',
            onPressed: () async {
              final nav = Navigator.of(context);
              if (await _confirmLeave() && mounted) nav.pop();
            },
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Container(
              height: 44,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              decoration: BoxDecoration(color: Fs.card, borderRadius: BorderRadius.circular(22)),
              child: Row(children: [
                Container(width: 10, height: 10, decoration: BoxDecoration(color: rec && !paused ? Fs.record : Fs.lineStrong, shape: BoxShape.circle)),
                const SizedBox(width: 8),
                if (rec) ...[
                  Text('${el ~/ 60}:${(el % 60).floor().toString().padLeft(2, '0')}',
                      style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800, fontFeatures: [FontFeature.tabularFigures()])),
                  const SizedBox(width: 8),
                ],
                Expanded(
                  child: Text(widget.setup.title.isEmpty ? preset.label : widget.setup.title,
                      style: const TextStyle(fontSize: 13, color: Fs.muted, fontWeight: FontWeight.w600), overflow: TextOverflow.ellipsis),
                ),
              ]),
            ),
          ),
          if (lidar && AppState.I.caps['mesh'] == true) ...[
            const SizedBox(width: 8),
            RoundIconButton(
              tooltip: 'Mesh overlay',
              icon: meshOverlay ? Icons.grid_on_rounded : Icons.grid_off_rounded,
              onPressed: () => setState(() => meshOverlay = !meshOverlay),
            ),
          ],
        ]),
        const SizedBox(height: 10),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(color: Fs.card, borderRadius: BorderRadius.circular(Fs.cardRadius)),
          child: Row(children: [
            Icon(ok ? Icons.check_circle_rounded : (waiting ? Icons.hourglass_top_rounded : Icons.warning_amber_rounded),
                color: ok ? Fs.moss : (waiting ? Fs.faint : Fs.amberInk)),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(ok ? 'Tracking normal' : (waiting ? 'Waiting for the camera' : 'Tracking ${tr.replaceAll('_', ' ')}'),
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: ok ? Fs.mossInk : (waiting ? Fs.ink : Fs.amberInk))),
                Text(
                    ok
                        ? (rec ? 'Keep moving slowly around the feature.' : 'Ready when you are.')
                        : (waiting ? 'Point the phone at the feature while ARKit starts.' : 'Move slower and keep the feature in view.'),
                    style: const TextStyle(fontSize: 12, color: Fs.muted)),
              ]),
            ),
          ]),
        ),
        if (rec) ...[
          const SizedBox(height: 8),
          Row(children: [
            Expanded(child: StatTile('${status['keyframes'] ?? 0}', 'frames')),
            const SizedBox(width: 8),
            Expanded(child: StatTile('${status['photos'] ?? 0}', 'photos')),
            const SizedBox(width: 8),
            Expanded(child: lidar ? StatTile(_fmtCount(status['fusedPoints']), 'points') : StatTile(paused ? 'paused' : 'live', 'state')),
          ]),
        ],
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: Wrap(children: [
            if (lidar && depth.isNotEmpty) _chip('depth valid ${_pct(depth['valid_fraction'])} · high conf ${_pct(conf['high'])}', icon: Icons.sensors_rounded),
            _chip('blur ≈ ${blur.toStringAsFixed(1)} px', icon: Icons.blur_on_rounded, warn: blurry),
            if (status['thermal'] != null && status['thermal'] != 'nominal') _chip('thermal ${status['thermal']}', icon: Icons.thermostat_rounded, warn: true),
            if (rec && paused) _chip('PAUSED', warn: true),
          ]),
        ),
        if (warnings.isNotEmpty) Note(kind: TagKind.warn, child: Text(warnings.first)),
        const Spacer(),
        if (phase == _Phase.ready)
          Container(
            margin: const EdgeInsets.only(bottom: 10),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.94), borderRadius: BorderRadius.circular(Fs.cardRadius)),
            child: Text(
              rig
                  ? 'Rig mode: press Start, then clamp the phone on the rig within 5 seconds (cameras outward). Walk slowly; listen for the ticks.'
                  : 'Move slowly around the feature. Keep it in frame at 0.5–2 m. Avoid wet, shiny or featureless surfaces.',
              style: const TextStyle(color: Fs.ink2, fontSize: 13, height: 1.4),
              textAlign: TextAlign.center,
            ),
          ),
        _controls(),
        const SizedBox(height: 12),
      ]),
    );
  }

  String _fmtCount(dynamic v) {
    final n = (v as num?)?.toInt() ?? 0;
    if (n >= 1000000) return '${(n / 1e6).toStringAsFixed(1)}M';
    if (n >= 1000) return '${(n / 1000).toStringAsFixed(0)}k';
    return '$n';
  }

  Widget _square(IconData icon, String tip, VoidCallback onTap) => SizedBox(
        width: Fs.buttonHeight,
        height: Fs.buttonHeight,
        child: IconButton(
          tooltip: tip,
          onPressed: onTap,
          style: IconButton.styleFrom(backgroundColor: Fs.quiet, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Fs.buttonRadius))),
          icon: Icon(icon, color: Fs.ink),
        ),
      );

  Widget _controls() {
    final rec = phase == _Phase.recording;
    final ready = phase == _Phase.ready;
    final label = ready ? 'Start' : (rec ? 'Stop & save' : (phase == _Phase.preparing ? 'Starting camera…' : phase.name));
    final link = AppState.I.ble;
    final remoteLine = !(widget.remoteRig || _lastSaved != null)
        ? null
        : [
            link.paired ? 'Controlled from ${link.desktopInfo?['name'] ?? 'the Mac'}' : (link.reconnecting ? 'Reconnecting to the Mac…' : 'Not connected to the Mac'),
            if (_lastSaved != null) 'Last: $_lastSaved',
          ].join('\n');
    return Column(mainAxisSize: MainAxisSize.min, children: [
      if (remoteLine != null)
        Container(
          width: double.infinity,
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(color: Fs.card, borderRadius: BorderRadius.circular(16)),
          child: Text(remoteLine, style: const TextStyle(color: Fs.ink, fontSize: 13, fontWeight: FontWeight.w600)),
        ),
      _controlBar(ready, rec, label),
    ]);
  }

  Widget _controlBar(bool ready, bool rec, String label) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(color: Fs.card, borderRadius: BorderRadius.circular(24)),
      child: Row(children: [
        if (rec) ...[
          _square(paused ? Icons.play_arrow_rounded : Icons.pause_rounded, paused ? 'Resume' : 'Pause', () async {
            paused ? await Scanner.resume() : await Scanner.pause();
            setState(() => paused = !paused);
          }),
          const SizedBox(width: 10),
        ],
        Expanded(
          child: FilledButton(
            style: FilledButton.styleFrom(backgroundColor: rec ? Fs.record : Fs.moss),
            onPressed: ready ? () => _start() : (rec ? () => _stop('user') : null),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              if (rec) ...[Container(width: 14, height: 14, decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(4))), const SizedBox(width: 10)],
              if (ready) ...[const Icon(Icons.fiber_manual_record_rounded, size: 18), const SizedBox(width: 8)],
              Text(label),
            ]),
          ),
        ),
        if (rec) ...[
          const SizedBox(width: 10),
          _square(Icons.camera_rounded, 'Keyframe now', () {
            HapticFeedback.lightImpact();
            Scanner.captureNow();
          }),
        ],
      ]),
    );
  }

  /// Full light screen used for countdown, rig lock, saving and errors: title area, centred content, bottom action.
  Widget _panel({required Widget child, Widget? bottom, String? title, Widget? subtitle}) => Container(
        color: Fs.ground,
        child: SafeArea(
          child: Column(children: [
            if (title != null) ScreenHeader(title: title, subtitle: subtitle) else const SizedBox(height: 104),
            // shrink rather than overlap when the content is taller than the space (landscape on the rig)
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: Fs.side),
                child: LayoutBuilder(
                  builder: (_, c) => Center(
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: SizedBox(width: c.maxWidth, child: child),
                    ),
                  ),
                ),
              ),
            ),
            if (bottom != null) Padding(padding: const EdgeInsets.fromLTRB(Fs.side, 8, Fs.side, 16), child: SizedBox(width: double.infinity, child: bottom)),
          ]),
        ),
      );

  Widget _countdownView() {
    final t = Theme.of(context).textTheme;
    return _panel(
      title: 'Rig mode',
      subtitle: const Text('Recording starts by itself'),
      bottom: OutlinedButton(onPressed: () => setState(() => phase = _Phase.ready), child: const Text('Cancel')),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        SizedBox(
          width: 280,
          height: 190,
          child: Stack(children: [
            const Positioned(left: 0, bottom: 0, child: Pebble(width: 190, semanticLabel: 'A rock waiting for the countdown')),
            Positioned(
              right: 0,
              top: 0,
              child: Container(
                width: 104,
                height: 104,
                alignment: Alignment.center,
                decoration: BoxDecoration(color: Fs.card, shape: BoxShape.circle, border: Border.all(color: Fs.moss, width: 3)),
                child: Text('$countdown', style: const TextStyle(fontSize: 56, fontWeight: FontWeight.w800, color: Fs.moss, height: 1)),
              ),
            ),
          ]),
        ),
        const SizedBox(height: 20),
        Text('Mount the phone on the rig', style: t.headlineSmall, textAlign: TextAlign.center),
        const SizedBox(height: 8),
        Text('Landscape, screen toward the laptop lid, cameras facing the feature. A tick sounds for every photo.',
            style: t.bodyMedium?.copyWith(color: Fs.muted), textAlign: TextAlign.center),
        const SizedBox(height: 20),
        FsCard(
          child: Row(children: [
            const RigDrawing(width: 110),
            const SizedBox(width: 14),
            Expanded(child: Text('Phone on the back of the lid, cameras pointing at the rock.', style: t.bodySmall?.copyWith(color: Fs.ink2))),
          ]),
        ),
      ]),
    );
  }

  Widget _rigCover() {
    final ok = status['tracking'] == 'normal';
    final landscape = MediaQuery.orientationOf(context) == Orientation.landscape;
    final t = Theme.of(context).textTheme;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onLongPressStart: (_) => _holdStart(),
      onLongPressEnd: (_) => _holdEnd(),
      onTapDown: (_) => _holdStart(),
      onTapUp: (_) => _holdEnd(),
      onTapCancel: _holdEnd,
      child: _panel(
        title: 'Recording',
        subtitle: const StatusLine('Screen locked · dimmed to 5%', dot: Fs.record),
        bottom: Container(
          height: Fs.buttonHeight,
          alignment: Alignment.center,
          decoration: BoxDecoration(borderRadius: BorderRadius.circular(Fs.buttonRadius), border: Border.all(color: Fs.lineStrong, width: 1.5)),
          child: const Text('Hold anywhere for 2 seconds to unlock', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: Fs.ink2)),
        ),
        child: Builder(builder: (context) {
          final rock = Pebble(width: landscape ? 150 : 170, mood: ok ? PebbleMood.sleeping : PebbleMood.worried);
          final count = Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: landscape ? CrossAxisAlignment.start : CrossAxisAlignment.center, children: [
            Text('${status['keyframes'] ?? 0}',
                style: TextStyle(fontSize: 60, fontWeight: FontWeight.w800, height: 1, color: ok ? Fs.moss : Fs.amberInk, fontFeatures: const [FontFeature.tabularFigures()])),
            const SizedBox(height: 6),
            Text(ok ? 'frames recorded' : 'Tracking limited. Move slower.', style: t.titleSmall?.copyWith(color: Fs.ink2)),
          ]);
          // on the rig the phone is landscape: rock and count side by side
          return landscape
              ? Row(mainAxisAlignment: MainAxisAlignment.center, children: [rock, const SizedBox(width: 32), count])
              : Column(mainAxisSize: MainAxisSize.min, children: [rock, const SizedBox(height: 16), count]);
        }),
      ),
    );
  }

  Widget _savingView() => _panel(
        child: const Column(mainAxisSize: MainAxisSize.min, children: [
          Pebble(width: 150),
          SizedBox(height: 24),
          SizedBox(width: 160, child: LinearProgressIndicator(minHeight: 6, borderRadius: BorderRadius.all(Radius.circular(3)))),
          SizedBox(height: 16),
          Text('Saving point cloud, mesh and hashes…', style: TextStyle(color: Fs.ink2, fontSize: 15, fontWeight: FontWeight.w700)),
        ]),
      );

  Widget _failedView() => _panel(
        bottom: FilledButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Back')),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Pebble(width: 150, mood: PebbleMood.worried),
          const SizedBox(height: 20),
          Text(error ?? 'Something went wrong', style: const TextStyle(color: Fs.ink, fontSize: 15, height: 1.45), textAlign: TextAlign.center),
        ]),
      );
}

// Draft written with AI assistance (Claude, Anthropic); disclosed per the Space Apps AI policy.

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../service/app_state.dart';
import '../service/models.dart';
import '../widgets/common.dart';

class PairingScreen extends StatefulWidget {
  const PairingScreen({super.key});
  @override
  State<PairingScreen> createState() => _PairingScreenState();
}

class _PairingScreenState extends State<PairingScreen> {
  Timer? _poll;
  Map<String, dynamic> _st = {};
  String? _error;
  bool _busy = false;
  final _title = TextEditingController();
  String _feature = 'other';
  static const _features = {
    'rock_face': 'Rock face',
    'boulder': 'Boulder',
    'boulder_field': 'Boulder field',
    'outcrop': 'Outcrop',
    'ground': 'Ground',
    'other': 'Other',
  };

  static const _bleEvents = {
    'pairing_opened',
    'phone_paired',
    'phone_reconnected',
    'pair_rejected',
    'remote_command',
    'phone_ack',
    'command_failed',
    'phone_capture_state',
    'phone_capture_complete',
    'phone_disconnected',
    'phone_error',
    'message_dropped',
  };

  @override
  void initState() {
    super.initState();
    _refresh();
    _poll = Timer.periodic(const Duration(seconds: 1), (_) => _refresh());
  }

  @override
  void dispose() {
    _title.dispose();
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    if (!mounted) return;
    final s = AppScope.read(context);
    if (s.api == null) return;
    try {
      final r = asMap(await s.api!.getJson('/api/ble/status', timeout: const Duration(seconds: 3)));
      if (mounted) setState(() => _st = r);
    } catch (_) {}
  }

  Future<void> _pair() async {
    final s = AppScope.read(context);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await s.ble.pairPhone();
      await _refresh();
    } catch (e) {
      _error = errText(e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Id of the last command sent from here, and its type, until the phone answers (or the retry runs out).
  String? _sentId;
  String? _sentType;

  Future<void> _send(String central, String type) async {
    final s = AppScope.read(context);
    try {
      final r = asMap(await s.api!.postJson('/api/ble/send', {
        'central': central,
        'type': type,
        if (type == 'start_capture' && _title.text.trim().isNotEmpty) 'title': _title.text.trim(),
        if (type == 'start_capture') 'feature_type': _feature,
      }));
      if (!mounted) return;
      setState(() {
        _sentId = asStr(asMap(r['sent'])['id']);
        _sentType = type;
      });
      // the title belongs to this one scan; clear it so the next scan doesn't repeat it by accident
      if (type == 'start_capture') _title.clear();
    } catch (e) {
      if (mounted) showSnack(context, errText(e), error: true);
    }
  }

  /// The answer to the command sent from here, once it has arrived.
  Map<String, dynamic>? _answer(AppState s) {
    if (_sentId == null) return null;
    for (final e in s.events.reversed) {
      if ((e['type'] == 'phone_ack' || e['type'] == 'command_failed') && e['ref'] == _sentId) return e;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    final t = Theme.of(context);
    final ble = s.ble;
    final phones = asList(_st['phones']).map(asMap).toList();

    final children = <Widget>[
      if (!ble.available) _unavailable(s, t) else ...[
        for (final p in phones) ...[_rigPanel(s, t, p), const SizedBox(height: 16)],
        _pairCard(t, again: phones.isNotEmpty),
        if (phones.isEmpty) ...[const SizedBox(height: 16), _howTo(t)],
      ],
      const SizedBox(height: 16),
      _details(s, t),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const PageHeader(
          'Phone',
          subtitle: 'Run the iPhone on the rig from here: pair once, then start and stop its scans. Plugged in by cable, '
              'each finished scan copies into Library by itself.',
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 32),
            children: [
              Align(
                alignment: Alignment.topLeft,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 820),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _unavailable(AppState s, ThemeData t) => SectionCard(
    title: Platform.isMacOS ? 'Bluetooth is not available' : 'Phone pairing needs the macOS build',
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          Platform.isMacOS
              ? (s.ble.unavailableReason ?? 'The Bluetooth bridge did not start in this build.')
              : 'Pairing uses the CoreBluetooth bridge, which only the macOS build includes. Everything else works on this computer: '
                    'export a scan from the iPhone app as a .zip and import it in Library.',
          style: t.textTheme.bodyMedium,
        ),
        const SizedBox(height: 12),
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton(onPressed: () => s.go(Section.library), child: const Text('Go to Library')),
        ),
      ],
    ),
  );

  Widget _howTo(ThemeData t) {
    Widget step(String n, String head, String body) => Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 24,
            height: 24,
            alignment: Alignment.center,
            decoration: const BoxDecoration(color: FsPalette.surveyTint, shape: BoxShape.circle),
            child: Text(n, style: t.textTheme.labelMedium?.copyWith(color: FsPalette.surveyDeep, fontWeight: FontWeight.w700)),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text.rich(
              TextSpan(children: [
                TextSpan(text: '$head  ', style: const TextStyle(fontWeight: FontWeight.w600)),
                TextSpan(text: body),
              ]),
              style: t.textTheme.bodyMedium,
            ),
          ),
        ],
      ),
    );
    return SectionCard(
      title: 'Putting the phone on the rig',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          step('1', 'Pair.', 'Click Pair a phone above. On the iPhone open Field Scan › Connect › Find Field Station and type the code.'),
          step('2', 'Plug in.', 'Connect the phone to this Mac with a cable (unlocked, "Trust This Computer"). Finished scans then copy here by themselves.'),
          step('3', 'Rig mode.', 'On the phone tap "Rig mode: let the Mac run the scans", then mount it. Its screen stays on; you do not need to touch it again.'),
          step('4', 'Scan.', 'Start and stop from here. Each scan appears in Library a few seconds after it stops.'),
        ],
      ),
    );
  }

  Widget _pairCard(ThemeData t, {required bool again}) {
    final open = _st['open'] == true;
    return SectionCard(
      title: again ? 'Pair another phone' : 'Pair a phone',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (open) ...[
            Text('Type this code in the iPhone app (Connect › Find Field Station):', style: t.textTheme.bodyMedium),
            const SizedBox(height: 8),
            SelectableText(
              _spaced(asStr(_st['code'])),
              style: t.textTheme.displaySmall?.copyWith(fontSize: 44, fontWeight: FontWeight.w600, letterSpacing: 8, color: FsPalette.surveyDeep),
            ),
            const SizedBox(height: 4),
            Text('Expires in ${_st['expires_in_s']} s. One phone per code; locks after 3 wrong attempts.', style: t.textTheme.bodySmall),
          ] else ...[
            if (_st['locked'] == true) ...[
              const Hint('Locked after 3 wrong codes. Start a new pairing window.', color: FsPalette.record, icon: Icons.lock_outline),
              const SizedBox(height: 6),
            ],
            Text(
              'Shows a 6-digit code for 120 s. Only someone who can see this screen can pair; the pairing lasts 12 hours.',
              style: t.textTheme.bodyMedium,
            ),
          ],
          const SizedBox(height: 12),
          (again ? OutlinedButton.new : FilledButton.new)(
            onPressed: _busy || open ? null : _pair,
            child: Text(open ? 'Waiting for the phone…' : (again ? 'Pair another phone' : 'Pair a phone')),
          ),
          if (_error != null) ...[const SizedBox(height: 8), ErrorBox(_error!)],
        ],
      ),
    );
  }

  /// The control panel for one paired phone: what it is doing, the buttons, the next scan's name, the cable and
  /// the last scan.
  Widget _rigPanel(AppState s, ThemeData t, Map<String, dynamic> p) {
    final c = asStr(p['central']);
    final name = asStr(p['phone_name'], 'iPhone');
    final ps = asMap(p['phone_state']);
    final st = asStr(ps['state'], 'idle');
    final rec = st == 'recording' || st == 'paused';
    final saving = st == 'saving';
    final inRange = s.ble.centrals.contains(c);
    final mins = ((asInt(p['expires_in_s']) ?? 0) / 60).round();
    final answer = _answer(s);
    final waiting = _sentId != null && answer == null;

    // last scan the phone finished, and whether it has reached Library yet
    final done = s.events.lastWhere((e) => e['type'] == 'phone_capture_complete', orElse: () => const {});
    final doneId = asStr(done['scan_id']);
    final imported = doneId.isEmpty
        ? const <String, dynamic>{}
        : s.events.lastWhere((e) => e['type'] == 'scan_imported' && e['scan_id'] == doneId, orElse: () => const {});
    final importFailed = doneId.isNotEmpty &&
        s.events.any((e) => e['type'] == 'usb_import_failed' && e['scan_id'] == doneId) &&
        imported.isEmpty;

    final u = s.usbSync;
    final wired = asList(u['devices']).isNotEmpty;
    final autoOn = u['enabled'] == true && u['available'] != false;

    final accent = rec ? FsPalette.record : (inRange ? FsPalette.sensor : FsPalette.caution);
    final String big;
    if (!inRange) {
      big = 'Out of range';
    } else if (rec) {
      big = '${st == 'paused' ? 'Paused' : 'Recording'}  ${_clock(asInt(ps['elapsed_ms']) ?? 0)}';
    } else if (saving) {
      big = 'Saving…';
    } else {
      big = 'Ready';
    }
    final String small;
    if (!inRange) {
      small = 'The link dropped. The phone reconnects by itself when it is back in range (no code needed for $mins more minutes).';
    } else if (rec || saving) {
      small = '${ps['frames_recorded'] ?? 0} keyframes · tracking ${asStr(ps['tracking'], '—')}';
    } else {
      small = 'Press Start: the phone opens its scanner if needed and begins recording.';
    }

    String? problem;
    if (answer != null && !(answer['type'] == 'phone_ack' && answer['ok'] == true)) {
      final what = (_sentType ?? 'command').replaceAll('_', ' ');
      problem = answer['type'] == 'command_failed'
          ? 'No answer to $what. The phone may be locked or Field Scan may be in the background: Bluetooth only works while '
                'the app is open. Open Field Scan on the phone (Rig mode keeps it awake), then try again.'
          : 'The phone did not $what: ${asStr(answer['error'], 'no reason given')}';
    }

    final Widget mainButton = rec
        ? FilledButton.icon(
            style: FilledButton.styleFrom(backgroundColor: FsPalette.record, minimumSize: const Size(180, 48)),
            onPressed: waiting || !inRange ? null : () => _send(c, 'stop_capture'),
            icon: _btnIcon(waiting && _sentType == 'stop_capture', Icons.stop_rounded),
            label: const Text('Stop & save'),
          )
        : FilledButton.icon(
            style: FilledButton.styleFrom(backgroundColor: FsPalette.sensor, minimumSize: const Size(180, 48)),
            onPressed: waiting || saving || !inRange ? null : () => _send(c, 'start_capture'),
            icon: _btnIcon(waiting && _sentType == 'start_capture', Icons.fiber_manual_record_rounded),
            label: Text(waiting && _sentType == 'start_capture' ? 'Starting…' : 'Start scan'),
          );

    return Panel(
      child: Container(
        decoration: BoxDecoration(border: Border(left: BorderSide(color: accent, width: 4))),
        padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Icon(Icons.phone_iphone, size: 20, color: FsPalette.ink),
                const SizedBox(width: 8),
                Expanded(child: Text(name, style: t.textTheme.titleMedium)),
                _chip(t, inRange ? 'Connected' : 'Reconnecting', inRange ? FsPalette.sensor : FsPalette.caution,
                    inRange ? Icons.bluetooth_connected : Icons.bluetooth_searching),
                const SizedBox(width: 6),
                _chip(t, wired ? 'Cable' : 'No cable', wired ? FsPalette.sensor : FsPalette.inkMuted,
                    wired ? Icons.usb : Icons.usb_off),
              ],
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                if (rec) ...[const _Pulse(), const SizedBox(width: 10)],
                Text(big, style: t.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w600, color: accent == FsPalette.sensor ? FsPalette.ink : accent,
                    fontFeatures: const [FontFeature.tabularFigures()])),
              ],
            ),
            const SizedBox(height: 2),
            Text(small, style: t.textTheme.bodyMedium?.copyWith(color: FsPalette.inkMuted)),
            const SizedBox(height: 16),
            if (!rec) ...[
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _title,
                      enabled: inRange,
                      decoration: const InputDecoration(
                        labelText: 'Name for the next scan (optional)',
                        hintText: 'e.g. Boulder A, north face',
                        isDense: true,
                      ),
                      onSubmitted: (_) => waiting || saving || !inRange ? null : _send(c, 'start_capture'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  SizedBox(
                    width: 170,
                    child: DropdownButtonFormField<String>(
                      initialValue: _feature,
                      isDense: true,
                      decoration: const InputDecoration(labelText: 'Feature type'),
                      items: [for (final e in _features.entries) DropdownMenuItem(value: e.key, child: Text(e.value))],
                      onChanged: (v) => setState(() => _feature = v ?? 'other'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
            ],
            Wrap(
              spacing: 10,
              runSpacing: 10,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                mainButton,
                if (rec)
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(minimumSize: const Size(0, 48)),
                    onPressed: st == 'recording' && !waiting ? () => _send(c, 'capture_now') : null,
                    icon: const Icon(Icons.camera_outlined, size: 18),
                    label: const Text('Keyframe now'),
                  ),
                if (waiting) Text('Waiting for the phone…', style: t.textTheme.bodySmall),
              ],
            ),
            if (problem != null) ...[const SizedBox(height: 12), ErrorBox(problem)],
            const SizedBox(height: 16),
            const Divider(height: 1, color: FsPalette.ruleLight),
            const SizedBox(height: 12),
            Hint(
              !autoOn
                  ? (u['available'] == false
                        ? 'Automatic copy over the cable is not available here: ${asStr(u['reason'])}'
                        : 'Automatic copy is off (Library). Scans stay on the phone until you import them.')
                  : wired
                  ? 'Plugged in: each finished scan copies into Library by itself, with every file\'s SHA-256 checked.'
                  : 'Not plugged in: scans stay on the phone and copy over as soon as it is connected by cable.',
              icon: wired && autoOn ? Icons.check_circle_outline : Icons.info_outline,
              color: wired && autoOn ? FsPalette.sensor : null,
            ),
            if (doneId.isNotEmpty) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'Last scan: ${asStr(imported['title']).isNotEmpty ? '"${asStr(imported['title'])}" · ' : ''}'
                      '${done['keyframes'] ?? 0} keyframes · ${_thousands(asInt(done['points']) ?? 0)} points · '
                      '${imported.isNotEmpty ? 'in Library' : (importFailed ? 'copy failed (see Library)' : (wired && autoOn ? 'copying…' : 'on the phone'))}',
                      style: t.textTheme.bodySmall,
                    ),
                  ),
                  if (imported.isNotEmpty)
                    TextButton(onPressed: () => s.go(Section.viewer, scanId: doneId), child: const Text('Open')),
                ],
              ),
            ],
            const SizedBox(height: 4),
            Text(
              'Paired ${utcText(p['paired_utc'])} UTC · pairing valid for ${mins ~/ 60} h ${mins % 60} min more. '
              'The phone obeys only while "Let the paired Mac control capture" is on.',
              style: t.textTheme.bodySmall?.copyWith(color: FsPalette.inkMuted),
            ),
          ],
        ),
      ),
    );
  }

  Widget _btnIcon(bool spinning, IconData icon) => spinning
      ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
      : Icon(icon, size: 20);

  Widget _chip(ThemeData t, String text, Color c, IconData icon) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
    decoration: BoxDecoration(border: Border.all(color: c.withValues(alpha: 0.45)), borderRadius: BorderRadius.circular(12)),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 13, color: c),
        const SizedBox(width: 4),
        Text(text, style: t.textTheme.labelSmall?.copyWith(color: c, fontWeight: FontWeight.w600)),
      ],
    ),
  );

  static String _clock(int ms) {
    final sec = ms ~/ 1000;
    return '${sec ~/ 60}:${(sec % 60).toString().padLeft(2, '0')}';
  }

  static String _thousands(int n) => n.toString().replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (_) => ',');

  /// Radio state, command history and the raw event log: useful when something goes wrong, folded away otherwise.
  Widget _details(AppState s, ThemeData t) {
    final ble = s.ble;
    final evs = s.events.where((e) => _bleEvents.contains(e['type'])).toList().reversed.take(60).toList();
    final outcomes = s.events
        .where((e) => e['type'] == 'phone_ack' || e['type'] == 'command_failed' || e['type'] == 'phone_error')
        .toList()
        .reversed
        .take(6)
        .toList();
    final muted = t.textTheme.bodyMedium?.copyWith(color: FsPalette.inkMuted);
    final bad = t.textTheme.bodySmall?.copyWith(color: FsPalette.record, fontWeight: FontWeight.w600);
    return Panel(
      child: Theme(
        data: t.copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          tilePadding: const EdgeInsets.symmetric(horizontal: 18),
          childrenPadding: const EdgeInsets.fromLTRB(18, 0, 18, 18),
          expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
          title: Text('Connection details', style: t.textTheme.titleSmall),
          subtitle: Text(
            ble.available
                ? 'Bluetooth ${ble.bluetooth}${ble.advertising ? ', advertising' : ''} · ${ble.centrals.length} connected'
                : 'Bluetooth not available',
            style: t.textTheme.bodySmall,
          ),
          children: [
            if (ble.available) ...[
              KV('Radio', ble.bluetooth),
              KV('Advertising', ble.advertising ? 'yes, as "${s.health['app'] ?? 'Field Station'}"' : 'no'),
              KV('Connected phones', ble.centrals.isEmpty ? 'none' : ble.centrals.length.toString()),
              if (ble.bluetooth == 'unauthorized')
                Text('Bluetooth permission denied. In System Settings, Privacy & Security, Bluetooth, allow Field Station.', style: bad),
              if (ble.bluetooth == 'poweredOff') Text('Bluetooth is off. Turn it on in Control Centre.', style: bad),
              if (ble.lastError != null) Text('Last error: ${ble.lastError}', style: bad),
              if (ble.advertising) ...[
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: OutlinedButton(onPressed: ble.stopAdvertising, child: const Text('Stop advertising')),
                ),
              ],
              if (outcomes.isNotEmpty) ...[const SizedBox(height: 14), _commandCard(t, outcomes)],
              const SizedBox(height: 14),
              Text('Bluetooth events', style: t.textTheme.labelLarge),
              const SizedBox(height: 6),
              evs.isEmpty
                  ? Text('No events yet.', style: muted)
                  : Container(
                      padding: const EdgeInsets.all(10),
                      color: FsPalette.sheetAlt,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          for (final e in evs)
                            Text(
                              '${asStr(e['t_utc']).length > 19 ? asStr(e['t_utc']).substring(11, 19) : ''}  ${e['type']}  '
                              '${e.entries.where((x) => !const {'type', 't_utc', 'seq'}.contains(x.key)).map((x) => '${x.key}=${x.value}').join(' ')}',
                              style: mono(t.textTheme.bodySmall, size: 11)?.copyWith(color: FsPalette.ink),
                            ),
                        ],
                      ),
                    ),
            ],
            const SizedBox(height: 14),
            Text(
              'Bluetooth carries control messages only (pairing, start, stop, status). Scans move over the cable, or as .zip files '
              '(AirDrop, Files) imported in Library; every import is checked against the SHA-256 hashes in the scan\'s scan.json.',
              style: t.textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }

  /// Phone command results, newest first. Red only when the latest result is a failure.
  Widget _commandCard(ThemeData t, List<Map<String, dynamic>> outcomes) {
    bool ok(Map<String, dynamic> e) => e['type'] == 'phone_ack' && e['ok'] == true;
    const done = {'start_capture': 'started recording', 'stop_capture': 'stopped recording', 'capture_now': 'took a keyframe'};
    String text(Map<String, dynamic> e) {
      final who = asStr(e['phone_name'], 'phone');
      final when = asStr(e['t_utc']).length > 19 ? asStr(e['t_utc']).substring(11, 19) : '';
      switch (e['type']) {
        case 'phone_ack':
          return ok(e)
              ? '$when  $who ${done[e['command']] ?? 'did ${e['command'] ?? 'the command'}'}'
              : '$when  $who refused ${e['command'] ?? 'a command'}: ${asStr(e['error'], '(no reason given)')}';
        case 'command_failed':
          return '$when  No answer from $who to ${e['command']} after one retry (5 s each).';
        default:
          return '$when  $who reported error ${e['code'] ?? ''}: ${asStr(e['message'])}';
      }
    }

    final failedNow = !ok(outcomes.first);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: failedNow ? FsPalette.recordTint : FsPalette.sheet,
        borderRadius: BorderRadius.circular(2),
        border: Border.all(color: failedNow ? FsPalette.recordRule : FsPalette.rule),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(failedNow ? Icons.error_outline : Icons.check_circle_outline, color: failedNow ? FsPalette.record : FsPalette.sensor, size: 18),
              const SizedBox(width: 8),
              Text(failedNow ? 'The phone did not carry out the last command' : 'Phone commands', style: t.textTheme.titleSmall),
            ],
          ),
          const SizedBox(height: 8),
          for (final e in outcomes)
            Padding(
              padding: const EdgeInsets.only(top: 3),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 3),
                    child: Icon(ok(e) ? Icons.check : Icons.close, size: 14, color: ok(e) ? FsPalette.sensor : FsPalette.record),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: SelectableText(text(e), style: t.textTheme.bodyMedium?.copyWith(color: ok(e) ? FsPalette.ink : FsPalette.recordInk)),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  static String _spaced(String code) => code.length == 6 ? '${code.substring(0, 3)} ${code.substring(3)}' : code;
}

/// A small red dot that pulses while the phone records.
class _Pulse extends StatefulWidget {
  const _Pulse();
  @override
  State<_Pulse> createState() => _PulseState();
}

class _PulseState extends State<_Pulse> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 900))..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FadeTransition(
    opacity: Tween(begin: 0.35, end: 1.0).animate(_c),
    child: Container(width: 14, height: 14, decoration: const BoxDecoration(color: FsPalette.record, shape: BoxShape.circle)),
  );
}

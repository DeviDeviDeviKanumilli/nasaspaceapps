import 'dart:async';

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

  static const _bleEvents = {
    'pairing_opened', 'phone_paired', 'pair_rejected', 'remote_command', 'phone_ack', 'command_failed',
    'phone_capture_state', 'phone_capture_complete', 'phone_disconnected', 'phone_error', 'message_dropped',
  };

  @override
  void initState() {
    super.initState();
    _refresh();
    _poll = Timer.periodic(const Duration(seconds: 1), (_) => _refresh());
  }

  @override
  void dispose() {
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

  Future<void> _send(String central, String type) async {
    final s = AppScope.read(context);
    try {
      await s.api!.postJson('/api/ble/send', {'central': central, 'type': type});
      if (mounted) showSnack(context, 'Sent $type; waiting for the phone\'s ack (5 s, one retry).');
    } catch (e) {
      if (mounted) showSnack(context, errText(e), error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    final t = Theme.of(context);
    final ble = s.ble;
    final open = _st['open'] == true;
    final phones = asList(_st['phones']).map(asMap).toList();
    final evs = s.events.where((e) => _bleEvents.contains(e['type'])).toList().reversed.take(60).toList();
    final failures = s.events
        .where((e) => (e['type'] == 'phone_ack' && e['ok'] == false) || e['type'] == 'command_failed' || e['type'] == 'phone_error')
        .toList()
        .reversed
        .take(5)
        .toList();
    return ListView(padding: const EdgeInsets.only(bottom: 32), children: [
      const PageHeader('Pairing',
          subtitle: 'Pair the iPhone app over Bluetooth LE to start/stop captures remotely. Bluetooth carries control messages only.'),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (!ble.available)
            ErrorBox(ble.unavailableReason ?? 'Bluetooth bridge unavailable in this build')
          else
            SectionCard(
              title: 'Bluetooth',
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                KV('Radio', ble.bluetooth),
                KV('Advertising', ble.advertising ? 'yes, as "${s.health['app'] ?? 'Field Station'} …"' : 'no'),
                KV('Connected phones (BLE)', ble.centrals.isEmpty ? 'none' : ble.centrals.length.toString()),
                if (ble.bluetooth == 'unauthorized')
                  Text('Bluetooth permission denied: System Settings › Privacy & Security › Bluetooth, allow Field Station.',
                      style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.error)),
                if (ble.bluetooth == 'poweredOff') Text('Bluetooth is off. Turn it on in Control Centre.', style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.error)),
                if (ble.lastError != null) Text('Last error: ${ble.lastError}', style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.error)),
                if (ble.advertising) ...[
                  const SizedBox(height: 8),
                  OutlinedButton(onPressed: ble.stopAdvertising, child: const Text('Stop advertising')),
                ],
              ]),
            ),
          const SizedBox(height: 16),
          SectionCard(
            title: 'Pair a phone',
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              if (open) ...[
                Text('Enter this code in the iPhone app:', style: t.textTheme.bodyMedium),
                const SizedBox(height: 8),
                SelectableText(
                  _spaced(asStr(_st['code'])),
                  style: t.textTheme.displayMedium?.copyWith(
                      fontWeight: FontWeight.w600, letterSpacing: 6, color: t.colorScheme.primary, fontFeatures: const [FontFeature.tabularFigures()]),
                ),
                Text('Expires in ${_st['expires_in_s']} s · one phone per code · locks after 3 wrong attempts',
                    style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
              ] else ...[
                if (_st['locked'] == true)
                  Text('Locked after 3 wrong codes. Start a new pairing window.', style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.error)),
                Text('A new 6-digit code appears here for 120 s. Only someone who can see this screen can pair.', style: t.textTheme.bodyMedium),
              ],
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: _busy || open ? null : _pair,
                icon: const Icon(Icons.bluetooth_searching),
                label: Text(open ? 'Waiting for the phone…' : 'Pair a phone'),
              ),
              if (_error != null) ...[const SizedBox(height: 8), ErrorBox(_error!)],
            ]),
          ),
          if (failures.isNotEmpty) ...[
            const SizedBox(height: 16),
            _failureCard(t, failures),
          ],
          const SizedBox(height: 16),
          SectionCard(
            title: 'Paired phones',
            child: phones.isEmpty
                ? Text('None.', style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant))
                : Column(children: [
                    for (final p in phones)
                      Container(
                        margin: const EdgeInsets.only(bottom: 8),
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(border: Border.all(color: t.colorScheme.outlineVariant), borderRadius: BorderRadius.circular(8)),
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(asStr(p['phone_name'], 'iPhone'), style: t.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w600)),
                          Text('paired ${p['paired_utc']} · session expires in ${((asInt(p['expires_in_s']) ?? 0) / 60).round()} min',
                              style: t.textTheme.bodySmall),
                          if (p['phone_state'] != null)
                            Text(
                                'phone: ${asMap(p['phone_state'])['state']} · ${asMap(p['phone_state'])['frames_recorded'] ?? 0} keyframes · tracking ${asMap(p['phone_state'])['tracking'] ?? '—'}',
                                style: t.textTheme.bodySmall),
                          const SizedBox(height: 8),
                          Wrap(spacing: 8, children: [
                            OutlinedButton(onPressed: () => _send(asStr(p['central']), 'start_capture'), child: const Text('Start phone capture')),
                            OutlinedButton(onPressed: () => _send(asStr(p['central']), 'stop_capture'), child: const Text('Stop')),
                            OutlinedButton(onPressed: () => _send(asStr(p['central']), 'capture_now'), child: const Text('Capture keyframe now')),
                          ]),
                          Text('The phone obeys only if "Let the paired Mac control capture" is on.',
                              style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
                        ]),
                      ),
                  ]),
          ),
          const SizedBox(height: 16),
          SectionCard(
            title: 'Moving scans',
            child: Text(
              'Bluetooth carries control messages only. Move scans by zip (AirDrop / Files / USB) → Library › Import. '
              'Imports are checked against the SHA-256 in each bundle\'s scan.json.',
              style: t.textTheme.bodyMedium,
            ),
          ),
          const SizedBox(height: 16),
          SectionCard(
            title: 'Bluetooth events',
            child: evs.isEmpty
                ? Text('No events yet.', style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant))
                : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    for (final e in evs)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 2),
                        child: Text(
                          '${asStr(e['t_utc']).length > 19 ? asStr(e['t_utc']).substring(11, 19) : ''}  ${e['type']}  '
                          '${e.entries.where((x) => !const {'type', 't_utc', 'seq'}.contains(x.key)).map((x) => '${x.key}=${x.value}').join(' ')}',
                          style: t.textTheme.bodySmall?.copyWith(fontFamily: 'Menlo', fontSize: 11),
                        ),
                      ),
                  ]),
          ),
        ]),
      ),
    ]);
  }

  Widget _failureCard(ThemeData t, List<Map<String, dynamic>> failures) {
    String text(Map<String, dynamic> e) {
      final who = asStr(e['phone_name'], 'phone');
      final when = asStr(e['t_utc']).length > 19 ? asStr(e['t_utc']).substring(11, 19) : '';
      switch (e['type']) {
        case 'phone_ack':
          return '$when  $who refused ${e['command'] ?? 'a command'}: ${asStr(e['error'], '(no reason given)')}';
        case 'command_failed':
          return '$when  No answer from $who to ${e['command']} after one retry (5 s each).';
        default:
          return '$when  $who reported error ${e['code'] ?? ''}: ${asStr(e['message'])}';
      }
    }

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: t.colorScheme.errorContainer.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: t.colorScheme.error, width: 1.5),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(Icons.error_outline, color: t.colorScheme.error),
          const SizedBox(width: 8),
          Text('The phone did not carry out a command', style: t.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
        ]),
        const SizedBox(height: 8),
        for (final e in failures)
          Padding(
            padding: const EdgeInsets.only(top: 3),
            child: SelectableText(text(e), style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onErrorContainer)),
          ),
      ]),
    );
  }

  static String _spaced(String code) => code.length == 6 ? '${code.substring(0, 3)} ${code.substring(3)}' : code;
}

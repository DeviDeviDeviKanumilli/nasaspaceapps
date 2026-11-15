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

  static const _bleEvents = {
    'pairing_opened',
    'phone_paired',
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
      if (mounted) showSnack(context, 'Sent ${type.replaceAll('_', ' ')}. Waiting for the phone to confirm (5 s, one retry).');
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
    final muted = t.textTheme.bodyMedium?.copyWith(color: FsPalette.inkMuted);
    final bad = t.textTheme.bodySmall?.copyWith(color: FsPalette.record, fontWeight: FontWeight.w600);

    final children = <Widget>[
      if (!ble.available)
        SectionCard(
          title: Platform.isMacOS ? 'Bluetooth is not available' : 'Phone pairing needs the macOS build',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                Platform.isMacOS
                    ? (ble.unavailableReason ?? 'The Bluetooth bridge did not start in this build.')
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
        )
      else
        SectionCard(
          title: 'Bluetooth',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
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
            ],
          ),
        ),
      if (ble.available) ...[
        const SizedBox(height: 16),
        SectionCard(
          title: 'Pair a phone',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (open) ...[
                Text('Enter this code in the iPhone app:', style: t.textTheme.bodyMedium),
                const SizedBox(height: 8),
                SelectableText(
                  _spaced(asStr(_st['code'])),
                  style: t.textTheme.displaySmall?.copyWith(fontSize: 40, fontWeight: FontWeight.w600, letterSpacing: 6),
                ),
                Text(
                  'Expires in ${_st['expires_in_s']} s. One phone per code; locks after 3 wrong attempts.',
                  style: t.textTheme.bodySmall,
                ),
              ] else ...[
                if (_st['locked'] == true)
                  Text(
                    'Locked after 3 wrong codes. Start a new pairing window.',
                    style: t.textTheme.bodyMedium?.copyWith(color: FsPalette.record),
                  ),
                Text(
                  'A new 6-digit code appears here for 120 s. Only someone who can see this screen can pair.',
                  style: t.textTheme.bodyMedium,
                ),
              ],
              const SizedBox(height: 12),
              FilledButton(onPressed: _busy || open ? null : _pair, child: Text(open ? 'Waiting for the phone' : 'Pair a phone')),
              if (_error != null) ...[const SizedBox(height: 8), ErrorBox(_error!)],
            ],
          ),
        ),
        if (failures.isNotEmpty) ...[const SizedBox(height: 16), _failureCard(t, failures)],
        const SizedBox(height: 16),
        SectionCard(
          title: 'Paired phones',
          child: phones.isEmpty
              ? Text('None.', style: muted)
              : Column(
                  children: [
                    for (final p in phones)
                      Container(
                        margin: const EdgeInsets.only(bottom: 8),
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          border: Border.all(color: FsPalette.rule),
                          borderRadius: BorderRadius.circular(2),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(asStr(p['phone_name'], 'iPhone'), style: t.textTheme.titleSmall),
                            Text(
                              'Paired ${utcText(p['paired_utc'])} UTC. Session expires in ${((asInt(p['expires_in_s']) ?? 0) / 60).round()} min.',
                              style: t.textTheme.bodySmall,
                            ),
                            if (p['phone_state'] != null)
                              Text(
                                'Phone ${asMap(p['phone_state'])['state']}, ${asMap(p['phone_state'])['frames_recorded'] ?? 0} keyframes, '
                                'tracking ${asMap(p['phone_state'])['tracking'] ?? '—'}',
                                style: t.textTheme.bodySmall,
                              ),
                            const SizedBox(height: 8),
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: [
                                OutlinedButton(
                                  onPressed: () => _send(asStr(p['central']), 'start_capture'),
                                  child: const Text('Start phone capture'),
                                ),
                                OutlinedButton(onPressed: () => _send(asStr(p['central']), 'stop_capture'), child: const Text('Stop')),
                                OutlinedButton(
                                  onPressed: () => _send(asStr(p['central']), 'capture_now'),
                                  child: const Text('Capture a keyframe now'),
                                ),
                              ],
                            ),
                            const SizedBox(height: 6),
                            Text('The phone obeys only if "Let the paired Mac control capture" is on.', style: t.textTheme.bodySmall),
                          ],
                        ),
                      ),
                  ],
                ),
        ),
      ],
      const SizedBox(height: 16),
      SectionCard(
        title: 'Moving scans',
        child: Text(
          'Bluetooth carries control messages only. Move scans as .zip files (AirDrop, Files or USB), then import them in Library. '
          'Each import is checked against the SHA-256 hashes in the bundle\'s scan.json.',
          style: t.textTheme.bodyMedium,
        ),
      ),
      if (ble.available) ...[
        const SizedBox(height: 16),
        SectionCard(
          title: 'Bluetooth events',
          child: evs.isEmpty
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
        ),
      ],
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const PageHeader(
          'Pairing',
          subtitle:
              'Pair the iPhone app over Bluetooth LE to start and stop its captures from here. Bluetooth carries control messages only.',
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
        color: FsPalette.recordTint,
        borderRadius: BorderRadius.circular(2),
        border: Border.all(color: FsPalette.recordRule),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.error_outline, color: FsPalette.record, size: 18),
              const SizedBox(width: 8),
              Text('The phone did not carry out a command', style: t.textTheme.titleSmall),
            ],
          ),
          const SizedBox(height: 8),
          for (final e in failures)
            Padding(
              padding: const EdgeInsets.only(top: 3),
              child: SelectableText(text(e), style: t.textTheme.bodyMedium?.copyWith(color: FsPalette.recordInk)),
            ),
        ],
      ),
    );
  }

  static String _spaced(String code) => code.length == 6 ? '${code.substring(0, 3)} ${code.substring(3)}' : code;
}

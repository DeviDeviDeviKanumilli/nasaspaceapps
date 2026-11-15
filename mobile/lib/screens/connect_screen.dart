import 'package:flutter/material.dart';

import '../core/app_state.dart';
import '../core/ble_link.dart';
import '../ui/style.dart';

class ConnectScreen extends StatefulWidget {
  const ConnectScreen({super.key});
  @override
  State<ConnectScreen> createState() => _ConnectScreenState();
}

class _ConnectScreenState extends State<ConnectScreen> {
  final code = TextEditingController();

  BleLink get link => AppState.I.ble;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return ListenableBuilder(
      listenable: link,
      builder: (context, _) {
        return Scaffold(
          body: SafeArea(
            bottom: false,
            child: Column(children: [
              ScreenHeader(
                title: 'Connect',
                subtitle: link.paired
                    ? StatusLine('Paired with ${link.desktopInfo?['name'] ?? 'Field Station'}')
                    : const Text('Pair with Field Station on the Mac'),
              ),
              Expanded(
                child: ListView(padding: const EdgeInsets.fromLTRB(Fs.side, 4, Fs.side, 24), children: [
                  if (link.error != null) ...[
                    Note(kind: TagKind.bad, leading: const Icon(Icons.error_outline_rounded, color: Fs.redInk), child: Text(link.error!)),
                    const SizedBox(height: 12),
                  ],
                  if (link.paired) _pairedCard(t) else _pairing(t),
                  const SizedBox(height: 12),
                  SwitchCard(
                    title: 'Let the paired Mac control capture',
                    subtitle: 'Start, stop and take a keyframe from the Mac while the phone sits on the rig.',
                    value: AppState.I.allowRemoteControl,
                    onChanged: (v) {
                      AppState.I.allowRemoteControl = v;
                      AppState.I.saveSettings();
                      setState(() {});
                    },
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'Bluetooth carries pairing and small commands only (start, stop, status). Move scans by Export, then AirDrop or Files. '
                    'No internet is needed.',
                    style: t.textTheme.bodySmall,
                  ),
                  if (link.log.isNotEmpty) ...[
                    const SizedBox(height: 18),
                    const SectionLabel('Link log'),
                    FsCard(
                      padding: const EdgeInsets.all(14),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        for (final l in link.log.take(15))
                          Text(l, style: t.textTheme.bodySmall?.copyWith(fontFamily: 'Menlo', fontSize: 11, color: Fs.ink2)),
                      ]),
                    ),
                  ],
                  const SizedBox(height: 16),
                  const Note(kind: TagKind.warn, child: Text('Not yet tested with a real Field Station Mac.')),
                ]),
              ),
            ]),
          ),
        );
      },
    );
  }

  Widget _pairing(ThemeData t) {
    final s = link.state;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      FilledButton.icon(
        style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(Fs.buttonHeight)),
        onPressed: s == LinkState.scanning || s == LinkState.connecting ? null : link.scan,
        icon: s == LinkState.scanning ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Fs.faint)) : const Icon(Icons.bluetooth_searching_rounded),
        label: Text(s == LinkState.scanning ? 'Looking for Field Station…' : 'Find Field Station'),
      ),
      const SizedBox(height: 8),
      if (link.found.isEmpty && s != LinkState.scanning)
        Text('On the Mac, open Field Station and press "Pair a phone". Keep both devices within a few metres.', style: t.textTheme.bodySmall),
      if (link.found.isNotEmpty) ...[const SizedBox(height: 10), const SectionLabel('Nearby')],
      for (final d in link.found) ...[
        FsCard(
          padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
          onTap: () => link.connect(d, AppState.I.phoneId),
          child: Row(children: [
            const Icon(Icons.laptop_mac_rounded, color: Fs.ink2),
            const SizedBox(width: 14),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(d.name.isEmpty ? 'Field Station' : d.name, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800)),
                Text('signal ${d.rssi} dBm', style: t.textTheme.bodySmall),
              ]),
            ),
            s == LinkState.connecting
                ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.chevron_right_rounded, color: Fs.faint),
          ]),
        ),
        const SizedBox(height: 8),
      ],
      if (s == LinkState.awaitingCode || s == LinkState.pairing) ...[
        const SizedBox(height: 14),
        SectionLabel('Type the 6-digit code shown on ${link.desktopInfo?['name'] ?? 'the Mac'}'),
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: TextField(
              controller: code,
              keyboardType: TextInputType.number,
              maxLength: 6,
              onChanged: (_) => setState(() {}),
              style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800, letterSpacing: 8, fontFeatures: [FontFeature.tabularFigures()]),
              decoration: const InputDecoration(hintText: '000000', counterText: ''),
            ),
          ),
          const SizedBox(width: 10),
          FilledButton(
            onPressed: s == LinkState.pairing || code.text.length != 6 && code.text.isNotEmpty ? null : () => link.pair(code.text),
            child: Text(s == LinkState.pairing ? 'Pairing…' : 'Pair'),
          ),
        ]),
      ],
    ]);
  }

  Widget _pairedCard(ThemeData t) {
    final cs = link.desktopCaptureState;
    final caps = (link.desktopInfo?['capabilities'] as List?)?.join(', ') ?? '–';
    final d435 = (link.desktopInfo?['capabilities'] as List?)?.contains('d435_capture') ?? false;
    return FsCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Icon(Icons.bluetooth_connected_rounded, color: Fs.moss),
            const SizedBox(width: 10),
            Expanded(child: Text('Paired with ${link.desktopInfo?['name'] ?? 'Field Station'}', style: t.textTheme.titleSmall)),
            TextButton(onPressed: () => link.disconnect(), child: const Text('Disconnect')),
          ]),
          Text('Mac reports: $caps', style: t.textTheme.bodySmall),
          if (cs != null) Text('Mac capture: ${cs['state']} · ${cs['frames_recorded'] ?? 0} frames', style: t.textTheme.bodySmall),
          const SizedBox(height: 10),
          if (d435)
            Wrap(spacing: 8, children: [
              FilledButton.tonal(
                onPressed: () async {
                  final a = await link.send({'type': 'start_capture', 'target': 'desktop', 'sensor_id': 'realsense:d435', 'profile': 'field_static'}, wantAck: true);
                  _toast(a?['ok'] == true ? 'Mac started D435 capture' : 'Mac did not start: ${a?['error'] ?? 'no answer'}');
                },
                child: const Text('Start D435 on Mac'),
              ),
              OutlinedButton(
                onPressed: () async {
                  final a = await link.send({'type': 'stop_capture', 'target': 'desktop'}, wantAck: true);
                  _toast(a?['ok'] == true ? 'Mac stopped capture' : 'No confirmation: ${a?['error'] ?? 'no answer'}');
                },
                child: const Text('Stop'),
              ),
            ]),
        ]),
    );
  }

  void _toast(String s) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s)));
  }
}

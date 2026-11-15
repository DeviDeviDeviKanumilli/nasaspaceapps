import 'package:flutter/material.dart';

import '../service/app_state.dart';
import '../service/models.dart';
import '../widgets/common.dart';

class DevicesScreen extends StatefulWidget {
  const DevicesScreen({super.key});
  @override
  State<DevicesScreen> createState() => _DevicesScreenState();
}

class _DevicesScreenState extends State<DevicesScreen> {
  final Map<String, Map<String, dynamic>> _found = {};
  final Set<String> _scanning = {};
  String _profile = 'field_static';
  String? _busy;
  String? _openError;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final s = AppScope.read(context);
      if (s.adapters.isEmpty) s.refreshBasics();
      _scan('realsense');
    });
  }

  Future<void> _scan(String adapterId) async {
    final s = AppScope.read(context);
    setState(() => _scanning.add(adapterId));
    try {
      final r = asMap(await s.api!.getJson('/api/adapters/$adapterId/devices', timeout: const Duration(seconds: 30)));
      setState(() => _found[adapterId] = r);
    } catch (e) {
      setState(() => _found[adapterId] = {'devices': [], 'error': errText(e)});
    } finally {
      if (mounted) setState(() => _scanning.remove(adapterId));
    }
  }

  Future<void> _open(String adapterId, String deviceId) async {
    final s = AppScope.read(context);
    setState(() {
      _busy = deviceId;
      _openError = null;
    });
    try {
      s.status = asMap(await s.api!.postJson('/api/device/open', {'adapter_id': adapterId, 'device_id': deviceId, 'profile': _profile}));
      s.bumpScans();
      if (mounted) s.go(Section.capture);
    } catch (e) {
      setState(() => _openError = errText(e));
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  Future<void> _close() async {
    final s = AppScope.read(context);
    try {
      s.status = asMap(await s.api!.postJson('/api/device/close'));
      s.bumpScans();
    } catch (e) {
      if (mounted) showSnack(context, errText(e), error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    final t = Theme.of(context);
    final adapters = asList(s.adapters['adapters']).map(asMap).toList();
    final profiles = asMap(s.adapters['profiles']);
    final sdk = asMap(s.health['realsense_sdk']);
    final st = s.status;
    final open = st['state'] != null && st['state'] != 'idle';
    return ListView(padding: const EdgeInsets.only(bottom: 32), children: [
      PageHeader('Devices',
          subtitle: 'Sensors this workstation can use. Real sensors and replay are always listed; the synthetic test scene only when fixtures are enabled.'),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          SectionCard(
            title: 'Current sensor',
            trailing: open ? OutlinedButton.icon(onPressed: _close, icon: const Icon(Icons.close), label: const Text('Close')) : null,
            child: open
                ? Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      OriginChip(st['origin'] as String?),
                      const SizedBox(width: 10),
                      StatusChip(asStr(st['state'])),
                    ]),
                    const SizedBox(height: 8),
                    KV('Device', asStr(asMap(st['device'])['name'], '—')),
                    KV('USB', asStr(asMap(st['device'])['usb_type'], '—')),
                    KV('Firmware', asStr(asMap(st['device'])['firmware'], '—')),
                    KV('Profile', asStr(st['profile'])),
                    KV('Depth stream', asStr(asMap(st['calibration_summary'])['depth'], '—')),
                    KV('Colour stream', asStr(asMap(st['calibration_summary'])['color'], '—')),
                    KV('Measured frame rate', st['measured_fps'] == null ? '—' : '${st['measured_fps']} fps'),
                    if (st['error'] != null) ...[const SizedBox(height: 8), ErrorBox(asStr(asMap(st['error'])['message']))],
                  ])
                : Text('No sensor open. Choose a profile and open a device below.',
                    style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant)),
          ),
          const SizedBox(height: 16),
          SectionCard(
            title: 'Capture profile',
            child: DropdownButtonFormField<String>(
              initialValue: profiles.containsKey(_profile) ? _profile : null,
              items: [
                for (final e in profiles.entries)
                  DropdownMenuItem(value: e.key, child: Text(asStr(asMap(e.value)['label'], e.key))),
              ],
              onChanged: (v) => setState(() => _profile = v ?? _profile),
              decoration: const InputDecoration(labelText: 'Resolution, frame rate and frames per scan'),
            ),
          ),
          const SizedBox(height: 16),
          for (final a in adapters) ...[
            _adapterCard(a, t, sdk),
            const SizedBox(height: 16),
          ],
          if (_openError != null) ErrorBox('Could not open the sensor: $_openError'),
        ]),
      ),
    ]);
  }

  Widget _adapterCard(Map<String, dynamic> a, ThemeData t, Map<String, dynamic> sdk) {
    final id = asStr(a['adapter_id']);
    final res = _found[id];
    final devices = asList(res?['devices']).map(asMap).toList();
    final error = res?['error'] as String?;
    final scanning = _scanning.contains(id);
    return SectionCard(
      title: asStr(a['label'], id),
      trailing: OutlinedButton.icon(
        onPressed: scanning ? null : () => _scan(id),
        icon: scanning
            ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
            : const Icon(Icons.search),
        label: Text(scanning ? 'Scanning…' : 'Scan for devices'),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (id == 'realsense')
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: KV('RealSense SDK',
                sdk['available'] == true ? '${sdk['package'] ?? 'pyrealsense2'}${sdk['version'] != null ? ' ${sdk['version']}' : ''} (imports; a camera is still needed)' : 'not available: ${sdk['error'] ?? 'unknown'}'),
          ),
        if (id != 'realsense')
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              id == 'synthetic'
                  ? 'Not a sensor: a ray-cast test scene with simulated noise. Every scan from it is stamped SYNTHETIC.'
                  : 'Plays back the raw frames of a saved scan. Scans recorded from a replay are stamped REPLAY and are never a new observation.',
              style: t.textTheme.bodySmall?.copyWith(color: warnColor(context)),
            ),
          ),
        if (error != null) ErrorBox(error),
        if (res == null && !scanning)
          Text('Not scanned yet.', style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
        if (res != null && devices.isEmpty && error == null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(
              id == 'realsense'
                  ? 'No RealSense camera found. Check: USB 3 data cable (not charge-only), port, then Scan again.'
                  : id == 'replay'
                      ? 'No saved scans with raw frames to replay yet.'
                      : 'No devices.',
              style: t.textTheme.bodyMedium,
            ),
          ),
        for (final d in devices) _deviceRow(id, d, t),
      ]),
    );
  }

  Widget _deviceRow(String adapterId, Map<String, dynamic> d, ThemeData t) {
    final did = asStr(d['device_id']);
    final details = <String>[
      if (d['serial'] != null) 'serial ${d['serial']}',
      if (d['firmware'] != null) 'firmware ${d['firmware']}',
      if (d['usb_type'] != null) 'USB ${d['usb_type']}',
      if (d['source_origin'] != null) 'source ${originBadge(d['source_origin'] as String?)}',
      if (d['captured_at_utc'] != null) 'captured ${d['captured_at_utc']}',
    ].join(' · ');
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(border: Border.all(color: t.colorScheme.outlineVariant), borderRadius: BorderRadius.circular(8)),
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(asStr(d['name'], did), style: t.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w600)),
            if (details.isNotEmpty) Text(details, style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
            if (d['warning'] != null) Text(asStr(d['warning']), style: t.textTheme.bodySmall?.copyWith(color: warnColor(context))),
            if (d['note'] != null) Text(asStr(d['note']), style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
          ]),
        ),
        const SizedBox(width: 12),
        FilledButton(
          onPressed: _busy != null ? null : () => _open(adapterId, did),
          child: _busy == did ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('Open'),
        ),
      ]),
    );
  }
}

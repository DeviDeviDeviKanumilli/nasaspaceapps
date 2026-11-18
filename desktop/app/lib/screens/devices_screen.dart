// Draft written with AI assistance (Claude, Anthropic); disclosed per the Space Apps AI policy.

import 'dart:io';

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
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      final s = AppScope.read(context);
      if (s.adapters.isEmpty) await s.refreshBasics();
      if (!mounted) return;
      // Scan every source on arrival so the page never opens on "not scanned yet".
      _scanAll();
    });
  }

  List<String> _adapterIds(AppState s) {
    final ids = asList(s.adapters['adapters']).map((a) => asStr(asMap(a)['adapter_id'])).where((id) => id.isNotEmpty).toList();
    return ids.isEmpty ? const ['realsense'] : ids;
  }

  void _scanAll() {
    for (final id in _adapterIds(AppScope.read(context))) {
      _scan(id);
    }
  }

  Future<void> _scan(String adapterId) async {
    final s = AppScope.read(context);
    if (s.api == null) return;
    setState(() => _scanning.add(adapterId));
    try {
      final r = asMap(await s.api!.getJson('/api/adapters/$adapterId/devices', timeout: const Duration(seconds: 30)));
      if (mounted) setState(() => _found[adapterId] = r);
    } catch (e) {
      if (mounted) setState(() => _found[adapterId] = {'devices': [], 'error': errText(e)});
    } finally {
      if (mounted) setState(() => _scanning.remove(adapterId));
    }
  }

  Future<void> _open(String adapterId, String deviceId) async {
    final s = AppScope.read(context);
    // A camera on a USB 2 link cannot carry depth + colour at the field profiles; the service says which profile fits.
    final dev = asList(asMap(_found[adapterId])['devices']).map(asMap).where((d) => d['device_id'] == deviceId).firstOrNull;
    final rec = dev == null ? null : dev['recommended_profile'] as String?;
    setState(() {
      _busy = deviceId;
      _openError = null;
      if (rec != null && asMap(s.adapters['profiles']).containsKey(rec)) _profile = rec;
    });
    try {
      s.status = asMap(await s.api!.postJson('/api/device/open', {'adapter_id': adapterId, 'device_id': deviceId, 'profile': _profile}));
      s.bumpScans();
      if (mounted) s.go(Section.capture);
    } catch (e) {
      if (mounted) setState(() => _openError = errText(e));
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

  bool _isOpen(AppState s, String deviceId) {
    final st = s.status;
    return st['device_id'] == deviceId && st['state'] != null && st['state'] != 'idle';
  }

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    final t = Theme.of(context);
    final adapters = asList(s.adapters['adapters']).map(asMap).toList();
    final profiles = asMap(s.adapters['profiles']);
    final st = s.status;
    final open = st['state'] != null && st['state'] != 'idle';
    final scanningAny = _scanning.isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PageHeader(
          'Devices',
          subtitle: 'Choose where depth comes from. Only a RealSense camera produces sensor measurements.',
          actions: [
            SizedBox(
              width: 380,
              child: DropdownButtonFormField<String>(
                initialValue: profiles.containsKey(_profile) ? _profile : null,
                isExpanded: true,
                items: [
                  for (final e in profiles.entries)
                    DropdownMenuItem(
                      value: e.key,
                      child: Text(dims(asStr(asMap(e.value)['label'], e.key)), overflow: TextOverflow.ellipsis),
                    ),
                ],
                onChanged: (v) => setState(() => _profile = v ?? _profile),
                decoration: const InputDecoration(labelText: 'Stream profile, used when you open a source'),
              ),
            ),
            OutlinedButton(onPressed: scanningAny ? null : _scanAll, child: Text(scanningAny ? 'Scanning' : 'Scan again')),
          ],
        ),
        Expanded(
          child: LayoutBuilder(
            builder: (context, box) {
              final wide = box.maxWidth > 980;
              final main = <Widget>[
                if (_openError != null) ...[ErrorBox('Could not open the source: $_openError'), const SizedBox(height: 16)],
                for (final a in adapters) ...[_adapterPanel(s, t, a), const SizedBox(height: 16)],
              ];
              final aside = <Widget>[
                if (open) ...[_openNow(s, t, st), const SizedBox(height: 16)],
                _otherWays(s, t),
                const SizedBox(height: 16),
                _servicePanel(s, t),
              ];
              if (!wide) {
                return ListView(
                  padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
                  children: [...aside, const SizedBox(height: 16), ...main],
                );
              }
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: ListView(padding: const EdgeInsets.fromLTRB(24, 0, 0, 24), children: main),
                  ),
                  const SizedBox(width: 20),
                  SizedBox(
                    width: 380,
                    child: ListView(padding: const EdgeInsets.fromLTRB(0, 0, 24, 24), children: aside),
                  ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _panelHead(ThemeData t, String title, List<Widget> extras, {Widget? trailing}) => Container(
    padding: const EdgeInsets.fromLTRB(18, 14, 18, 10),
    decoration: const BoxDecoration(
      border: Border(bottom: BorderSide(color: FsPalette.ruleLight)),
    ),
    child: Row(
      children: [
        Flexible(child: Text(title, style: t.textTheme.titleMedium)),
        for (final e in extras) ...[const SizedBox(width: 12), e],
        if (trailing != null) ...[const Spacer(), trailing],
      ],
    ),
  );

  Widget _adapterPanel(AppState s, ThemeData t, Map<String, dynamic> a) {
    final id = asStr(a['adapter_id']);
    final res = _found[id];
    final devices = asList(res?['devices']).map(asMap).toList();
    final error = res?['error'] as String?;
    final scanning = _scanning.contains(id);
    final sdk = asMap(s.health['realsense_sdk']);
    final small = t.textTheme.bodySmall;

    if (id == 'realsense') {
      final sdkOk = sdk['available'] == true;
      return Panel(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _panelHead(
              t,
              'Intel RealSense (D435)',
              [Text('Real sensor', style: small)],
              trailing: Text(
                sdkOk ? 'SDK ${sdk['package'] ?? 'pyrealsense2'} ${sdk['version'] ?? ''}, installed' : 'SDK not available',
                style: small?.copyWith(color: sdkOk ? null : FsPalette.record),
              ),
            ),
            if (scanning && res == null) const LinearProgressIndicator(minHeight: 2),
            if (error != null) Padding(padding: const EdgeInsets.all(18), child: ErrorBox(error)),
            if (!sdkOk)
              Padding(padding: const EdgeInsets.all(18), child: ErrorBox('RealSense SDK not available: ${sdk['error'] ?? 'unknown'}'))
            else if (res != null && devices.isEmpty && error == null)
              Padding(
                padding: const EdgeInsets.all(18),
                child: Row(
                  children: [
                    const _CameraOutline(),
                    const SizedBox(width: 22),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(scanning ? 'Looking for a camera' : 'No camera found', style: t.textTheme.titleSmall),
                          const SizedBox(height: 2),
                          Text(
                            'Plug the D435 straight into a USB-C port on this computer with a USB 3 data cable (not charge-only), then '
                            'select Scan again. A USB 2 link works only with the fallback profile.'
                            '${Platform.isMacOS ? ' Not sure it is working? In Terminal run desktop/d435.sh: it checks the link speed and that real depth comes out.' : ''}',
                            style: t.textTheme.bodyMedium?.copyWith(color: FsPalette.inkMuted),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            for (int i = 0; i < devices.length; i++) _deviceRow(s, t, id, devices[i], first: i == 0),
          ],
        ),
      );
    }

    final synthetic = id == 'synthetic';
    return Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _panelHead(t, synthetic ? 'Synthetic test scene' : 'Replay a saved scan', [
            if (synthetic)
              const OriginTag('synthetic_fixture', label: 'Not a sensor')
            else
              Flexible(
                child: Text('Plays recorded frames back as if live. Not a new measurement.', style: small, overflow: TextOverflow.ellipsis),
              ),
          ]),
          if (scanning && res == null) const LinearProgressIndicator(minHeight: 2),
          if (error != null) Padding(padding: const EdgeInsets.all(18), child: ErrorBox(error)),
          if (res != null && devices.isEmpty && error == null)
            Padding(
              padding: const EdgeInsets.all(18),
              child: Text(
                synthetic ? 'No test scene offered. Turn it on in About.' : 'No saved scans with raw frames yet. Record one first.',
                style: t.textTheme.bodyMedium?.copyWith(color: FsPalette.inkMuted),
              ),
            ),
          if (!synthetic && devices.isNotEmpty)
            _replayTable(s, t, devices)
          else
            for (int i = 0; i < devices.length; i++) _deviceRow(s, t, id, devices[i], first: i == 0),
        ],
      ),
    );
  }

  Widget _openButton(AppState s, String adapterId, String did, {bool primary = true}) {
    if (_isOpen(s, did)) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          OutlinedButton(onPressed: _close, child: const Text('Close')),
          const SizedBox(width: 6),
          FilledButton(onPressed: () => s.go(Section.capture), child: const Text('Go to Capture')),
        ],
      );
    }
    final busy = _busy == did;
    final child = busy ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('Open');
    return primary
        ? FilledButton(onPressed: _busy != null ? null : () => _open(adapterId, did), child: child)
        : OutlinedButton(onPressed: _busy != null ? null : () => _open(adapterId, did), child: child);
  }

  Widget _deviceRow(AppState s, ThemeData t, String adapterId, Map<String, dynamic> d, {required bool first}) {
    final did = asStr(d['device_id']);
    final isOpen = _isOpen(s, did);
    final fps = s.status['measured_fps'];
    final details = <String>[
      if (d['serial'] != null) 'serial ${d['serial']}',
      if (d['firmware'] != null) 'firmware ${d['firmware']}',
      if (d['usb_type'] != null) 'USB ${d['usb_type']}',
    ].join(', ');
    return Container(
      color: isOpen ? FsPalette.sheetAlt : null,
      padding: const EdgeInsets.fromLTRB(18, 12, 18, 12),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(asStr(d['name'], did), style: t.textTheme.titleSmall),
                if (details.isNotEmpty) Text(details, style: t.textTheme.bodySmall),
                if (d['note'] != null) Text(asStr(d['note']), style: t.textTheme.bodySmall),
                if (d['warning'] != null) ...[
                  const SizedBox(height: 4),
                  Hint(asStr(d['warning']), color: FsPalette.caution, icon: Icons.warning_amber_rounded),
                ],
              ],
            ),
          ),
          if (isOpen) ...[
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                color: d['is_real_sensor'] == true ? FsPalette.sensor : FsPalette.synthetic,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 6),
            Text('Open${fps != null ? ', $fps fps' : ''}', style: t.textTheme.bodyMedium),
            const SizedBox(width: 16),
          ],
          _openButton(s, adapterId, did),
        ],
      ),
    );
  }

  Widget _replayTable(AppState s, ThemeData t, List<Map<String, dynamic>> devices) {
    final head = t.textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w500);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.fromLTRB(18, 8, 18, 8),
          decoration: const BoxDecoration(
            border: Border(bottom: BorderSide(color: FsPalette.ruleLight)),
          ),
          child: Row(
            children: [
              Expanded(flex: 5, child: Text('Scan', style: head)),
              Expanded(flex: 3, child: Text('Recorded from', style: head)),
              Expanded(flex: 3, child: Text('Captured, UTC', style: head)),
              const SizedBox(width: 236), // fits Close + Go to Capture when the replay is open
            ],
          ),
        ),
        for (int i = 0; i < devices.length; i++)
          Builder(
            builder: (context) {
              final d = devices[i];
              final did = asStr(d['device_id']);
              final name = asStr(d['name'], did).replaceFirst(RegExp(r'^REPLAY:\s*'), '');
              final scanId = did.startsWith('replay:') ? did.substring(7) : did;
              return Container(
                color: _isOpen(s, did) ? FsPalette.sheetAlt : null,
                padding: const EdgeInsets.fromLTRB(18, 8, 18, 8),
                child: Row(
                  children: [
                    Expanded(
                      flex: 5,
                      child: Text.rich(
                        TextSpan(
                          children: [
                            TextSpan(text: name),
                            TextSpan(
                              text: '  ${shortId(scanId)}',
                              style: TextStyle(color: FsPalette.inkMuted),
                            ),
                          ],
                        ),
                        style: t.textTheme.bodyMedium,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Expanded(
                      flex: 3,
                      child: Align(alignment: Alignment.centerLeft, child: OriginTag(d['source_origin'] as String?)),
                    ),
                    Expanded(flex: 3, child: Text(utcText(d['captured_at_utc']), style: t.textTheme.bodyMedium)),
                    SizedBox(
                      width: 236,
                      child: Align(alignment: Alignment.centerRight, child: _openButton(s, 'replay', did, primary: false)),
                    ),
                  ],
                ),
              );
            },
          ),
      ],
    );
  }

  Widget _openNow(AppState s, ThemeData t, Map<String, dynamic> st) {
    final dev = asMap(st['device']);
    final cal = asMap(st['calibration_summary']);
    final real = st['is_real_sensor'] == true;
    return SectionCard(
      title: 'Open now',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          KV(
            'Source',
            // A replay reports the recorded device's name; say it is a replay so it never reads as a live camera.
            st['origin'] == 'replay' ? 'Replay of ${asStr(dev['name'], 'a saved scan')}' : asStr(dev['name'], '—'),
            labelWidth: 120,
            valueStyle: t.textTheme.bodyMedium?.copyWith(
              fontSize: 13.5,
              fontWeight: FontWeight.w600,
              color: real ? FsPalette.sensor : FsPalette.synthetic,
            ),
          ),
          KV('Profile', asStr(st['profile'], '—'), labelWidth: 120),
          KV('Depth', dims(asStr(cal['depth'], '—')), labelWidth: 120),
          KV('Colour', dims(asStr(cal['color'], '—')), labelWidth: 120),
          if (cal['depth_scale_m'] != null) KV('Depth unit', '${cal['depth_scale_m']} m', labelWidth: 120),
          if (cal['stereo_baseline_m'] != null)
            KV(
              'Stereo baseline',
              '${(asDouble(cal['stereo_baseline_m']) ?? 0).toStringAsFixed(3)} m${cal['baseline_source'] != null ? ', ${asStr(cal['baseline_source']).replaceAll('_', ' ')}' : ''}',
              labelWidth: 120,
            ),
          KV('Measured rate', st['measured_fps'] == null ? '—' : '${st['measured_fps']} fps', labelWidth: 120),
          if (dev['usb_type'] != null) KV('USB', asStr(dev['usb_type']), labelWidth: 120),
          if (dev['firmware'] != null) KV('Firmware', asStr(dev['firmware']), labelWidth: 120),
          if (st['error'] != null) ...[const SizedBox(height: 10), ErrorBox(asStr(asMap(st['error'])['message']))],
          const SizedBox(height: 12),
          Row(
            children: [
              OutlinedButton(onPressed: _close, child: const Text('Close')),
              const SizedBox(width: 8),
              FilledButton(onPressed: () => s.go(Section.capture), child: const Text('Go to Capture')),
            ],
          ),
        ],
      ),
    );
  }

  Widget _otherWays(AppState s, ThemeData t) {
    return SectionCard(
      title: 'Other ways to add data',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('iPhone and iPad Pro LiDAR scans are imported in Library, not streamed live.', style: t.textTheme.bodyMedium),
          const SizedBox(height: 4),
          TextButton(
            onPressed: () => s.go(Section.library),
            style: TextButton.styleFrom(padding: EdgeInsets.zero, minimumSize: const Size(0, 32)),
            child: const Text('Import an iPhone scan in Library'),
          ),
          if (!Platform.isMacOS) ...[
            const Divider(height: 20, color: FsPalette.ruleLight),
            Text(
              'Phone pairing over Bluetooth needs the macOS build. On this computer, copy the phone\'s exported .zip over USB or a shared drive.',
              style: t.textTheme.bodySmall?.copyWith(fontSize: 13),
            ),
          ],
        ],
      ),
    );
  }

  Widget _servicePanel(AppState s, ThemeData t) {
    final h = s.health;
    return SectionCard(
      title: 'Local service',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          KV('Version', '${h['version'] ?? '—'}, pipeline ${h['pipeline_version'] ?? '—'}', labelWidth: 90),
          KV('Address', '127.0.0.1, this computer only', labelWidth: 90),
          KV('Scope', 'Sensor capture and local geometry. Analog discovery is on the website.', labelWidth: 90),
        ],
      ),
    );
  }
}

/// Line drawing of a D435 with its cable unplugged, for the "no camera" state.
class _CameraOutline extends StatelessWidget {
  const _CameraOutline();

  @override
  Widget build(BuildContext context) => Semantics(
    label: 'Outline of a D435 camera with no cable attached',
    child: SizedBox(width: 96, height: 40, child: CustomPaint(painter: _CameraPainter())),
  );
}

class _CameraPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = FsPalette.inkMuted
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4;
    canvas.drawRRect(RRect.fromRectAndRadius(const Rect.fromLTWH(1, 9, 70, 22), const Radius.circular(4)), p);
    canvas.drawCircle(const Offset(13, 20), 4.5, p);
    canvas.drawCircle(const Offset(31, 20), 3, p);
    canvas.drawCircle(const Offset(44, 20), 3, p);
    canvas.drawCircle(const Offset(59, 20), 4.5, p);
    for (double x = 76; x < 82; x += 4) {
      canvas.drawLine(Offset(x, 20), Offset(x + 2, 20), p);
    }
    canvas.drawRRect(RRect.fromRectAndRadius(const Rect.fromLTWH(84, 15, 11, 10), const Radius.circular(1.5)), p);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

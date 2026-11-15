// Draft written with AI assistance (Claude, Anthropic); disclosed per the Space Apps AI policy.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'screens/about_screen.dart';
import 'screens/analysis_screen.dart';
import 'screens/capture_screen.dart';
import 'screens/devices_screen.dart';
import 'screens/library_screen.dart';
import 'screens/pairing_screen.dart';
import 'screens/viewer_screen.dart';
import 'service/app_state.dart';
import 'service/models.dart';
import 'widgets/common.dart';
import 'widgets/honesty_banner.dart';

class FieldStationApp extends StatelessWidget {
  const FieldStationApp({super.key, required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    return AppScope(
      state: state,
      child: MaterialApp(
        title: 'Field Station',
        debugShowCheckedModeBanner: false,
        theme: buildTheme(),
        themeMode: ThemeMode.light,
        home: const Shell(),
      ),
    );
  }
}

class _Dest {
  const _Dest(this.section, this.label, this.hint);
  final Section section;
  final String label;
  final String hint;
}

class Shell extends StatelessWidget {
  const Shell({super.key});

  static const _work = [
    _Dest(Section.devices, 'Devices', 'Choose and open a sensor'),
    _Dest(Section.capture, 'Capture', 'Live preview and recording'),
    _Dest(Section.viewer, 'Viewer', '3D point cloud'),
    _Dest(Section.analysis, 'Analysis', 'Roughness, protrusion, distance'),
    _Dest(Section.library, 'Library', 'Saved scans, import and export'),
  ];
  static const _sys = [
    _Dest(Section.pairing, 'Pairing', 'Phone link over Bluetooth'),
    _Dest(Section.about, 'About', 'Versions, test sources, diagnostics'),
  ];
  static final _all = [..._work, ..._sys];

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    final st = s.status;
    final mac = Platform.isMacOS;
    final liveOrigin = st['origin'] as String?;
    // Scan screens carry their own banner for the scan being shown; the live one would be about something else.
    final showLiveBanner =
        liveOrigin != null && st['state'] != 'idle' && !const {Section.viewer, Section.analysis, Section.library}.contains(s.section);
    return CallbackShortcuts(
      bindings: {
        for (int i = 0; i < _all.length; i++)
          SingleActivator(LogicalKeyboardKey(LogicalKeyboardKey.digit1.keyId + i), control: !mac, meta: mac): () => s.go(_all[i].section),
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          body: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: LayoutBuilder(
                  builder: (context, box) {
                    final compact = box.maxWidth < 1080;
                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _Sidebar(state: s, compact: compact),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              if (showLiveBanner)
                                HonestyBanner(
                                  origin: liveOrigin,
                                  isRealSensor: st['is_real_sensor'] as bool?,
                                  replayOf: (st['device'] is Map) ? (st['device'] as Map)['replay_of_scan_id'] as String? : null,
                                ),
                              if (s.launcher.error != null) _ServiceDown(state: s),
                              Expanded(child: _body(s)),
                            ],
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
              _StatusFooter(state: s),
            ],
          ),
        ),
      ),
    );
  }

  Widget _body(AppState s) {
    if (s.api == null) {
      if (s.launcher.starting) return const _Starting();
      if (s.launcher.error == null) return const SizedBox.shrink();
      return const EmptyState(
        title: 'The local service is not running',
        body: 'Capture, analysis and the library need it. Select Restart service above. About shows the diagnostics.',
      );
    }
    switch (s.section) {
      case Section.devices:
        return const DevicesScreen();
      case Section.capture:
        return const CaptureScreen();
      case Section.viewer:
        return const ViewerScreen();
      case Section.analysis:
        return const AnalysisScreen();
      case Section.library:
        return const LibraryScreen();
      case Section.pairing:
        return const PairingScreen();
      case Section.about:
        return const AboutScreen();
    }
  }
}

class _Starting extends StatelessWidget {
  const _Starting();

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(width: 160, child: LinearProgressIndicator()),
          const SizedBox(height: 16),
          Text('Starting the local service', style: t.textTheme.titleLarge),
          const SizedBox(height: 4),
          Text(
            'Loading the sensor and analysis libraries. This takes a few seconds.',
            style: t.textTheme.bodyMedium?.copyWith(color: FsPalette.inkMuted),
          ),
        ],
      ),
    );
  }
}

// ------------------------------------------------------------------------------------------------- sidebar

class _Sidebar extends StatelessWidget {
  const _Sidebar({required this.state, required this.compact});
  final AppState state;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final s = state;
    final mac = Platform.isMacOS;
    final st = s.deviceState;
    final recording = st == 'recording';
    final sensorOpen = st != 'idle' && s.status['adapter_id'] != null;
    final realSensor = s.status['is_real_sensor'] == true;
    (Color, String)? dotFor(Section sec) {
      if (sec == Section.capture && recording) return (FsPalette.record, 'recording');
      if (sec == Section.devices && sensorOpen) {
        return realSensor ? (FsPalette.sensor, 'real sensor open') : (FsPalette.synthetic, 'non-sensor source open');
      }
      return null;
    }

    Widget item(_Dest d, int index) => _NavItem(
      dest: d,
      number: index + 1,
      selected: s.section == d.section,
      compact: compact,
      dot: dotFor(d.section),
      shortcut: '${mac ? '⌘' : 'Ctrl+'}${index + 1}',
      onTap: () => s.go(d.section),
    );

    return Container(
      width: compact ? 64 : 196,
      decoration: const BoxDecoration(
        color: FsPalette.sheet,
        border: Border(right: BorderSide(color: FsPalette.rule)),
      ),
      padding: EdgeInsets.symmetric(horizontal: compact ? 8 : 12, vertical: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(compact ? 0 : 8, 0, 0, 18),
            child: compact
                ? const Center(child: _Mark(size: 26))
                : Row(
                    children: [
                      const _Mark(size: 26),
                      const SizedBox(width: 10),
                      Text(
                        'Field Station',
                        style: t.textTheme.titleMedium?.copyWith(fontSize: 16, fontWeight: FontWeight.w700, letterSpacing: -0.1),
                      ),
                    ],
                  ),
          ),
          for (int i = 0; i < Shell._work.length; i++) item(Shell._work[i], i),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
            child: Container(height: 1, color: FsPalette.rule),
          ),
          for (int i = 0; i < Shell._sys.length; i++) item(Shell._sys[i], Shell._work.length + i),
          const Spacer(),
          if (!compact)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Works offline. ${mac ? '⌘' : 'Ctrl+'}1 to ${mac ? '⌘' : 'Ctrl+'}7 switch sections.',
                    style: t.textTheme.bodySmall?.copyWith(fontSize: 12),
                  ),
                  if (s.health['version'] != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      'Version ${s.health['version']}, scan schema ${s.health['schema_version'] ?? '—'}',
                      style: t.textTheme.bodySmall?.copyWith(fontSize: 12),
                    ),
                  ],
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// Brand mark: three nested contour lines with a filled summit, in field ochre (a contour map of a boulder).
class _Mark extends StatelessWidget {
  const _Mark({required this.size});
  final double size;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: size,
    height: size,
    child: CustomPaint(painter: _MarkPainter()),
  );
}

class _MarkPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / 26, size.height / 26);
    final stroke = Paint()
      ..color = FsPalette.ochre
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4;
    final outer = Path()
      ..moveTo(3, 18)
      ..cubicTo(4, 11, 9, 5, 14, 5)
      ..cubicTo(19, 5, 23, 10, 23, 15)
      ..cubicTo(23, 20, 19, 23, 13, 23)
      ..cubicTo(7, 23, 2, 22, 3, 18)
      ..close();
    final mid = Path()
      ..moveTo(7, 17)
      ..cubicTo(8, 13, 11, 9, 14, 9)
      ..cubicTo(17, 9, 19, 12, 19, 15)
      ..cubicTo(19, 18, 16, 20, 13, 20)
      ..cubicTo(10, 20, 6, 19, 7, 17)
      ..close();
    final top = Path()
      ..moveTo(11, 16)
      ..cubicTo(11, 14, 13, 13, 14, 13)
      ..cubicTo(15, 13, 16, 14, 16, 15)
      ..cubicTo(16, 16, 15, 17, 13, 17)
      ..cubicTo(11, 17, 11, 17, 11, 16)
      ..close();
    canvas.drawPath(outer, stroke);
    canvas.drawPath(mid, stroke);
    canvas.drawPath(top, Paint()..color = FsPalette.ochre);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _NavItem extends StatefulWidget {
  const _NavItem({
    required this.dest,
    required this.number,
    required this.selected,
    required this.compact,
    required this.onTap,
    required this.shortcut,
    this.dot,
  });
  final _Dest dest;
  final int number;
  final bool selected;
  final bool compact;
  final VoidCallback onTap;
  final String shortcut;
  final (Color, String)? dot;

  @override
  State<_NavItem> createState() => _NavItemState();
}

class _NavItemState extends State<_NavItem> {
  bool _hover = false;
  bool _focus = false;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final sel = widget.selected;
    final fg = sel ? FsPalette.survey : FsPalette.ink;
    final num = Text(
      '${widget.number}',
      style: t.textTheme.labelMedium?.copyWith(
        fontSize: 12,
        color: sel ? FsPalette.survey : FsPalette.inkMuted,
        fontWeight: sel ? FontWeight.w600 : FontWeight.w400,
      ),
    );
    final dot = widget.dot == null
        ? null
        : Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(color: widget.dot!.$1, shape: BoxShape.circle),
          );
    return Tooltip(
      message: '${widget.dest.label}: ${widget.dest.hint} (${widget.shortcut})${widget.dot != null ? ', ${widget.dot!.$2}' : ''}',
      preferBelow: false,
      waitDuration: const Duration(milliseconds: 700),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 1),
        child: FocusableActionDetector(
          onShowHoverHighlight: (v) => setState(() => _hover = v),
          onShowFocusHighlight: (v) => setState(() => _focus = v),
          mouseCursor: SystemMouseCursors.click,
          actions: {ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) => widget.onTap())},
          child: Semantics(
            button: true,
            selected: sel,
            label: widget.dest.label,
            child: GestureDetector(
              onTap: widget.onTap,
              child: Container(
                height: 36,
                padding: EdgeInsets.symmetric(horizontal: widget.compact ? 0 : 10),
                decoration: BoxDecoration(
                  color: sel ? FsPalette.surveyTint : (_hover ? FsPalette.paper : Colors.transparent),
                  borderRadius: BorderRadius.circular(4),
                  border: _focus ? Border.all(color: FsPalette.survey, width: 2) : null,
                ),
                child: widget.compact
                    ? Stack(
                        alignment: Alignment.center,
                        children: [
                          Text(
                            '${widget.number}',
                            style: t.textTheme.labelLarge?.copyWith(color: fg, fontWeight: sel ? FontWeight.w600 : FontWeight.w500),
                          ),
                          if (dot != null) Positioned(right: 8, top: 8, child: dot),
                        ],
                      )
                    : Row(
                        children: [
                          SizedBox(width: 18, child: num),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              widget.dest.label,
                              style: t.textTheme.bodyMedium?.copyWith(color: fg, fontWeight: sel ? FontWeight.w600 : FontWeight.w400),
                            ),
                          ),
                          ?dot,
                        ],
                      ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ------------------------------------------------------------------------------------------------- status footer

/// One line that always answers: which source, doing what, what kind of data, and is everything connected.
class _StatusFooter extends StatelessWidget {
  const _StatusFooter({required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    final s = state;
    final t = Theme.of(context);
    final st = s.status;
    final dev = asMap(st['device']);
    final ds = s.deviceState;
    final open = ds != 'idle' && st['adapter_id'] != null;
    final cap = s.capture;
    final recording = ds == 'recording';
    final fps = st['measured_fps'];
    final svcOk = s.connected && s.eventsConnected;
    final real = st['is_real_sensor'] == true;
    final dotColor = switch (ds) {
      'recording' || 'error' => FsPalette.record,
      'processing' => FsPalette.caution,
      'streaming' => real ? FsPalette.sensor : FsPalette.synthetic,
      _ => FsPalette.field,
    };
    final n = asInt(cap['frames_recorded']) ?? 0;
    final req = asInt(cap['frames_requested']) ?? 0;
    final small = t.textTheme.bodySmall?.copyWith(fontSize: 12.5);
    final ink = small?.copyWith(color: FsPalette.ink);
    final stateWord = switch (ds) {
      'streaming' => 'Streaming',
      'recording' => 'Recording',
      'processing' => 'Processing',
      'error' => 'Stopped with an error',
      _ => 'Open',
    };

    return Container(
      height: 30,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: const BoxDecoration(
        color: FsPalette.sheet,
        border: Border(top: BorderSide(color: FsPalette.rule)),
      ),
      // Source names can be long (a replay is named after its scan's title): cap them so the footer never overflows.
      child: LayoutBuilder(
        builder: (context, box) => Row(
          children: [
            InkWell(
              onTap: () => s.go(open ? Section.capture : Section.devices),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
                child: Row(
                  children: [
                    _PulseDot(color: dotColor, pulsing: recording),
                    const SizedBox(width: 7),
                    ConstrainedBox(
                      constraints: BoxConstraints(maxWidth: box.maxWidth * 0.32),
                      child: Text(
                        open
                            ? [
                                stateWord,
                                st['origin'] == 'replay' ? 'replay of ${asStr(dev['name'], 'a saved scan')}' : asStr(dev['name'], 'sensor'),
                                if (fps != null && ds == 'streaming') '$fps fps',
                              ].join(', ')
                            : 'No source open',
                        maxLines: 1,
                        softWrap: false,
                        overflow: TextOverflow.ellipsis,
                        style: recording ? ink?.copyWith(color: FsPalette.record, fontWeight: FontWeight.w600) : ink,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            if (recording) ...[
              const SizedBox(width: 14),
              Text(
                '$n of $req frames',
                style: small?.copyWith(color: FsPalette.record, fontWeight: FontWeight.w600),
              ),
              const SizedBox(width: 10),
              SizedBox(
                width: 120,
                child: LinearProgressIndicator(value: req > 0 ? n / req : null, color: FsPalette.record, minHeight: 3),
              ),
            ] else if (open && box.maxWidth >= 900) ...[
              const SizedBox(width: 22),
              ConstrainedBox(
                constraints: BoxConstraints(maxWidth: box.maxWidth * 0.16),
                child: Text(
                  'Origin ${asStr(st['origin'], '—')}',
                  style: small,
                  maxLines: 1,
                  softWrap: false,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
            const Spacer(),
            _FooterItem(
              ok: svcOk,
              label: svcOk ? 'Service 127.0.0.1, connected' : (s.launcher.starting ? 'Service starting' : 'Service offline'),
              tooltip: svcOk
                  ? 'Local service on this computer, loopback only.${s.launcher.external ? ' External instance.' : ''}'
                  : 'The local service is not connected. About shows the diagnostics.',
              onTap: svcOk ? null : () => s.go(Section.about),
            ),
            const SizedBox(width: 22),
            _FooterItem(
              ok: s.ble.available && s.ble.centrals.isNotEmpty,
              neutral: !s.ble.available || s.ble.centrals.isEmpty,
              label: !s.ble.available
                  ? (Platform.isMacOS ? 'Bluetooth unavailable' : 'Phone link: macOS only')
                  : (s.ble.centrals.isEmpty
                        ? 'No phone linked'
                        : '${s.ble.centrals.length} phone${s.ble.centrals.length == 1 ? '' : 's'} linked'),
              tooltip: !s.ble.available
                  ? 'Pairing uses the CoreBluetooth bridge in the macOS build. Scans still import by zip in Library.'
                  : 'Bluetooth LE control link to the iPhone app.',
              onTap: () => s.go(Section.pairing),
            ),
            if (s.health['home'] != null) ...[
              const SizedBox(width: 22),
              Flexible(
                child: Tooltip(
                  message: asStr(s.health['home']),
                  child: Text('Data in ${_shortHome(asStr(s.health['home']))}', style: small, overflow: TextOverflow.ellipsis),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  static String _shortHome(String home) {
    final local = Platform.environment['LOCALAPPDATA'];
    if (local != null && home.toLowerCase().startsWith(local.toLowerCase())) return '%LOCALAPPDATA%${home.substring(local.length)}';
    final h = Platform.environment['HOME'];
    if (h != null && home.startsWith(h)) return '~${home.substring(h.length)}';
    return home;
  }
}

class _FooterItem extends StatelessWidget {
  const _FooterItem({required this.ok, required this.label, required this.tooltip, this.neutral = false, this.onTap});
  final bool ok;
  final bool neutral;
  final String label;
  final String tooltip;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final bad = !ok && !neutral;
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (bad) ...[const Icon(Icons.error_outline, size: 13, color: FsPalette.record), const SizedBox(width: 5)],
              Text(
                label,
                style: t.textTheme.bodySmall?.copyWith(
                  fontSize: 12.5,
                  color: bad ? FsPalette.record : null,
                  fontWeight: bad ? FontWeight.w600 : null,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// State dot; pulses only while recording, the one moment that needs attention.
class _PulseDot extends StatefulWidget {
  const _PulseDot({required this.color, required this.pulsing});
  final Color color;
  final bool pulsing;

  @override
  State<_PulseDot> createState() => _PulseDotState();
}

class _PulseDotState extends State<_PulseDot> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 900));

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(covariant _PulseDot oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync();
  }

  void _sync() {
    final reduce = WidgetsBinding.instance.platformDispatcher.accessibilityFeatures.disableAnimations;
    if (widget.pulsing && !reduce) {
      if (!_c.isAnimating) _c.repeat(reverse: true);
    } else {
      _c.stop();
      _c.value = 1;
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) => Container(
        width: 8,
        height: 8,
        decoration: BoxDecoration(
          color: widget.color.withValues(alpha: widget.pulsing ? 0.35 + 0.65 * _c.value : 1),
          shape: BoxShape.circle,
        ),
      ),
    );
  }
}

class _ServiceDown extends StatelessWidget {
  const _ServiceDown({required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 14, 24, 0),
      child: ErrorBox(
        state.launcher.error!,
        action: FilledButton(
          onPressed: state.launcher.starting ? null : () => state.restartService(),
          child: const Text('Restart service'),
        ),
      ),
    );
  }
}

import 'package:flutter/material.dart';

import '../core/app_state.dart';
import '../core/scan_record.dart';
import '../core/scanner.dart';
import '../ui/rocks.dart';
import '../ui/style.dart';
import 'capture_screen.dart';

class ScanSetupScreen extends StatefulWidget {
  const ScanSetupScreen({super.key});
  @override
  State<ScanSetupScreen> createState() => _ScanSetupScreenState();
}

class _ScanSetupScreenState extends State<ScanSetupScreen> {
  final setup = ScanSetup();
  final _title = TextEditingController();
  final _notes = TextEditingController();
  final _site = TextEditingController();
  final _cand = TextEditingController();
  bool _more = false;

  @override
  void initState() {
    super.initState();
    setup.preset = AppState.I.defaultPreset;
    setup.collectLocation = AppState.I.defaultLocation;
    setup.rigMode = setup.preset == 'rig';
  }

  void _pick(String preset) => setState(() {
        setup.preset = preset;
        setup.rigMode = preset == 'rig';
      });

  @override
  Widget build(BuildContext context) {
    final st = AppState.I;
    final t = Theme.of(context);
    if (!st.hasArkit) return _Unsupported(model: st.deviceModel);
    final lidar = st.hasLidar;
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(children: [
          ScreenHeader(
            title: 'New scan',
            subtitle: StatusLine(
              lidar ? '${st.deviceModel} · LiDAR ready' : '${st.deviceModel} · photos and poses only (no LiDAR)',
              dot: lidar ? Fs.live : Fs.amberInk,
            ),
          ),
          Expanded(
            child: ListView(padding: const EdgeInsets.fromLTRB(Fs.side, 4, Fs.side, 24), children: [
              TextField(
                controller: _title,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(labelText: 'Name', hintText: 'e.g. Boulder A, trail entrance'),
              ),
              const SizedBox(height: 22),
              const SectionLabel('What are you scanning?'),
              _featureGrid(),
              const SizedBox(height: 6),
              Text('Your label only. The app does not identify rock types.', style: t.textTheme.bodySmall),
              const SizedBox(height: 22),
              const SectionLabel('Capture'),
              _captureChoice(),
              const SizedBox(height: 12),
              SwitchCard(
                title: 'Save location',
                subtitle: 'Off by default. Kept privately on this phone and never written into photos.',
                value: setup.collectLocation,
                onChanged: (v) => setState(() => setup.collectLocation = v),
              ),
              const SizedBox(height: 8),
              SwitchCard(
                title: 'Rig mode',
                subtitle: 'Screen dims and ignores touches; spoken prompts; the paired Mac can start and stop. Hold 2 s to unlock.',
                value: setup.rigMode,
                onChanged: (v) => setState(() => setup.rigMode = v),
              ),
              const SizedBox(height: 4),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () => setState(() => _more = !_more),
                  icon: Icon(_more ? Icons.expand_less_rounded : Icons.expand_more_rounded),
                  label: const Text('Notes and links (optional)'),
                ),
              ),
              if (_more) ...[
                TextField(controller: _notes, maxLines: 3, decoration: const InputDecoration(labelText: 'Field notes')),
                const SizedBox(height: 12),
                TextField(controller: _site, decoration: const InputDecoration(labelText: 'Field site ID')),
                const SizedBox(height: 12),
                TextField(controller: _cand, decoration: const InputDecoration(labelText: 'Website candidate ID', hintText: 'e.g. G-R-JZ-003')),
                const SizedBox(height: 6),
                Text('Stored as references only. Analog search and ranking live on the website, not in this app.', style: t.textTheme.bodySmall),
              ],
            ]),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(Fs.side, 8, Fs.side, 16),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: () {
                  setup.title = _title.text.trim();
                  setup.notes = _notes.text.trim();
                  setup.fieldSiteId = _site.text.trim();
                  setup.candidateId = _cand.text.trim();
                  Navigator.of(context).push(MaterialPageRoute(builder: (_) => CaptureScreen(setup: setup)));
                },
                child: const Text('Open scanner'),
              ),
            ),
          ),
        ]),
      ),
    );
  }

  Widget _featureGrid() {
    final keys = featureTypes.keys.toList();
    return GridView.count(
      crossAxisCount: 3,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: 8,
      crossAxisSpacing: 8,
      childAspectRatio: 1.35,
      children: [
        for (final k in keys)
          _Tile(
            selected: setup.featureType == k,
            onTap: () => setState(() => setup.featureType = k),
            child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
              RockIcon(k, width: 40),
              const SizedBox(height: 6),
              Text(featureTypes[k]!.split(' /').first, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700), maxLines: 1, overflow: TextOverflow.ellipsis),
            ]),
          ),
      ],
    );
  }

  Widget _captureChoice() {
    final main = [presetById('handheld'), presetById('rig')];
    final other = presets.where((p) => p.id != 'handheld' && p.id != 'rig').toList();
    final t = Theme.of(context).textTheme;
    return Column(children: [
      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        for (final p in main) ...[
          if (p != main.first) const SizedBox(width: 10),
          Expanded(
            child: _Tile(
              selected: setup.preset == p.id,
              onTap: () => _pick(p.id),
              padding: const EdgeInsets.all(14),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                p.id == 'rig' ? const RigDrawing(width: 76) : const HandheldDrawing(width: 76),
                const SizedBox(height: 8),
                Text(p.id == 'rig' ? 'On the rig' : 'Handheld', style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800)),
                const SizedBox(height: 2),
                Text(
                  p.id == 'rig' ? 'Screen hidden. Takes photos automatically with spoken prompts.' : 'Walk slowly around the feature at 0.5–2 m.',
                  style: t.bodySmall,
                ),
              ]),
            ),
          ),
        ],
      ]),
      const SizedBox(height: 8),
      Row(children: [
        for (final p in other) ...[
          if (p != other.first) const SizedBox(width: 8),
          Expanded(
            child: _Tile(
              selected: setup.preset == p.id,
              onTap: () => _pick(p.id),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
              child: Row(children: [
                Icon(p.id == 'manual' ? Icons.touch_app_outlined : Icons.timer_outlined, size: 18, color: setup.preset == p.id ? Fs.mossInk : Fs.ink2),
                const SizedBox(width: 8),
                Expanded(child: Text(p.label, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700), overflow: TextOverflow.ellipsis)),
              ]),
            ),
          ),
        ],
      ]),
    ]);
  }
}

/// Selectable white tile; selected = moss outline on a pale green fill.
class _Tile extends StatelessWidget {
  final bool selected;
  final VoidCallback onTap;
  final Widget child;
  final EdgeInsetsGeometry padding;
  const _Tile({required this.selected, required this.onTap, required this.child, this.padding = const EdgeInsets.all(6)});

  @override
  Widget build(BuildContext context) => Semantics(
        selected: selected,
        button: true,
        child: Material(
          color: selected ? Fs.mossTint : Fs.card,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: BorderSide(color: selected ? Fs.moss : Colors.transparent, width: 2),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(onTap: onTap, child: Padding(padding: padding, child: child)),
        ),
      );
}

class _Unsupported extends StatelessWidget {
  final String model;
  const _Unsupported({required this.model});
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Scaffold(
      body: SafeArea(
        child: Column(children: [
          const ScreenHeader(title: 'Scan'),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                const Pebble(width: 140, mood: PebbleMood.sleeping, semanticLabel: 'A sleeping rock'),
                const SizedBox(height: 20),
                Text('ARKit is not available on $model', style: t.titleLarge, textAlign: TextAlign.center),
                const SizedBox(height: 8),
                Text(
                  'Scanning needs an iPhone with ARKit world tracking (and LiDAR for depth). The simulator has neither. '
                  'You can still open saved scans in the Library.',
                  style: t.bodyMedium?.copyWith(color: Fs.muted),
                  textAlign: TextAlign.center,
                ),
              ]),
            ),
          ),
          const SizedBox(height: 60),
        ]),
      ),
    );
  }
}

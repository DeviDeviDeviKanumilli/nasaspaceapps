import 'package:flutter/material.dart';

import '../core/app_state.dart';
import '../core/fixture.dart';
import '../core/scan_record.dart';
import '../core/scanner.dart';
import '../ui/style.dart';
import 'intro_screen.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  int? freeMB;
  late final TextEditingController name = TextEditingController(text: AppState.I.displayName);

  @override
  void initState() {
    super.initState();
    Scanner.freeSpaceMB().then((v) => setState(() => freeMB = v));
  }

  @override
  Widget build(BuildContext context) {
    final st = AppState.I;
    final t = Theme.of(context);
    final c = st.caps;
    void save(VoidCallback f) => setState(() {
          f();
          st.saveSettings();
        });
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(children: [
          const ScreenHeader(title: 'Settings'),
          Expanded(
            child: ListView(padding: const EdgeInsets.fromLTRB(Fs.side, 4, Fs.side, 32), children: [
              const SectionLabel('Defaults'),
              TextField(
                controller: name,
                decoration: const InputDecoration(labelText: 'Credit name for contributions', hintText: 'A nickname is fine'),
                onSubmitted: (v) {
                  st.displayName = v.trim();
                  st.saveSettings();
                },
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                isExpanded: true,
                initialValue: st.defaultPreset,
                decoration: const InputDecoration(labelText: 'Default capture'),
                borderRadius: BorderRadius.circular(16),
                items: [for (final p in presets) DropdownMenuItem(value: p.id, child: Text(p.label))],
                onChanged: (v) => save(() => st.defaultPreset = v!),
              ),
              const SizedBox(height: 12),
              SwitchCard(title: 'Save location by default', value: st.defaultLocation, onChanged: (v) => save(() => st.defaultLocation = v)),
              const SizedBox(height: 8),
              SwitchCard(
                title: 'Rig mode: spoken prompts',
                subtitle: '"Recording", "Tracking limited. Move slower.", frame counts. Plays even with the silent switch on.',
                value: st.rigSpeech,
                onChanged: (v) => save(() => st.rigSpeech = v),
              ),
              const SizedBox(height: 8),
              SwitchCard(
                title: 'Rig mode: tick on every keyframe',
                subtitle: 'System sound; silent when the ring switch is off.',
                value: st.rigSound,
                onChanged: (v) => save(() => st.rigSound = v),
              ),
              const SizedBox(height: 24),
              const SectionLabel('This phone'),
              FsCard(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Column(children: [
                  _kv('Model', '${st.deviceModel} (${c['modelIdentifier']})'),
                  _kv('iOS', '${c['osVersion'] ?? '–'}'),
                  _kv('ARKit world tracking', c['arkit'] == true ? 'yes' : 'no'),
                  _kv('LiDAR scene depth', c['sceneDepth'] == true ? 'yes' : 'no'),
                  _kv('Scene mesh', c['mesh'] == true ? (c['meshClassification'] == true ? 'yes, with surface classes' : 'yes') : 'no'),
                  _kv('Full-resolution photos with pose', c['highResFrames'] == true ? 'yes' : 'no'),
                  _kv('Free storage', freeMB == null || freeMB! < 0 ? '–' : '${(freeMB! / 1000).toStringAsFixed(1)} GB'),
                  _kv('Scans on phone', '${st.scans.length}', last: true),
                ]),
              ),
              const SizedBox(height: 24),
              const SectionLabel('Testing'),
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(Fs.buttonHeight)),
                icon: const Icon(Icons.science_outlined),
                label: const Text('Add a SYNTHETIC test scan'),
                onPressed: () async {
                  await writeSyntheticScan(st.library);
                  await st.refresh();
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Synthetic boulder added to the Library (labelled as a fixture).')));
                  }
                },
              ),
              const SizedBox(height: 6),
              Text('A generated boulder on flat ground for trying the viewer and measurement tools. Clearly marked; never a real scan.',
                  style: t.textTheme.bodySmall),
              const SizedBox(height: 24),
              const SectionLabel('About'),
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(Fs.buttonHeight)),
                icon: const Icon(Icons.auto_stories_outlined),
                label: const Text('Show intro again'),
                onPressed: () => Navigator.of(context).push(MaterialPageRoute(fullscreenDialog: true, builder: (_) => const IntroScreen(replay: true))),
              ),
              const SizedBox(height: 10),
              FsCard(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('$appName $appVersion · pipeline $pipelineVersion · scan schema $schemaVersion', style: t.textTheme.bodySmall),
                  const SizedBox(height: 8),
                  Text(
                    'Field Scan records what the phone can measure: ARKit depth, camera poses, photos and a scene mesh, in metres in a local frame. '
                    'It does not identify minerals or rock types, and a scan of a few metres cannot confirm kilometre-scale planetary comparisons. '
                    'Finding analog sites is the website\'s job. Built for NASA Space Apps 2026 by team Vancomycin; code drafted with AI assistance (Claude, Anthropic). '
                    'Typeface: Nunito Sans (SIL Open Font License).',
                    style: t.textTheme.bodyMedium?.copyWith(color: Fs.ink2),
                  ),
                ]),
              ),
            ]),
          ),
        ]),
      ),
    );
  }

  Widget _kv(String k, String v, {bool last = false}) => Container(
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(border: last ? null : const Border(bottom: BorderSide(color: Fs.quiet))),
        child: Row(children: [
          Expanded(child: Text(k, style: const TextStyle(fontSize: 14, color: Fs.ink2))),
          Text(v, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
        ]),
      );
}

// Draft written with AI assistance (Claude, Anthropic); disclosed per the Space Apps AI policy.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../service/app_state.dart';
import '../service/models.dart';
import '../service/platform.dart';
import '../widgets/common.dart';

class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    final t = Theme.of(context);
    final h = s.health;
    final sdk = asMap(h['realsense_sdk']);
    final home = asStr(h['home'], s.launcher.home ?? '');
    const lw = 140.0;

    final left = <Widget>[
      SectionCard(
        title: 'What this app does',
        child: Text(
          'Field Station records depth and colour from a sensor (Intel RealSense D435 first), writes reproducible scan bundles, '
          'and computes local geometric measurements with units, uncertainty and limitations. It imports iPhone LiDAR scan bundles. '
          'It does not identify rock type or mineralogy, and it does not rank or score planetary analogs; a scan can carry a website '
          'candidate ID as a reference only. Everything works offline.',
          style: t.textTheme.bodyMedium?.copyWith(height: 1.55),
        ),
      ),
      const SizedBox(height: 16),
      SectionCard(
        title: 'Versions',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            KV('App', '${h['app'] ?? 'Field Station'} ${h['version'] ?? ''}', labelWidth: lw),
            KV('Scan schema', asStr(h['schema_version'], '—'), labelWidth: lw),
            KV('Phone protocol', asStr(h['protocol_version'], '—'), labelWidth: lw),
            KV('Pipeline', asStr(h['pipeline_version'], '—'), labelWidth: lw),
            KV(
              'RealSense SDK',
              sdk['available'] == true ? '${sdk['package']} ${sdk['version'] ?? ''}' : 'not available: ${sdk['error'] ?? '—'}',
              labelWidth: lw,
            ),
            KV(
              'Service',
              s.launcher.external
                  ? 'external (FIELDSTATION_URL), not started by this app'
                  : 'started by this app from ${s.launcher.serviceDir ?? '—'}',
              labelWidth: lw,
            ),
            if (asList(h['recovered_scans']).isNotEmpty)
              KV(
                'Recovered at start',
                '${asList(h['recovered_scans']).length} scans marked incomplete after an interruption',
                labelWidth: lw,
              ),
            KV('Data folder', home.isEmpty ? '—' : home, labelWidth: lw),
            if (home.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(left: lw - 10),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(onPressed: () => Desktop.reveal(home), child: Text('Open in ${Desktop.fileManager}')),
                ),
              ),
          ],
        ),
      ),
      const SizedBox(height: 16),
      SectionCard(
        title: 'Test sources',
        child: SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: s.fixturesSetting || s.launcher.fixtures,
          onChanged: s.launcher.external ? null : (v) => s.setFixtures(v),
          title: const Text('Offer the synthetic test scene in Devices'),
          subtitle: Text(
            s.launcher.external
                ? 'Set by the external service (currently ${s.launcher.fixtures ? 'on' : 'off'}).'
                : 'Restarts the local service. Synthetic scans are stamped SYNTHETIC everywhere. Keep it off for field work.',
          ),
        ),
      ),
    ];

    final diag = SectionCard(
      title: 'Diagnostics',
      subtitle: 'Output of the local service and the app, newest at the bottom.',
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: s.diagnostics.join('\n')));
              showSnack(context, 'Diagnostics copied.');
            },
            child: const Text('Copy'),
          ),
          const SizedBox(width: 4),
          OutlinedButton(onPressed: s.launcher.external ? null : () => s.restartService(), child: const Text('Restart service')),
        ],
      ),
      child: Container(
        height: 420,
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: FsPalette.sheetAlt,
          border: Border.all(color: FsPalette.ruleLight),
        ),
        child: s.diagnostics.isEmpty
            ? Text('Nothing yet.', style: t.textTheme.bodySmall)
            : ListView(
                reverse: true,
                children: [
                  for (final l in s.diagnostics.reversed.take(400))
                    Text(l, style: mono(t.textTheme.bodySmall, size: 11)?.copyWith(color: FsPalette.ink)),
                ],
              ),
      ),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const PageHeader(
          'About',
          subtitle: 'A field instrument workstation. Planetary analog discovery is on the project website, not here.',
        ),
        Expanded(
          child: LayoutBuilder(
            builder: (context, box) {
              if (box.maxWidth < 1000) {
                return ListView(padding: const EdgeInsets.fromLTRB(24, 0, 24, 24), children: [...left, const SizedBox(height: 16), diag]);
              }
              return ListView(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        flex: 5,
                        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: left),
                      ),
                      const SizedBox(width: 20),
                      Expanded(flex: 6, child: diag),
                    ],
                  ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }
}

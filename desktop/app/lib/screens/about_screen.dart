import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../service/app_state.dart';
import '../service/models.dart';
import '../widgets/common.dart';

class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    final t = Theme.of(context);
    final h = s.health;
    final sdk = asMap(h['realsense_sdk']);
    return ListView(padding: const EdgeInsets.only(bottom: 32), children: [
      const PageHeader('About', subtitle: 'Field instrument workstation. No planetary analog discovery here — that is on the website.'),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          SectionCard(
            title: 'Scope',
            child: Text(
              'Field Station acquires depth and colour from a sensor (Intel RealSense D435 first), writes reproducible scan bundles, '
              'and computes local geometric measurements with units, uncertainty and limitations. It imports iPhone ARKit scan bundles. '
              'It does not identify rock type or mineralogy, and it does not rank or score planetary analogs; a scan can carry a website '
              'candidate ID as a reference only. Everything works offline.',
              style: t.textTheme.bodyMedium,
            ),
          ),
          const SizedBox(height: 16),
          SectionCard(
            title: 'Versions',
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              KV('App', '${h['app'] ?? 'Field Station'} ${h['version'] ?? ''}'),
              KV('Scan schema', asStr(h['schema_version'], '—')),
              KV('BLE protocol', asStr(h['protocol_version'], '—')),
              KV('Pipeline', asStr(h['pipeline_version'], '—')),
              KV('RealSense SDK', sdk['available'] == true ? '${sdk['package']} ${sdk['version'] ?? ''}' : 'unavailable: ${sdk['error'] ?? '—'}'),
              KV('Data folder', asStr(h['home'], s.launcher.home ?? '—')),
              KV('Service', s.launcher.external ? 'external (FIELDSTATION_URL), not started by this app' : 'started by this app from ${s.launcher.serviceDir ?? '—'}'),
              if (asList(h['recovered_scans']).isNotEmpty)
                KV('Recovered at start', '${asList(h['recovered_scans']).length} scans marked incomplete after an interruption'),
            ]),
          ),
          const SizedBox(height: 16),
          SectionCard(
            title: 'Test sources',
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: s.fixturesSetting || s.launcher.fixtures,
                onChanged: s.launcher.external ? null : (v) => s.setFixtures(v),
                title: const Text('Offer the SYNTHETIC test scene in Devices'),
                subtitle: Text(s.launcher.external
                    ? 'Controlled by the external service (currently ${s.launcher.fixtures ? 'on' : 'off'}).'
                    : 'Restarts the local service. Synthetic scans are stamped SYNTHETIC everywhere. Keep off for field work.'),
              ),
            ]),
          ),
          const SizedBox(height: 16),
          SectionCard(
            title: 'Diagnostics',
            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
              TextButton(
                onPressed: () => Clipboard.setData(ClipboardData(text: s.diagnostics.join('\n'))),
                child: const Text('Copy'),
              ),
              TextButton(onPressed: s.launcher.external ? null : () => s.restartService(), child: const Text('Restart service')),
            ]),
            child: Container(
              height: 280,
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: t.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(6),
              ),
              child: ListView(
                reverse: true,
                children: [
                  for (final l in s.diagnostics.reversed.take(400))
                    Text(l, style: t.textTheme.bodySmall?.copyWith(fontFamily: 'Menlo', fontSize: 11)),
                ],
              ),
            ),
          ),
        ]),
      ),
    ]);
  }
}

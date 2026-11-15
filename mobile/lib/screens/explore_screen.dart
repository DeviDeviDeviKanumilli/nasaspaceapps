import 'package:flutter/material.dart';

import '../ui/rocks.dart';
import '../ui/style.dart';

/// Public scan catalog. No catalog service exists yet, so this says so instead of showing sample entries.
class ExploreScreen extends StatelessWidget {
  const ExploreScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(children: [
          const ScreenHeader(title: 'Explore', subtitle: Text('Field scans shared by other people')),
          Expanded(
            child: ListView(padding: const EdgeInsets.fromLTRB(Fs.side, 8, Fs.side, 24), children: [
              const SizedBox(height: 8),
              Center(
                child: SizedBox(
                  width: 240,
                  height: 150,
                  child: Stack(alignment: Alignment.bottomCenter, children: [
                    const Positioned(top: 0, child: SkyScene(width: 240)), // ground line at y≈103; the rock stands on it
                    const Positioned(bottom: 40, child: Pebble(width: 100, semanticLabel: 'A rock looking up at the Moon and Mars')),
                  ]),
                ),
              ),
              const SizedBox(height: 18),
              Text('No public catalog yet', style: t.titleLarge, textAlign: TextAlign.center),
              const SizedBox(height: 8),
              Text(
                'Reviewed field scans from other people will appear here: 3D previews, measurements, licences and limitations, '
                'searchable by coarse region, feature type and sensor. The catalog service is not built yet, so nothing is listed '
                'rather than showing invented examples.',
                textAlign: TextAlign.center,
                style: t.bodyMedium?.copyWith(color: Fs.muted),
              ),
              const SizedBox(height: 24),
              FsCard(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('What this tab is not', style: t.titleSmall),
                  const SizedBox(height: 4),
                  Text(
                    'Finding Earth sites that share terrain or geology with Moon and Mars regions happens on the project website, '
                    'from NASA and other agency data. This app only records and shares field observations; it never ranks analog sites.',
                    style: t.bodyMedium?.copyWith(color: Fs.ink2),
                  ),
                ]),
              ),
              const SizedBox(height: 10),
              FsCard(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('Today', style: t.titleSmall),
                  const SizedBox(height: 4),
                  Text(
                    'Prepare a contribution from any scan in your Library. It stays a private draft on this phone until a catalog service '
                    'exists and you choose to upload it for review.',
                    style: t.bodyMedium?.copyWith(color: Fs.ink2),
                  ),
                ]),
              ),
            ]),
          ),
        ]),
      ),
    );
  }
}

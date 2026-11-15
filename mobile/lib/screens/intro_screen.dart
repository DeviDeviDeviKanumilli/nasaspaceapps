// Two-page first-launch intro: what the app does, and what it keeps private. Shown once; replayable from Settings.
import 'package:flutter/material.dart';

import '../core/app_state.dart';
import '../main.dart';
import '../ui/rocks.dart';
import '../ui/style.dart';

class IntroScreen extends StatefulWidget {
  /// true when opened from Settings: finishing just closes it.
  final bool replay;
  const IntroScreen({super.key, this.replay = false});
  @override
  State<IntroScreen> createState() => _IntroScreenState();
}

class _IntroScreenState extends State<IntroScreen> {
  final _pages = PageController();
  int _page = 0;

  Future<void> _finish() async {
    final st = AppState.I;
    if (!st.introSeen) {
      st.introSeen = true;
      await st.saveSettings();
    }
    if (!mounted) return;
    if (widget.replay) {
      Navigator.of(context).pop();
    } else {
      Navigator.of(context).pushReplacement(PageRouteBuilder(
        pageBuilder: (_, _, _) => const HomeTabs(),
        transitionsBuilder: (_, a, _, child) => FadeTransition(opacity: a, child: child),
      ));
    }
  }

  void _next() {
    if (_page == 1) {
      _finish();
    } else {
      _pages.nextPage(duration: const Duration(milliseconds: 320), curve: Curves.easeOutCubic);
    }
  }

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(children: [
          SizedBox(
            height: 56,
            child: Align(
              alignment: Alignment.centerRight,
              child: Padding(
                padding: const EdgeInsets.only(right: Fs.side - 8),
                child: TextButton(onPressed: _finish, child: Text(widget.replay ? 'Close' : 'Skip')),
              ),
            ),
          ),
          Expanded(
            child: PageView(
              controller: _pages,
              onPageChanged: (i) => setState(() => _page = i),
              children: const [
                _Page(
                  art: _ScanArt(),
                  title: 'Measure rocks in 3D',
                  body: 'Field Scan records rock surfaces with the iPhone\'s LiDAR and camera, then measures them right on the phone.',
                  points: [
                    (Icons.back_hand_outlined, 'Scan handheld, or clip the phone on the FieldKit rig and it takes photos by itself.'),
                    (Icons.straighten_rounded, 'Measure distances, surface tilt and roughness on the 3D point cloud.'),
                    (Icons.cloud_off_rounded, 'Works with no signal. Everything is saved on the phone.'),
                  ],
                ),
                _Page(
                  art: _PrivateArt(),
                  title: 'Private by default',
                  body: 'Your scans are yours. Nothing leaves the phone unless you export it.',
                  points: [
                    (Icons.location_off_outlined, 'Location is off unless you turn it on, and GPS is never written into photos.'),
                    (Icons.lock_outline_rounded, 'Sharing makes a private draft first. Photos with people in them are left out.'),
                    (Icons.info_outline_rounded, 'The app reports geometry only. It doesn\'t identify rock types or rank Moon and Mars sites.'),
                  ],
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(Fs.side, 8, Fs.side, 16),
            child: Column(children: [
              Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                for (int i = 0; i < 2; i++)
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 220),
                    margin: const EdgeInsets.symmetric(horizontal: 4),
                    width: i == _page ? 22 : 8,
                    height: 8,
                    decoration: BoxDecoration(color: i == _page ? Fs.moss : Fs.lineStrong, borderRadius: BorderRadius.circular(4)),
                  ),
              ]),
              const SizedBox(height: 18),
              SizedBox(
                width: double.infinity,
                child: FilledButton(onPressed: _next, child: Text(_page == 1 ? (widget.replay ? 'Done' : 'Get started') : 'Next')),
              ),
            ]),
          ),
        ]),
      ),
    );
  }
}

class _Page extends StatelessWidget {
  final Widget art;
  final String title;
  final String body;
  final List<(IconData, String)> points;
  const _Page({required this.art, required this.title, required this.body, required this.points});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return ListView(padding: const EdgeInsets.symmetric(horizontal: Fs.side), children: [
      const SizedBox(height: 8),
      Center(child: art),
      const SizedBox(height: 28),
      Text(title, style: t.headlineMedium),
      const SizedBox(height: 8),
      Text(body, style: t.bodyLarge?.copyWith(color: Fs.muted, height: 1.45)),
      const SizedBox(height: 22),
      for (final (icon, text) in points)
        Padding(
          padding: const EdgeInsets.only(bottom: 14),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(color: Fs.mossTint, borderRadius: BorderRadius.circular(12)),
              child: Icon(icon, size: 19, color: Fs.mossInk),
            ),
            const SizedBox(width: 14),
            Expanded(child: Padding(padding: const EdgeInsets.only(top: 7), child: Text(text, style: t.bodyMedium?.copyWith(color: Fs.ink2)))),
          ]),
        ),
    ]);
  }
}

/// Page 1 art: the rock character on the ground between two plain rock shapes.
class _ScanArt extends StatelessWidget {
  const _ScanArt();
  @override
  Widget build(BuildContext context) => SizedBox(
        width: 300,
        height: 170,
        child: Stack(alignment: Alignment.bottomCenter, children: [
          Positioned(bottom: 10, left: 4, right: 4, child: Container(height: 2.5, decoration: BoxDecoration(color: const Color(0xFF3A3833), borderRadius: BorderRadius.circular(2)))),
          const Positioned(bottom: 11, left: 14, child: RockIcon('rock_face', width: 58)),
          const Positioned(bottom: 11, right: 12, child: RockIcon('boulder_field', width: 66)),
          const Positioned(bottom: 3, child: Pebble(width: 136, semanticLabel: 'A rock smiling')),
        ]),
      );
}

/// Page 2 art: the rock character with a small lock badge.
class _PrivateArt extends StatelessWidget {
  const _PrivateArt();
  @override
  Widget build(BuildContext context) => SizedBox(
        width: 300,
        height: 170,
        child: Stack(alignment: Alignment.bottomCenter, children: [
          Positioned(bottom: 10, left: 60, right: 60, child: Container(height: 2.5, decoration: BoxDecoration(color: const Color(0xFF3A3833), borderRadius: BorderRadius.circular(2)))),
          const Positioned(bottom: 3, child: Pebble(width: 150, mood: PebbleMood.sleeping, semanticLabel: 'A rock resting, eyes closed')),
          Positioned(
            top: 6,
            right: 70,
            child: Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(color: Fs.card, shape: BoxShape.circle, border: Border.all(color: Fs.moss, width: 2.5)),
              child: const Icon(Icons.lock_rounded, color: Fs.moss, size: 26),
            ),
          ),
        ]),
      );
}

import 'package:flutter/material.dart';

import '../core/app_state.dart';
import '../core/geometry.dart';
import '../core/scan_record.dart';
import '../ui/rocks.dart';
import '../ui/style.dart';
import 'scan_detail_screen.dart';

class LibraryScreen extends StatelessWidget {
  const LibraryScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return ListenableBuilder(
      listenable: AppState.I,
      builder: (context, _) {
        final scans = AppState.I.scans;
        return Scaffold(
          body: SafeArea(
            bottom: false,
            child: Column(children: [
              ScreenHeader(
                title: 'Library',
                subtitle: Text(scans.isEmpty ? 'Saved privately on this phone' : '${scans.length} scan${scans.length == 1 ? '' : 's'} · private on this phone'),
                trailing: scans.isEmpty
                    ? null
                    : OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(minimumSize: const Size(0, 40), padding: const EdgeInsets.symmetric(horizontal: 14)),
                        onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const CompareScreen())),
                        icon: const Icon(Icons.compare_arrows_rounded, size: 18),
                        label: const Text('Compare', style: TextStyle(fontSize: 14)),
                      ),
              ),
              Expanded(
                child: scans.isEmpty
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 40),
                          child: Column(mainAxisSize: MainAxisSize.min, children: [
                            const Pebble(width: 130, semanticLabel: 'A rock waiting to be scanned'),
                            const SizedBox(height: 18),
                            Text('No scans yet', style: t.textTheme.titleLarge),
                            const SizedBox(height: 6),
                            Text('Scans are saved privately on this phone and work without any signal.',
                                textAlign: TextAlign.center, style: t.textTheme.bodyMedium?.copyWith(color: Fs.muted)),
                          ]),
                        ),
                      )
                    : RefreshIndicator(
                        onRefresh: AppState.I.refresh,
                        child: ListView.separated(
                          padding: const EdgeInsets.fromLTRB(Fs.side, 4, Fs.side, 24),
                          itemCount: scans.length,
                          separatorBuilder: (_, _) => const SizedBox(height: 10),
                          itemBuilder: (c, i) => _ScanTile(scans[i]),
                        ),
                      ),
              ),
            ]),
          ),
        );
      },
    );
  }
}

class _ScanTile extends StatelessWidget {
  final ScanRecord r;
  const _ScanTile(this.r);

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final q = r.json['quality'] as Map? ?? {};
    final start = r.start?.toLocal();
    final pub = r.publication;
    final feature = '${(r.json['observation'] as Map?)?['feature_type'] ?? 'other'}';
    return FsCard(
      padding: const EdgeInsets.all(10),
      onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => ScanDetailScreen(record: r))).then((_) => AppState.I.refresh()),
      child: Row(children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: SizedBox(
            width: 72,
            height: 72,
            child: r.has('thumbnail.jpg')
                ? Image.file(r.file('thumbnail.jpg'), fit: BoxFit.cover, cacheWidth: 200)
                : Container(color: Fs.well, alignment: Alignment.center, child: RockIcon(feature, width: 46)),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(r.title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800), maxLines: 1, overflow: TextOverflow.ellipsis),
            const SizedBox(height: 2),
            Text(
              [
                if (start != null) '${start.year}-${_two(start.month)}-${_two(start.day)} ${_two(start.hour)}:${_two(start.minute)}',
                '${q['keyframes'] ?? 0} frames',
                if (q['fused_points'] != null) '${q['fused_points']} pts',
              ].join(' · '),
              style: t.textTheme.bodySmall,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 6),
            Wrap(spacing: 6, runSpacing: 4, children: [
              if (r.synthetic) const Tag('synthetic fixture', kind: TagKind.special),
              if (r.status != 'complete') Tag(r.status, kind: TagKind.warn),
              Tag(pub == 'local_private' ? 'private on phone' : pub.replaceAll('_', ' '), kind: pub == 'local_private' ? TagKind.neutral : TagKind.info),
              if (r.json['origin'] == 'iphone_arkit_camera') const Tag('photos only'),
              if (r.measurements.isNotEmpty) Tag('${r.measurements.length} measurements', kind: TagKind.good),
            ]),
          ]),
        ),
        const Icon(Icons.chevron_right_rounded, color: Fs.faint),
      ]),
    );
  }

  String _two(int v) => v.toString().padLeft(2, '0');
}

/// Groups measurements by (label, name) across scans: the repeatability check from the field protocol.
class CompareScreen extends StatelessWidget {
  const CompareScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final groups = <String, List<(ScanRecord, Map<String, dynamic>)>>{};
    for (final r in AppState.I.scans) {
      for (final m in r.measurements) {
        if (m['value'] == null) continue;
        groups.putIfAbsent('${m['label']}\u0000${m['name']}', () => []).add((r, m));
      }
    }
    final keys = groups.keys.where((k) => groups[k]!.length >= 2).toList()..sort();
    return Scaffold(
      appBar: subBar(context, 'Repeat scans'),
      body: keys.isEmpty
          ? Padding(
              padding: const EdgeInsets.all(Fs.side),
              child: Note(
                child: const Text(
                    'Give the same label to a measurement in two or more scans (for example "boulder A face" on three scans of the same boulder) '
                    'and they appear here with their spread. Spread between repeats is empirical repeatability, not accuracy.'),
              ),
            )
          : ListView(padding: const EdgeInsets.fromLTRB(Fs.side, 8, Fs.side, 24), children: [
              for (final k in keys) ...[_group(t, k, groups[k]!), const SizedBox(height: 10)],
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Text(
                    'Each scan has its own ARKit frame and its own picked ROI, so differences mix sensor noise, ROI placement and tracking. '
                    'SD uses n−1.',
                    style: t.textTheme.bodySmall),
              ),
            ]),
    );
  }

  Widget _group(ThemeData t, String key, List<(ScanRecord, Map<String, dynamic>)> items) {
    final parts = key.split('\u0000');
    final unit = items.first.$2['unit'];
    final vals = [for (final it in items) (it.$2['value'] as num).toDouble()];
    final s = SummaryStats.of(vals)!;
    String f(double v) => unit == 'deg' ? '${v.toStringAsFixed(1)}°' : '${(v * 1000).toStringAsFixed(1)} mm';
    return FsCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('${parts[0]} · ${parts[1].replaceAll('_', ' ')}', style: t.textTheme.labelLarge),
        const SizedBox(height: 6),
        Row(crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic, children: [
          Text(f(s.mean), style: t.textTheme.headlineSmall),
          const SizedBox(width: 10),
          Expanded(child: Text('± ${f(s.sd)} SD · n = ${s.n}', style: t.textTheme.bodySmall)),
        ]),
        Text('range ${f(s.min)} – ${f(s.max)}', style: t.textTheme.bodySmall),
        const SizedBox(height: 10),
        _Strip(vals),
        const SizedBox(height: 8),
        for (final it in items)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Row(children: [
              SizedBox(width: 76, child: Text(f((it.$2['value'] as num).toDouble()), style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700))),
              Expanded(child: Text(it.$1.title, style: t.textTheme.bodySmall, overflow: TextOverflow.ellipsis)),
            ]),
          ),
      ]),
    );
  }
}

/// Dots for each repeat on a track, with the min–max band shaded.
class _Strip extends StatelessWidget {
  final List<double> vals;
  const _Strip(this.vals);
  @override
  Widget build(BuildContext context) => SizedBox(height: 20, width: double.infinity, child: CustomPaint(painter: _StripPainter(vals)));
}

class _StripPainter extends CustomPainter {
  final List<double> v;
  _StripPainter(this.v);
  @override
  void paint(Canvas c, Size s) {
    final lo = v.reduce((a, b) => a < b ? a : b), hi = v.reduce((a, b) => a > b ? a : b);
    final pad = (hi - lo).abs() < 1e-12 ? (lo.abs() * 0.05 + 1e-6) : (hi - lo) * 0.6;
    double x(double val) => 8 + (val - (lo - pad)) / ((hi + pad) - (lo - pad)) * (s.width - 16);
    final mid = s.height / 2;
    c.drawLine(Offset(4, mid), Offset(s.width - 4, mid), Paint()..color = Fs.well..strokeWidth = 6..strokeCap = StrokeCap.round);
    c.drawRRect(RRect.fromLTRBR(x(lo) - 7, mid - 6, x(hi) + 7, mid + 6, const Radius.circular(6)), Paint()..color = Fs.mossTint);
    for (final val in v) {
      c.drawCircle(Offset(x(val), mid), 6, Paint()..color = Colors.white);
      c.drawCircle(Offset(x(val), mid), 4.5, Paint()..color = Fs.moss);
    }
  }

  @override
  bool shouldRepaint(_StripPainter o) => o.v != v;
}

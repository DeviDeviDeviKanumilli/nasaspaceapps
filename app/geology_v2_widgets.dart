// Flutter widgets for the geology_v2 block. Drop into the team app next to geology_v2.dart.
// NOTE: written against the stable Material API but NOT compiled here (no Flutter SDK in this environment);
// the data model in geology_v2.dart is tested with `dart run geology_v2_check.dart`.
// Draft written with AI assistance (Claude, Anthropic); disclosed per the Space Apps AI policy.
import 'package:flutter/material.dart';
import 'geology_v2.dart';

/// One row: Mars property (with evidence type, site and citations) beside the Earth record.
class ComparisonRowTile extends StatelessWidget {
  final ComparisonRow row;
  const ComparisonRowTile(this.row, {super.key});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final icon = row.role == 'not_compared'
        ? Icons.remove_circle_outline
        : row.earthRecorded
            ? Icons.check_circle_outline
            : (row.earthStatus.startsWith('CONTRADICTION') ? Icons.block : Icons.radio_button_unchecked);
    return ListTile(
      dense: true,
      leading: Icon(icon),
      title: Text('${row.property}  ·  ${row.roleLabel}', style: t.titleSmall),
      subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Mars (${row.marsEvidenceType}${row.marsSite == null ? '' : ', ${row.marsSite}'}): ${row.marsStatement}'),
        Text('Sources: ${row.citations.join(', ')}', style: t.bodySmall),
        Text('Earth: ${row.earthStatus}${row.earthText == null || row.earthText!.isEmpty ? '' : ' — "${row.earthText}"'}'),
      ]),
    );
  }
}

/// The featured independent-validation case (e.g. Lockatong in Sourland Mountain Preserve).
class FeaturedCaseCard extends StatelessWidget {
  final FeaturedCase f;
  const FeaturedCaseCard(this.f, {super.key});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final share = f.shareWithin500mOfIntrusion;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(f.title, style: t.titleMedium),
          const SizedBox(height: 4),
          Text(f.outcome, style: t.bodyMedium),
          Text('${f.unitName} (${f.unitLink}) · reference ${f.reference}', style: t.bodySmall),
          if (share != null)
            Text('Caution: ${(share * 100).round()}% of this polygon lies within 500 m of an intrusive contact (possible heat alteration).',
                style: t.bodySmall),
          for (final c in f.conflicts) Text('Recorded conflict: $c', style: t.bodySmall),
          Text(f.note, style: t.bodySmall),
          const Divider(),
          for (final r in f.comparison) ComparisonRowTile(r),
        ]),
      ),
    );
  }
}

/// Compact card for one candidate map unit. No score is shown because none exists.
class GeoUnitCardView extends StatelessWidget {
  final GeoUnitCard u;
  const GeoUnitCardView(this.u, {super.key});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return ExpansionTile(
      title: Text('${u.unitName} (${u.state})'),
      subtitle: Text('${u.reference} · supporting recorded ${u.supportingRecorded.length} of ${u.supportingTotal} · '
          '${u.areaKm2.toStringAsFixed(1)} km² · nearest ${u.nearestDistanceKm?.toStringAsFixed(0) ?? '-'} km'),
      children: [
        if (u.publicLandsWithSteepGround.isNotEmpty)
          Text('Steep public ground in: ${u.publicLandsWithSteepGround.join(', ')}', style: t.bodySmall),
        Text(u.exposureNote, style: t.bodySmall),
        for (final r in u.comparison) ComparisonRowTile(r),
        Text('Not comparable: ${u.notComparable.join('; ')}', style: t.bodySmall),
      ],
    );
  }
}

/// Section to place on a page: featured case first, then unit cards for one region/reference.
class GeologyV2Section extends StatelessWidget {
  final GeologyV2Block block;
  final String region, reference;
  const GeologyV2Section(this.block, {super.key, this.region = 'newark', this.reference = 'MARS-LAKE'});

  @override
  Widget build(BuildContext context) {
    return ListView(children: [
      for (final f in block.featured.where((f) => f.reference == reference)) FeaturedCaseCard(f),
      for (final u in block.unitsFor(region, reference)) GeoUnitCardView(u),
      for (final l in block.limitations) Padding(padding: const EdgeInsets.all(8), child: Text('Limitation: $l')),
    ]);
  }
}

// Parse an app_bundle.json with the geology_v2 model and print the featured case as the app would list it.
// Usage: dart run geology_v2_check.dart app_bundle.json
import 'dart:convert';
import 'dart:io';
import 'geology_v2.dart';

void main(List<String> args) {
  final bundle = jsonDecode(File(args[0]).readAsStringSync()) as Map<String, dynamic>;
  final g = GeologyV2Block.fromBundle(bundle);
  if (g == null) { print('no geology_v2 block (older bundle): app shows nothing new'); return; }
  print('block ${g.blockVersion}: ${g.references.length} references, ${g.units.length} unit cards, '
      '${g.featured.length} featured, ${g.controls.length} control rows');
  for (final f in g.featured) {
    print('\n${f.title}\n  ${f.outcome}\n  ${f.unitName} (${f.unitLink}); '
        '${((f.shareWithin500mOfIntrusion ?? 0) * 100).round()}% of polygon within 500 m of an intrusion');
    for (final r in f.comparison) {
      print('  [${r.roleLabel}] ${r.property}  Mars: ${r.marsEvidenceType}'
          '${r.marsSite == null ? '' : ' @${r.marsSite}'} (${r.citations.join(', ')})  Earth: ${r.earthStatus}');
    }
  }
  final serp = g.references.firstWhere((r) => r.id == 'MARS-SERP');
  print('\nMARS-SERP site note: ${serp.siteNote}');
  for (final c in g.controls) {
    print('control ${c.region} ${c.reference} ${c.method}: precision ${c.precision}, recall ${c.recall}');
  }
}

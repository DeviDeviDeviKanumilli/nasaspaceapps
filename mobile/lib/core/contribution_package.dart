// Builds the shareable contribution package: a zip holding only what the contribution form says becomes public.
// The full private scan folder never goes into it. Shared by the user through the iOS share sheet.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import 'scan_record.dart';

class ContributionOptions {
  final String locationPrecision; // hidden | coarse | exact
  final bool includePhotos; // already false when people or private property may be visible
  final bool includeNotes;
  final String license;
  final String attribution;
  const ContributionOptions({
    required this.locationPrecision,
    required this.includePhotos,
    required this.includeNotes,
    required this.license,
    required this.attribution,
  });
}

/// Location as it may appear publicly, or null.
Map<String, dynamic>? publicLocationOf(Map<String, dynamic> scanJson, String precision) {
  final loc = scanJson['location'] as Map? ?? {};
  if (precision == 'hidden' || loc['collected'] != true || loc['latitude'] == null) return null;
  final lat = (loc['latitude'] as num).toDouble(), lon = (loc['longitude'] as num).toDouble();
  if (precision == 'coarse') {
    return {'latitude': (lat * 10).round() / 10, 'longitude': (lon * 10).round() / 10, 'precision': 'rounded to 0.1 degree (about 10 km)'};
  }
  return {'latitude': lat, 'longitude': lon, 'uncertainty_m': loc['uncertainty_m'], 'precision': 'exact'};
}

/// The public copy of scan.json: no exact location unless chosen, no notes unless chosen, only the files in the package.
Map<String, dynamic> publicScanJson(Map<String, dynamic> scanJson, ContributionOptions o, Set<String> packagedFiles) {
  final j = jsonDecode(jsonEncode(scanJson)) as Map<String, dynamic>; // deep copy
  final pub = publicLocationOf(scanJson, o.locationPrecision);
  j['location'] = {'sharing': pub == null ? 'hidden' : o.locationPrecision, if (pub != null) ...pub};
  if (pub == null) j.remove('field_site_id'); // a site id can point at the place
  j.remove('session_id'); // links scans taken on the same outing
  j.remove('catalog_draft');
  final obs = Map<String, dynamic>.from(j['observation'] as Map? ?? {});
  if (!o.includeNotes) obs.remove('notes');
  j['observation'] = obs;
  final dev = Map<String, dynamic>.from(j['device'] as Map? ?? {});
  dev.remove('name'); // never present today; guard against future fields
  j['device'] = dev;
  j['files'] = [
    for (final f in (j['files'] as List? ?? []))
      if (packagedFiles.contains((f as Map)['path'])) f,
  ];
  j['publication'] = {'status': 'shared_package_unreviewed', 'license': o.license, 'attribution': o.attribution, 'consent_obtained': true};
  return j;
}

/// Removes metadata that can carry a position from a JPEG: any APP1 (EXIF or XMP) whose EXIF has a GPS block,
/// every XMP APP1, and APP13 (IPTC). EXIF without GPS is kept so photos keep their orientation.
Uint8List stripJpegLocation(Uint8List b) {
  if (b.length < 4 || b[0] != 0xFF || b[1] != 0xD8) return b; // not a JPEG
  final out = BytesBuilder(copy: false)..add([0xFF, 0xD8]);
  var i = 2;
  while (i + 4 <= b.length && b[i] == 0xFF) {
    final marker = b[i + 1];
    if (marker == 0xDA || marker == 0xD9) break; // start of scan: the rest is image data
    final len = (b[i + 2] << 8) | b[i + 3];
    final end = i + 2 + len;
    if (end > b.length) break;
    final seg = Uint8List.sublistView(b, i, end);
    var drop = marker == 0xED; // APP13 IPTC
    if (marker == 0xE1) {
      final payload = Uint8List.sublistView(b, i + 4, end);
      final isExif = payload.length > 6 && String.fromCharCodes(payload.sublist(0, 4)) == 'Exif';
      drop = !isExif || _exifHasGps(Uint8List.sublistView(payload, 6));
    }
    if (!drop) out.add(seg);
    i = end;
  }
  out.add(Uint8List.sublistView(b, i));
  return out.toBytes();
}

bool _exifHasGps(Uint8List t) {
  if (t.length < 8) return true; // unreadable: treat as unsafe
  final le = t[0] == 0x49;
  int u16(int o) => le ? t[o] | (t[o + 1] << 8) : (t[o] << 8) | t[o + 1];
  int u32(int o) => le ? t[o] | (t[o + 1] << 8) | (t[o + 2] << 16) | (t[o + 3] << 24) : (t[o] << 24) | (t[o + 1] << 16) | (t[o + 2] << 8) | t[o + 3];
  final ifd = u32(4);
  if (ifd + 2 > t.length) return true;
  final n = u16(ifd);
  for (var k = 0; k < n; k++) {
    final e = ifd + 2 + k * 12;
    if (e + 2 > t.length) return true;
    if (u16(e) == 0x8825) return true; // GPSInfo IFD pointer
  }
  return false;
}

/// Writes the package zip and returns it. [draft] is the catalog draft saved alongside the scan.
Future<File> buildContributionPackage(ScanRecord r, ContributionOptions o, Map<String, dynamic> draft, Directory outDir) async {
  final a = Archive();
  final packaged = <String>{};
  void addBytes(String name, List<int> bytes) => a.addFile(ArchiveFile(name, bytes.length, bytes));

  for (final name in ['point_cloud_fused.ply', 'mesh_arkit.ply']) {
    if (r.has(name)) {
      addBytes(name, await r.file(name).readAsBytes());
      packaged.add(name);
    }
  }
  if (o.includePhotos) {
    for (final sub in ['photos', 'keyframes']) {
      final d = Directory('${r.dir.path}/$sub');
      if (!d.existsSync()) continue;
      for (final f in d.listSync().whereType<File>().where((f) => f.path.toLowerCase().endsWith('.jpg'))) {
        final name = '$sub/${f.uri.pathSegments.last}';
        addBytes(name, stripJpegLocation(await f.readAsBytes()));
        packaged.add(name);
      }
    }
    if (r.has('thumbnail.jpg')) {
      addBytes('thumbnail.jpg', stripJpegLocation(await r.file('thumbnail.jpg').readAsBytes()));
      packaged.add('thumbnail.jpg');
    }
  }
  const enc = JsonEncoder.withIndent(' ');
  addBytes('scan_public.json', utf8.encode(enc.convert(publicScanJson(r.json, o, packaged))));
  addBytes('contribution.json', utf8.encode(enc.convert({...draft, 'packaged_files': packaged.toList()..sort()})));
  addBytes('README.txt', utf8.encode(_readme(r, o)));

  final safe = r.title.replaceAll(RegExp(r'[^A-Za-z0-9]+'), '-').replaceAll(RegExp(r'^-|-$'), '');
  final f = File('${outDir.path}/fieldscan-contribution-${safe.isEmpty ? 'scan' : safe}-${r.id.substring(0, 8)}.zip');
  await f.writeAsBytes(ZipEncoder().encode(a));
  return f;
}

String _readme(ScanRecord r, ContributionOptions o) => '''
Field Scan contribution package
${r.title}

A field observation recorded by a user with Field Scan (team Vancomycin, NASA Space Apps 2026).
It is not peer-reviewed and is not a certified planetary analog. The app records geometry only;
it does not identify rock types.

Licence: ${o.license}
Credit: ${o.attribution}
Location: ${o.locationPrecision == 'hidden' ? 'not included' : o.locationPrecision == 'coarse' ? 'rounded to about 10 km' : 'exact, chosen by the author'}
Photos: ${o.includePhotos ? 'included, with location metadata removed' : 'not included'}

Files
  scan_public.json   capture details, measurements and limitations (public copy)
  contribution.json  licence, consent and what the author chose to share
  *.ply              point cloud / mesh in the scan's local ARKit frame (metres, +Y up)
''';

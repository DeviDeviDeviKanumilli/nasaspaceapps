// Prepare a catalog contribution. There is no catalog service in this build: the result is a local draft
// (catalog_draft.json), and the user can share a package holding only the public parts through the share sheet.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../core/app_state.dart';
import '../core/contribution_package.dart';
import '../core/scan_record.dart';
import '../ui/style.dart';

const licenses = {
  'CC-BY-4.0': 'CC BY 4.0 (credit me)',
  'CC-BY-SA-4.0': 'CC BY-SA 4.0',
  'CC0-1.0': 'CC0 (public domain)',
  'all-rights-reserved': 'All rights reserved (viewable, not reusable)',
};

class ContributeScreen extends StatefulWidget {
  final ScanRecord record;
  const ContributeScreen({super.key, required this.record});
  @override
  State<ContributeScreen> createState() => _ContributeScreenState();
}

class _ContributeScreenState extends State<ContributeScreen> {
  ScanRecord get r => widget.record;
  String locationPrecision = 'hidden';
  String people = 'unsure';
  bool privateProperty = false;
  bool sensitiveSite = false;
  bool includePhotos = false;
  String license = 'CC-BY-4.0';
  late final TextEditingController credit;
  bool consent = false;
  bool ownRights = false;
  bool includeNotes = false;
  bool busy = false;

  @override
  void initState() {
    super.initState();
    credit = TextEditingController(text: AppState.I.displayName);
    final d = r.json['catalog_draft'] as Map?;
    if (d != null) {
      locationPrecision = d['location_precision'] ?? locationPrecision;
      license = d['license'] ?? license;
      credit.text = d['attribution'] ?? credit.text;
    }
  }

  bool get hasNotes => '${r.json['observation']?['notes'] ?? ''}'.trim().isNotEmpty;
  bool get photosAllowed => people == 'no' && !privateProperty;
  bool get canSave => consent && ownRights && credit.text.trim().isNotEmpty;

  List<String> get publicFiles => [
        if (r.has('point_cloud_fused.ply')) 'point_cloud_fused.ply',
        if (r.has('mesh_arkit.ply')) 'mesh_arkit.ply',
        'public scan.json (no device name, ${locationPrecision == 'exact' ? 'exact location' : 'no exact location'}, measurements and limitations kept)',
        if (includeNotes && hasNotes) 'your field notes',
        if (includePhotos && photosAllowed) 'keyframe and photo JPEGs (no GPS in EXIF)',
        if (includePhotos && photosAllowed && r.has('thumbnail.jpg')) 'thumbnail.jpg',
      ];

  String get publicLocation {
    final loc = r.json['location'] as Map? ?? {};
    if (locationPrecision == 'hidden' || loc['collected'] != true) return 'none';
    final lat = (loc['latitude'] as num).toDouble(), lon = (loc['longitude'] as num).toDouble();
    if (locationPrecision == 'coarse') return '${(lat * 10).round() / 10}, ${(lon * 10).round() / 10} (rounded to 0.1°, about 10 km)';
    return '${lat.toStringAsFixed(5)}, ${lon.toStringAsFixed(5)} (exact)';
  }

  Map<String, dynamic> _draft() => {
      'schema_version': schemaVersion,
      'catalog_entry_id': null,
      'scan_id': r.id,
      'status': 'draft_local',
      'status_note': 'No catalog service is configured in this build; nothing has been uploaded.',
      'visibility_requested': 'public_after_review',
      'license': license,
      'attribution': credit.text.trim(),
      'author_approval': {'consent': consent, 'owns_rights': ownRights, 'utc': utcNow()},
      'location_precision': locationPrecision,
      'public_location': publicLocation,
      'people_visible': people,
      'private_property_visible': privateProperty,
      'sensitive_site': sensitiveSite,
      'include_photos': includePhotos && photosAllowed,
      'public_files': publicFiles,
      'quality_state': 'unreviewed_user_contribution',
      'moderation': [],
      'include_notes': includeNotes && hasNotes,
      'revisions': [
        {'utc': utcNow(), 'change': 'draft prepared on phone'}
      ],
    };

  Future<Map<String, dynamic>> _writeDraft(String change) async {
    final draft = _draft();
    r.json['catalog_draft'] = draft;
    r.json['publication'] = {'status': 'draft_local', 'license': license, 'consent_obtained': consent};
    final f = r.file('catalog_draft.json');
    await f.writeAsString(const JsonEncoder.withIndent(' ').convert(draft));
    await r.save(change);
    await AppState.I.refresh();
    return draft;
  }

  Future<void> _save() async {
    await _writeDraft('catalog draft prepared (local only)');
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Draft saved on this phone. Not uploaded: no catalog service yet.')));
      Navigator.of(context).pop();
    }
  }

  /// Builds the public-only package and opens the share sheet (AirDrop, Files, Messages, Mail).
  Future<void> _share(BuildContext buttonContext) async {
    final box = buttonContext.findRenderObject() as RenderBox?;
    final origin = box == null ? null : box.localToGlobal(Offset.zero) & box.size;
    setState(() => busy = true);
    try {
      final draft = await _writeDraft('contribution package prepared for sharing');
      final out = Directory('${(await getTemporaryDirectory()).path}/contributions')..createSync(recursive: true);
      final zip = await buildContributionPackage(
        r,
        ContributionOptions(
          locationPrecision: locationPrecision,
          includePhotos: includePhotos && photosAllowed,
          includeNotes: includeNotes && hasNotes,
          license: license,
          attribution: credit.text.trim(),
        ),
        draft,
        out,
      );
      final res = await SharePlus.instance.share(ShareParams(
        files: [XFile(zip.path, mimeType: 'application/zip')],
        subject: 'Field Scan contribution: ${r.title}',
        sharePositionOrigin: origin,
      ));
      if (res.status == ShareResultStatus.success) {
        await r.save('contribution package shared by the author (${res.raw.isEmpty ? 'share sheet' : res.raw})');
      }
      if (mounted && res.status == ShareResultStatus.success) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Contribution package shared. Only the public parts were included.')));
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not build the package: $e')));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Scaffold(
      appBar: subBar(context, 'Prepare contribution'),
      body: ListView(padding: const EdgeInsets.fromLTRB(Fs.side, 8, Fs.side, 32), children: [
        const Note(
          kind: TagKind.info,
          leading: Icon(Icons.lock_outline_rounded, color: Fs.blueInk),
          child: Text(
              'Contributions are field observations by users, not certified planetary analogs. There is no catalog service yet: '
              'save a private draft on this phone, or share a package with only the public parts (AirDrop, Files, Mail). '
              'A future catalog upload would still need a reviewer to approve it.'),
        ),
        const SizedBox(height: 22),
        const SectionLabel('Location'),
        SegmentedButton<String>(
          showSelectedIcon: false,
          segments: const [
            ButtonSegment(value: 'hidden', label: Text('Hidden')),
            ButtonSegment(value: 'coarse', label: Text('~10 km')),
            ButtonSegment(value: 'exact', label: Text('Exact')),
          ],
          selected: {locationPrecision},
          onSelectionChanged: (s) => setState(() => locationPrecision = s.first),
        ),
        const SizedBox(height: 6),
        Text(r.json['location']?['collected'] == true ? 'Public: $publicLocation' : 'No location was saved with this scan.', style: t.textTheme.bodySmall),
        const SizedBox(height: 22),
        const SectionLabel('Are people visible in any photo?'),
        SegmentedButton<String>(
          showSelectedIcon: false,
          segments: const [
            ButtonSegment(value: 'no', label: Text('No')),
            ButtonSegment(value: 'yes', label: Text('Yes')),
            ButtonSegment(value: 'unsure', label: Text('Not sure')),
          ],
          selected: {people},
          onSelectionChanged: (s) => setState(() => people = s.first),
        ),
        if (people != 'no') ...[
          const SizedBox(height: 8),
          const Note(kind: TagKind.warn, child: Text('Photos will not be included. Many on this team are under 18: never publish faces.')),
        ],
        const SizedBox(height: 12),
        CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          value: privateProperty,
          onChanged: (v) => setState(() => privateProperty = v!),
          title: const Text('Private property, car plates or buildings are visible'),
        ),
        CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          value: sensitiveSite,
          onChanged: (v) => setState(() {
            sensitiveSite = v!;
            if (v) locationPrecision = 'hidden';
          }),
          title: const Text('Sensitive site (fossils, protected habitat, cave)'),
          subtitle: const Text('Forces the location to hidden.'),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: includePhotos && photosAllowed,
          onChanged: photosAllowed ? (v) => setState(() => includePhotos = v) : null,
          title: const Text('Include photos'),
          subtitle: Text(photosAllowed ? 'GPS is never written into the images.' : 'Only when no people and no private property are visible.'),
        ),
        if (hasNotes)
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: includeNotes,
            onChanged: (v) => setState(() => includeNotes = v),
            title: const Text('Include my field notes'),
            subtitle: const Text('Off by default. Read them first: no names, phone numbers or exact directions.'),
          ),
        const SizedBox(height: 16),
        DropdownButtonFormField<String>(
          isExpanded: true,
          initialValue: license,
          borderRadius: BorderRadius.circular(16),
          decoration: const InputDecoration(labelText: 'Licence'),
          items: [for (final e in licenses.entries) DropdownMenuItem(value: e.key, child: Text(e.value, overflow: TextOverflow.ellipsis))],
          onChanged: (v) => setState(() => license = v!),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: credit,
          decoration: const InputDecoration(labelText: 'Credit as', hintText: 'A nickname is fine'),
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 22),
        const SectionLabel('What would become public'),
        FsCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            for (final f in publicFiles) _bullet(Icons.public_rounded, f),
            _bullet(Icons.block_rounded, 'Never shared: device identifiers, the outing (session) id, exact location unless chosen, field notes unless included'),
          ]),
        ),
        const SizedBox(height: 12),
        CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          value: ownRights,
          onChanged: (v) => setState(() => ownRights = v!),
          title: const Text('I made this scan and may share it; I stayed on the trail and collected nothing'),
        ),
        CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          value: consent,
          onChanged: (v) => setState(() => consent = v!),
          title: const Text('I agree to submit this for review under the licence above'),
        ),
        const SizedBox(height: 16),
        FilledButton(onPressed: canSave && !busy ? _save : null, child: const Text('Save draft on this phone')),
        const SizedBox(height: 8),
        Builder(
          builder: (bc) => OutlinedButton.icon(
            onPressed: canSave && !busy ? () => _share(bc) : null,
            icon: busy
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.ios_share_rounded),
            label: const Text('Share contribution package'),
          ),
        ),
        const SizedBox(height: 6),
        Text('Shares only what is listed above. Upload to a public catalog is not built yet.',
            style: t.textTheme.bodySmall, textAlign: TextAlign.center),
      ]),
    );
  }

  Widget _bullet(IconData i, String s) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(i, size: 16, color: Fs.faint),
          const SizedBox(width: 10),
          Expanded(child: Text(s, style: const TextStyle(fontSize: 13, color: Fs.ink2, height: 1.4))),
        ]),
      );
}

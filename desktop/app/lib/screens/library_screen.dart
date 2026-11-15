import 'dart:io';

import 'package:flutter/material.dart';

import '../service/app_state.dart';
import '../service/models.dart';
import '../widgets/common.dart';
import '../widgets/honesty_banner.dart';

class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key});
  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  List<ScanSummary> _scans = [];
  int _version = -1;
  bool _loading = false;
  String? _error;
  Map<String, dynamic> _detail = {};
  String? _detailFor;
  int _detailVersion = -1;
  bool _busy = false;
  String? _exportPath;

  Future<void> _load(AppState s) async {
    _version = s.scansVersion;
    setState(() => _loading = true);
    try {
      final r = asMap(await s.api!.getJson('/api/scans'));
      _scans = asList(r['scans']).map((e) => ScanSummary(asMap(e))).toList();
      _error = null;
    } catch (e) {
      _error = errText(e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _loadDetail(AppState s, String id) async {
    _detailFor = id;
    _detailVersion = s.scansVersion;
    try {
      final d = asMap(await s.api!.getJson('/api/scans/$id'));
      if (mounted) setState(() => _detail = d);
    } catch (e) {
      if (mounted) setState(() => _detail = {'error': errText(e)});
    }
  }

  Future<void> _import(AppState s) async {
    String? path;
    try {
      final r = await Process.run('osascript', [
        '-e',
        'POSIX path of (choose file with prompt "Import a scan bundle (.zip) or point cloud (.ply)" of type {"zip", "ply", "public.zip-archive"})',
      ]);
      if (r.exitCode == 0) path = (r.stdout as String).trim();
    } catch (_) {}
    if (path == null || path.isEmpty) return;
    setState(() => _busy = true);
    try {
      final r = asMap(await s.api!.postJson('/api/import', {'path': path}));
      if (mounted) showSnack(context, 'Imported ${originBadge(r['origin'] as String?)} scan ${shortId(r['scan_id'] as String?)} (checksums verified)');
      s.selectScan(r['scan_id'] as String?);
      s.bumpScans();
    } catch (e) {
      if (mounted) _alert('Import refused', errText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _export(AppState s, String id) async {
    setState(() => _busy = true);
    try {
      final r = asMap(await s.api!.postJson('/api/scans/$id/export'));
      setState(() => _exportPath = r['path'] as String?);
    } catch (e) {
      if (mounted) showSnack(context, errText(e), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _reprocess(AppState s, String id) async {
    setState(() => _busy = true);
    try {
      await s.api!.postJson('/api/scans/$id/reprocess', {'params': {}});
      s.bumpScans();
      if (mounted) showSnack(context, 'Derived files rebuilt from the raw frames.');
    } catch (e) {
      if (mounted) _alert('Reprocess failed', errText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _alert(String title, String msg) {
    showDialog<void>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(title),
        content: SizedBox(width: 480, child: SelectableText(msg)),
        actions: [TextButton(onPressed: () => Navigator.pop(c), child: const Text('OK'))],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    final t = Theme.of(context);
    if (_version != s.scansVersion && !_loading) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _load(s));
      _version = s.scansVersion;
    }
    final sel = s.selectedScanId;
    if (sel != null && (_detailFor != sel || _detailVersion != s.scansVersion)) {
      _detailFor = sel;
      WidgetsBinding.instance.addPostFrameCallback((_) => _loadDetail(s, sel));
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      PageHeader('Library',
          subtitle: 'Scans stored on this Mac (${s.health['home'] ?? ''}). Private by default; nothing is uploaded.',
          actions: [
            OutlinedButton.icon(
              onPressed: _busy ? null : () => _import(s),
              icon: const Icon(Icons.file_open_outlined),
              label: const Text('Import .zip / .ply'),
            ),
          ]),
      if (_error != null) Padding(padding: const EdgeInsets.symmetric(horizontal: 24), child: ErrorBox(_error!)),
      Expanded(
        child: _scans.isEmpty && !_loading
            ? const EmptyState(
                icon: Icons.folder_open_outlined,
                title: 'No scans yet',
                body: 'Record a scan in Capture, or import an iPhone scan bundle (.zip) sent by AirDrop or Files.')
            : Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                SizedBox(
                  width: 430,
                  child: ListView.separated(
                    padding: const EdgeInsets.fromLTRB(24, 0, 12, 24),
                    itemCount: _scans.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 8),
                    itemBuilder: (_, i) => _tile(s, t, _scans[i], _scans[i].id == sel),
                  ),
                ),
                const VerticalDivider(width: 1),
                Expanded(child: sel == null ? const EmptyState(icon: Icons.touch_app_outlined, title: 'Select a scan') : _detailPane(s, t, sel)),
              ]),
      ),
    ]);
  }

  Widget _tile(AppState s, ThemeData t, ScanSummary sc, bool selected) {
    return Material(
      color: selected ? t.colorScheme.primary.withValues(alpha: 0.08) : Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: selected ? t.colorScheme.primary : t.colorScheme.outlineVariant),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () => s.selectScan(sc.id),
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: SizedBox(
                width: 120,
                height: 68,
                child: sc.hasThumbnail
                    ? Image.network(s.api!.url('/api/scans/${sc.id}/file/thumbnail.jpg').toString(),
                        fit: BoxFit.cover, errorBuilder: (_, e, _) => const ColoredBox(color: Colors.black12))
                    : ColoredBox(color: t.colorScheme.surfaceContainerHighest, child: const Icon(Icons.scatter_plot_outlined)),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(sc.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: t.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w600)),
                const SizedBox(height: 4),
                Row(children: [OriginChip(sc.origin), const SizedBox(width: 8), StatusChip(sc.status)]),
                const SizedBox(height: 4),
                Text(
                  '${(sc.capturedAt ?? '').replaceFirst('T', ' ').split('.').first} UTC\n${sc.frames ?? '—'} frames · ${sc.measurementCount} measurements',
                  style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                if (sc.status == 'incomplete' && sc.statusReason != null)
                  Text(sc.statusReason!, maxLines: 2, overflow: TextOverflow.ellipsis, style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.error)),
              ]),
            ),
            Tooltip(
              message: 'Include in repeatability comparison',
              child: Checkbox(value: s.repeatSelection.contains(sc.id), onChanged: (_) => s.toggleRepeat(sc.id)),
            ),
          ]),
        ),
      ),
    );
  }

  Widget _detailPane(AppState s, ThemeData t, String id) {
    if (_detail['error'] != null) return Padding(padding: const EdgeInsets.all(24), child: ErrorBox('${_detail['error']}'));
    final man = asMap(_detail['manifest']);
    if (man.isEmpty || man['scan_id'] != id) return const Center(child: CircularProgressIndicator());
    final obs = asMap(man['observation']);
    final dev = asMap(man['device']);
    final cap = asMap(man['capture']);
    final pub = asMap(man['publication']);
    final files = asList(man['files']).map(asMap).toList();
    final log = asList(_detail['log']).map(asMap).toList();
    final draft = _detail['catalog_draft'];
    final captured = man['captured_at_utc'];
    final start = captured is Map ? captured['start'] : captured;
    final isD435Like = _detail['depth_image'] != null;
    return ListView(padding: const EdgeInsets.fromLTRB(20, 0, 24, 32), children: [
      HonestyBanner(origin: man['origin'] as String?, isRealSensor: man['is_real_sensor'] as bool?, replayOf: asMap(man['replay_of'])['scan_id'] as String?),
      const SizedBox(height: 12),
      Wrap(spacing: 8, runSpacing: 8, children: [
        FilledButton.icon(onPressed: () => s.go(Section.viewer, scanId: id), icon: const Icon(Icons.view_in_ar), label: const Text('View 3D')),
        OutlinedButton.icon(onPressed: () => s.go(Section.analysis, scanId: id), icon: const Icon(Icons.straighten), label: const Text('Analyse')),
        OutlinedButton.icon(onPressed: _busy ? null : () => _export(s, id), icon: const Icon(Icons.archive_outlined), label: const Text('Export zip')),
        OutlinedButton.icon(onPressed: () => _editDialog(s, id, obs, man), icon: const Icon(Icons.edit_outlined), label: const Text('Edit notes')),
        if (isD435Like)
          OutlinedButton.icon(onPressed: _busy ? null : () => _reprocess(s, id), icon: const Icon(Icons.refresh), label: const Text('Reprocess')),
        OutlinedButton.icon(onPressed: () => _draftDialog(s, id, obs, draft), icon: const Icon(Icons.public_outlined), label: const Text('Catalog draft')),
      ]),
      if (_exportPath != null && _exportPath!.contains(id)) ...[
        const SizedBox(height: 10),
        Row(children: [
          Expanded(child: SelectableText('Exported: $_exportPath', style: t.textTheme.bodySmall)),
          TextButton(onPressed: () => Process.run('open', ['-R', _exportPath!]), child: const Text('Reveal in Finder')),
        ]),
      ],
      const SizedBox(height: 16),
      SectionCard(
        title: asStr(obs['title']).isEmpty ? 'Untitled scan' : asStr(obs['title']),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          KV('Scan ID', asStr(man['scan_id'])),
          KV('Session ID', asStr(man['session_id'])),
          KV('Status', '${man['status']}${man['status_reason'] != null ? ' — ${man['status_reason']}' : ''}'),
          KV('Origin', '${originBadge(man['origin'] as String?)} (${man['origin']})'),
          KV('Device', [dev['manufacturer'], dev['model'], if (dev['firmware'] != null) 'fw ${dev['firmware']}', if (dev['usb_type'] != null) 'USB ${dev['usb_type']}']
              .whereType<Object>()
              .join(' · ')),
          KV('Captured (UTC)', asStr(start, '—')),
          KV('Frames', '${cap['frames_recorded'] ?? cap['keyframes'] ?? '—'} (profile ${cap['profile'] ?? '—'})'),
          KV('Coordinate frame', '${asMap(man['coordinate_frame'])['name']} — ${asMap(man['coordinate_frame'])['axes'] ?? asMap(man['coordinate_frame'])['up'] ?? ''}'),
          KV('Feature type', '${obs['feature_type'] ?? '—'} (user annotation)'),
          if (asStr(obs['notes']).isNotEmpty) KV('Notes', asStr(obs['notes'])),
          for (final c in asList(obs['claims']).map(asMap)) KV('Claim (${c['kind']})', asStr(c['text'])),
          KV('Field site / candidate', '${man['field_site_id'] ?? '—'} / ${man['candidate_id'] ?? '—'} (references only)'),
          KV('Location', '${asMap(man['location'])['sharing'] ?? 'hidden'} — ${asMap(man['location'])['note'] ?? ''}'),
          KV('Publication', '${pub['status']} · license ${pub['license'] ?? 'none'} · consent ${pub['consent_obtained'] == true ? 'yes' : 'no'}'),
        ]),
      ),
      const SizedBox(height: 16),
      SectionCard(
        title: 'Limitations',
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          for (final l in asList(man['limitations'])) Padding(padding: const EdgeInsets.symmetric(vertical: 2), child: Text('• $l', style: t.textTheme.bodySmall)),
        ]),
      ),
      const SizedBox(height: 16),
      SectionCard(
        title: 'Files (${files.length}) — SHA-256 recorded for each',
        child: Column(children: [
          for (final f in files.take(60))
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(children: [
                SizedBox(
                  width: 62,
                  child: Text(asStr(f['kind'], '—'),
                      style: t.textTheme.labelSmall?.copyWith(color: f['kind'] == 'raw' ? t.colorScheme.primary : t.colorScheme.onSurfaceVariant)),
                ),
                Expanded(child: Text(asStr(f['path']), style: t.textTheme.bodySmall, overflow: TextOverflow.ellipsis)),
                SizedBox(width: 120, child: Text(asStr(f['role']), style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant), overflow: TextOverflow.ellipsis)),
                SizedBox(width: 80, child: Text(_bytes(asInt(f['bytes'])), textAlign: TextAlign.right, style: t.textTheme.bodySmall)),
                const SizedBox(width: 10),
                Text(asStr(f['sha256']).length >= 12 ? asStr(f['sha256']).substring(0, 12) : '—',
                    style: t.textTheme.bodySmall?.copyWith(fontFamily: 'Menlo', color: t.colorScheme.onSurfaceVariant)),
              ]),
            ),
          if (files.length > 60) Text('… ${files.length - 60} more (see scan.json)', style: t.textTheme.bodySmall),
        ]),
      ),
      const SizedBox(height: 16),
      SectionCard(
        title: 'Log (latest ${log.length > 30 ? 30 : log.length})',
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          for (final e in log.reversed.take(30))
            Text('${asStr(e['t_utc']).split('.').first}  ${e['event']}  ${e.entries.where((x) => x.key != 't_utc' && x.key != 'event').map((x) => '${x.key}=${x.value}').join(' ')}',
                style: t.textTheme.bodySmall?.copyWith(fontFamily: 'Menlo', fontSize: 11), maxLines: 2, overflow: TextOverflow.ellipsis),
        ]),
      ),
    ]);
  }

  static String _bytes(int? b) {
    if (b == null) return '—';
    if (b > 1e6) return '${(b / 1e6).toStringAsFixed(1)} MB';
    if (b > 1e3) return '${(b / 1e3).toStringAsFixed(0)} kB';
    return '$b B';
  }

  Future<void> _editDialog(AppState s, String id, Map<String, dynamic> obs, Map<String, dynamic> man) async {
    final title = TextEditingController(text: asStr(obs['title']));
    final notes = TextEditingController(text: asStr(obs['notes']));
    final site = TextEditingController(text: asStr(man['field_site_id']));
    final cand = TextEditingController(text: asStr(man['candidate_id']));
    final claim = TextEditingController();
    String feature = featureTypes.contains(obs['feature_type']) ? obs['feature_type'] as String : 'other';
    String claimKind = 'observed';
    final claims = asList(obs['claims']).map(asMap).toList();
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, set) => AlertDialog(
          title: const Text('Edit observation'),
          content: SizedBox(
            width: 520,
            child: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                TextField(controller: title, decoration: const InputDecoration(labelText: 'Title')),
                const SizedBox(height: 10),
                DropdownButtonFormField<String>(
                  initialValue: feature,
                  items: [for (final f in featureTypes) DropdownMenuItem(value: f, child: Text(prettyName(f)))],
                  onChanged: (v) => set(() => feature = v ?? 'other'),
                  decoration: const InputDecoration(labelText: 'Feature type (annotation, not automatic classification)'),
                ),
                const SizedBox(height: 10),
                TextField(controller: notes, maxLines: 3, decoration: const InputDecoration(labelText: 'Notes')),
                const SizedBox(height: 10),
                TextField(controller: site, decoration: const InputDecoration(labelText: 'Field site ID (website reference)')),
                const SizedBox(height: 10),
                TextField(controller: cand, decoration: const InputDecoration(labelText: 'Website candidate ID (reference only)')),
                const SizedBox(height: 16),
                Text('Claims', style: Theme.of(c).textTheme.titleSmall),
                for (final cl in claims) Text('• [${cl['kind']}] ${cl['text']}'),
                Row(children: [
                  Expanded(child: TextField(controller: claim, decoration: const InputDecoration(labelText: 'Add a claim'))),
                  const SizedBox(width: 8),
                  DropdownButton<String>(
                    value: claimKind,
                    items: const [
                      DropdownMenuItem(value: 'observed', child: Text('observed')),
                      DropdownMenuItem(value: 'interpreted', child: Text('interpreted')),
                      DropdownMenuItem(value: 'user_reported', child: Text('user reported')),
                    ],
                    onChanged: (v) => set(() => claimKind = v ?? 'observed'),
                  ),
                  IconButton(
                    onPressed: () => set(() {
                      if (claim.text.trim().isNotEmpty) claims.add({'text': claim.text.trim(), 'kind': claimKind});
                      claim.clear();
                    }),
                    icon: const Icon(Icons.add),
                  ),
                ]),
              ]),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Save')),
          ],
        ),
      ),
    );
    if (ok == true) {
      try {
        await s.api!.patchJson('/api/scans/$id', {
          'title': title.text.trim(),
          'notes': notes.text.trim(),
          'feature_type': feature,
          'field_site_id': site.text.trim(),
          'candidate_id': cand.text.trim(),
          'claims': claims,
        });
        s.bumpScans();
      } catch (e) {
        if (mounted) showSnack(context, errText(e), error: true);
      }
    }
  }

  Future<void> _draftDialog(AppState s, String id, Map<String, dynamic> obs, Object? existing) async {
    final ex = asMap(existing);
    final attribution = TextEditingController(text: asStr(ex['attribution']));
    String? license = ex['license'] as String?;
    bool approval = ex['author_approval'] == true;
    bool consent = ex['consent_obtained'] == true;
    bool? people = ex['people_or_private_property_visible'] as bool?;
    const licenses = ['CC BY 4.0', 'CC BY-SA 4.0', 'CC0 1.0', 'All rights reserved'];
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, set) => AlertDialog(
          title: const Text('Prepare catalog draft'),
          content: SizedBox(
            width: 520,
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(border: Border.all(color: warnColor(c)), borderRadius: BorderRadius.circular(6)),
                child: Text('Local draft only — this build has no catalog service; nothing is uploaded. Location stays hidden.',
                    style: TextStyle(color: warnColor(c), fontWeight: FontWeight.w600)),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: licenses.contains(license) ? license : null,
                items: [for (final l in licenses) DropdownMenuItem(value: l, child: Text(l))],
                onChanged: (v) => set(() => license = v),
                decoration: const InputDecoration(labelText: 'License (your explicit choice)'),
              ),
              const SizedBox(height: 10),
              TextField(controller: attribution, decoration: const InputDecoration(labelText: 'Attribution (pseudonym is fine)')),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: approval,
                onChanged: (v) => set(() => approval = v ?? false),
                title: const Text('I am the author, or have the author\'s approval'),
              ),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: consent,
                onChanged: (v) => set(() => consent = v ?? false),
                title: const Text('I consent to this scan being shared once a catalog exists'),
              ),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                tristate: true,
                value: people,
                onChanged: (v) => set(() => people = v),
                title: const Text('People, faces or private property are visible'),
                subtitle: const Text('Unchecked = no, dash = not reviewed. Scans showing people must not be published.'),
              ),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Save local draft')),
          ],
        ),
      ),
    );
    if (ok == true) {
      try {
        await s.api!.postJson('/api/scans/$id/catalog_draft', {
          'title': obs['title'],
          'license': license,
          'attribution': attribution.text.trim(),
          'author_approval': approval,
          'consent_obtained': consent,
          'people_or_private_property_visible': people,
        });
        s.bumpScans();
        if (mounted) showSnack(context, 'Local catalog draft saved (status draft_local). Nothing was uploaded.');
      } catch (e) {
        if (mounted) showSnack(context, errText(e), error: true);
      }
    }
  }
}

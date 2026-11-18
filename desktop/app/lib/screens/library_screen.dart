// Draft written with AI assistance (Claude, Anthropic); disclosed per the Space Apps AI policy.

import 'dart:async';

import 'package:flutter/material.dart';

import '../service/app_state.dart';
import '../service/models.dart';
import '../service/platform.dart';
import '../widgets/common.dart';
import '../widgets/honesty_banner.dart';

enum _OriginFilter { all, real, iphone, synthetic, replay, unverified }

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
  final _search = TextEditingController();
  _OriginFilter _filter = _OriginFilter.all;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

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
    final path = await Desktop.pickFile(
      prompt: 'Import a scan bundle (.zip) or point cloud (.ply)',
      extensions: const ['zip', 'ply'],
      description: 'Scan bundles and point clouds',
    );
    if (path == null || path.isEmpty) return;
    setState(() => _busy = true);
    try {
      final r = asMap(await s.api!.postJson('/api/import', {'path': path}));
      if (mounted) {
        showSnack(
          context,
          'Imported scan ${shortId(r['scan_id'] as String?)}, ${originLabel(r['origin'] as String?).toLowerCase()}. Checksums verified.',
        );
      }
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

  String? _scanFolder(AppState s, String id) {
    final home = s.health['home'] as String?;
    if (home == null) return null;
    final sep = home.contains('\\') ? '\\' : '/';
    return '$home${sep}scans${sep}scan-$id';
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

  bool _matches(ScanSummary sc) {
    final k = originKind(sc.origin);
    final okOrigin = switch (_filter) {
      _OriginFilter.all => true,
      _OriginFilter.real => k == OriginKind.realD435,
      _OriginFilter.iphone => k == OriginKind.iphone,
      _OriginFilter.synthetic => k == OriginKind.synthetic,
      _OriginFilter.replay => k == OriginKind.replay,
      _OriginFilter.unverified => k == OriginKind.unknownImport || k == OriginKind.other,
    };
    if (!okOrigin) return false;
    final q = _search.text.trim().toLowerCase();
    if (q.isEmpty) return true;
    return sc.title.toLowerCase().contains(q) ||
        sc.id.toLowerCase().startsWith(q) ||
        (sc.featureType ?? '').toLowerCase().contains(q) ||
        (sc.sessionId ?? '').toLowerCase().startsWith(q);
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
    final shown = _scans.where(_matches).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PageHeader(
          'Library',
          subtitle: 'Scans stored on this computer. Private by default; nothing is uploaded.',
          actions: [
            SizedBox(
              width: 230,
              child: TextField(
                controller: _search,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(
                  labelText: 'Search',
                  hintText: 'Title, feature or ID',
                  prefixIcon: Icon(Icons.search, size: 18),
                  prefixIconConstraints: BoxConstraints(minWidth: 36, minHeight: 20),
                ),
              ),
            ),
            SizedBox(
              width: 190,
              child: DropdownButtonFormField<_OriginFilter>(
                initialValue: _filter,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Origin'),
                items: const [
                  DropdownMenuItem(value: _OriginFilter.all, child: Text('All origins')),
                  DropdownMenuItem(value: _OriginFilter.real, child: Text('Real sensor, D435')),
                  DropdownMenuItem(value: _OriginFilter.iphone, child: Text('iPhone')),
                  DropdownMenuItem(value: _OriginFilter.synthetic, child: Text('Synthetic')),
                  DropdownMenuItem(value: _OriginFilter.replay, child: Text('Replay')),
                  DropdownMenuItem(value: _OriginFilter.unverified, child: Text('Unverified import')),
                ],
                onChanged: (v) => setState(() => _filter = v ?? _OriginFilter.all),
              ),
            ),
            OutlinedButton(onPressed: _busy ? null : () => _import(s), child: const Text('Import .zip or .ply…')),
          ],
        ),
        const Padding(padding: EdgeInsets.fromLTRB(24, 0, 24, 12), child: UsbSyncBar()),
        if (_error != null) Padding(padding: const EdgeInsets.fromLTRB(24, 0, 24, 12), child: ErrorBox(_error!)),
        Expanded(
          child: _scans.isEmpty && !_loading
              ? EmptyState(
                  title: 'No scans yet',
                  body: 'Record a scan in Capture, or import a scan bundle (.zip) exported from the iPhone app.',
                  action: FilledButton(onPressed: () => s.go(Section.capture), child: const Text('Go to Capture')),
                )
              : Padding(
                  padding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(child: Panel(child: _table(s, t, shown, sel))),
                      const SizedBox(width: 20),
                      SizedBox(
                        width: 470,
                        child: sel == null
                            ? Panel(
                                child: EmptyState(title: 'Select a scan', body: 'Its files, checksums and history appear here.'),
                              )
                            : _detailPane(s, t, sel),
                      ),
                    ],
                  ),
                ),
        ),
      ],
    );
  }

  // ------------------------------------------------------------------ table

  static const _wCheck = 70.0, _wThumb = 74.0, _wOrigin = 126.0, _wDate = 128.0, _wNum = 52.0;

  Widget _table(AppState s, ThemeData t, List<ScanSummary> shown, String? sel) {
    final head = t.textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w600, color: FsPalette.ink);
    final groups = <String, List<ScanSummary>>{};
    for (final sc in shown) {
      groups.putIfAbsent(sc.sessionId ?? '', () => []).add(sc);
    }
    final compare = s.repeatSelection.length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.fromLTRB(8, 9, 14, 9),
          decoration: const BoxDecoration(
            border: Border(bottom: BorderSide(color: FsPalette.ink)),
          ),
          child: Row(
            children: [
              SizedBox(
                width: _wCheck,
                child: Tooltip(
                  message: 'Tick scans to compare in Analysis, Repeatability',
                  child: Text('Compare', textAlign: TextAlign.center, style: head),
                ),
              ),
              const SizedBox(width: _wThumb),
              Expanded(child: Text('Scan', style: head)),
              SizedBox(
                width: _wOrigin,
                child: Text('Origin', style: head),
              ),
              SizedBox(
                width: _wDate,
                child: Text('Captured, UTC', style: head),
              ),
              SizedBox(
                width: _wNum,
                child: Text('Frames', textAlign: TextAlign.right, style: head),
              ),
              SizedBox(
                width: _wNum + 8,
                child: Text('Results', textAlign: TextAlign.right, style: head),
              ),
            ],
          ),
        ),
        Expanded(
          child: shown.isEmpty
              ? Center(
                  child: Text('No scans match.', style: t.textTheme.bodyMedium?.copyWith(color: FsPalette.inkMuted)),
                )
              : ListView(
                  children: [
                    for (final e in groups.entries) ...[
                      Container(
                        color: FsPalette.sheetAlt,
                        padding: const EdgeInsets.fromLTRB(14, 6, 14, 6),
                        child: Text(
                          e.key.isEmpty
                              ? 'No session, ${e.value.length} scan${e.value.length == 1 ? '' : 's'}'
                              : 'Session ${shortId(e.key)}, ${e.value.length} scan${e.value.length == 1 ? '' : 's'}, '
                                    '${(e.value.first.capturedAt ?? '').split('T').first}',
                          style: t.textTheme.labelMedium?.copyWith(color: FsPalette.inkMuted),
                        ),
                      ),
                      for (final sc in e.value) _row(s, t, sc, sc.id == sel),
                    ],
                  ],
                ),
        ),
        Container(
          padding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
          decoration: const BoxDecoration(
            border: Border(top: BorderSide(color: FsPalette.rule)),
          ),
          child: Row(
            children: [
              Text('${shown.length} of ${_scans.length} scans', style: t.textTheme.bodySmall),
              const Spacer(),
              if (compare > 0) ...[
                Text('$compare ticked to compare', style: t.textTheme.bodySmall),
                const SizedBox(width: 8),
                TextButton(
                  onPressed: compare < 2 ? null : () => s.go(Section.analysis),
                  style: TextButton.styleFrom(minimumSize: const Size(0, 28), padding: const EdgeInsets.symmetric(horizontal: 8)),
                  child: const Text('Compare in Analysis'),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _row(AppState s, ThemeData t, ScanSummary sc, bool selected) {
    final bad = sc.status != 'complete';
    return Material(
      color: selected ? FsPalette.surveyTint : FsPalette.sheet,
      child: InkWell(
        onTap: () => s.selectScan(sc.id),
        hoverColor: FsPalette.paper,
        child: Container(
          padding: const EdgeInsets.fromLTRB(8, 7, 14, 7),
          decoration: const BoxDecoration(
            border: Border(bottom: BorderSide(color: FsPalette.ruleLight)),
          ),
          child: Row(
            children: [
              SizedBox(
                width: _wCheck,
                child: Checkbox(
                  value: s.repeatSelection.contains(sc.id),
                  onChanged: (_) => s.toggleRepeat(sc.id),
                  visualDensity: VisualDensity.compact,
                  semanticLabel: 'Compare ${sc.title}',
                ),
              ),
              SizedBox(
                width: _wThumb,
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Container(
                    width: 64,
                    height: 36,
                    decoration: BoxDecoration(border: Border.all(color: FsPalette.rule)),
                    child: sc.hasThumbnail
                        ? Image.network(
                            s.api!.url('/api/scans/${sc.id}/file/thumbnail.jpg').toString(),
                            fit: BoxFit.cover,
                            errorBuilder: (_, e, _) => const ColoredBox(color: FsPalette.sheetAlt),
                          )
                        : const ColoredBox(color: FsPalette.sheetAlt),
                  ),
                ),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      sc.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: t.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600, color: selected ? FsPalette.surveyDeep : null),
                    ),
                    Text(
                      [
                        shortId(sc.id),
                        if (sc.featureType != null) prettyName(sc.featureType!).toLowerCase(),
                        if (bad) sc.status,
                      ].join(', '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: t.textTheme.bodySmall?.copyWith(
                        color: bad ? FsPalette.record : null,
                        fontWeight: bad ? FontWeight.w600 : null,
                      ),
                    ),
                  ],
                ),
              ),
              SizedBox(
                width: _wOrigin,
                child: Align(alignment: Alignment.centerLeft, child: OriginTag(sc.origin)),
              ),
              SizedBox(
                width: _wDate,
                child: Text(
                  utcText(sc.capturedAt).replaceFirst(RegExp(r':\d\d$'), ''),
                  style: t.textTheme.bodyMedium?.copyWith(fontSize: 13),
                ),
              ),
              SizedBox(
                width: _wNum,
                child: Text('${sc.frames ?? '—'}', textAlign: TextAlign.right, style: t.textTheme.bodyMedium?.copyWith(fontSize: 13)),
              ),
              SizedBox(
                width: _wNum + 8,
                child: Text('${sc.measurementCount}', textAlign: TextAlign.right, style: t.textTheme.bodyMedium?.copyWith(fontSize: 13)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ------------------------------------------------------------------ detail

  Widget _detailPane(AppState s, ThemeData t, String id) {
    if (_detail['error'] != null) return Align(alignment: Alignment.topCenter, child: ErrorBox('${_detail['error']}'));
    final man = asMap(_detail['manifest']);
    if (man.isEmpty || man['scan_id'] != id) {
      return const Panel(
        child: Center(child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))),
      );
    }
    final obs = asMap(man['observation']);
    final dev = asMap(man['device']);
    final cap = asMap(man['capture']);
    final pub = asMap(man['publication']);
    final cf = asMap(man['coordinate_frame']);
    final loc = asMap(man['location']);
    final files = asList(man['files']).map(asMap).toList();
    final log = asList(_detail['log']).map(asMap).toList();
    final draft = _detail['catalog_draft'];
    final captured = man['captured_at_utc'];
    final start = captured is Map ? captured['start'] : captured;
    final hasDepth = _detail['depth_image'] != null;
    final folder = _scanFolder(s, id);
    final limitations = asList(man['limitations']).map((e) => '$e').toList();
    final small = t.textTheme.bodySmall;
    const lw = 112.0;

    return ListView(
      children: [
        Panel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              PanelPart(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(asStr(obs['title']).isEmpty ? 'Untitled scan' : asStr(obs['title']), style: t.textTheme.titleLarge),
                              const SizedBox(height: 2),
                              SelectableText('Scan ${man['scan_id']}', style: small),
                            ],
                          ),
                        ),
                        const SizedBox(width: 10),
                        OriginTag(man['origin'] as String?),
                      ],
                    ),
                    if (HonestyBanner.messageFor(man['origin'] as String?) != null) ...[
                      const SizedBox(height: 12),
                      HonestyBanner(
                        origin: man['origin'] as String?,
                        isRealSensor: man['is_real_sensor'] as bool?,
                        replayOf: asMap(man['replay_of'])['scan_id'] as String?,
                        compact: true,
                        boxed: true,
                      ),
                    ],
                    const SizedBox(height: 14),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        FilledButton(
                          onPressed: () => s.go(Section.viewer, scanId: id),
                          child: const Text('Open in Viewer'),
                        ),
                        OutlinedButton(
                          onPressed: () => s.go(Section.analysis, scanId: id),
                          child: const Text('Analyse'),
                        ),
                        OutlinedButton(onPressed: _busy ? null : () => _export(s, id), child: const Text('Export .zip')),
                        PopupMenuButton<String>(
                          tooltip: 'More actions',
                          position: PopupMenuPosition.under,
                          onSelected: (v) {
                            switch (v) {
                              case 'edit':
                                _editDialog(s, id, obs, man);
                              case 'reprocess':
                                _reprocess(s, id);
                              case 'draft':
                                _draftDialog(s, id, obs, draft);
                              case 'folder':
                                if (folder != null) Desktop.reveal(folder);
                            }
                          },
                          itemBuilder: (_) => [
                            const PopupMenuItem(value: 'edit', child: Text('Edit title and notes')),
                            if (hasDepth)
                              PopupMenuItem(value: 'reprocess', enabled: !_busy, child: const Text('Reprocess from raw frames')),
                            const PopupMenuItem(value: 'draft', child: Text('Prepare catalog draft')),
                            if (folder != null) PopupMenuItem(value: 'folder', child: Text('Show folder in ${Desktop.fileManager}')),
                          ],
                          child: IgnorePointer(
                            child: OutlinedButton(
                              onPressed: () {},
                              child: const Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [Text('More'), SizedBox(width: 2), Icon(Icons.arrow_drop_down, size: 20)],
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                    if (_exportPath != null && _exportPath!.contains(id)) ...[
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          Expanded(child: SelectableText('Exported to $_exportPath', style: small)),
                          TextButton(onPressed: () => Desktop.reveal(_exportPath!), child: Text('Show in ${Desktop.fileManager}')),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
              PanelPart(
                ruled: true,
                title: 'Record',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    KV('Session', asStr(man['session_id'], '—'), labelWidth: lw),
                    KV(
                      'Status',
                      '${man['status']}${man['status_reason'] != null ? ', ${asStr(man['status_reason']).replaceAll('_', ' ')}' : ''}',
                      labelWidth: lw,
                      valueStyle: man['status'] == 'complete'
                          ? null
                          : t.textTheme.bodyMedium?.copyWith(fontSize: 13.5, color: FsPalette.record, fontWeight: FontWeight.w600),
                    ),
                    KV('Origin', '${originLabel(man['origin'] as String?)} (${man['origin']})', labelWidth: lw),
                    KV(
                      'Device',
                      [
                        dev['manufacturer'],
                        dev['model'],
                        if (dev['firmware'] != null) 'firmware ${dev['firmware']}',
                        if (dev['usb_type'] != null) 'USB ${dev['usb_type']}',
                      ].whereType<Object>().join(', '),
                      labelWidth: lw,
                    ),
                    KV('Captured, UTC', utcText(start), labelWidth: lw),
                    KV(
                      'Frames',
                      '${cap['frames_recorded'] ?? cap['keyframes'] ?? '—'}${cap['profile'] != null ? ', profile ${cap['profile']}' : ''}',
                      labelWidth: lw,
                    ),
                    KV('Coordinates', [cf['name'], cf['axes'] ?? cf['up']].whereType<Object>().join(', '), labelWidth: lw),
                    KV(
                      'Feature type',
                      '${obs['feature_type'] == null ? '—' : prettyName(asStr(obs['feature_type']))}, your annotation',
                      labelWidth: lw,
                    ),
                    if (asStr(obs['notes']).isNotEmpty) KV('Notes', asStr(obs['notes']), labelWidth: lw),
                    for (final c in asList(obs['claims']).map(asMap))
                      KV('Claim, ${asStr(c['kind']).replaceAll('_', ' ')}', asStr(c['text']), labelWidth: lw),
                    KV(
                      'Site, candidate',
                      '${man['field_site_id'] ?? '—'}, ${man['candidate_id'] ?? '—'} (references only)',
                      labelWidth: lw,
                    ),
                    KV('Location', '${loc['sharing'] ?? 'hidden'}${loc['note'] != null ? ', ${loc['note']}' : ''}', labelWidth: lw),
                    KV(
                      'Publication',
                      '${asStr(pub['status']).replaceAll('_', ' ')}, licence ${pub['license'] ?? 'none'}, consent ${pub['consent_obtained'] == true ? 'given' : 'not given'}',
                      labelWidth: lw,
                    ),
                  ],
                ),
              ),
              if (limitations.isNotEmpty)
                PanelPart(
                  ruled: true,
                  title: 'Limitations',
                  subtitle: 'Written into scan.json; they travel with every export.',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final l in limitations)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 5),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('–  ', style: t.textTheme.bodyMedium?.copyWith(color: FsPalette.inkMuted, fontSize: 13)),
                              Expanded(child: Text(l, style: t.textTheme.bodyMedium?.copyWith(fontSize: 13))),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              PanelPart(
                ruled: true,
                title: 'Files',
                subtitle:
                    '${files.length} files, ${bytesText(files.fold<int>(0, (a, f) => a + (asInt(f['bytes']) ?? 0)))} in all. A SHA-256 hash is recorded for each.',
                child: ResultTable(
                  fontSize: 12.5,
                  columns: const [
                    RCol('File', flex: 6),
                    RCol('Kind', flex: 2),
                    RCol('Size', numeric: true, flex: 2),
                    RCol('SHA-256', flex: 3),
                  ],
                  rows: [
                    for (final f in files.take(40))
                      [
                        Tooltip(
                          message: asStr(f['role']).isEmpty ? asStr(f['path']) : '${f['path']}: ${f['role']}',
                          child: Text(
                            asStr(f['path']),
                            overflow: TextOverflow.ellipsis,
                            style: t.textTheme.bodyMedium?.copyWith(fontSize: 12.5),
                          ),
                        ),
                        asStr(f['kind'], '—'),
                        bytesText(asInt(f['bytes'])),
                        asStr(f['sha256']).length >= 10 ? '${asStr(f['sha256']).substring(0, 10)}…' : '—',
                      ],
                  ],
                  footnotes: [
                    if (files.length > 40) '${files.length - 40} more files are listed in scan.json.',
                    'Hashes are shortened here; scan.json holds the full values.',
                  ],
                ),
              ),
              if (log.isNotEmpty)
                PanelPart(
                  ruled: true,
                  title: 'Log',
                  subtitle: 'Latest ${log.length > 30 ? 30 : log.length} events, newest first.',
                  child: Container(
                    padding: const EdgeInsets.all(10),
                    color: FsPalette.sheetAlt,
                    child: SelectableText(
                      [
                        for (final e in log.reversed.take(30))
                          '${utcText(e['t_utc'])}  ${e['event']}  ${e.entries.where((x) => x.key != 't_utc' && x.key != 'event').map((x) => '${x.key}=${x.value}').join(' ')}',
                      ].join('\n'),
                      style: mono(t.textTheme.bodySmall, size: 11)?.copyWith(color: FsPalette.ink),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
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
          title: const Text('Edit title and notes'),
          content: SizedBox(
            width: 540,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const SizedBox(height: 6),
                  TextField(
                    controller: title,
                    decoration: const InputDecoration(labelText: 'Title'),
                  ),
                  const SizedBox(height: 14),
                  DropdownButtonFormField<String>(
                    initialValue: feature,
                    items: [for (final f in featureTypes) DropdownMenuItem(value: f, child: Text(prettyName(f)))],
                    onChanged: (v) => set(() => feature = v ?? 'other'),
                    decoration: const InputDecoration(labelText: 'Feature type, your annotation (not automatic classification)'),
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    controller: notes,
                    maxLines: 3,
                    decoration: const InputDecoration(labelText: 'Notes'),
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    controller: site,
                    decoration: const InputDecoration(labelText: 'Field site ID, website reference'),
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    controller: cand,
                    decoration: const InputDecoration(labelText: 'Website candidate ID, reference only'),
                  ),
                  const SizedBox(height: 18),
                  Text('Claims', style: Theme.of(c).textTheme.titleSmall),
                  const SizedBox(height: 4),
                  if (claims.isEmpty) Text('None.', style: Theme.of(c).textTheme.bodySmall),
                  for (final cl in claims) Text('${asStr(cl['kind']).replaceAll('_', ' ')}: ${cl['text']}'),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: claim,
                          decoration: const InputDecoration(labelText: 'Add a claim'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      SizedBox(
                        width: 150,
                        child: DropdownButtonFormField<String>(
                          initialValue: claimKind,
                          decoration: const InputDecoration(labelText: 'Kind'),
                          items: const [
                            DropdownMenuItem(value: 'observed', child: Text('Observed')),
                            DropdownMenuItem(value: 'interpreted', child: Text('Interpreted')),
                            DropdownMenuItem(value: 'user_reported', child: Text('User reported')),
                          ],
                          onChanged: (v) => set(() => claimKind = v ?? 'observed'),
                        ),
                      ),
                      const SizedBox(width: 4),
                      TextButton(
                        onPressed: () => set(() {
                          if (claim.text.trim().isNotEmpty) claims.add({'text': claim.text.trim(), 'kind': claimKind});
                          claim.clear();
                        }),
                        child: const Text('Add'),
                      ),
                    ],
                  ),
                ],
              ),
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
        if (mounted) showSnack(context, 'Saved.');
      } catch (e) {
        if (mounted) showSnack(context, errText(e), error: true);
      }
    }
  }

  Future<void> _draftDialog(AppState s, String id, Map<String, dynamic> obs, Object? existing) async {
    final ex = asMap(existing);
    final attribution = TextEditingController(text: asStr(ex['attribution']));
    // SPDX ids, as the phone writes them; older desktop drafts used the display names.
    const licenses = {'CC-BY-4.0': 'CC BY 4.0', 'CC-BY-SA-4.0': 'CC BY-SA 4.0', 'CC0-1.0': 'CC0 1.0', 'all-rights-reserved': 'All rights reserved'};
    String? license = ex['license'] as String?;
    license = licenses.entries.where((e) => e.value == license).map((e) => e.key).firstOrNull ?? license;
    // A draft can come from the phone (author_approval is a map there, people/property are separate answers).
    final aa = ex['author_approval'];
    bool approval = aa == true || (aa is Map && aa['owns_rights'] == true);
    bool consent = ex['consent_obtained'] == true || (aa is Map && aa['consent'] == true);
    bool? people = ex['people_or_private_property_visible'] as bool?;
    if (people == null && (ex.containsKey('people_visible') || ex.containsKey('private_property_visible'))) {
      final pv = ex['people_visible'], pp = ex['private_property_visible'];
      people = (pv == 'yes' || pp == true) ? true : ((pv == 'no' && pp == false) ? false : null);
    }
    final precision = asStr(ex['location_precision'], 'hidden');
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, set) => AlertDialog(
          title: const Text('Prepare catalog draft'),
          content: SizedBox(
            width: 540,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Hint(
                  'Saved on this computer only. This build has no catalog service, so nothing is uploaded. '
                  '${precision == 'hidden' ? 'Location stays hidden.' : 'Location precision: $precision (chosen on the phone; kept as it is).'}',
                  color: FsPalette.caution,
                  icon: Icons.warning_amber_rounded,
                ),
                const SizedBox(height: 16),
                DropdownButtonFormField<String>(
                  initialValue: licenses.containsKey(license) ? license : null,
                  items: [for (final l in licenses.entries) DropdownMenuItem(value: l.key, child: Text(l.value))],
                  onChanged: (v) => set(() => license = v),
                  decoration: const InputDecoration(labelText: 'Licence, your explicit choice'),
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: attribution,
                  decoration: const InputDecoration(labelText: 'Attribution, a pseudonym is fine'),
                ),
                const SizedBox(height: 6),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  value: approval,
                  onChanged: (v) => set(() => approval = v ?? false),
                  title: const Text('I am the author, or have the author\'s approval'),
                ),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  value: consent,
                  onChanged: (v) => set(() => consent = v ?? false),
                  title: const Text('I consent to this scan being shared once a catalog exists'),
                ),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  tristate: true,
                  value: people,
                  onChanged: (v) => set(() => people = v),
                  title: const Text('People, faces or private property are visible'),
                  subtitle: const Text('Unticked means no; a dash means not reviewed. Scans that show people must not be published.'),
                ),
              ],
            ),
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
        if (mounted) showSnack(context, 'Local catalog draft saved. Nothing was uploaded.');
      } catch (e) {
        if (mounted) showSnack(context, errText(e), error: true);
      }
    }
  }
}

/// iPhone on the USB cable: its finished scans import automatically (on by default).
class UsbSyncBar extends StatefulWidget {
  const UsbSyncBar({super.key});
  @override
  State<UsbSyncBar> createState() => _UsbSyncBarState();
}

class _UsbSyncBarState extends State<UsbSyncBar> {
  bool _asked = false;

  Future<void> _fetch(AppState s) async {
    _asked = true;
    try {
      s.usbSync = asMap(await s.api!.getJson('/api/usb/sync'));
      if (mounted) setState(() {});
    } catch (_) {}
  }

  Future<void> _toggle(AppState s, bool on) async {
    try {
      s.usbSync = asMap(await s.api!.postJson('/api/usb/sync', {'enabled': on}));
      if (mounted) setState(() {});
    } catch (e) {
      if (mounted) showSnack(context, errText(e), error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    final t = Theme.of(context);
    if (!_asked && s.api != null) unawaited(_fetch(s));
    final u = s.usbSync;
    if (u.isEmpty || u['available'] == false && u['reason'] == null) return const SizedBox.shrink();
    final small = t.textTheme.bodySmall;
    final on = u['enabled'] == true;
    final devs = asList(u['devices']).map(asMap).toList();
    final busy = asMap(u['busy']);
    final last = asMap(u['last_import']);
    final String line;
    if (u['available'] == false) {
      line = 'Automatic iPhone import over USB is not available here: ${asStr(u['reason'])}';
    } else if (!on) {
      line = 'Automatic iPhone import is off.';
    } else if (busy.isNotEmpty) {
      line = '${busy['stage'] == 'verifying' ? 'Checking SHA-256 of' : 'Copying'} scan ${asStr(busy['scan_id']).substring(0, 8)} from ${asStr(busy['device'], 'the iPhone')}…';
    } else if (devs.isEmpty) {
      line = 'Plug the iPhone in with a cable (unlocked, "Trust This Computer"): its finished scans import here automatically.';
    } else {
      line = '${devs.map((d) => asStr(d['name'], 'iPhone')).join(', ')} connected by USB. Finished scans import automatically.';
    }
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 6, 6, 6),
      decoration: BoxDecoration(
        color: devs.isNotEmpty && on ? FsPalette.sensorTint : FsPalette.sheetAlt,
        border: Border.all(color: devs.isNotEmpty && on ? FsPalette.sensorRule : FsPalette.rule),
        borderRadius: BorderRadius.circular(2),
      ),
      child: Row(
        children: [
          Icon(busy.isNotEmpty ? Icons.sync : Icons.phone_iphone, size: 18, color: devs.isNotEmpty && on ? FsPalette.sensor : FsPalette.inkMuted),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(line, style: t.textTheme.bodyMedium),
                if (last.isNotEmpty)
                  Text(
                    'Last imported: ${asStr(last['title']).isEmpty ? 'scan ${asStr(last['scan_id']).substring(0, 8)}' : asStr(last['title'])}'
                    ' from ${asStr(last['device'], 'iPhone')} at ${utcText(last['utc'])} UTC (${last['seconds']} s, SHA-256 verified)',
                    style: small,
                  ),
                if (u['last_error'] != null)
                  Text('Last problem: ${asStr(u['last_error'])}', style: small?.copyWith(color: FsPalette.record)),
              ],
            ),
          ),
          if (u['available'] != false) ...[
            Text('Auto-import', style: small),
            Switch(value: on, onChanged: (v) => _toggle(s, v)),
          ],
        ],
      ),
    );
  }
}

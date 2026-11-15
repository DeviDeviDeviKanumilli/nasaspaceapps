// Draft written with AI assistance (Claude, Anthropic); disclosed per the Space Apps AI policy.

import 'package:flutter/material.dart';

import '../service/models.dart';
import 'common.dart';

/// Measurements as a ruled results table: quantity, value with unit, and a note (uncertainty or status).
/// Caveats become numbered footnotes. Select a row to see its method, region, uncertainty and validity limits.
class MeasurementTable extends StatefulWidget {
  const MeasurementTable({super.key, required this.measurements, this.emptyText = 'No measurements yet.'});
  final List<Measurement> measurements;
  final String emptyText;

  @override
  State<MeasurementTable> createState() => _MeasurementTableState();
}

class _MeasurementTableState extends State<MeasurementTable> {
  final Set<String> _open = {};

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final ms = widget.measurements;
    if (ms.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Text(widget.emptyText, style: t.textTheme.bodyMedium?.copyWith(color: FsPalette.inkMuted)),
      );
    }
    final notes = <String>[];
    int noteFor(String text) {
      final i = notes.indexOf(text);
      if (i >= 0) return i + 1;
      notes.add(text);
      return notes.length;
    }

    final body = t.textTheme.bodyMedium?.copyWith(fontSize: 13.5);
    final head = body?.copyWith(fontWeight: FontWeight.w600);
    final muted = body?.copyWith(color: FsPalette.inkMuted);

    Widget row(Measurement m, bool last) {
      final key = m.id.isEmpty ? '${m.name}/${m.label}' : m.id;
      final open = _open.contains(key);
      final u = m.uncertainty;
      final status = m.status;
      final parts = <String>[];
      if (status != 'measured') {
        parts.add(status.replaceAll('_', ' '));
        final ex = statusExplanation(status);
        if (ex.isNotEmpty) parts.add(sup(noteFor(ex)));
      } else if (u['std_m'] != null) {
        parts.add('± ${formatMetres(asDouble(u['std_m'])!)}${u['n'] != null ? ', n = ${u['n']}' : ''}');
        if (u['note'] != null) parts.add(sup(noteFor(asStr(u['note']))));
      } else if (m.extra['baseline_m'] != null) {
        parts.add('baseline ${formatMetres(asDouble(m.extra['baseline_m'])!)}');
      }
      final noteColor = status == 'at_noise_floor' ? FsPalette.caution : FsPalette.inkMuted;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          InkWell(
            onTap: () => setState(() => open ? _open.remove(key) : _open.add(key)),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    flex: 5,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(prettyName(m.name), style: body),
                        if (m.label.isNotEmpty) Text(m.label, style: t.textTheme.bodySmall, overflow: TextOverflow.ellipsis),
                      ],
                    ),
                  ),
                  Expanded(
                    flex: 3,
                    child: Text(
                      m.displayValue,
                      textAlign: TextAlign.right,
                      style: m.value == null ? muted : body?.copyWith(fontWeight: FontWeight.w600),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    flex: 4,
                    child: Text(
                      parts.join(' '),
                      style: body?.copyWith(color: noteColor, fontWeight: status == 'at_noise_floor' ? FontWeight.w600 : null),
                    ),
                  ),
                  Icon(open ? Icons.expand_less : Icons.expand_more, size: 18, color: FsPalette.inkMuted),
                ],
              ),
            ),
          ),
          if (open)
            Container(
              color: FsPalette.sheetAlt,
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
              margin: const EdgeInsets.only(bottom: 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  KV('Method', m.method, labelWidth: 120),
                  KV('Frame', m.frame, labelWidth: 120),
                  if (m.sourceArtifact != null && m.sourceArtifact!.isNotEmpty) KV('Source file', m.sourceArtifact!, labelWidth: 120),
                  if (m.roi.isNotEmpty) KV('Region', _roiText(m.roi), labelWidth: 120),
                  if (m.extra['baseline_m'] != null) KV('Baseline', formatMetres(asDouble(m.extra['baseline_m'])!), labelWidth: 120),
                  for (final e in m.extra.entries.where((e) => e.key != 'baseline_m' && e.value is num))
                    KV(prettyName(e.key), e.key.endsWith('_m') ? formatMetres(asDouble(e.value)!) : '${e.value}', labelWidth: 120),
                  KV('Uncertainty', _uncText(u), labelWidth: 120),
                  if (m.validity.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text('Validity limits', style: t.textTheme.labelMedium),
                    for (final v in m.validity)
                      Padding(
                        padding: const EdgeInsets.only(left: 8, top: 2),
                        child: Text('• $v', style: t.textTheme.bodySmall),
                      ),
                  ],
                ],
              ),
            ),
          Container(height: last ? 1.5 : 1, color: last ? FsPalette.ink : FsPalette.ruleLight),
        ],
      );
    }

    final rows = [for (int i = 0; i < ms.length; i++) row(ms[i], i == ms.length - 1)];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(vertical: 6),
          decoration: const BoxDecoration(
            border: Border(
              top: BorderSide(color: FsPalette.ink, width: 1.5),
              bottom: BorderSide(color: FsPalette.ink),
            ),
          ),
          child: Row(
            children: [
              Expanded(flex: 5, child: Text('Quantity', style: head)),
              Expanded(
                flex: 3,
                child: Text('Value', textAlign: TextAlign.right, style: head),
              ),
              const SizedBox(width: 12),
              Expanded(flex: 4, child: Text('Note', style: head)),
              const SizedBox(width: 18),
            ],
          ),
        ),
        ...rows,
        if (notes.isNotEmpty) ...[
          const SizedBox(height: 8),
          for (int i = 0; i < notes.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 3),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(width: 18, child: Text('${i + 1}', style: t.textTheme.bodySmall)),
                  Expanded(child: Text(notes[i], style: t.textTheme.bodySmall)),
                ],
              ),
            ),
        ],
        const SizedBox(height: 4),
        Text('Select a row for method, region and validity limits.', style: t.textTheme.bodySmall?.copyWith(fontSize: 12)),
      ],
    );
  }

  static String _roiText(Map<String, dynamic> roi) {
    final k = roi['kind'];
    final n = roi['n_points'] != null ? ', ${roi['n_points']} points' : '';
    if (k == 'pixel_rect') {
      final r = asList(roi['rect_px']);
      if (r.length == 4) return 'depth pixels u ${r[0]} to ${r[2]}, v ${r[1]} to ${r[3]}$n';
      return 'depth pixels ${r.join(', ')}$n';
    }
    if (k == 'sphere') {
      final c = asList(roi['center']).map((e) => (asDouble(e) ?? 0).toStringAsFixed(3)).join(', ');
      return 'sphere r = ${formatMetres(asDouble(roi['radius_m']) ?? 0)} at ($c) m$n';
    }
    if (k == 'points') return 'two picked points';
    return '$roi';
  }

  static String _uncText(Map<String, dynamic> u) {
    final method = asStr(u['method'], 'none');
    final parts = <String>[method.replaceAll('_', ' ')];
    if (u['n'] != null) parts.add('n = ${u['n']}');
    if (u['std_m'] != null) parts.add('std ${formatMetres(asDouble(u['std_m'])!)}');
    if (u['reference_rms_m'] != null) parts.add('reference RMS ${formatMetres(asDouble(u['reference_rms_m'])!)}');
    if (u['expected_sensor_noise_rms_m'] != null) {
      parts.add('expected sensor noise ${formatMetres(asDouble(u['expected_sensor_noise_rms_m'])!)}');
    }
    if (u['note'] != null) parts.add('${u['note']}');
    return parts.join('; ');
  }
}

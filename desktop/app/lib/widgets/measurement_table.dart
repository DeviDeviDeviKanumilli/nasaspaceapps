import 'package:flutter/material.dart';

import '../service/models.dart';
import 'common.dart';

/// Measurements with value + unit + status; method, uncertainty and validity expand on tap.
class MeasurementTable extends StatelessWidget {
  const MeasurementTable({super.key, required this.measurements, this.emptyText = 'No measurements yet.'});
  final List<Measurement> measurements;
  final String emptyText;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    if (measurements.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Text(emptyText, style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant)),
      );
    }
    return Column(children: [for (final m in measurements) _MeasurementTile(m)]);
  }
}

class _MeasurementTile extends StatelessWidget {
  const _MeasurementTile(this.m);
  final Measurement m;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final special = m.status != 'measured';
    final statusColor = m.status == 'at_noise_floor'
        ? warnColor(context)
        : (m.status == 'not_measured' ? t.colorScheme.onSurfaceVariant : t.colorScheme.primary);
    final unc = m.uncertainty;
    final roi = m.roi;
    return Theme(
      data: t.copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        tilePadding: const EdgeInsets.symmetric(horizontal: 4),
        childrenPadding: const EdgeInsets.fromLTRB(8, 0, 8, 12),
        dense: true,
        title: Row(children: [
          Expanded(
            flex: 5,
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(prettyName(m.name), style: t.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
              if (m.label.isNotEmpty)
                Text(m.label, style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant), overflow: TextOverflow.ellipsis),
            ]),
          ),
          Expanded(
            flex: 3,
            child: Text(m.displayValue,
                textAlign: TextAlign.right,
                style: t.textTheme.titleMedium?.copyWith(
                    fontFeatures: const [FontFeature.tabularFigures()],
                    color: m.value == null ? t.colorScheme.onSurfaceVariant : null)),
          ),
          const SizedBox(width: 16),
          SizedBox(
            width: 120,
            child: Text(m.status.replaceAll('_', ' '),
                style: t.textTheme.labelMedium?.copyWith(color: statusColor, fontWeight: special ? FontWeight.w700 : FontWeight.w500)),
          ),
        ]),
        children: [
          if (statusExplanation(m.status).isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(statusExplanation(m.status), style: t.textTheme.bodySmall?.copyWith(color: statusColor)),
            ),
          KV('Method', m.method),
          KV('Frame', m.frame),
          if (m.sourceArtifact != null && m.sourceArtifact!.isNotEmpty) KV('Source artifact', m.sourceArtifact!),
          if (roi.isNotEmpty) KV('Region', _roiText(roi)),
          if (m.extra['baseline_m'] != null) KV('Baseline (ROI size)', formatMetres(asDouble(m.extra['baseline_m'])!)),
          for (final e in m.extra.entries.where((e) => e.key != 'baseline_m' && e.value is num))
            KV(prettyName(e.key), e.key.endsWith('_m') ? formatMetres(asDouble(e.value)!) : '${e.value}'),
          KV('Uncertainty', _uncText(unc)),
          if (m.validity.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text('Validity limits', style: t.textTheme.labelMedium),
            for (final v in m.validity)
              Padding(
                padding: const EdgeInsets.only(left: 8, top: 2),
                child: Text('• $v', style: t.textTheme.bodySmall),
              ),
          ],
        ],
      ),
    );
  }

  static String _roiText(Map<String, dynamic> roi) {
    final k = roi['kind'];
    final n = roi['n_points'] != null ? ', ${roi['n_points']} points' : '';
    if (k == 'pixel_rect') return 'depth pixels ${asList(roi['rect_px']).join(', ')}$n';
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
    if (u['expected_sensor_noise_rms_m'] != null) parts.add('expected sensor noise ${formatMetres(asDouble(u['expected_sensor_noise_rms_m'])!)}');
    if (u['note'] != null) parts.add('${u['note']}');
    return parts.join(' · ');
  }
}

// Draft written with AI assistance (Claude, Anthropic); disclosed per the Space Apps AI policy.

import 'package:flutter/material.dart';

import '../service/models.dart';
import 'common.dart';
import 'figure.dart';

/// Persistent banner whenever data does not come from a live real sensor: synthetic fixtures, replays and
/// unverified imports. Hatched magenta, the one place an all-caps line is used, because it is a warning.
class HonestyBanner extends StatelessWidget {
  const HonestyBanner({super.key, required this.origin, this.isRealSensor, this.replayOf, this.compact = false, this.boxed = false});
  final String? origin;
  final bool? isRealSensor;
  final String? replayOf;

  /// Message only, no explanatory detail.
  final bool compact;

  /// Bordered box inside page content (scan views) rather than a full-width band (live data).
  final bool boxed;

  static String? messageFor(String? origin, {String? replayOf}) {
    switch (originKind(origin)) {
      case OriginKind.synthetic:
        return 'SYNTHETIC TEST SCENE — not a sensor measurement';
      case OriginKind.replay:
        return 'REPLAY${replayOf != null ? ' of scan ${shortId(replayOf)}' : ''} — not live, not a new observation';
      case OriginKind.unknownImport:
        return 'IMPORTED WITHOUT PROVENANCE — sensor, units and frame unverified';
      default:
        return null;
    }
  }

  static String? detailFor(String? origin) {
    switch (originKind(origin)) {
      case OriginKind.synthetic:
        return 'Ray-cast board, box and sphere with simulated noise. Every scan from it is stamped SYNTHETIC.';
      case OriginKind.replay:
        return 'Raw frames of an earlier recording, played back.';
      case OriginKind.unknownImport:
        return 'Treat every value as unverified.';
      default:
        return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final msg =
        messageFor(origin, replayOf: replayOf) ??
        (isRealSensor == false && origin != null && originKind(origin) != OriginKind.iphone ? 'NOT A LIVE SENSOR' : null);
    if (msg == null) return const SizedBox.shrink();
    final t = Theme.of(context);
    final detail = compact ? null : detailFor(origin);
    return Semantics(
      container: true,
      label: '$msg. ${detail ?? ''}',
      child: SyntheticHatch(
        boxed: boxed,
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: boxed ? 14 : 24, vertical: boxed ? 8 : 9),
          child: Wrap(
            spacing: 14,
            runSpacing: 2,
            crossAxisAlignment: WrapCrossAlignment.end,
            children: [
              Text(msg, style: t.textTheme.labelLarge?.copyWith(color: FsPalette.synthetic)),
              if (detail != null) Text(detail, style: t.textTheme.bodyMedium?.copyWith(color: FsPalette.synthetic, fontSize: 13)),
            ],
          ),
        ),
      ),
    );
  }
}

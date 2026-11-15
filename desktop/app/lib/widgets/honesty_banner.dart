import 'package:flutter/material.dart';

import '../service/models.dart';
import 'common.dart';

/// Persistent banner whenever data does not come from a live real sensor.
/// Shown for synthetic fixtures, replays and unverified imports.
class HonestyBanner extends StatelessWidget {
  const HonestyBanner({super.key, required this.origin, this.isRealSensor, this.replayOf, this.compact = false});
  final String? origin;
  final bool? isRealSensor;
  final String? replayOf;
  final bool compact;

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

  @override
  Widget build(BuildContext context) {
    final msg = messageFor(origin, replayOf: replayOf) ??
        (isRealSensor == false && origin != null && originKind(origin) != OriginKind.iphone ? 'NOT A LIVE SENSOR' : null);
    if (msg == null) return const SizedBox.shrink();
    final c = warnColor(context);
    return Container(
      width: double.infinity,
      padding: EdgeInsets.symmetric(horizontal: 16, vertical: compact ? 6 : 10),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.14),
        border: Border(bottom: BorderSide(color: c, width: 2)),
      ),
      child: Row(children: [
        Icon(Icons.warning_amber_rounded, color: c, size: compact ? 16 : 20),
        const SizedBox(width: 10),
        Expanded(
          child: Text(msg,
              style: Theme.of(context).textTheme.labelLarge?.copyWith(color: c, fontWeight: FontWeight.w800, letterSpacing: 0.5)),
        ),
      ]),
    );
  }
}

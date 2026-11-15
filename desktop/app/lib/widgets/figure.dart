// Draft written with AI assistance (Claude, Anthropic); disclosed per the Space Apps AI policy.

import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'common.dart';

// ---------------------------------------------------------------------------------------------------------------
// Figures. Every image in the app is shown the way a methods paper would print it: a black frame, pixel ticks on
// the top and left edges, a colour bar when colour encodes a value, and a caption that says what was measured and
// what was not.
// ---------------------------------------------------------------------------------------------------------------

/// Polynomial fit to matplotlib's viridis. Same coefficients as the service (fieldstation/bundle.py), so a colour
/// bar drawn here matches the images the service renders.
const _vir = [
  [0.2777273272234177, 0.005407344544966578, 0.3340998053353061],
  [0.1050930431085774, 1.404613529898575, 1.384590162594685],
  [-0.3308618287255563, 0.214847559468213, 0.09509516302823659],
  [-4.634230498983486, -5.799100973351585, -19.33244095627987],
  [6.228269936347081, 14.17993336680509, 56.69055260068105],
  [4.776384997670288, -13.74514537774601, -65.35303263337234],
  [-5.435455855934631, 4.645852612178535, 26.3124352495832],
];

/// Viridis at t in [0, 1] as 0xAARRGGBB.
int viridisArgb(double t) {
  t = t.isNaN ? 0 : t.clamp(0.0, 1.0);
  int ch(int i) {
    double c = _vir[6][i];
    for (int k = 5; k >= 0; k--) {
      c = _vir[k][i] + t * c;
    }
    return (c.clamp(0.0, 1.0) * 255).round();
  }

  return 0xFF000000 | (ch(0) << 16) | (ch(1) << 8) | ch(2);
}

Color viridis(double t) => Color(viridisArgb(t));

List<Color> viridisStops([int n = 12]) => [for (int i = 0; i <= n; i++) viridis(i / n)];

class FigureCaption extends StatelessWidget {
  const FigureCaption(this.title, this.text, {super.key});
  final String title;
  final String text;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final base = t.textTheme.bodyMedium?.copyWith(fontSize: 13);
    return Text.rich(
      TextSpan(
        children: [
          TextSpan(
            text: '$title ',
            style: base?.copyWith(fontWeight: FontWeight.w600),
          ),
          TextSpan(
            text: text,
            style: base?.copyWith(color: FsPalette.inkMuted),
          ),
        ],
      ),
    );
  }
}

/// Vertical colour bar, high value at the top. [lo] and [hi] are in display units.
class ColorBarSpec {
  const ColorBarSpec({required this.lo, required this.hi, required this.unit, this.decimals = 2});
  final double lo, hi;
  final String unit;
  final int decimals;
}

/// A figure: the image ([child]) is fitted at its data aspect ratio, framed in ink, with ticks in data units
/// (pixels) on the top and left edges, an optional colour bar and a caption. [overlay] sits on the image at the
/// same size; annotations are painted there.
///
/// With [dataSize] the figure takes only the height it needs (give it loose constraints, e.g. inside an Align),
/// keeping [captionReserve] pixels for the caption. Without [dataSize] the image fills the available space.
class Figure extends StatelessWidget {
  const Figure({
    super.key,
    required this.child,
    this.dataSize,
    this.unitX = 'px',
    this.unitY = '',
    this.overlay,
    this.colorBar,
    this.caption,
    this.captionReserve = 76,
    this.background = FsPalette.sheet,
  });

  /// Size of the image in data units (e.g. 848 x 480 depth pixels). Null: fill the space, no ticks.
  final Size? dataSize;
  final String unitX, unitY;
  final Widget child;
  final Widget? overlay;
  final ColorBarSpec? colorBar;
  final Widget? caption;
  final double captionReserve;
  final Color background;

  static const _gutterL = 38.0, _gutterT = 22.0, _barW = 74.0;

  Widget _plot(BuildContext context, Rect plot, double totalW, double totalH) {
    final ticks = dataSize != null;
    return SizedBox(
      width: totalW,
      height: totalH,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned.fromRect(
            rect: plot,
            child: Container(
              color: background,
              foregroundDecoration: BoxDecoration(border: Border.all(color: FsPalette.ink)),
              child: ClipRect(
                child: Stack(fit: StackFit.expand, children: [child, ?overlay]),
              ),
            ),
          ),
          if (ticks)
            Positioned.fill(
              child: IgnorePointer(
                child: CustomPaint(
                  painter: _TickPainter(
                    plot: plot,
                    data: dataSize!,
                    unitX: unitX,
                    unitY: unitY,
                    style: Theme.of(context).textTheme.labelSmall!.copyWith(color: FsPalette.ink, fontSize: 10.5),
                  ),
                ),
              ),
            ),
          if (colorBar != null)
            Positioned(left: plot.right + 14, top: plot.top, width: _barW - 14, height: plot.height, child: ColorBar(colorBar!)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ticks = dataSize != null;
    final gl = ticks ? _gutterL : 0.0, gt = ticks ? _gutterT : 0.0;
    final gr = colorBar != null ? _barW : 0.0;
    final cap = caption == null ? null : Padding(padding: EdgeInsets.fromLTRB(gl, 10, 0, 0), child: caption);

    if (dataSize == null) {
      // Fill mode (3D view): the image takes whatever the caption leaves.
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: LayoutBuilder(
              builder: (context, box) {
                final plot = Rect.fromLTWH(0, 0, math.max(10.0, box.maxWidth - gr), box.maxHeight);
                return _plot(context, plot, box.maxWidth, box.maxHeight);
              },
            ),
          ),
          ?cap,
        ],
      );
    }

    return LayoutBuilder(
      builder: (context, box) {
        final availW = math.max(10.0, box.maxWidth - gl - gr - 2);
        final scW = availW / dataSize!.width;
        final scH = box.maxHeight.isFinite
            ? math.max(10.0, box.maxHeight - gt - (caption == null ? 0 : captionReserve) - 2) / dataSize!.height
            : double.infinity;
        final sc = math.min(scW, scH);
        final w = dataSize!.width * sc, h = dataSize!.height * sc;
        final totalW = gl + w + gr;
        return Align(
          alignment: Alignment.topCenter,
          heightFactor: 1,
          child: SizedBox(
            width: totalW,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [_plot(context, Rect.fromLTWH(gl, gt, w, h), totalW, gt + h), ?cap],
            ),
          ),
        );
      },
    );
  }
}

class _TickPainter extends CustomPainter {
  _TickPainter({required this.plot, required this.data, required this.unitX, required this.unitY, required this.style});
  final Rect plot;
  final Size data;
  final String unitX, unitY;
  final TextStyle style;

  static double _step(double pxPerUnit) {
    const steps = [10.0, 20.0, 25.0, 50.0, 100.0, 200.0, 250.0, 500.0, 1000.0, 2000.0, 5000.0];
    for (final s in steps) {
      if (s * pxPerUnit >= 58) return s;
    }
    return steps.last;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final sc = plot.width / data.width;
    final step = _step(sc);
    final p = Paint()
      ..color = FsPalette.ink
      ..strokeWidth = 1;
    TextPainter tp(String s) => TextPainter(
      text: TextSpan(text: s, style: style),
      textDirection: TextDirection.ltr,
    )..layout();
    // top edge
    final nx = (data.width / step).floor();
    for (int i = 0; i <= nx; i++) {
      final x = plot.left + i * step * sc;
      canvas.drawLine(Offset(x, plot.top - 6), Offset(x, plot.top), p);
      final last = i == nx;
      final t = tp('${(i * step).round()}${last && unitX.isNotEmpty ? ' $unitX' : ''}');
      final dx = last && x + t.width / 2 > size.width ? x - t.width : x - (i == 0 ? 0 : t.width / 2);
      t.paint(canvas, Offset(dx, plot.top - 8 - t.height));
    }
    // left edge
    final ny = (data.height / step).floor();
    for (int i = 0; i <= ny; i++) {
      final y = plot.top + i * step * sc;
      canvas.drawLine(Offset(plot.left - 6, y), Offset(plot.left, y), p);
      final t = tp('${(i * step).round()}');
      t.paint(canvas, Offset(plot.left - 9 - t.width, i == 0 ? y : y - t.height / 2));
    }
    if (unitY.isNotEmpty) {
      final t = tp(unitY);
      t.paint(canvas, Offset(plot.left - 9 - t.width, plot.bottom - t.height));
    }
  }

  @override
  bool shouldRepaint(covariant _TickPainter old) => old.plot != plot || old.data != data || old.unitX != unitX || old.unitY != unitY;
}

class ColorBar extends StatelessWidget {
  const ColorBar(this.spec, {super.key});
  final ColorBarSpec spec;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final st = t.textTheme.labelSmall?.copyWith(color: FsPalette.ink, fontSize: 10.5);
    String f(double v) => v.toStringAsFixed(spec.decimals);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                width: 12,
                decoration: BoxDecoration(
                  border: Border.all(color: FsPalette.ink),
                  gradient: LinearGradient(begin: Alignment.bottomCenter, end: Alignment.topCenter, colors: viridisStops()),
                ),
              ),
              const SizedBox(width: 6),
              Column(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(f(spec.hi), style: st),
                  Text(f((spec.lo + spec.hi) / 2), style: st),
                  Text(f(spec.lo), style: st),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 6),
        Text(spec.unit, style: t.textTheme.labelSmall),
      ],
    );
  }
}

/// Horizontal viridis scale with end labels, for side panels.
class ColorScaleStrip extends StatelessWidget {
  const ColorScaleStrip({super.key, required this.lo, required this.hi, this.caption});
  final String lo, hi;
  final String? caption;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final st = t.textTheme.labelSmall?.copyWith(color: FsPalette.ink, fontSize: 10.5);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (caption != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(caption!, style: t.textTheme.bodySmall),
          ),
        Container(
          height: 8,
          decoration: BoxDecoration(
            border: Border.all(color: FsPalette.ink),
            gradient: LinearGradient(colors: viridisStops()),
          ),
        ),
        const SizedBox(height: 3),
        Row(
          children: [
            Text(lo, style: st),
            const Spacer(),
            Text(hi, style: st),
          ],
        ),
      ],
    );
  }
}

/// A small time-series plot with real axes: value (percent) against seconds before now.
class TrendPlot extends StatelessWidget {
  const TrendPlot({super.key, required this.samples, this.windowS = 60, this.height = 96, this.semantics = ''});

  /// (seconds before now, value 0-100). Newest last.
  final List<(double, double)> samples;
  final double windowS;
  final double height;
  final String semantics;

  @override
  Widget build(BuildContext context) => Semantics(
    label: semantics,
    child: SizedBox(
      height: height,
      width: double.infinity,
      child: CustomPaint(painter: _TrendPainter(samples, windowS, Theme.of(context).textTheme.labelSmall!)),
    ),
  );
}

class _TrendPainter extends CustomPainter {
  _TrendPainter(this.samples, this.windowS, this.style);
  final List<(double, double)> samples;
  final double windowS;
  final TextStyle style;

  @override
  void paint(Canvas canvas, Size size) {
    const left = 34.0, bottom = 18.0, top = 6.0, right = 6.0;
    final plot = Rect.fromLTRB(left, top, size.width - right, size.height - bottom);
    final vals = samples.map((e) => e.$2).toList();
    final lo = vals.isEmpty ? 90.0 : math.min(90.0, (vals.reduce(math.min) / 10).floor() * 10.0);
    const hi = 100.0;
    final ink = Paint()
      ..color = FsPalette.ink
      ..strokeWidth = 1;
    final grid = Paint()
      ..color = FsPalette.ruleLight
      ..strokeWidth = 1;
    TextPainter tp(String s) => TextPainter(
      text: TextSpan(text: s, style: style),
      textDirection: TextDirection.ltr,
    )..layout();
    double y(double v) => plot.bottom - (v - lo) / (hi - lo) * plot.height;
    double x(double ago) => plot.right - ago / windowS * plot.width;
    canvas.drawLine(Offset(plot.left, y((lo + hi) / 2)), Offset(plot.right, y((lo + hi) / 2)), grid);
    canvas.drawLine(plot.topLeft, plot.bottomLeft, ink);
    canvas.drawLine(plot.bottomLeft, plot.bottomRight, ink);
    for (final v in [hi, (lo + hi) / 2, lo]) {
      canvas.drawLine(Offset(plot.left - 4, y(v)), Offset(plot.left, y(v)), ink);
      final t = tp(v == lo ? '${v.round()} %' : '${v.round()}');
      t.paint(canvas, Offset(plot.left - 7 - t.width, y(v) - t.height / 2));
    }
    for (final (ago, label) in [(windowS, '−${windowS.round()} s'), (windowS / 2, '−${(windowS / 2).round()} s'), (0.0, 'now')]) {
      canvas.drawLine(Offset(x(ago), plot.bottom), Offset(x(ago), plot.bottom + 4), ink);
      final t = tp(label);
      final dx = ago == 0 ? x(ago) - t.width : (ago == windowS ? x(ago) - t.width / 2 + 6 : x(ago) - t.width / 2);
      t.paint(canvas, Offset(dx, plot.bottom + 5));
    }
    final pts = samples.where((s) => s.$1 <= windowS).toList();
    if (pts.length >= 2) {
      final path = Path()..moveTo(x(pts.first.$1), y(pts.first.$2));
      for (final p in pts.skip(1)) {
        path.lineTo(x(p.$1), y(p.$2));
      }
      canvas.drawPath(
        path,
        Paint()
          ..color = FsPalette.survey
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..strokeJoin = StrokeJoin.round,
      );
    } else if (pts.length == 1) {
      canvas.drawCircle(Offset(x(pts.first.$1), y(pts.first.$2)), 2, Paint()..color = FsPalette.survey);
    }
  }

  @override
  bool shouldRepaint(covariant _TrendPainter old) => true;
}

/// Hatched magenta band: maps hatch areas with no survey data, and this marks data with no sensor behind it.
class SyntheticHatch extends StatelessWidget {
  const SyntheticHatch({super.key, required this.child, this.boxed = false});
  final Widget child;
  final bool boxed;

  @override
  Widget build(BuildContext context) => Container(
    decoration: BoxDecoration(
      color: FsPalette.syntheticTint,
      border: boxed ? Border.all(color: FsPalette.syntheticRule) : const Border(bottom: BorderSide(color: FsPalette.syntheticRule)),
      borderRadius: boxed ? BorderRadius.circular(2) : null,
    ),
    child: CustomPaint(painter: _HatchPainter(), child: child),
  );
}

class _HatchPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = FsPalette.synthetic.withValues(alpha: 0.16)
      ..strokeWidth = 2;
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    const gap = 9.0;
    for (double x = -size.height; x < size.width + size.height; x += gap) {
      canvas.drawLine(Offset(x, 0), Offset(x + size.height, size.height), p);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _HatchPainter old) => false;
}

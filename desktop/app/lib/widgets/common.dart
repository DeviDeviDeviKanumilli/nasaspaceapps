import 'dart:io';

import 'package:flutter/material.dart';

import '../service/api.dart';
import '../service/models.dart';

// ---------------------------------------------------------------------------------------------------------------
// Design tokens ("survey plate").
//
// The app should read like a lab notebook or a figure in a methods paper: light paper, black-framed figures with
// axes and captions, ruled result tables, footnoted caveats. Colour is reserved for meaning:
//   survey blue  = you can act on it (links, selection, primary buttons)
//   field ochre  = annotations you drew (regions, distances) and the brand mark
//   record red   = recording, errors
//   magenta      = not from a sensor (synthetic, replay, unverified import), always with a hatch or a label
//   sensor green = origin tag of a real measurement, nothing else
// Data colours are separate: viridis for depth and range.
// ---------------------------------------------------------------------------------------------------------------

class FsPalette {
  static const paper = Color(0xFFF3F4F2);
  static const sheet = Color(0xFFFFFFFF);
  static const sheetAlt = Color(0xFFF7F8F7);
  static const plot = Color(0xFFF6F7F6);
  static const ink = Color(0xFF1B1D1F);
  static const inkMuted = Color(0xFF586066); // 6.5:1 on sheet, 5.9:1 on paper
  static const rule = Color(0xFFCDD1D3);
  static const ruleLight = Color(0xFFE3E6E7);
  static const field = Color(0xFFA9AFB2);
  static const disabledFill = Color(0xFFD9DDDF);
  static const survey = Color(0xFF1D5FA0);
  static const surveyDeep = Color(0xFF123F6B);
  static const surveyTint = Color(0xFFE4EDF7);
  static const ochre = Color(0xFF8F531A);
  static const record = Color(0xFFBE2A2A);
  static const recordInk = Color(0xFF7A1B1B);
  static const recordTint = Color(0xFFFBEDED);
  static const recordRule = Color(0xFFE5B9B9);
  static const synthetic = Color(0xFF85308A);
  static const syntheticTint = Color(0xFFFBF6FB);
  static const syntheticRule = Color(0xFFD9B8DA);
  static const sensor = Color(0xFF23704A);
  static const sensorTint = Color(0xFFEEF6F1);
  static const sensorRule = Color(0xFFA9CDB8);
  static const caution = Color(0xFF8A6100); // capture-quality guidance; always paired with a warning icon
}

/// Semantic colour lookup kept as a small object so call sites read `FsColors.of(context).sim`.
class FsColors {
  const FsColors();
  Color get real => FsPalette.sensor;
  Color get sim => FsPalette.synthetic;
  Color get record => FsPalette.record;
  Color get warn => FsPalette.caution;
  Color get annotate => FsPalette.ochre;
  Color get action => FsPalette.survey;
  Color get panel => FsPalette.sheet;
  Color get line => FsPalette.rule;
  Color get lineLight => FsPalette.ruleLight;

  static FsColors of(BuildContext c) => const FsColors();
}

const fsFont = 'PublicSans';
const tnum = [FontFeature.tabularFigures()];
const monoFallback = ['Menlo', 'Consolas', 'Cascadia Mono', 'Courier New', 'monospace'];

/// Monospaced text, for logs only. Numbers elsewhere use the body face with tabular figures.
TextStyle? mono(TextStyle? base, {double size = 11.5}) =>
    base?.copyWith(fontFamily: Platform.isMacOS ? 'Menlo' : 'Consolas', fontFamilyFallback: monoFallback, fontSize: size, height: 1.45);

ThemeData buildTheme() {
  const ink = FsPalette.ink, muted = FsPalette.inkMuted, survey = FsPalette.survey, white = FsPalette.sheet;

  TextStyle s(double size, FontWeight w, {double h = 1.4, double ls = 0, Color color = ink}) =>
      TextStyle(fontFamily: fsFont, fontSize: size, fontWeight: w, height: h, letterSpacing: ls, color: color, fontFeatures: tnum);

  final text = TextTheme(
    displaySmall: s(30, FontWeight.w600, h: 1.15, ls: -0.3),
    headlineSmall: s(22, FontWeight.w600, h: 1.25, ls: -0.2),
    titleLarge: s(17, FontWeight.w600, h: 1.3),
    titleMedium: s(15, FontWeight.w600, h: 1.35),
    titleSmall: s(14, FontWeight.w600, h: 1.35),
    bodyLarge: s(15, FontWeight.w400, h: 1.45),
    bodyMedium: s(14, FontWeight.w400, h: 1.45),
    bodySmall: s(12.5, FontWeight.w400, h: 1.4, color: muted),
    labelLarge: s(14, FontWeight.w600, h: 1.2),
    labelMedium: s(13, FontWeight.w500, h: 1.25),
    labelSmall: s(11, FontWeight.w500, h: 1.2, color: muted),
  );

  const scheme = ColorScheme(
    brightness: Brightness.light,
    primary: survey,
    onPrimary: white,
    primaryContainer: FsPalette.surveyTint,
    onPrimaryContainer: FsPalette.surveyDeep,
    secondary: FsPalette.ochre,
    onSecondary: white,
    secondaryContainer: FsPalette.surveyTint,
    onSecondaryContainer: FsPalette.surveyDeep,
    tertiary: FsPalette.synthetic,
    onTertiary: white,
    error: FsPalette.record,
    onError: white,
    errorContainer: FsPalette.recordTint,
    onErrorContainer: FsPalette.recordInk,
    surface: FsPalette.paper,
    onSurface: ink,
    onSurfaceVariant: muted,
    surfaceContainerLowest: white,
    surfaceContainerLow: white,
    surfaceContainer: FsPalette.sheetAlt,
    surfaceContainerHigh: Color(0xFFEDEFEE),
    surfaceContainerHighest: Color(0xFFE6E8E7),
    outline: FsPalette.field,
    outlineVariant: FsPalette.rule,
    inverseSurface: ink,
    onInverseSurface: white,
    inversePrimary: Color(0xFF9CC2EA),
    shadow: Colors.black,
    scrim: Colors.black,
    surfaceTint: Colors.transparent,
  );

  final r4 = BorderRadius.circular(4);
  WidgetStateProperty<BorderSide?> ring(BorderSide? base) =>
      WidgetStateProperty.resolveWith((st) => st.contains(WidgetState.focused) ? const BorderSide(color: survey, width: 2) : base);
  final focusDarken = WidgetStateProperty.resolveWith<Color?>((st) {
    if (st.contains(WidgetState.pressed)) return Colors.black.withValues(alpha: 0.16);
    if (st.contains(WidgetState.focused)) return Colors.black.withValues(alpha: 0.22);
    if (st.contains(WidgetState.hovered)) return Colors.black.withValues(alpha: 0.08);
    return null;
  });

  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.light,
    colorScheme: scheme,
    fontFamily: fsFont,
    textTheme: text,
    scaffoldBackgroundColor: FsPalette.paper,
    canvasColor: white,
    visualDensity: VisualDensity.compact,
    splashFactory: NoSplash.splashFactory,
    hoverColor: ink.withValues(alpha: 0.04),
    focusColor: survey.withValues(alpha: 0.14),
    highlightColor: Colors.transparent,
    cardTheme: CardThemeData(
      elevation: 0,
      margin: EdgeInsets.zero,
      color: white,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(2),
        side: const BorderSide(color: FsPalette.rule),
      ),
    ),
    dividerTheme: const DividerThemeData(color: FsPalette.rule, space: 1, thickness: 1),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: survey,
        foregroundColor: white,
        disabledBackgroundColor: FsPalette.disabledFill,
        disabledForegroundColor: muted,
        textStyle: text.labelLarge,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: r4),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        minimumSize: const Size(0, 38),
      ).copyWith(overlayColor: focusDarken),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: ink,
        backgroundColor: white,
        disabledForegroundColor: muted,
        textStyle: text.labelLarge?.copyWith(fontWeight: FontWeight.w500),
        shape: RoundedRectangleBorder(borderRadius: r4),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        minimumSize: const Size(0, 38),
      ).copyWith(side: ring(const BorderSide(color: FsPalette.field))),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: survey,
        textStyle: text.labelLarge,
        shape: RoundedRectangleBorder(borderRadius: r4),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
      ).copyWith(side: ring(null)),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(
        foregroundColor: ink,
        shape: RoundedRectangleBorder(borderRadius: r4),
      ).copyWith(side: ring(null)),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        backgroundColor: WidgetStateProperty.resolveWith((st) => st.contains(WidgetState.selected) ? FsPalette.surveyTint : white),
        foregroundColor: WidgetStateProperty.resolveWith((st) => st.contains(WidgetState.selected) ? survey : ink),
        textStyle: WidgetStateProperty.resolveWith(
          (st) => text.labelLarge?.copyWith(fontWeight: st.contains(WidgetState.selected) ? FontWeight.w600 : FontWeight.w400),
        ),
        side: const WidgetStatePropertyAll(BorderSide(color: FsPalette.field)),
        shape: WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: r4)),
        padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 14, vertical: 9)),
        visualDensity: VisualDensity.compact,
        overlayColor: WidgetStateProperty.resolveWith((st) => st.contains(WidgetState.focused) ? survey.withValues(alpha: 0.18) : null),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      isDense: true,
      filled: true,
      fillColor: white,
      floatingLabelBehavior: FloatingLabelBehavior.always,
      contentPadding: const EdgeInsets.fromLTRB(12, 14, 12, 12),
      labelStyle: text.bodyMedium?.copyWith(color: muted),
      floatingLabelStyle: text.labelMedium?.copyWith(color: muted),
      helperStyle: text.bodySmall,
      hintStyle: text.bodyMedium?.copyWith(color: muted),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(3),
        borderSide: const BorderSide(color: FsPalette.field),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(3),
        borderSide: const BorderSide(color: FsPalette.field),
      ),
      disabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(3),
        borderSide: const BorderSide(color: FsPalette.ruleLight),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(3),
        borderSide: const BorderSide(color: survey, width: 2),
      ),
    ),
    checkboxTheme: CheckboxThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(2)),
      side: const BorderSide(color: FsPalette.inkMuted, width: 1.5),
      fillColor: WidgetStateProperty.resolveWith((st) => st.contains(WidgetState.selected) ? survey : null),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((st) => st.contains(WidgetState.selected) ? white : FsPalette.inkMuted),
      trackColor: WidgetStateProperty.resolveWith((st) => st.contains(WidgetState.selected) ? survey : FsPalette.ruleLight),
      trackOutlineColor: WidgetStateProperty.resolveWith((st) => st.contains(WidgetState.selected) ? survey : FsPalette.field),
    ),
    sliderTheme: SliderThemeData(
      trackHeight: 3,
      activeTrackColor: survey,
      inactiveTrackColor: FsPalette.ruleLight,
      thumbColor: survey,
      overlayColor: survey.withValues(alpha: 0.12),
      overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
      thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(color: survey, linearTrackColor: FsPalette.ruleLight),
    tabBarTheme: TabBarThemeData(
      labelColor: survey,
      unselectedLabelColor: ink,
      labelStyle: text.labelLarge,
      unselectedLabelStyle: text.labelLarge?.copyWith(fontWeight: FontWeight.w400),
      indicatorSize: TabBarIndicatorSize.label,
      indicator: const UnderlineTabIndicator(borderSide: BorderSide(color: survey, width: 2)),
      dividerColor: FsPalette.rule,
      labelPadding: const EdgeInsets.only(right: 24),
      overlayColor: WidgetStatePropertyAll(Colors.transparent),
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(color: ink, borderRadius: BorderRadius.circular(3)),
      textStyle: text.bodySmall?.copyWith(color: white),
      waitDuration: const Duration(milliseconds: 500),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: ink,
      contentTextStyle: text.bodyMedium?.copyWith(color: white),
      actionTextColor: const Color(0xFF9CC2EA),
      shape: RoundedRectangleBorder(borderRadius: r4),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: white,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: r4),
      titleTextStyle: text.titleLarge,
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: white,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: r4,
        side: const BorderSide(color: FsPalette.rule),
      ),
      textStyle: text.bodyMedium,
    ),
    listTileTheme: ListTileThemeData(titleTextStyle: text.bodyMedium, subtitleTextStyle: text.bodySmall),
    expansionTileTheme: const ExpansionTileThemeData(shape: Border(), collapsedShape: Border()),
    scrollbarTheme: ScrollbarThemeData(
      thickness: const WidgetStatePropertyAll(6),
      radius: const Radius.circular(3),
      thumbColor: WidgetStatePropertyAll(FsPalette.field.withValues(alpha: 0.7)),
    ),
  );
}

/// Capture-quality guidance colour (not provenance, not an action).
Color warnColor(BuildContext c) => FsPalette.caution;

/// Colour for data that is not a new real-sensor observation (synthetic, replay, unverified import).
Color simColor(BuildContext c) => FsPalette.synthetic;

// --------------------------------------------------------------------------------------------- panels and text

/// A white sheet on the paper background. Panels have a 2 px radius and no shadow.
class Panel extends StatelessWidget {
  const Panel({super.key, required this.child, this.padding = EdgeInsets.zero, this.strong = false});
  final Widget child;
  final EdgeInsets padding;

  /// Ink border instead of a rule, for title blocks.
  final bool strong;

  @override
  Widget build(BuildContext context) => Container(
    padding: padding,
    decoration: BoxDecoration(
      color: FsPalette.sheet,
      borderRadius: BorderRadius.circular(2),
      border: Border.all(color: strong ? FsPalette.ink : FsPalette.rule, width: strong ? 1.5 : 1),
    ),
    clipBehavior: Clip.antiAlias,
    child: child,
  );
}

/// A titled part of a panel. Several parts in one [Panel] are separated by rules (pass [ruled]).
class PanelPart extends StatelessWidget {
  const PanelPart({
    super.key,
    this.title,
    required this.child,
    this.trailing,
    this.subtitle,
    this.ruled = false,
    this.padding = const EdgeInsets.fromLTRB(18, 16, 18, 18),
  });
  final String? title;
  final String? subtitle;
  final Widget child;
  final Widget? trailing;
  final bool ruled;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Container(
      decoration: ruled
          ? const BoxDecoration(
              border: Border(top: BorderSide(color: FsPalette.rule)),
            )
          : null,
      padding: padding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (title != null || trailing != null) ...[
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(child: Text(title ?? '', style: t.textTheme.titleMedium)),
                ?trailing,
              ],
            ),
            if (subtitle != null) ...[const SizedBox(height: 2), Text(subtitle!, style: t.textTheme.bodySmall)],
            const SizedBox(height: 10),
          ],
          child,
        ],
      ),
    );
  }
}

/// One panel with one titled part: the common case.
class SectionCard extends StatelessWidget {
  const SectionCard({
    super.key,
    this.title,
    required this.child,
    this.trailing,
    this.subtitle,
    this.padding = const EdgeInsets.fromLTRB(18, 16, 18, 18),
  });
  final String? title;
  final String? subtitle;
  final Widget child;
  final Widget? trailing;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) => Panel(
    child: PanelPart(title: title, subtitle: subtitle, trailing: trailing, padding: padding, child: child),
  );
}

/// Label / value pair, like a definition list. Values use tabular figures and can be selected.
class KV extends StatelessWidget {
  const KV(this.label, this.value, {super.key, this.labelWidth = 150, this.valueStyle});
  final String label;
  final String value;
  final double labelWidth;
  final TextStyle? valueStyle;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: labelWidth,
            child: Padding(
              padding: const EdgeInsets.only(top: 1, right: 12),
              child: Text(label, style: t.textTheme.bodyMedium?.copyWith(color: FsPalette.inkMuted, fontSize: 13.5)),
            ),
          ),
          Expanded(child: SelectableText(value, style: valueStyle ?? t.textTheme.bodyMedium?.copyWith(fontSize: 13.5))),
        ],
      ),
    );
  }
}

class FactRow {
  const FactRow(this.label, this.value, {this.unit, this.color});
  final String label;
  final String value;
  final String? unit;
  final Color? color;
}

/// Quantity table: label left, value right-aligned in semibold, unit in its own column. Light rules between rows.
class FactTable extends StatelessWidget {
  const FactTable(this.rows, {super.key, this.unitWidth = 44, this.dense = false});
  final List<FactRow> rows;
  final double unitWidth;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (int i = 0; i < rows.length; i++)
          Container(
            padding: EdgeInsets.symmetric(vertical: dense ? 4 : 5.5),
            decoration: i == rows.length - 1
                ? null
                : const BoxDecoration(
                    border: Border(bottom: BorderSide(color: FsPalette.ruleLight)),
                  ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Expanded(
                  child: Text(rows[i].label, style: t.textTheme.bodyMedium?.copyWith(color: FsPalette.inkMuted)),
                ),
                const SizedBox(width: 12),
                Text(
                  rows[i].value,
                  style: t.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600, color: rows[i].color),
                ),
                SizedBox(
                  width: unitWidth,
                  child: Padding(
                    padding: const EdgeInsets.only(left: 6),
                    child: Text(rows[i].unit ?? '', style: t.textTheme.bodyMedium?.copyWith(color: FsPalette.inkMuted)),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class RCol {
  const RCol(this.label, {this.flex = 1, this.numeric = false, this.width});
  final String label;
  final int flex;
  final bool numeric;
  final double? width;
}

/// Result table with three rules only: heavy top and bottom, light under the header (booktabs style).
/// Cells are Strings or Widgets. Footnotes are numbered below the table.
class ResultTable extends StatelessWidget {
  const ResultTable({super.key, required this.columns, required this.rows, this.footnotes = const [], this.fontSize = 13.5});
  final List<RCol> columns;
  final List<List<Object?>> rows;
  final List<String> footnotes;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final body = t.textTheme.bodyMedium?.copyWith(fontSize: fontSize);
    Widget cell(int c, Object? v, {bool head = false}) {
      final col = columns[c];
      final w = v is Widget
          ? v
          : Text(
              asStr(v, ''),
              textAlign: col.numeric ? TextAlign.right : TextAlign.left,
              style: head ? body?.copyWith(fontWeight: FontWeight.w600) : body,
            );
      final padded = Padding(
        padding: EdgeInsets.only(left: c == 0 ? 0 : 12),
        child: Align(alignment: col.numeric ? Alignment.centerRight : Alignment.centerLeft, child: w),
      );
      return col.width != null ? SizedBox(width: col.width, child: padded) : Expanded(flex: col.flex, child: padded);
    }

    Widget row(List<Object?> cells, {bool head = false, Border? border}) => Container(
      padding: const EdgeInsets.symmetric(vertical: 6),
      decoration: BoxDecoration(border: border),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [for (int c = 0; c < columns.length; c++) cell(c, c < cells.length ? cells[c] : null, head: head)],
      ),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        row(
          [for (final c in columns) c.label],
          head: true,
          border: const Border(
            top: BorderSide(color: FsPalette.ink, width: 1.5),
            bottom: BorderSide(color: FsPalette.ink),
          ),
        ),
        for (int r = 0; r < rows.length; r++)
          row(
            rows[r],
            border: Border(
              bottom: r == rows.length - 1
                  ? const BorderSide(color: FsPalette.ink, width: 1.5)
                  : const BorderSide(color: FsPalette.ruleLight),
            ),
          ),
        if (rows.isEmpty) Container(height: 1.5, color: FsPalette.ink),
        if (footnotes.isNotEmpty) ...[
          const SizedBox(height: 8),
          for (int i = 0; i < footnotes.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 3),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(width: 18, child: Text('${i + 1}', style: t.textTheme.bodySmall)),
                  Expanded(child: Text(footnotes[i], style: t.textTheme.bodySmall)),
                ],
              ),
            ),
        ],
      ],
    );
  }
}

/// Superscript digits for footnote markers.
String sup(int n) => '$n'.split('').map((d) => '⁰¹²³⁴⁵⁶⁷⁸⁹'[int.parse(d)]).join();

// --------------------------------------------------------------------------------------------- provenance

String originLabel(String? origin) {
  switch (originKind(origin)) {
    case OriginKind.realD435:
      return 'Real sensor, D435';
    case OriginKind.replay:
      return 'Replay';
    case OriginKind.synthetic:
      return 'Synthetic';
    case OriginKind.iphone:
      return origin == 'iphone_arkit_camera' ? 'iPhone camera' : 'iPhone LiDAR';
    case OriginKind.unknownImport:
      return 'Unverified import';
    case OriginKind.other:
      return origin ?? 'Unknown origin';
  }
}

/// Provenance tag. Green only for real measurements; magenta for anything that is not a new sensor observation;
/// a dashed outline for replays, which always repeat an earlier recording.
class OriginTag extends StatelessWidget {
  const OriginTag(this.origin, {super.key, this.label});
  final String? origin;
  final String? label;

  @override
  Widget build(BuildContext context) {
    final k = originKind(origin);
    final t = Theme.of(context);
    final (fg, bg, line, dashed) = switch (k) {
      OriginKind.realD435 || OriginKind.iphone => (FsPalette.sensor, FsPalette.sensorTint, FsPalette.sensorRule, false),
      OriginKind.synthetic || OriginKind.unknownImport => (FsPalette.synthetic, FsPalette.syntheticTint, FsPalette.syntheticRule, false),
      OriginKind.replay => (FsPalette.inkMuted, FsPalette.sheet, FsPalette.inkMuted, true),
      OriginKind.other => (FsPalette.inkMuted, FsPalette.sheet, FsPalette.field, false),
    };
    final txt = Text(
      label ?? originLabel(origin),
      style: t.textTheme.labelMedium?.copyWith(color: fg, fontWeight: FontWeight.w600, fontSize: 12, height: 1.2),
    );
    const pad = EdgeInsets.symmetric(horizontal: 7, vertical: 2.5);
    if (dashed) {
      return CustomPaint(
        painter: _DashedRectPainter(line),
        child: Padding(padding: pad, child: txt),
      );
    }
    return Container(
      padding: pad,
      decoration: BoxDecoration(
        color: bg,
        border: Border.all(color: line),
        borderRadius: BorderRadius.circular(3),
      ),
      child: txt,
    );
  }
}

class _DashedRectPainter extends CustomPainter {
  _DashedRectPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = color
      ..strokeWidth = 1;
    void dash(Offset a, Offset b) {
      final len = (b - a).distance;
      final dir = (b - a) / len;
      for (double d = 0; d < len; d += 6) {
        canvas.drawLine(a + dir * d, a + dir * (d + 3 > len ? len : d + 3), p);
      }
    }

    final r = (Offset.zero & size).deflate(0.5);
    dash(r.topLeft, r.topRight);
    dash(r.topRight, r.bottomRight);
    dash(r.bottomRight, r.bottomLeft);
    dash(r.bottomLeft, r.topLeft);
  }

  @override
  bool shouldRepaint(covariant _DashedRectPainter old) => old.color != color;
}

class StatusChip extends StatelessWidget {
  const StatusChip(this.status, {super.key});
  final String status;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final bad = status == 'incomplete' || status == 'error' || status == 'unreadable';
    final busy = status == 'recording' || status == 'processing';
    final fg = bad ? FsPalette.record : (busy ? FsPalette.caution : FsPalette.inkMuted);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(bad ? Icons.error_outline : (busy ? Icons.hourglass_top_rounded : Icons.check_rounded), size: 14, color: fg),
        const SizedBox(width: 4),
        Text(
          status,
          style: t.textTheme.labelMedium?.copyWith(color: fg, fontWeight: bad ? FontWeight.w700 : FontWeight.w500),
        ),
      ],
    );
  }
}

// --------------------------------------------------------------------------------------------- page furniture

/// Page title, optional muted subtitle, controls that belong to the title ([inline]) and actions on the right.
class PageHeader extends StatelessWidget {
  const PageHeader(
    this.title, {
    super.key,
    this.subtitle,
    this.inline = const [],
    this.actions = const [],
    this.padding = const EdgeInsets.fromLTRB(24, 18, 24, 14),
  });
  final String title;
  final String? subtitle;
  final List<Widget> inline;
  final List<Widget> actions;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final head = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(title, style: t.textTheme.headlineSmall),
        if (subtitle != null) ...[
          const SizedBox(height: 2),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 680),
            child: Text(subtitle!, style: t.textTheme.bodyMedium?.copyWith(color: FsPalette.inkMuted)),
          ),
        ],
      ],
    );
    // Title and its controls on the left; actions hug the right edge and wrap before they crowd the title.
    return Padding(
      padding: padding,
      child: LayoutBuilder(
        builder: (context, box) {
          final actionsBox = actions.isEmpty
              ? const SizedBox.shrink()
              : ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: box.maxWidth * (inline.isEmpty ? 0.6 : 0.4)),
                  child: Wrap(
                    alignment: WrapAlignment.end,
                    spacing: 10,
                    runSpacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.end,
                    children: actions,
                  ),
                );
          return Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              if (inline.isEmpty) Expanded(child: head) else head,
              if (inline.isNotEmpty) ...[
                const SizedBox(width: 20),
                Expanded(
                  child: Wrap(spacing: 12, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.end, children: inline),
                ),
              ],
              const SizedBox(width: 16),
              actionsBox,
            ],
          );
        },
      ),
    );
  }
}

class EmptyState extends StatelessWidget {
  const EmptyState({super.key, this.icon, required this.title, this.body, this.action});
  final IconData? icon;
  final String title;
  final String? body;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[Icon(icon, size: 28, color: FsPalette.inkMuted), const SizedBox(height: 12)],
              Text(title, textAlign: TextAlign.center, style: t.textTheme.titleLarge),
              if (body != null) ...[
                const SizedBox(height: 6),
                Text(
                  body!,
                  textAlign: TextAlign.center,
                  style: t.textTheme.bodyMedium?.copyWith(color: FsPalette.inkMuted),
                ),
              ],
              if (action != null) ...[const SizedBox(height: 18), action!],
            ],
          ),
        ),
      ),
    );
  }
}

/// Error shown verbatim from the service: what went wrong, in the interface's voice.
class ErrorBox extends StatelessWidget {
  const ErrorBox(this.message, {super.key, this.action});
  final String message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: FsPalette.recordTint,
        borderRadius: BorderRadius.circular(2),
        border: Border.all(color: FsPalette.recordRule),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(top: 1),
            child: Icon(Icons.error_outline, size: 17, color: FsPalette.record),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: SelectableText(message, style: t.textTheme.bodyMedium?.copyWith(color: FsPalette.recordInk)),
          ),
          if (action != null) ...[const SizedBox(width: 12), action!],
        ],
      ),
    );
  }
}

/// One line of guidance, with an icon so meaning never relies on colour alone.
class Hint extends StatelessWidget {
  const Hint(this.text, {super.key, this.color, this.icon = Icons.info_outline});
  final String text;
  final Color? color;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final c = color ?? FsPalette.inkMuted;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 1.5),
          child: Icon(icon, size: 15, color: c),
        ),
        const SizedBox(width: 7),
        Expanded(
          child: Text(
            text,
            style: t.textTheme.bodySmall?.copyWith(color: c, fontWeight: color == null ? null : FontWeight.w500),
          ),
        ),
      ],
    );
  }
}

/// Segmented control used across the app (Colour/Depth, Filtered/Raw/Mesh, tools).
class Segmented<T> extends StatelessWidget {
  const Segmented({super.key, required this.value, required this.options, required this.onChanged, this.expand = false});
  final T value;
  final List<(T, String)> options;
  final ValueChanged<T>? onChanged;
  final bool expand;

  @override
  Widget build(BuildContext context) {
    final b = SegmentedButton<T>(
      showSelectedIcon: false,
      segments: [
        for (final (v, l) in options)
          ButtonSegment<T>(
            value: v,
            label: Text(l, overflow: TextOverflow.ellipsis),
          ),
      ],
      selected: {value},
      onSelectionChanged: onChanged == null ? null : (s) => onChanged!(s.first),
    );
    return expand ? SizedBox(width: double.infinity, child: b) : b;
  }
}

void showSnack(BuildContext context, String msg, {bool error = false}) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Row(
        children: [
          Icon(
            error ? Icons.error_outline : Icons.check_circle_outline,
            color: error ? const Color(0xFFF2A7A7) : const Color(0xFF9CC2EA),
            size: 18,
          ),
          const SizedBox(width: 10),
          Expanded(child: Text(msg)),
        ],
      ),
      behavior: SnackBarBehavior.floating,
      width: 560,
    ),
  );
}

String errText(Object e) => e is ApiException ? e.toString() : '$e';

String pct(Object? v) {
  final d = asDouble(v);
  return d == null ? '—' : '${(d * 100).toStringAsFixed(1)} %';
}

String metres(Object? v) {
  final d = asDouble(v);
  return d == null ? '—' : '${d.toStringAsFixed(3)} m';
}

String shortId(String? id) => id == null || id.length < 8 ? (id ?? '—') : id.substring(0, 8);

/// "2026-11-15T08:43:11.064Z" -> "2026-11-15 08:43:11".
String utcText(Object? iso) {
  final s = asStr(iso);
  if (s.isEmpty) return '—';
  return s.replaceFirst('T', ' ').split('.').first.replaceAll('Z', '');
}

String bytesText(int? b) {
  if (b == null) return '—';
  if (b >= 1e6) return '${(b / 1e6).toStringAsFixed(1)} MB';
  if (b >= 1e3) return '${(b / 1e3).toStringAsFixed(b >= 1e5 ? 0 : 1)} kB';
  return '$b B';
}

/// "848x480 @ 30 fps" -> "848 × 480 @ 30 fps".
String dims(Object? s) => asStr(s).replaceAllMapped(RegExp(r'(\d)\s*x\s*(\d)'), (m) => '${m[1]} × ${m[2]}');

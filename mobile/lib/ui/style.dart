// Field Scan look: light ground, white cards, moss green actions, Nunito Sans throughout (heavy weight for headings).
// One set of numbers for every screen: 20 px side margins, 20 px card corners, 56 px buttons with 18 px corners.
import 'package:flutter/material.dart';

class Fs {
  // ground and surfaces
  static const ground = Color(0xFFF4F5F0);
  static const card = Color(0xFFFFFFFF);
  static const well = Color(0xFFE8EBE3); // segmented-control track, viewer background tint
  static const quiet = Color(0xFFEEF0EA); // secondary round buttons
  static const line = Color(0xFFDDE0D6);
  static const lineStrong = Color(0xFFCDD1C5);

  // text
  static const ink = Color(0xFF23251F);
  static const ink2 = Color(0xFF3B3E36);
  static const muted = Color(0xFF55594F);
  static const faint = Color(0xFF5F635A);

  // actions and states
  static const moss = Color(0xFF2F6B4F);
  static const mossTint = Color(0xFFE3EFE6);
  static const mossInk = Color(0xFF1F4A36);
  static const live = Color(0xFF3E8A5E);
  static const record = Color(0xFFD2553A);
  static const amberTint = Color(0xFFFBEBC8);
  static const amberInk = Color(0xFF7A4D00);
  static const blueTint = Color(0xFFE1ECF6);
  static const blueInk = Color(0xFF1E4E79);
  static const blue = Color(0xFF2C79B0);
  static const purpleTint = Color(0xFFEDE6F6);
  static const purpleInk = Color(0xFF5B3A86);
  static const redTint = Color(0xFFF9E1DC);
  static const redInk = Color(0xFF9A2F1A);

  // rocks
  static const stone = Color(0xFFB9B4A9);
  static const slate = Color(0xFF9AA3AA);
  static const clay = Color(0xFFC99A78);
  static const sand = Color(0xFFD9C7A4);

  static const side = 20.0;
  static const cardRadius = 20.0;
  static const buttonRadius = 18.0;
  static const buttonHeight = 56.0;

  static const display = 'NunitoSans';
  static const body = 'NunitoSans';
}

ThemeData fieldScanTheme() {
  const scheme = ColorScheme(
    brightness: Brightness.light,
    primary: Fs.moss,
    onPrimary: Colors.white,
    primaryContainer: Fs.mossTint,
    onPrimaryContainer: Fs.mossInk,
    secondary: Fs.record,
    onSecondary: Colors.white,
    secondaryContainer: Fs.redTint,
    onSecondaryContainer: Fs.redInk,
    tertiary: Fs.blue,
    onTertiary: Colors.white,
    error: Color(0xFFB3261E),
    onError: Colors.white,
    surface: Fs.ground,
    onSurface: Fs.ink,
    onSurfaceVariant: Fs.muted,
    surfaceContainerLowest: Fs.card,
    surfaceContainerLow: Fs.card,
    surfaceContainer: Fs.quiet,
    surfaceContainerHigh: Fs.well,
    surfaceContainerHighest: Color(0xFFE3E5DE),
    outline: Fs.lineStrong,
    outlineVariant: Fs.line,
  );

  final base = Typography.blackMountainView.apply(fontFamily: Fs.body, bodyColor: Fs.ink, displayColor: Fs.ink);
  TextStyle d(TextStyle? s, double size) => (s ?? const TextStyle()).copyWith(fontFamily: Fs.display, fontWeight: FontWeight.w800, fontSize: size, height: 1.15, letterSpacing: -0.3);
  final text = base.copyWith(
    displaySmall: d(base.displaySmall, 34),
    headlineMedium: d(base.headlineMedium, 30),
    headlineSmall: d(base.headlineSmall, 24),
    titleLarge: d(base.titleLarge, 20),
    titleMedium: d(base.titleMedium, 17),
    titleSmall: base.titleSmall?.copyWith(fontWeight: FontWeight.w700, fontSize: 14),
    labelLarge: base.labelLarge?.copyWith(fontWeight: FontWeight.w700, fontSize: 13, color: Fs.ink2),
    bodyLarge: base.bodyLarge?.copyWith(fontSize: 16),
    bodyMedium: base.bodyMedium?.copyWith(fontSize: 14, height: 1.4),
    bodySmall: base.bodySmall?.copyWith(fontSize: 12, height: 1.4, color: Fs.faint),
  );

  final btnShape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(Fs.buttonRadius));
  const btnText = TextStyle(fontFamily: Fs.body, fontWeight: FontWeight.w700, fontSize: 16);
  const fieldBorder = OutlineInputBorder(borderRadius: BorderRadius.all(Radius.circular(16)), borderSide: BorderSide(color: Fs.line, width: 1.5));

  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    fontFamily: Fs.body,
    textTheme: text,
    scaffoldBackgroundColor: Fs.ground,
    splashFactory: InkSparkle.splashFactory,
    appBarTheme: AppBarTheme(
      backgroundColor: Fs.ground,
      surfaceTintColor: Colors.transparent,
      foregroundColor: Fs.ink,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: text.titleMedium?.copyWith(fontSize: 18),
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      color: Fs.card,
      surfaceTintColor: Colors.transparent,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Fs.cardRadius)),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(64, Fs.buttonHeight),
        shape: btnShape,
        textStyle: btnText,
        backgroundColor: Fs.moss,
        foregroundColor: Colors.white,
        disabledBackgroundColor: Fs.line,
        disabledForegroundColor: Fs.faint,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(64, Fs.buttonHeight),
        shape: btnShape,
        textStyle: btnText,
        backgroundColor: Fs.card,
        foregroundColor: Fs.ink,
        side: const BorderSide(color: Fs.lineStrong, width: 1.5),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(foregroundColor: Fs.moss, textStyle: const TextStyle(fontFamily: Fs.body, fontWeight: FontWeight.w700, fontSize: 14)),
    ),
    iconButtonTheme: IconButtonThemeData(style: IconButton.styleFrom(foregroundColor: Fs.ink)),
    inputDecorationTheme: const InputDecorationTheme(
      filled: true,
      fillColor: Fs.card,
      contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      border: fieldBorder,
      enabledBorder: fieldBorder,
      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.all(Radius.circular(16)), borderSide: BorderSide(color: Fs.moss, width: 2)),
      floatingLabelBehavior: FloatingLabelBehavior.always,
      labelStyle: TextStyle(fontWeight: FontWeight.w700, color: Fs.ink2),
      hintStyle: TextStyle(color: Color(0xFF8A8E84)),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        minimumSize: const WidgetStatePropertyAll(Size(0, 46)),
        backgroundColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? Fs.card : Fs.well),
        foregroundColor: const WidgetStatePropertyAll(Fs.ink),
        side: const WidgetStatePropertyAll(BorderSide(color: Fs.well, width: 4)),
        shape: WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: BorderRadius.circular(16))),
        textStyle: WidgetStateProperty.resolveWith((s) => TextStyle(
            fontFamily: Fs.body, fontSize: 14, fontWeight: s.contains(WidgetState.selected) ? FontWeight.w800 : FontWeight.w600)),
      ),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: const WidgetStatePropertyAll(Colors.white),
      trackColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? Fs.moss : Fs.line),
      trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
    ),
    checkboxTheme: CheckboxThemeData(
      fillColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? Fs.moss : Fs.card),
      side: const BorderSide(color: Color(0xFF9A9F93), width: 2),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(7)),
    ),
    listTileTheme: const ListTileThemeData(
      titleTextStyle: TextStyle(fontFamily: Fs.body, fontSize: 15, fontWeight: FontWeight.w700, color: Fs.ink),
      subtitleTextStyle: TextStyle(fontFamily: Fs.body, fontSize: 12, height: 1.4, color: Fs.faint),
    ),
    dividerTheme: const DividerThemeData(color: Fs.line, thickness: 1, space: 1),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: Fs.card,
      surfaceTintColor: Colors.transparent,
      indicatorColor: Fs.mossTint,
      elevation: 0,
      height: 60,
      labelPadding: const EdgeInsets.only(top: 2),
      iconTheme: WidgetStateProperty.resolveWith((s) => IconThemeData(color: s.contains(WidgetState.selected) ? Fs.moss : const Color(0xFF6B6F66))),
      labelTextStyle: WidgetStateProperty.resolveWith((s) => TextStyle(
          fontFamily: Fs.body,
          fontSize: 12,
          fontWeight: s.contains(WidgetState.selected) ? FontWeight.w800 : FontWeight.w600,
          color: s.contains(WidgetState.selected) ? Fs.moss : const Color(0xFF6B6F66))),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: Fs.ink,
      contentTextStyle: const TextStyle(fontFamily: Fs.body, color: Colors.white, fontSize: 14),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: Fs.card,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      titleTextStyle: text.titleLarge,
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(color: Fs.moss),
    sliderTheme: const SliderThemeData(activeTrackColor: Fs.moss, thumbColor: Fs.moss, inactiveTrackColor: Fs.line),
    dropdownMenuTheme: const DropdownMenuThemeData(menuStyle: MenuStyle(backgroundColor: WidgetStatePropertyAll(Fs.card))),
    popupMenuTheme: PopupMenuThemeData(color: Fs.card, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16))),
  );
}

/// Big title block used at the top of every tab: same height and type everywhere.
class ScreenHeader extends StatelessWidget {
  final String title;
  final Widget? subtitle;
  final Widget? trailing;
  const ScreenHeader({super.key, required this.title, this.subtitle, this.trailing});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(Fs.side, 16, Fs.side, 12),
      child: SizedBox(
        height: 76,
        child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
          Expanded(
            child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: t.headlineMedium, maxLines: 1, overflow: TextOverflow.ellipsis),
              if (subtitle != null) ...[
                const SizedBox(height: 4),
                DefaultTextStyle.merge(style: const TextStyle(fontSize: 13, color: Fs.muted), child: subtitle!),
              ],
            ]),
          ),
          ?trailing,
        ]),
      ),
    );
  }
}

/// Small dot + text line under a title ("iPhone 17 Pro · LiDAR ready").
class StatusLine extends StatelessWidget {
  final String text;
  final Color dot;
  const StatusLine(this.text, {super.key, this.dot = Fs.live});
  @override
  Widget build(BuildContext context) => Row(children: [
        Container(width: 8, height: 8, decoration: BoxDecoration(color: dot, shape: BoxShape.circle)),
        const SizedBox(width: 6),
        Flexible(child: Text(text, overflow: TextOverflow.ellipsis)),
      ]);
}

class SectionLabel extends StatelessWidget {
  final String text;
  const SectionLabel(this.text, {super.key});
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(text, style: Theme.of(context).textTheme.labelLarge),
      );
}

/// White rounded card with the standard padding.
class FsCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final Color color;
  final Color? border;
  final VoidCallback? onTap;
  const FsCard({super.key, required this.child, this.padding = const EdgeInsets.all(16), this.color = Fs.card, this.border, this.onTap});

  @override
  Widget build(BuildContext context) {
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(Fs.cardRadius),
      side: border == null ? BorderSide.none : BorderSide(color: border!, width: 2),
    );
    return Material(
      color: color,
      shape: shape,
      clipBehavior: Clip.antiAlias,
      child: InkWell(onTap: onTap, child: Padding(padding: padding, child: child)),
    );
  }
}

enum TagKind { neutral, good, info, warn, special, bad }

class Tag extends StatelessWidget {
  final String text;
  final TagKind kind;
  const Tag(this.text, {super.key, this.kind = TagKind.neutral});

  @override
  Widget build(BuildContext context) {
    final (bg, fg) = switch (kind) {
      TagKind.neutral => (Fs.quiet, Fs.ink2),
      TagKind.good => (Fs.mossTint, Fs.mossInk),
      TagKind.info => (Fs.blueTint, Fs.blueInk),
      TagKind.warn => (Fs.amberTint, Fs.amberInk),
      TagKind.special => (Fs.purpleTint, Fs.purpleInk),
      TagKind.bad => (Fs.redTint, Fs.redInk),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(8)),
      child: Text(text, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: fg)),
    );
  }
}

/// Tinted message box (info / warning / error) instead of raw coloured text.
class Note extends StatelessWidget {
  final Widget child;
  final TagKind kind;
  final Widget? leading;
  const Note({super.key, required this.child, this.kind = TagKind.neutral, this.leading});

  @override
  Widget build(BuildContext context) {
    final (bg, fg) = switch (kind) {
      TagKind.neutral => (Fs.card, Fs.ink2),
      TagKind.good => (Fs.mossTint, Fs.mossInk),
      TagKind.info => (Fs.blueTint, Fs.blueInk),
      TagKind.warn => (Fs.amberTint, Fs.amberInk),
      TagKind.special => (Fs.purpleTint, Fs.purpleInk),
      TagKind.bad => (Fs.redTint, Fs.redInk),
    };
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(Fs.cardRadius)),
      child: Row(children: [
        if (leading != null) ...[leading!, const SizedBox(width: 12)],
        Expanded(child: DefaultTextStyle.merge(style: TextStyle(color: fg, fontSize: 13, height: 1.45), child: child)),
      ]),
    );
  }
}

/// Label + description + switch in a white card.
class SwitchCard extends StatelessWidget {
  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool>? onChanged;
  const SwitchCard({super.key, required this.title, this.subtitle, required this.value, this.onChanged});

  @override
  Widget build(BuildContext context) => FsCard(
        padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
        onTap: onChanged == null ? null : () => onChanged!(!value),
        child: Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
              if (subtitle != null) ...[const SizedBox(height: 2), Text(subtitle!, style: Theme.of(context).textTheme.bodySmall)],
            ]),
          ),
          const SizedBox(width: 12),
          Switch(value: value, onChanged: onChanged),
        ]),
      );
}

/// Big number + small caption, used for live stats and measurement results.
class StatTile extends StatelessWidget {
  final String value;
  final String label;
  const StatTile(this.value, this.label, {super.key});
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(color: Fs.card, borderRadius: BorderRadius.circular(Fs.cardRadius)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Text(value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontFamily: Fs.display, fontWeight: FontWeight.w800, fontSize: 20, fontFeatures: [FontFeature.tabularFigures()])),
          Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, color: Fs.muted)),
        ]),
      );
}

/// Round white back button + title, for pushed screens.
PreferredSizeWidget subBar(BuildContext context, String title, {List<Widget> actions = const []}) => AppBar(
      toolbarHeight: 64,
      leadingWidth: Fs.side + 44 + 4,
      leading: Navigator.of(context).canPop()
          ? Padding(
              padding: const EdgeInsets.only(left: Fs.side - 4),
              child: Center(child: RoundIconButton(icon: Icons.arrow_back_ios_new_rounded, tooltip: 'Back', onPressed: () => Navigator.of(context).maybePop())),
            )
          : null,
      title: Text(title),
      actions: [...actions, const SizedBox(width: Fs.side - 8)],
    );

class RoundIconButton extends StatelessWidget {
  final IconData icon;
  final String? tooltip;
  final VoidCallback? onPressed;
  final double size;
  final Color color;
  const RoundIconButton({super.key, required this.icon, this.tooltip, this.onPressed, this.size = 44, this.color = Fs.card});

  @override
  Widget build(BuildContext context) => SizedBox(
        width: size,
        height: size,
        child: IconButton(
          tooltip: tooltip,
          onPressed: onPressed,
          iconSize: 18,
          style: IconButton.styleFrom(backgroundColor: color, foregroundColor: Fs.ink, padding: EdgeInsets.zero),
          icon: Icon(icon),
        ),
      );
}

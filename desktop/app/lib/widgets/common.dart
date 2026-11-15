import 'package:flutter/material.dart';

import '../service/api.dart';
import '../service/models.dart';

const accentSeed = Color(0xFF0F6E6A); // deep teal: the single accent

ThemeData buildTheme(Brightness b) {
  final dark = b == Brightness.dark;
  final scheme = ColorScheme.fromSeed(
    seedColor: accentSeed,
    brightness: b,
    dynamicSchemeVariant: DynamicSchemeVariant.neutral,
  ).copyWith(
    primary: dark ? const Color(0xFF6CCFC6) : const Color(0xFF0F6E6A),
    onPrimary: dark ? const Color(0xFF00201E) : Colors.white,
    surface: dark ? const Color(0xFF121314) : const Color(0xFFFAFAF9),
    onSurface: dark ? const Color(0xFFE7E6E3) : const Color(0xFF1A1B1C),
  );
  return ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    scaffoldBackgroundColor: scheme.surface,
    visualDensity: VisualDensity.standard,
    cardTheme: CardThemeData(
      elevation: 0,
      margin: EdgeInsets.zero,
      color: dark ? const Color(0xFF1B1C1E) : Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: scheme.outlineVariant),
      ),
    ),
    dividerTheme: DividerThemeData(color: scheme.outlineVariant, space: 1, thickness: 1),
    inputDecorationTheme: const InputDecorationTheme(border: OutlineInputBorder(), isDense: true),
    textTheme: const TextTheme().apply(bodyColor: scheme.onSurface, displayColor: scheme.onSurface),
  );
}

/// Warning colour used for honesty banners and quality warnings (not the accent).
Color warnColor(BuildContext c) =>
    Theme.of(c).brightness == Brightness.dark ? const Color(0xFFFFB74D) : const Color(0xFF9A4A00);

class SectionCard extends StatelessWidget {
  const SectionCard({super.key, required this.title, required this.child, this.trailing, this.padding = const EdgeInsets.all(16)});
  final String title;
  final Widget child;
  final Widget? trailing;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Card(
      child: Padding(
        padding: padding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(children: [
              Expanded(child: Text(title, style: t.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600))),
              ?trailing,
            ]),
            const SizedBox(height: 12),
            child,
          ],
        ),
      ),
    );
  }
}

/// Label/value row with tabular figures.
class KV extends StatelessWidget {
  const KV(this.label, this.value, {super.key, this.labelWidth = 170, this.valueStyle});
  final String label;
  final String value;
  final double labelWidth;
  final TextStyle? valueStyle;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(
          width: labelWidth,
          child: Text(label, style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
        ),
        Expanded(
          child: SelectableText(
            value,
            style: (valueStyle ?? t.textTheme.bodyMedium)?.copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
          ),
        ),
      ]),
    );
  }
}

class OriginChip extends StatelessWidget {
  const OriginChip(this.origin, {super.key});
  final String? origin;

  @override
  Widget build(BuildContext context) {
    final k = originKind(origin);
    final t = Theme.of(context);
    final warn = k == OriginKind.synthetic || k == OriginKind.replay || k == OriginKind.unknownImport;
    final fg = warn ? warnColor(context) : (k == OriginKind.realD435 || k == OriginKind.iphone ? t.colorScheme.primary : t.colorScheme.onSurfaceVariant);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        border: Border.all(color: fg.withValues(alpha: 0.7)),
        borderRadius: BorderRadius.circular(4),
        color: fg.withValues(alpha: 0.08),
      ),
      child: Text(originBadge(origin),
          style: t.textTheme.labelSmall?.copyWith(color: fg, fontWeight: FontWeight.w700, letterSpacing: 0.4)),
    );
  }
}

class StatusChip extends StatelessWidget {
  const StatusChip(this.status, {super.key});
  final String status;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final bad = status == 'incomplete' || status == 'error' || status == 'unreadable';
    final busy = status == 'recording' || status == 'processing';
    final fg = bad ? t.colorScheme.error : (busy ? warnColor(context) : t.colorScheme.onSurfaceVariant);
    return Text(status, style: t.textTheme.labelMedium?.copyWith(color: fg, fontWeight: bad ? FontWeight.w700 : FontWeight.w500));
  }
}

class PageHeader extends StatelessWidget {
  const PageHeader(this.title, {super.key, this.subtitle, this.actions = const []});
  final String title;
  final String? subtitle;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 12),
      child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: t.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w600)),
            if (subtitle != null) ...[
              const SizedBox(height: 4),
              Text(subtitle!, style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant)),
            ],
          ]),
        ),
        ...actions,
      ]),
    );
  }
}

class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.icon, required this.title, this.body, this.action});
  final IconData icon;
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
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 40, color: t.colorScheme.onSurfaceVariant),
            const SizedBox(height: 12),
            Text(title, textAlign: TextAlign.center, style: t.textTheme.titleMedium),
            if (body != null) ...[
              const SizedBox(height: 8),
              Text(body!, textAlign: TextAlign.center, style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant)),
            ],
            if (action != null) ...[const SizedBox(height: 16), action!],
          ]),
        ),
      ),
    );
  }
}

/// Inline error box that shows the service's message verbatim.
class ErrorBox extends StatelessWidget {
  const ErrorBox(this.message, {super.key});
  final String message;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: t.colorScheme.errorContainer.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: t.colorScheme.error.withValues(alpha: 0.5)),
      ),
      child: SelectableText(message, style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onErrorContainer)),
    );
  }
}

void showSnack(BuildContext context, String msg, {bool error = false}) {
  final t = Theme.of(context);
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
    content: Text(msg),
    backgroundColor: error ? t.colorScheme.error : null,
    behavior: SnackBarBehavior.floating,
    width: 560,
  ));
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

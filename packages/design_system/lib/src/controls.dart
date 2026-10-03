import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';

import 'focus.dart';
import 'tokens.dart';

/// A modal dialog exposed as role `dialog` whose accessible name is its
/// title (Material's AlertDialog is an unnamed `alertdialog`; 1.6 finding 5).
class ChurchDialog extends StatelessWidget {
  const ChurchDialog({
    super.key,
    required this.title,
    required this.content,
    required this.actions,
  });

  final String title;
  final Widget content;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final c = ChurchColors.of(context);
    return Dialog(
      semanticsRole: SemanticsRole.none,
      backgroundColor: c.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(ChurchGeometry.modalRadius),
      ),
      child: Semantics(
        container: true,
        role: SemanticsRole.dialog,
        scopesRoute: true,
        namesRoute: true,
        explicitChildNodes: true,
        label: title,
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            maxWidth: ChurchGeometry.modalWidth,
          ),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Semantics(
                  header: true,
                  child: Text(
                    title,
                    style: ChurchType.modalTitle.copyWith(color: c.ink),
                  ),
                ),
                const SizedBox(height: 16),
                Flexible(child: SingleChildScrollView(child: content)),
                const SizedBox(height: 16),
                Wrap(
                  alignment: WrapAlignment.end,
                  spacing: 8,
                  runSpacing: 8,
                  children: actions,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// One option of a [RadioSegments] control.
class SegmentOption<T> {
  const SegmentOption(this.value, this.label, {this.icon});
  final T value;
  final String label;
  final IconData? icon;
}

/// A segmented toggle exposed as a named radio group: each option is its own
/// focus stop with its own ring and a checked state. Replaces
/// `SegmentedButton`, which hides its selection from the browser and rings
/// the whole control (1.6 finding 2).
class RadioSegments<T> extends StatelessWidget {
  const RadioSegments({
    super.key,
    required this.label,
    required this.options,
    required this.selected,
    required this.onChanged,
  });

  final String label;
  final List<SegmentOption<T>> options;
  final T selected;
  final ValueChanged<T>? onChanged;

  @override
  Widget build(BuildContext context) {
    final c = ChurchColors.of(context);
    return Semantics(
      role: SemanticsRole.radioGroup,
      label: label,
      explicitChildNodes: true,
      child: Wrap(
        spacing: 4,
        runSpacing: 4,
        children: [
          for (final o in options)
            FocusRing(
              child: OutlinedButton.icon(
                key: ValueKey('segment-${o.label}'),
                onPressed: onChanged == null ? null : () => onChanged!(o.value),
                style: OutlinedButton.styleFrom(
                  backgroundColor: o.value == selected ? c.blueBg : null,
                  foregroundColor: c.link,
                  side: BorderSide(
                    color: o.value == selected ? c.link : c.muted,
                    width: o.value == selected ? 2 : 1,
                  ),
                ),
                icon: Icon(
                  o.value == selected
                      ? Icons.check
                      : (o.icon ?? Icons.circle_outlined),
                ),
                label: Semantics(
                  inMutuallyExclusiveGroup: true,
                  checked: o.value == selected,
                  child: Text(o.label),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// A navigation destination exposed as role `tab` in a named tab list.
///
/// Custom rather than `TabBar`/`NavigationBar`: their only focus cue is a faint
/// overlay that fails a 3:1 focus-change check on navy (1.6 finding 3). Built
/// on [InkWell], whose `canRequestFocus` drives the browser tab order
/// (1.6 finding 1).
class NavItem extends StatelessWidget {
  const NavItem({
    super.key,
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
    this.onDark = false,
    this.vertical = false,
    this.autofocus = false,
  });

  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  /// True on the navy sidebar/top bar: white text and a white ring.
  final bool onDark;

  /// Icon above label (mobile bottom tabs) instead of beside it.
  final bool vertical;

  /// Takes focus when first built: after a keyboard navigation rebuilds the
  /// shell, focus returns to the selected destination instead of the page
  /// body.
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    final c = ChurchColors.of(context);
    final fg = onDark
        ? (selected ? c.onSidebar : c.onSidebarMuted)
        : (selected ? c.link : c.muted);
    final highlight = onDark
        ? (selected ? c.onSidebar.withValues(alpha: 0.16) : Colors.transparent)
        : (selected ? c.blueBg : Colors.transparent);
    final text = Text(
      label,
      textAlign: vertical ? TextAlign.center : TextAlign.start,
      style: TextStyle(
        color: fg,
        fontSize: vertical ? 12 : 15,
        fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
      ),
    );
    final content = vertical
        ? Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: fg),
              const SizedBox(height: 2),
              text,
            ],
          )
        : Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: fg),
              const SizedBox(width: 12),
              Flexible(child: text),
            ],
          );
    return Semantics(
      role: SemanticsRole.tab,
      selected: selected,
      container: true,
      child: FocusRing(
        color: onDark ? c.onSidebar : null,
        radius: 12,
        child: Material(
          color: highlight,
          borderRadius: BorderRadius.circular(10),
          child: InkWell(
            onTap: onTap,
            autofocus: autofocus,
            borderRadius: BorderRadius.circular(10),
            focusColor: Colors.transparent,
            child: Container(
              constraints: const BoxConstraints(
                minHeight: ChurchGeometry.minTarget,
                minWidth: ChurchGeometry.minTarget,
              ),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              alignment: vertical ? Alignment.center : null,
              child: content,
            ),
          ),
        ),
      ),
    );
  }
}

/// Status tone; every status also carries a text label (never colour alone).
enum StatusTone { neutral, info, success, warning, danger }

/// A status chip: tone colours plus a mandatory readable label.
class StatusLabel extends StatelessWidget {
  const StatusLabel({super.key, required this.label, required this.tone});

  final String label;
  final StatusTone tone;

  @override
  Widget build(BuildContext context) {
    final (bg, fg) = toneColors(ChurchColors.of(context), tone);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(label, style: ChurchType.chip.copyWith(color: fg)),
    );
  }
}

/// Background and foreground tokens for a [StatusTone].
(Color, Color) toneColors(ChurchColors c, StatusTone tone) => switch (tone) {
  StatusTone.neutral => (c.grayBg, c.muted),
  StatusTone.info => (c.blueBg, c.blueFg),
  StatusTone.success => (c.greenBg, c.greenFg),
  StatusTone.warning => (c.amberBg, c.amberFg),
  StatusTone.danger => (c.redBg, c.redFg),
};

/// One action button of a [RequestStateBanner].
class BannerAction {
  const BannerAction(
    this.label,
    this.onPressed, {
    this.key,
    this.primary = false,
  });
  final String label;
  final VoidCallback? onPressed;
  final Key? key;
  final bool primary;
}

/// A persistent request-state panel (pending, conflict, unavailable, unknown
/// outcome, account changed…). Text states what is known; a toast is never
/// the only record of an outcome.
class RequestStateBanner extends StatelessWidget {
  const RequestStateBanner({
    super.key,
    required this.tone,
    required this.title,
    required this.message,
    this.icon,
    this.busy = false,
    this.actions = const [],
  });

  final StatusTone tone;
  final String title;
  final String message;
  final IconData? icon;

  /// Shows a progress indicator instead of [icon] (pending).
  final bool busy;
  final List<BannerAction> actions;

  @override
  Widget build(BuildContext context) {
    final c = ChurchColors.of(context);
    final (bg, fg) = toneColors(c, tone);
    return Semantics(
      container: true,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(ChurchGeometry.cardPadding),
        decoration: BoxDecoration(
          color: bg,
          border: Border.all(color: fg),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (busy)
                  SizedBox.square(
                    dimension: 22,
                    child: CircularProgressIndicator(strokeWidth: 3, color: fg),
                  )
                else
                  ExcludeSemantics(
                    child: Icon(icon ?? Icons.info_outline, color: fg),
                  ),
                const SizedBox(width: 10),
                Expanded(
                  child: Semantics(
                    header: true,
                    child: Text(
                      title,
                      style: ChurchType.cardTitle.copyWith(color: fg),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(message, style: ChurchType.body.copyWith(color: c.ink)),
            if (actions.isNotEmpty) ...[
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final a in actions)
                    FocusRing(
                      child: a.primary
                          ? FilledButton(
                              key: a.key,
                              onPressed: a.onPressed,
                              child: Text(a.label),
                            )
                          : OutlinedButton(
                              key: a.key,
                              onPressed: a.onPressed,
                              style: OutlinedButton.styleFrom(
                                foregroundColor: c.ink,
                                side: BorderSide(color: fg),
                              ),
                              child: Text(a.label),
                            ),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

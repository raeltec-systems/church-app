import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';

import 'focus.dart';
import 'staff.dart';
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
    // Handoff: a grey track (radius 14, padding 4) with equal segments; the
    // chosen one is a white segment with a soft shadow.
    return Semantics(
      role: SemanticsRole.radioGroup,
      label: label,
      explicitChildNodes: true,
      child: Container(
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          color: c.surface2,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          children: [
            // Each segment's share follows its label, so a long label
            // ("Needs a response (2)") is not squeezed to the width of a
            // short one ("Past (1)").
            for (final o in options)
              Expanded(
                flex: o.label.length < 6 ? 6 : o.label.length,
                child: FocusRing(
                  radius: 13,
                  child: TextButton(
                    key: ValueKey('segment-${o.label}'),
                    onPressed: onChanged == null
                        ? null
                        : () => onChanged!(o.value),
                    style: TextButton.styleFrom(
                      minimumSize: const Size(0, ChurchGeometry.minTarget),
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      backgroundColor: o.value == selected
                          ? c.surface
                          : Colors.transparent,
                      foregroundColor: o.value == selected ? c.ink : c.muted,
                      shadowColor: const Color(0x1F000000),
                      elevation: o.value == selected ? 1.5 : 0,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(11),
                      ),
                      textStyle: const TextStyle(
                        fontFamily: ChurchFonts.body,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    child: Semantics(
                      inMutuallyExclusiveGroup: true,
                      checked: o.value == selected,
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(o.label, maxLines: 1),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
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
    this.compact = false,
    this.fill = false,
    this.badge,
    this.badgeLabel,
  });

  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  /// Staff rail: the icon alone, the label in a tooltip and in semantics.
  final bool compact;

  /// Takes the full width it is given (the staff sidebar), so a [badge]
  /// sits at the row's end.
  final bool fill;

  /// A count of work waiting behind this destination (staff sidebar); null
  /// or zero shows nothing.
  final int? badge;

  /// What [badge] counts, read after the label ("3 waiting").
  final String? badgeLabel;

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
        ? (selected
              ? ChurchStaffChrome.onSidebar
              : ChurchStaffChrome.onSidebarMuted)
        : (selected ? c.link : c.muted);
    final highlight = onDark
        ? (selected ? ChurchStaffChrome.activeItem : Colors.transparent)
        : Colors.transparent;
    final count = badge ?? 0;
    final text = Text(
      label,
      textAlign: vertical ? TextAlign.center : TextAlign.start,
      style: (vertical ? ChurchType.tabLabel : ChurchType.staffBody).copyWith(
        color: fg,
        fontWeight: onDark
            ? FontWeight.w600
            : (selected ? FontWeight.w700 : FontWeight.w500),
      ),
    );
    if (compact) {
      return _tab(
        semanticsLabel: count > 0 ? '$label, ${badgeLabel ?? count}' : label,
        highlight: highlight,
        padding: EdgeInsets.zero,
        alignment: Alignment.center,
        child: Tooltip(
          message: label,
          excludeFromSemantics: true,
          child: SizedBox.square(
            dimension: ChurchGeometry.minTarget,
            child: Stack(
              alignment: Alignment.center,
              children: [
                Icon(icon, color: fg, size: 22),
                if (count > 0)
                  Positioned(
                    top: 7,
                    right: 7,
                    child: StaffNavBadge(count: count, dot: true),
                  ),
              ],
            ),
          ),
        ),
      );
    }
    final content = vertical
        ? Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: fg, size: 24),
              const SizedBox(height: 3),
              text,
            ],
          )
        : Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: fg, size: onDark ? 20 : null),
              SizedBox(width: onDark ? 10 : 12),
              if (fill) Expanded(child: text) else Flexible(child: text),
              if (count > 0) ...[
                const SizedBox(width: 8),
                StaffNavBadge(count: count),
              ],
            ],
          );
    return _tab(
      semanticsLabel: count > 0 ? '$label, ${badgeLabel ?? count}' : null,
      highlight: highlight,
      padding: EdgeInsets.symmetric(horizontal: onDark ? 10 : 12, vertical: 6),
      alignment: vertical ? Alignment.center : null,
      child: content,
    );
  }

  Widget _tab({
    required String? semanticsLabel,
    required Color highlight,
    required EdgeInsets padding,
    required AlignmentGeometry? alignment,
    required Widget child,
  }) {
    return Semantics(
      role: SemanticsRole.tab,
      selected: selected,
      container: true,
      label: semanticsLabel,
      child: FocusRing(
        color: onDark ? ChurchStaffChrome.onSidebar : null,
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
              padding: padding,
              alignment: alignment,
              child: semanticsLabel == null
                  ? child
                  : ExcludeSemantics(child: child),
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
    this.focusNode,
  });

  /// When given, the banner is a programmatic focus target named by [title]
  /// (not a Tab stop), so a screen can move focus to the state it reports
  /// instead of losing it when the triggering control is disabled or removed.
  final FocusNode? focusNode;

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
    final node = focusNode;
    final panel = Container(
      width: double.infinity,
      padding: const EdgeInsets.all(ChurchGeometry.cardPadding),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(14),
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
                  child: Icon(icon ?? Icons.info_outline, color: fg, size: 20),
                ),
              const SizedBox(width: 8),
              Expanded(
                child: Semantics(
                  // A focusable banner is itself named by its title; it is
                  // not also a heading (that would hide the name).
                  header: node == null,
                  excludeSemantics: node != null,
                  child: Text(
                    title,
                    style: ChurchType.body.copyWith(
                      color: fg,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            message,
            style: ChurchType.secondary.copyWith(color: c.ink, height: 1.4),
          ),
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
                        : TextButton(
                            key: a.key,
                            onPressed: a.onPressed,
                            style: TextButton.styleFrom(foregroundColor: fg),
                            child: Text(a.label),
                          ),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
    if (node == null) return Semantics(container: true, child: panel);
    return Semantics(
      container: true,
      label: title,
      child: Focus(
        focusNode: node,
        skipTraversal: true,
        child: ListenableBuilder(
          listenable: node,
          builder: (context, _) => FocusHighlightBuilder(
            builder: (context, keyboardMode) => Container(
              padding: const EdgeInsets.all(ChurchGeometry.focusRingWidth + 1),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: keyboardMode && node.hasPrimaryFocus
                      ? c.focus
                      : Colors.transparent,
                  width: ChurchGeometry.focusRingWidth,
                ),
              ),
              child: panel,
            ),
          ),
        ),
      ),
    );
  }
}

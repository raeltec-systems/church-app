import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';

import 'components.dart';
import 'controls.dart';
import 'focus.dart';
import 'tokens.dart';

/// True on staff web (the [ChurchLayout.staff] theme), false on the phone.
bool isStaffLayout(BuildContext context) =>
    identical(ChurchLayout.of(context), ChurchLayout.staff);

/// A card's radius for the current client: 12 on staff web, 18 on the
/// phone.
double churchCardRadiusOf(BuildContext context) => isStaffLayout(context)
    ? ChurchGeometry.staffCardRadius
    : ChurchGeometry.mobileCardRadius;

/// The header style of a staff table: 12 px grey, sentence case, regular
/// weight (never tracked capitals).
TextStyle staffTableHeadStyle(BuildContext context) => ChurchType.secondary
    .copyWith(color: ChurchColors.of(context).muted, fontSize: 12, height: 1.3);

/// A figure in a table cell or a summary: tabular, so digits line up.
TextStyle staffFigureStyle(BuildContext context) =>
    ChurchType.figures.copyWith(color: ChurchColors.of(context).ink);

/// One block of a staff screen: a white card (radius 12 on staff web) whose
/// first row is the block's title (17/600 Outfit) with an optional quiet
/// figure or action on the right, split from the body by a 1 px line. The
/// body sets its own padding ([bodyPadding]), so a table inside runs to the
/// card's edges.
class StaffSection extends StatelessWidget {
  const StaffSection({
    super.key,
    required this.title,
    required this.child,
    this.trailing,
    this.subtitle,
    this.bodyPadding = const EdgeInsets.fromLTRB(20, 16, 20, 18),
  });

  final String title;

  /// One grey line under the title (scope, privacy, the count it holds).
  final String? subtitle;

  /// A quiet figure ("3 of 5") or one action, on the title row's right.
  final Widget? trailing;
  final Widget child;
  final EdgeInsetsGeometry bodyPadding;

  @override
  Widget build(BuildContext context) {
    final c = ChurchColors.of(context);
    return ChurchCard(
      radius: churchCardRadiusOf(context),
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.fromLTRB(20, 14, 16, 12),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: c.line)),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Semantics(
                        header: true,
                        child: Text(
                          title,
                          style: ChurchType.cardTitle.copyWith(
                            color: c.ink,
                            fontSize: 17,
                          ),
                        ),
                      ),
                      if (subtitle case final s?)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(
                            s,
                            style: ChurchType.secondary.copyWith(
                              color: c.muted,
                              fontSize: 13,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                if (trailing case final t?) ...[const SizedBox(width: 12), t],
              ],
            ),
          ),
          Padding(padding: bodyPadding, child: child),
        ],
      ),
    );
  }
}

/// One column of a staff table: its header, its share of the row
/// ([flex]) or a fixed [width], and whether it holds figures (then the
/// header and the cells are right-aligned on one edge).
class StaffColumn {
  const StaffColumn(
    this.label, {
    this.flex = 1,
    this.width,
    this.numeric = false,
  });

  /// Sentence case; empty for an action column.
  final String label;
  final int flex;
  final double? width;
  final bool numeric;
}

/// Lays [cells] out on [columns]: fixed widths stay fixed, the rest share
/// what is left by their flex; numeric cells end on the column's right edge.
class StaffColumnsRow extends StatelessWidget {
  const StaffColumnsRow({
    super.key,
    required this.columns,
    required this.cells,
    this.gap = 16,
    this.crossAxisAlignment = CrossAxisAlignment.center,
  });

  final List<StaffColumn> columns;

  /// One per column, in the same order.
  final List<Widget> cells;
  final double gap;
  final CrossAxisAlignment crossAxisAlignment;

  @override
  Widget build(BuildContext context) {
    assert(columns.length == cells.length, 'one cell per column');
    final children = <Widget>[];
    for (var i = 0; i < columns.length; i++) {
      final col = columns[i];
      if (i > 0) children.add(SizedBox(width: gap));
      final cell = Align(
        alignment: col.numeric
            ? AlignmentDirectional.centerEnd
            : AlignmentDirectional.centerStart,
        widthFactor: 1,
        child: cells[i],
      );
      final w = col.width;
      children.add(
        w != null
            ? SizedBox(width: w, child: cell)
            : Expanded(flex: col.flex, child: cell),
      );
    }
    return Row(crossAxisAlignment: crossAxisAlignment, children: children);
  }
}

/// A staff table's header row: 12 px grey sentence-case labels, no fill
/// band, and the table's strongest rule under it.
class StaffTableHeader extends StatelessWidget {
  const StaffTableHeader({
    super.key,
    required this.columns,
    this.padding = const EdgeInsets.fromLTRB(20, 12, 20, 10),
    this.gap = 16,
  });

  final List<StaffColumn> columns;
  final EdgeInsetsGeometry padding;
  final double gap;

  @override
  Widget build(BuildContext context) {
    final c = ChurchColors.of(context);
    final head = staffTableHeadStyle(context);
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: c.line)),
      ),
      // The rows name their own fields to assistive technology.
      child: ExcludeSemantics(
        child: StaffColumnsRow(
          columns: columns,
          gap: gap,
          cells: [
            for (final col in columns)
              Text(
                col.label,
                style: head,
                textAlign: col.numeric ? TextAlign.end : TextAlign.start,
              ),
          ],
        ),
      ),
    );
  }
}

/// One row of a staff table: a 1 px rule above it (except the first), a
/// minimum height of 52, and, when it drives a detail pane, the selected
/// fill (the surface tint, never the accent) and a tap target.
class StaffTableRow extends StatelessWidget {
  const StaffTableRow({
    super.key,
    required this.child,
    this.divider = true,
    this.selected = false,
    this.onTap,
    this.semanticLabel,
    this.padding = const EdgeInsets.fromLTRB(20, 10, 20, 10),
    this.minHeight = 52,
  });

  /// Usually a [StaffColumnsRow] on wide screens and a two-line row on
  /// narrow ones.
  final Widget child;
  final bool divider;
  final bool selected;
  final VoidCallback? onTap;

  /// What the row opens, read when [onTap] is set ("Grace Banda, open
  /// details").
  final String? semanticLabel;
  final EdgeInsetsGeometry padding;
  final double minHeight;

  @override
  Widget build(BuildContext context) {
    final c = ChurchColors.of(context);
    final body = Container(
      constraints: BoxConstraints(minHeight: minHeight),
      padding: padding,
      alignment: AlignmentDirectional.centerStart,
      child: child,
    );
    final framed = DecoratedBox(
      decoration: BoxDecoration(
        color: selected ? c.surface2 : null,
        border: divider ? Border(top: BorderSide(color: c.line)) : null,
      ),
      child: onTap == null
          ? body
          : Semantics(
              button: true,
              selected: selected,
              label: semanticLabel,
              child: InkWell(onTap: onTap, child: body),
            ),
    );
    return framed;
  }
}

/// A staff table's frame: a white card with a 1 px line (radius 12 on
/// staff web) and no inner padding, so rules run to its edges.
class StaffTableFrame extends StatelessWidget {
  const StaffTableFrame({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => ChurchCard(
    radius: churchCardRadiusOf(context),
    padding: EdgeInsets.zero,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    ),
  );
}

/// One option of [StaffFilterPills].
class StaffFilterOption<T> {
  const StaffFilterOption(this.value, this.label, {this.count, this.key});

  final T value;
  final String label;

  /// How many rows this filter keeps, computed from the rows in view; null
  /// shows no figure.
  final int? count;
  final Key? key;
}

/// The handoff's filter pills with counts ("All 12", "Unfilled 1"): the
/// chosen pill filled in the brand navy with white text, the others white
/// with a 1 px line and their count in grey. One row that scrolls sideways
/// below 600 px; a named radio group to assistive technology, each pill its
/// own focus stop.
class StaffFilterPills<T> extends StatelessWidget {
  const StaffFilterPills({
    super.key,
    required this.label,
    required this.options,
    required this.selected,
    required this.onChanged,
  });

  final String label;
  final List<StaffFilterOption<T>> options;
  final T selected;
  final ValueChanged<T>? onChanged;

  @override
  Widget build(BuildContext context) {
    final pills = [
      for (final o in options)
        _StaffPill(
          pillKey: o.key,
          label: o.label,
          count: o.count,
          selected: o.value == selected,
          onTap: onChanged == null ? null : () => onChanged!(o.value),
        ),
    ];
    return Semantics(
      role: SemanticsRole.radioGroup,
      label: label,
      explicitChildNodes: true,
      child: LayoutBuilder(
        builder: (context, box) => box.maxWidth < 600
            ? SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(children: pills),
              )
            : Wrap(children: pills),
      ),
    );
  }
}

class _StaffPill extends StatelessWidget {
  const _StaffPill({
    this.pillKey,
    required this.label,
    required this.count,
    required this.selected,
    required this.onTap,
  });

  /// On the pill's tap target, so a test or a caller finds the pill itself.
  final Key? pillKey;
  final String label;
  final int? count;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = ChurchColors.of(context);
    final fg = selected ? c.onPrimary : c.ink;
    final countFg = selected ? c.onPrimary : c.muted;
    return FocusRing(
      radius: 24,
      child: Semantics(
        container: true,
        inMutuallyExclusiveGroup: true,
        checked: selected,
        button: true,
        enabled: onTap != null,
        label: count == null ? label : '$label, $count',
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            key: pillKey,
            onTap: onTap,
            customBorder: const StadiumBorder(),
            child: ExcludeSemantics(
              child: SizedBox(
                height: ChurchGeometry.minTarget,
                child: Center(
                  widthFactor: 1,
                  child: Container(
                    height: 36,
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    decoration: BoxDecoration(
                      color: selected ? c.primary : c.surface,
                      border: Border.all(color: selected ? c.primary : c.line),
                      borderRadius: BorderRadius.circular(18),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          label,
                          style: ChurchType.chip.copyWith(
                            color: fg,
                            fontSize: 14,
                          ),
                        ),
                        if (count case final n?) ...[
                          const SizedBox(width: 6),
                          Text(
                            '$n',
                            style: ChurchType.figures.copyWith(
                              color: countFg,
                              fontWeight: selected
                                  ? FontWeight.w600
                                  : FontWeight.w500,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A progress bar at the true ratio ([value] of [max]), fully rounded, 8 px
/// tall. On the navy summary ([onNavy]) the track is translucent white and
/// the fill the handoff's light blue (#4FB0FF); on white the track is the
/// surface tint and the fill the brand navy. A zero has no stub.
class StaffProgressBar extends StatelessWidget {
  const StaffProgressBar({
    super.key,
    required this.value,
    required this.max,
    this.onNavy = false,
    this.height = 8,
    this.color,
  });

  final num value;
  final num max;
  final bool onNavy;
  final double height;

  /// Overrides the fill (an amber bar under a short attendance, say).
  final Color? color;

  /// The handoff's progress fill on the navy summary.
  static const navyFill = Color(0xFF4FB0FF);

  @override
  Widget build(BuildContext context) {
    final c = ChurchColors.of(context);
    final ratio = max <= 0 ? 0.0 : (value / max).clamp(0, 1).toDouble();
    final track = onNavy ? Colors.white.withValues(alpha: 0.18) : c.surface2;
    final fill = color ?? (onNavy ? navyFill : c.brand);
    return ExcludeSemantics(
      child: ClipRRect(
        borderRadius: BorderRadius.circular(height),
        child: SizedBox(
          height: height,
          child: Stack(
            children: [
              Positioned.fill(child: ColoredBox(color: track)),
              if (ratio > 0)
                FractionallySizedBox(
                  widthFactor: ratio,
                  heightFactor: 1,
                  alignment: AlignmentDirectional.centerStart,
                  child: ColoredBox(color: fill),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The handoff's navy summary that leads a queue (Leader coverage "Sun 4
/// Oct · Morning service — 6 of 10 confirmed"): a quiet first line with its
/// meta on the right, the headline figure in white Outfit, then the
/// progress bar at its true ratio. Flat (no seal, no ornament).
class StaffSummaryBand extends StatelessWidget {
  const StaffSummaryBand({
    super.key,
    required this.title,
    required this.headline,
    this.meta,
    this.value,
    this.max,
    this.footer,
    this.semanticLabel,
  });

  /// The scope ("Sun 4 Oct · Morning service", "Next 7 days").
  final String title;

  /// The answer ("6 of 10 confirmed").
  final String headline;

  /// Right of [title] ("Report 08:30").
  final String? meta;

  /// The progress bar's value and maximum; no bar when either is null.
  final num? value;
  final num? max;

  /// One more grey line under the bar ("3 unfilled · 1 overdue").
  final String? footer;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    const quiet = Color(0xD9FFFFFF);
    return Semantics(
      container: true,
      label: semanticLabel,
      child: HeroCard(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    title,
                    style: ChurchType.staffBody.copyWith(
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                if (meta case final m?)
                  Text(m, style: ChurchType.figures.copyWith(color: quiet)),
              ],
            ),
            const SizedBox(height: 6),
            Semantics(
              header: true,
              child: Text(
                headline,
                style: const TextStyle(
                  fontFamily: ChurchFonts.heading,
                  fontSize: 26,
                  fontWeight: FontWeight.w700,
                  height: 1.15,
                  color: Colors.white,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
            ),
            if (value != null && max != null) ...[
              const SizedBox(height: 12),
              StaffProgressBar(value: value!, max: max!, onNavy: true),
            ],
            if (footer case final f?) ...[
              const SizedBox(height: 10),
              Text(f, style: ChurchType.secondary.copyWith(color: quiet)),
            ],
          ],
        ),
      ),
    );
  }
}

/// Asks before a destructive or hard-to-undo action. The [title] names the
/// action and the person or object ("Deactivate Grace Banda's
/// membership?"); [message] says what happens, in words. Resolves true only
/// when [confirmLabel] is pressed. The confirm button is keyed
/// `confirm-action` and Cancel `confirm-cancel`; [extra] (a reason picker)
/// sits under the message and [canConfirm] keeps the button disabled until
/// it is answered.
Future<bool> confirmStaffAction(
  BuildContext context, {
  required String title,
  required String message,
  required String confirmLabel,
  bool destructive = true,
  Widget Function(BuildContext context, StateSetter setState)? extra,
  bool Function()? canConfirm,
}) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) {
        final c = ChurchColors.of(context);
        final allowed = canConfirm?.call() ?? true;
        return ChurchDialog(
          title: title,
          content: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                message,
                style: ChurchType.staffBody.copyWith(
                  color: c.ink,
                  height: 1.45,
                ),
              ),
              if (extra != null) ...[
                const SizedBox(height: 12),
                extra(context, setState),
              ],
            ],
          ),
          actions: [
            FocusRing(
              child: OutlinedButton(
                key: const Key('confirm-cancel'),
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('Cancel'),
              ),
            ),
            FocusRing(
              child: FilledButton(
                key: const Key('confirm-action'),
                style: destructive
                    ? FilledButton.styleFrom(
                        backgroundColor: c.redFg,
                        foregroundColor: Colors.white,
                      )
                    : null,
                onPressed: allowed
                    ? () => Navigator.of(context).pop(true)
                    : null,
                child: Text(confirmLabel),
              ),
            ),
          ],
        );
      },
    ),
  );
  return ok ?? false;
}

/// The handoff's staff page header: a white band with a 1 px bottom line,
/// padding 18/32, the page title (24/700 Outfit, brand navy), one muted line
/// about the data under it, and the screen's main action on the right. It
/// sits above the page's scrolling body, so it stays in view (sticky).
class StaffPageHeader extends StatelessWidget {
  const StaffPageHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.actions = const [],
  });

  final String title;

  /// One sentence about the data or the scope ("Church-wide, this week"),
  /// never about the interface.
  final String? subtitle;

  /// The screen's main action first in reading order, then quieter ones.
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final c = ChurchColors.of(context);
    final narrow = MediaQuery.sizeOf(context).width < 600;
    final heading = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Semantics(
          header: true,
          child: Text(
            title,
            key: const Key('page-title'),
            style: ChurchType.staffPageTitle.copyWith(
              color: c.brand,
              height: 1.2,
            ),
          ),
        ),
        if (subtitle case final s?)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              s,
              key: const Key('page-subtitle'),
              style: ChurchType.secondary.copyWith(color: c.muted),
            ),
          ),
      ],
    );
    final tools = Wrap(
      alignment: WrapAlignment.end,
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: actions,
    );
    return Material(
      color: c.surface,
      child: Container(
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: c.line)),
        ),
        padding: EdgeInsets.symmetric(
          horizontal: narrow ? 16 : 32,
          vertical: 14,
        ),
        constraints: const BoxConstraints(minHeight: 72),
        alignment: AlignmentDirectional.centerStart,
        child: actions.isEmpty
            ? heading
            : narrow
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [heading, const SizedBox(height: 10), tools],
              )
            : Row(
                children: [
                  Expanded(flex: 3, child: heading),
                  const SizedBox(width: 16),
                  Flexible(
                    flex: 2,
                    child: Align(
                      alignment: AlignmentDirectional.centerEnd,
                      child: tools,
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}

/// A page's frame: on staff web the [StaffPageHeader] above the body (it
/// stays put while the body scrolls); on the phone the app bar with its back
/// chevron, unchanged.
class ChurchPageScaffold extends StatelessWidget {
  const ChurchPageScaffold({
    super.key,
    required this.title,
    required this.body,
    this.subtitle,
    this.actions = const [],
    this.bottomNavigationBar,
    this.appBarTitle,
  });

  final String title;

  /// Staff web only (the phone's bar has room for the title alone).
  final String? subtitle;

  /// Header actions (staff) or app bar actions (phone).
  final List<Widget> actions;
  final Widget body;
  final Widget? bottomNavigationBar;

  /// The phone bar's title when it is not plain text (for example a title
  /// with its own key).
  final Widget? appBarTitle;

  @override
  Widget build(BuildContext context) {
    if (!identical(ChurchLayout.of(context), ChurchLayout.staff)) {
      return Scaffold(
        appBar: AppBar(title: appBarTitle ?? Text(title), actions: actions),
        bottomNavigationBar: bottomNavigationBar,
        body: body,
      );
    }
    return Scaffold(
      bottomNavigationBar: bottomNavigationBar,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          StaffPageHeader(title: title, subtitle: subtitle, actions: actions),
          Expanded(child: body),
        ],
      ),
    );
  }
}

/// The quiet Reload control of a staff header: an outlined button with the
/// given [key]; [onPressed] is null while a read or command is under way.
Widget staffReloadButton(Key key, VoidCallback? onPressed) => FocusRing(
  child: OutlinedButton.icon(
    key: key,
    onPressed: onPressed,
    icon: const Icon(Icons.refresh, size: 18),
    label: const Text('Reload'),
  ),
);

/// A count on a staff navigation item: the handoff's blue pill (white 12/700
/// figures) on the navy sidebar, or a small dot when the sidebar is a rail.
class StaffNavBadge extends StatelessWidget {
  const StaffNavBadge({super.key, required this.count, this.dot = false});

  final int count;
  final bool dot;

  @override
  Widget build(BuildContext context) {
    if (dot) {
      return Container(
        width: 9,
        height: 9,
        decoration: BoxDecoration(
          color: ChurchColors.light.accent,
          shape: BoxShape.circle,
          border: Border.all(color: ChurchStaffChrome.sidebar, width: 1.5),
        ),
      );
    }
    return Container(
      constraints: const BoxConstraints(minWidth: 22),
      height: 20,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      decoration: BoxDecoration(
        color: ChurchColors.light.accent,
        borderRadius: BorderRadius.circular(10),
      ),
      alignment: Alignment.center,
      child: Text(
        count > 99 ? '99+' : '$count',
        style: const TextStyle(
          fontFamily: ChurchFonts.body,
          fontSize: 12,
          fontWeight: FontWeight.w700,
          color: Colors.white,
          fontFeatures: [FontFeature.tabularFigures()],
        ),
      ),
    );
  }
}

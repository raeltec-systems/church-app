import 'package:flutter/material.dart';

import 'focus.dart';
import 'tokens.dart';

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

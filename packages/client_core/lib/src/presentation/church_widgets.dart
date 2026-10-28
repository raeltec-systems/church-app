import 'package:church_design_system/church_design_system.dart';
import 'package:flutter/material.dart';

import '../domain/church_time.dart';

const _weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
const _months = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

/// The handoff's date badge for an instant in church time (Africa/Lusaka).
class ChurchDateBadge extends StatelessWidget {
  const ChurchDateBadge({
    super.key,
    required this.at,
    this.tone = DateBadgeTone.surface,
  });

  final DateTime at;
  final DateBadgeTone tone;

  @override
  Widget build(BuildContext context) {
    final w = ChurchTime.wall(at);
    return DateBadge(
      weekday: _weekdays[w.weekday - 1],
      day: '${w.day}',
      month: _months[w.month - 1],
      tone: tone,
    );
  }
}

/// A member tab's page: no app bar, the 24/700 title with a refresh button
/// beside it, pull to refresh, 16 px gutters.
/// Pushed detail screens keep their app bar and back chevron.
class MemberTabPage extends StatelessWidget {
  const MemberTabPage({
    super.key,
    required this.title,
    required this.reloadKey,
    required this.onReload,
    required this.children,
    this.bottom,
  });

  final String title;
  final Key reloadKey;

  /// Null while a read or command is under way.
  final VoidCallback? onReload;
  final List<Widget> children;
  final Widget? bottom;

  @override
  Widget build(BuildContext context) {
    final c = ChurchColors.of(context);
    final layout = ChurchLayout.of(context);
    return Scaffold(
      bottomNavigationBar: bottom,
      body: SafeArea(
        bottom: false,
        child: RefreshIndicator(
          onRefresh: () async => onReload?.call(),
          child: SingleChildScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
            child: Center(
              child: ConstrainedBox(
                constraints: BoxConstraints(maxWidth: layout.contentMaxWidth),
                child: DefaultTextStyle.merge(
                  style: layout.body.copyWith(color: c.ink),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Semantics(
                              header: true,
                              child: Text(
                                title,
                                style: ChurchType.mobileScreenTitle.copyWith(
                                  color: c.ink,
                                ),
                              ),
                            ),
                          ),
                          FocusRing(
                            radius: 22,
                            child: IconButton(
                              key: reloadKey,
                              tooltip: 'Reload',
                              onPressed: onReload,
                              icon: const Icon(Icons.refresh),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      ...children,
                    ],
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

/// Two initials for an avatar: first letters of the first and last words,
/// skipping the "SYNTHETIC" marker of test records.
String avatarInitials(String name) {
  final words = name
      .split(RegExp(r'\s+'))
      .where((w) => w.isNotEmpty && w != 'SYNTHETIC')
      .toList();
  if (words.isEmpty) return '?';
  final first = words.first.characters.first;
  final last = words.length > 1 ? words.last.characters.first : '';
  return (first + last).toUpperCase();
}

/// A round avatar with initials (the handoff's person rows).
class InitialsAvatar extends StatelessWidget {
  const InitialsAvatar({super.key, required this.name, this.size = 40});

  final String name;
  final double size;

  @override
  Widget build(BuildContext context) {
    final c = ChurchColors.of(context);
    return ExcludeSemantics(
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(color: c.surface2, shape: BoxShape.circle),
        alignment: Alignment.center,
        child: Text(
          avatarInitials(name),
          style: TextStyle(
            fontFamily: ChurchFonts.body,
            fontWeight: FontWeight.w700,
            fontSize: size * 0.35,
            color: c.ink,
          ),
        ),
      ),
    );
  }
}

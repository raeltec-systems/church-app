import 'package:church_design_system/church_design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../application/announcement_controllers.dart';
import '../domain/access_grants.dart';
import '../domain/content_announcements.dart';
import 'calendar_screens.dart'
    show churchLongWhen, churchShortWhen, staleNotice;

// Story 6.13: announcements for everyone, signed in or not, from the
// published projection only: Home's Announcements section (the pinned ones),
// the list (pinned first, then the newest) and one announcement. Both
// screens are pushed screens with their own back bar, on the phone and (from
// an inbox item) on staff web. Every time is church time (Africa/Lusaka). A
// failed read never looks like "no announcements".

/// The public announcement routes.
abstract final class AnnouncementPaths {
  /// Every published announcement, pinned first.
  static const list = '/announcements';

  /// One published announcement (the notice's deep link).
  static String detail(String announcementId) =>
      '/announcements/$announcementId';
}

/// One line of the body for a list row: whitespace collapsed.
String announcementExcerpt(String body) =>
    body.replaceAll(RegExp(r'\s+'), ' ').trim();

/// A public announcement read that did not answer, said plainly: it is not
/// "no announcements".
Widget _readProblem<T>(AccessRead<T> r, {required String key}) => switch (r) {
  AccessReadOk() => const SizedBox.shrink(),
  AccessReadFailed(:final unreachable) => RequestStateBanner(
    key: Key('$key-failed'),
    tone: StatusTone.danger,
    icon: unreachable ? Icons.cloud_off_outlined : Icons.error_outline,
    title: unreachable ? 'No connection' : 'Couldn\'t load',
    message: unreachable
        ? 'We couldn\'t reach the church server. This does not mean there are '
              'no announcements: nothing is shown until it answers.'
        : 'The server answered in an unexpected way. Try again later.',
  ),
  AccessReadDenied() => RequestStateBanner(
    key: Key('$key-unavailable'),
    tone: StatusTone.warning,
    icon: Icons.lock_outline,
    title: 'Not available yet',
    message: 'Announcements are not available from this app right now.',
  ),
};

/// One announcement row: the title, then when it was posted and the start
/// of its text on one line. Used by the list and by Home.
class AnnouncementRow extends StatelessWidget {
  const AnnouncementRow({
    super.key,
    required this.announcement,
    required this.onTap,
  });

  final PublicAnnouncement announcement;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = ChurchColors.of(context);
    final a = announcement;
    final when = churchShortWhen(a.publishedAt);
    return Semantics(
      button: true,
      label: [a.title, if (a.pinned) 'pinned', 'posted $when'].join(', '),
      excludeSemantics: true,
      child: FocusRing(
        radius: 4,
        child: InkWell(
          key: Key('announcement-row-${a.announcementId}'),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        a.title,
                        style: ChurchType.itemTitle.copyWith(color: c.ink),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '$when · ${announcementExcerpt(a.body)}',
                        key: Key('announcement-line-${a.announcementId}'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: ChurchType.secondary.copyWith(color: c.muted),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 6),
                ExcludeSemantics(
                  child: Icon(Icons.chevron_right, size: 20, color: c.muted),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Rows split by 1 px lines inside one card.
class _RowsCard extends StatelessWidget {
  const _RowsCard({super.key, required this.rows});

  final List<Widget> rows;

  @override
  Widget build(BuildContext context) {
    final c = ChurchColors.of(context);
    return ChurchCard(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final (i, r) in rows.indexed) ...[
            if (i > 0) Divider(height: 1, indent: 14, color: c.line),
            r,
          ],
        ],
      ),
    );
  }
}

/// A pushed public screen: its own back bar with Reload, pull to refresh,
/// 16 px gutters.
class _PublicPage extends StatelessWidget {
  const _PublicPage({
    required this.title,
    required this.reloadKey,
    required this.onReload,
    required this.children,
  });

  final String title;
  final Key reloadKey;
  final VoidCallback? onReload;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final layout = ChurchLayout.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        actions: [
          FocusRing(
            radius: 22,
            child: IconButton(
              key: reloadKey,
              tooltip: 'Reload',
              onPressed: onReload,
              icon: const Icon(Icons.refresh),
            ),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: () async => onReload?.call(),
          child: SingleChildScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
            child: Center(
              child: ConstrainedBox(
                constraints: BoxConstraints(maxWidth: layout.contentMaxWidth),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: children,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Story 6.13: every published announcement, the pinned ones first, then the
/// most recently posted; each row opens the announcement.
class AnnouncementsScreen extends ConsumerStatefulWidget {
  const AnnouncementsScreen({super.key});

  @override
  ConsumerState<AnnouncementsScreen> createState() =>
      _AnnouncementsScreenState();
}

class _AnnouncementsScreenState extends ConsumerState<AnnouncementsScreen> {
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onResume: _reload);
    // Opening the list asks the server again (Home may have read it before).
    if (ref.read(publicAnnouncementsProvider).result != null) {
      Future.microtask(_reload);
    }
  }

  void _reload() {
    if (mounted && !ref.read(publicAnnouncementsProvider).loading) {
      ref.read(publicAnnouncementsProvider.notifier).reload();
    }
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = ChurchColors.of(context);
    final s = ref.watch(publicAnnouncementsProvider);
    final children = <Widget>[];
    Widget rows(List<PublicAnnouncement> list, String key) => _RowsCard(
      key: Key(key),
      rows: [
        for (final a in list)
          AnnouncementRow(
            announcement: a,
            onTap: () =>
                context.push(AnnouncementPaths.detail(a.announcementId)),
          ),
      ],
    );
    switch (s.result) {
      case null:
        children.add(
          const RequestStateBanner(
            key: Key('announcements-loading'),
            tone: StatusTone.info,
            busy: true,
            title: 'Loading announcements…',
            message: 'Asking the church server.',
          ),
        );
      case AccessReadOk(:final value):
        if (staleNotice(
              s,
              what: 'list of announcements',
              key: 'announcements-stale',
            )
            case final n?) {
          children.addAll([n, const SizedBox(height: 16)]);
        }
        final pinned = value.pinned;
        final others = value.others;
        if (value.announcements.isEmpty) {
          children.add(
            ChurchCard(
              key: const Key('announcements-empty'),
              child: Text(
                'No announcements right now. Church announcements appear here '
                'once the church posts them.',
                style: ChurchType.body.copyWith(color: c.muted),
              ),
            ),
          );
        }
        if (pinned.isNotEmpty) {
          children.addAll([
            const SectionHeader(
              key: Key('announcements-pinned-header'),
              title: 'Pinned',
            ),
            const SizedBox(height: 10),
            rows(pinned, 'announcements-pinned'),
          ]);
        }
        if (others.isNotEmpty) {
          if (pinned.isNotEmpty) children.add(const SizedBox(height: 22));
          children.addAll([
            const SectionHeader(
              key: Key('announcements-latest-header'),
              title: 'Latest',
            ),
            const SizedBox(height: 10),
            rows(others, 'announcements-latest'),
          ]);
        }
        if (value.truncated) {
          children.addAll([
            const SizedBox(height: 16),
            Text(
              'Only the most recent announcements are listed here.',
              key: const Key('announcements-truncated'),
              style: ChurchType.secondary.copyWith(color: c.muted),
            ),
          ]);
        }
      case final AccessRead<PublicAnnouncements> problem:
        children.add(_readProblem(problem, key: 'announcements'));
    }
    return _PublicPage(
      title: 'Announcements',
      reloadKey: const Key('announcements-reload'),
      onReload: s.loading ? null : _reload,
      children: children,
    );
  }
}

/// Story 6.13: one published announcement (opened from Home, the list or an
/// inbox notice). A withdrawn one says so instead of showing an old copy;
/// returning to the app asks the server again.
class AnnouncementDetailScreen extends ConsumerStatefulWidget {
  const AnnouncementDetailScreen({super.key, required this.announcementId});

  final String announcementId;

  @override
  ConsumerState<AnnouncementDetailScreen> createState() =>
      _AnnouncementDetailScreenState();
}

class _AnnouncementDetailScreenState
    extends ConsumerState<AnnouncementDetailScreen> {
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onResume: _reload);
  }

  void _reload() {
    final p = publicAnnouncementProvider(widget.announcementId);
    if (mounted && !ref.read(p).loading) ref.read(p.notifier).reload();
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = ChurchColors.of(context);
    final announcementId = widget.announcementId;
    final s = ref.watch(publicAnnouncementProvider(announcementId));
    final ctl = ref.read(publicAnnouncementProvider(announcementId).notifier);
    final children = <Widget>[];
    switch (s.result) {
      case null:
        children.add(
          const RequestStateBanner(
            key: Key('announcement-loading'),
            tone: StatusTone.info,
            busy: true,
            title: 'Loading the announcement…',
            message: 'Asking the church server.',
          ),
        );
      case AccessReadOk(value: PublicAnnouncementRead(:final announcement)):
        if (staleNotice(s, what: 'announcement', key: 'announcement-stale')
            case final n?) {
          children.addAll([n, const SizedBox(height: 16)]);
        }
        if (announcement == null) {
          children.add(
            RequestStateBanner(
              key: const Key('announcement-gone'),
              tone: StatusTone.neutral,
              title: 'No longer published',
              message: 'This announcement is no longer published.',
              actions: [
                BannerAction(
                  'See all announcements',
                  () => context.pushReplacement(AnnouncementPaths.list),
                  key: const Key('announcement-gone-list'),
                  primary: true,
                ),
              ],
            ),
          );
        } else {
          children.addAll([
            Semantics(
              header: true,
              child: Text(
                announcement.title,
                key: const Key('announcement-title'),
                style: ChurchType.mobileScreenTitle.copyWith(color: c.ink),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'Posted ${churchLongWhen(announcement.publishedAt)}',
              key: const Key('announcement-posted'),
              style: ChurchType.secondary.copyWith(color: c.muted),
            ),
            const SizedBox(height: 16),
            Text(
              announcement.body,
              key: const Key('announcement-body'),
              style: ChurchType.body.copyWith(color: c.ink),
            ),
          ]);
        }
      case final AccessRead<PublicAnnouncementRead> problem:
        children.add(_readProblem(problem, key: 'announcement'));
    }
    return _PublicPage(
      title: 'Announcement',
      reloadKey: const Key('announcement-reload'),
      onReload: s.loading ? null : ctl.reload,
      children: children,
    );
  }
}

/// Story 6.13 (Home, everyone): the pinned announcements, at most three, each
/// opening the announcement, and See all. Coming back to Home or to the app
/// asks the server again, so a withdrawn announcement leaves Home. Entry 14
/// finishes Home around it.
class HomeAnnouncementsSection extends ConsumerStatefulWidget {
  const HomeAnnouncementsSection({super.key});

  static const shown = 3;

  @override
  ConsumerState<HomeAnnouncementsSection> createState() =>
      _HomeAnnouncementsSectionState();
}

class _HomeAnnouncementsSectionState
    extends ConsumerState<HomeAnnouncementsSection> {
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onResume: _reload);
    // Revisiting Home asks the server again (the list may have read it before).
    if (ref.read(publicAnnouncementsProvider).result != null) {
      Future.microtask(_reload);
    }
  }

  void _reload() {
    if (mounted && !ref.read(publicAnnouncementsProvider).loading) {
      ref.read(publicAnnouncementsProvider.notifier).reload();
    }
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = ChurchColors.of(context);
    final s = ref.watch(publicAnnouncementsProvider);
    Widget line(String key, String text, {bool ink = false}) => Text(
      text,
      key: Key(key),
      style: ink
          ? ChurchType.body.copyWith(color: c.ink)
          : ChurchType.body.copyWith(color: c.muted),
    );
    final Widget body = switch (s.result) {
      null => Text(
        'Loading announcements…',
        key: const Key('home-announcements-loading'),
        style: ChurchType.secondary.copyWith(color: c.muted),
      ),
      AccessReadOk(:final value) when value.announcements.isEmpty => line(
        'home-announcements-none',
        'No announcements right now.',
      ),
      AccessReadOk(:final value) when value.pinned.isEmpty => line(
        'home-announcements-no-pinned',
        'No pinned announcements.',
      ),
      AccessReadOk(:final value) => _RowsCard(
        key: const Key('home-announcements-list'),
        rows: [
          for (final a in value.pinned.take(HomeAnnouncementsSection.shown))
            AnnouncementRow(
              announcement: a,
              onTap: () =>
                  context.push(AnnouncementPaths.detail(a.announcementId)),
            ),
        ],
      ),
      AccessReadFailed(:final unreachable) => line(
        'home-announcements-failed',
        unreachable
            ? 'No connection: we couldn\'t reach the church server, so no '
                  'announcements are shown. This does not mean there are none.'
            : 'Couldn\'t load the announcements. Try again later.',
        ink: true,
      ),
      AccessReadDenied() => line(
        'home-announcements-unavailable',
        'Announcements are not available from this app right now.',
        ink: true,
      ),
    };
    return Column(
      key: const Key('home-announcements'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionHeader(
          title: 'Announcements',
          action: FocusRing(
            child: TextButton(
              key: const Key('home-announcements-all'),
              onPressed: () => context.push(AnnouncementPaths.list),
              child: const Text('See all'),
            ),
          ),
        ),
        const SizedBox(height: 8),
        body,
      ],
    );
  }
}

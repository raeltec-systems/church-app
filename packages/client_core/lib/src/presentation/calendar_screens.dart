import 'package:church_design_system/church_design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../application/access_controllers.dart' show myAccessProvider;
import '../application/content_controllers.dart';
import '../application/duties_controllers.dart' show dutyCalendarExportProvider;
import '../application/providers.dart'
    show accountProvider, bannerRepositoryProvider;
import '../domain/access_grants.dart';
import '../domain/church_time.dart';
import '../domain/content_events.dart';
import '../domain/duty_calendar.dart' show CalendarHandoff, ShareOrigin;
import '../domain/event_calendar.dart';
import 'calendar_overlay_widgets.dart';
import 'church_widgets.dart';
import 'shell_routing.dart' show ClientPaths;

// Story 6.1 (mobile): the public Calendar tab and an event's detail, read by
// everyone, signed in or not, from the published projection only. Every time
// is church time (Africa/Lusaka), whatever zone the phone uses. A failed read
// never looks like an empty calendar. Story 6.11 adds the poster (a 16:9
// thumbnail in the list, in full on the detail), Add to calendar and the
// RSVP: counts for everyone, an answer for approved members.

/// The public calendar routes.
abstract final class CalendarPaths {
  /// The Calendar tab.
  static const calendar = '/calendar';

  /// One published event.
  static String event(String eventId) => '/calendar/events/$eventId';
}

const _weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
const _weekdaysLong = [
  'Monday',
  'Tuesday',
  'Wednesday',
  'Thursday',
  'Friday',
  'Saturday',
  'Sunday',
];
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
const _monthsLong = [
  'January',
  'February',
  'March',
  'April',
  'May',
  'June',
  'July',
  'August',
  'September',
  'October',
  'November',
  'December',
];

/// "09:00" in church time.
String churchClockText(DateTime at) => ChurchTime.timeText(at);

/// "Sat 10 Oct 09:00" in church time.
String churchShortWhen(DateTime at) {
  final w = ChurchTime.wall(at);
  return '${_weekdays[w.weekday - 1]} ${w.day} ${_months[w.month - 1]} '
      '${churchClockText(at)}';
}

/// "Saturday 10 October 2026, 09:00" in church time.
String churchLongWhen(DateTime at) {
  final w = ChurchTime.wall(at);
  return '${_weekdaysLong[w.weekday - 1]} ${w.day} ${_monthsLong[w.month - 1]} '
      '${w.year}, ${churchClockText(at)}';
}

/// "October 2026": the church month of [at].
String churchMonthTitle(DateTime at) {
  final w = ChurchTime.wall(at);
  return '${_monthsLong[w.month - 1]} ${w.year}';
}

/// When an event runs, in one line: `09:00–12:00` on one day, both endpoints
/// (`Sat 10 Oct 09:00 – Sun 11 Oct 12:00`) when it runs over several.
String eventSpanText(DateTime startsAt, DateTime endsAt) =>
    churchSameDay(startsAt, endsAt)
    ? '${churchClockText(startsAt)}–${churchClockText(endsAt)}'
    : '${churchShortWhen(startsAt)} – ${churchShortWhen(endsAt)}';

/// The notice over data kept from an earlier answer when the latest refresh
/// failed: what is shown and from when. Null when the data is current.
Widget? staleNotice<T>(
  PublicReadState<T> s, {
  required String what,
  required String key,
}) {
  final failed = s.refreshFailed;
  final at = s.asOf;
  if (failed == null || at == null) return null;
  final clock =
      '${at.toLocal().hour.toString().padLeft(2, '0')}:'
      '${at.toLocal().minute.toString().padLeft(2, '0')}';
  if (s.offlineSnapshot) {
    return RequestStateBanner(
      key: Key(key),
      tone: StatusTone.warning,
      icon: Icons.cloud_off_outlined,
      title: 'Offline · saved at $clock',
      message: 'Showing the saved $what. It may have changed since.',
    );
  }
  return RequestStateBanner(
    key: Key(key),
    tone: StatusTone.warning,
    icon: failed.unreachable ? Icons.cloud_off_outlined : Icons.error_outline,
    title: 'Couldn\'t refresh',
    message: failed.unreachable
        ? 'No connection. This is the $what as it was at $clock; it may have '
              'changed since.'
        : 'The server answered in an unexpected way. This is the $what as it '
              'was at $clock.',
  );
}

/// The last successful local save, or the explicit offline state when a
/// public list is being shown from that snapshot.
Widget? publicSavedStatus<T>(
  BuildContext context,
  PublicReadState<T> state, {
  required String what,
  required String key,
}) {
  if (state.offlineSnapshot) return staleNotice(state, what: what, key: key);
  final at = state.savedAt;
  if (at == null) return null;
  final local = at.toLocal();
  final clock =
      '${local.hour.toString().padLeft(2, '0')}:'
      '${local.minute.toString().padLeft(2, '0')}';
  return Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Text(
      'Saved for offline at $clock',
      key: Key('$key-saved'),
      style: ChurchType.secondary.copyWith(
        color: ChurchColors.of(context).muted,
      ),
    ),
  );
}

/// One event row: the start's date badge, the title and when · where. Used
/// by the Calendar and by Home's Coming up.
class PublicEventRow extends StatelessWidget {
  const PublicEventRow({super.key, required this.event, required this.onTap});

  final PublicEvent event;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = ChurchColors.of(context);
    final e = event;
    final when = eventSpanText(e.startsAt, e.endsAt);
    // The date badge is hidden from screen readers with the rest of the row,
    // so the spoken label carries the date as well as the times.
    final spoken = churchSameDay(e.startsAt, e.endsAt)
        ? '${churchShortWhen(e.startsAt)} to ${churchClockText(e.endsAt)}'
        : '${churchShortWhen(e.startsAt)} to ${churchShortWhen(e.endsAt)}';
    return Semantics(
      button: true,
      label: '${e.title}, $spoken, ${e.location}',
      excludeSemantics: true,
      child: FocusRing(
        radius: 4,
        child: InkWell(
          key: Key('event-row-${e.eventId}'),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ChurchDateBadge(at: e.startsAt),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        e.title,
                        style: ChurchType.itemTitle.copyWith(color: c.ink),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '$when · ${e.location}',
                        key: Key('event-when-${e.eventId}'),
                        style: ChurchType.secondary.copyWith(color: c.muted),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 6),
                // Story 6.11: the poster as a 16:9 thumbnail (decorative in
                // the row: its text alternative is read on the detail).
                if (e.poster case final poster?)
                  _EventRowThumb(eventId: e.eventId, poster: poster)
                else
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

/// Story 6.11: an event poster as a small 16:9 thumbnail. A poster that does
/// not load leaves a plain tile, never a broken image.
class _EventRowThumb extends ConsumerWidget {
  const _EventRowThumb({required this.eventId, required this.poster});

  final String eventId;
  final PublicEventPoster poster;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = ChurchColors.of(context);
    final url = ref
        .read(bannerRepositoryProvider)
        .publicFileUrl(poster.image.path);
    return ExcludeSemantics(
      child: ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: SizedBox(
          width: 64,
          height: 36,
          child: ColoredBox(
            color: c.surface2,
            child: Image.network(
              url.toString(),
              key: Key('event-thumb-$eventId'),
              fit: BoxFit.cover,
              excludeFromSemantics: true,
              errorBuilder: (context, _, _) => const SizedBox.expand(),
            ),
          ),
        ),
      ),
    );
  }
}

/// Rows split by 1 px lines inside one card (a group, not boxed cards).
class EventRowsCard extends StatelessWidget {
  const EventRowsCard({super.key, required this.rows});

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
            if (i > 0) Divider(height: 1, indent: 76, color: c.line),
            r,
          ],
        ],
      ),
    );
  }
}

/// A public read that did not answer, said plainly: it is not an empty
/// calendar.
Widget publicReadProblem<T>(AccessRead<T> r, {required String what}) =>
    switch (r) {
      AccessReadOk() => const SizedBox.shrink(),
      AccessReadFailed(:final unreachable) => RequestStateBanner(
        key: const Key('calendar-failed'),
        tone: StatusTone.danger,
        icon: unreachable ? Icons.cloud_off_outlined : Icons.error_outline,
        title: unreachable ? 'No connection' : 'Couldn\'t load',
        message: unreachable
            ? 'We couldn\'t reach the church server. This is not an empty '
                  '$what: nothing is shown until it answers.'
            : 'The server answered in an unexpected way. Try again later.',
      ),
      AccessReadDenied() => RequestStateBanner(
        key: const Key('calendar-unavailable'),
        tone: StatusTone.warning,
        icon: Icons.lock_outline,
        title: 'Not available yet',
        message: 'The $what is not available from this app right now.',
      ),
    };

/// Story 6.1, mobile: the public Calendar tab. Upcoming and ongoing events
/// grouped by church month, soonest first; each row opens the event.
class CalendarScreen extends ConsumerStatefulWidget {
  const CalendarScreen({super.key});

  @override
  ConsumerState<CalendarScreen> createState() => _CalendarScreenState();
}

class _CalendarScreenState extends ConsumerState<CalendarScreen> {
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onResume: _reload);
    // Revisiting the tab asks the server again.
    if (ref.read(publicEventsProvider).result != null) {
      Future.microtask(_reload);
    }
  }

  void _reload() {
    if (mounted && !ref.read(publicEventsProvider).loading) {
      ref.read(publicEventsProvider.notifier).reload();
    }
    // Epic 6 entry 19: the member's switched-on overlays are asked again.
    if (mounted) reloadCalendarOverlays(ref);
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = ChurchColors.of(context);
    final s = ref.watch(publicEventsProvider);
    final children = <Widget>[];
    // Epic 6 entry 19: a member with live access can lay their own duties
    // and cell meetings over the calendar (hidden for guests and Pending).
    final overlaysOffered = calendarOverlaysOffered(ref);
    final overlays = watchCalendarOverlays(ref);
    if (overlaysOffered) {
      children.add(CalendarOverlaySwitchBar(view: overlays));
    }
    switch (s.result) {
      case null:
        children.add(
          const RequestStateBanner(
            key: Key('calendar-loading'),
            tone: StatusTone.info,
            busy: true,
            title: 'Loading the calendar…',
            message: 'Asking the church server.',
          ),
        );
      case AccessReadOk(:final value):
        if (publicSavedStatus(
              context,
              s,
              what: 'calendar',
              key: 'calendar-stale',
            )
            case final n?) {
          children.addAll([n, const SizedBox(height: 16)]);
        }
        if (value.events.isEmpty) {
          children.add(
            ChurchCard(
              key: const Key('calendar-empty'),
              child: Text(
                'No upcoming events. Church events appear here once the '
                'church publishes them, until they end.',
                style: ChurchType.body.copyWith(color: c.muted),
              ),
            ),
          );
        }
        // Grouped by the church month of each start, in the server's order.
        // Epic 6 entry 19: the member's own items join their month, in
        // time order among the events (an event first at the same time).
        final groups = <String, List<(DateTime, Widget)>>{};
        for (final e in value.events) {
          groups.putIfAbsent(churchMonthTitle(e.startsAt), () => []).add((
            e.startsAt,
            PublicEventRow(
              event: e,
              onTap: () => context.push(CalendarPaths.event(e.eventId)),
            ),
          ));
        }
        for (final o in overlays.items) {
          final inMonth = groups.putIfAbsent(
            churchMonthTitle(o.startsAt),
            () => [],
          );
          var at = inMonth.length;
          while (at > 0 && inMonth[at - 1].$1.isAfter(o.startsAt)) {
            at--;
          }
          inMonth.insert(at, (o.startsAt, CalendarOverlayRow(item: o)));
        }
        final months = groups.keys.toList()
          ..sort((a, b) => groups[a]!.first.$1.compareTo(groups[b]!.first.$1));
        for (final (i, month) in months.indexed) {
          final inMonth = groups[month]!;
          if (i > 0) children.add(const SizedBox(height: 22));
          children.addAll([
            SectionHeader(key: Key('calendar-month-$i'), title: month),
            const SizedBox(height: 10),
            EventRowsCard(rows: [for (final (_, row) in inMonth) row]),
          ]);
        }
        if (value.truncated) {
          children.addAll([
            const SizedBox(height: 16),
            Text(
              'Only the soonest events are listed here.',
              key: const Key('calendar-truncated'),
              style: ChurchType.secondary.copyWith(color: c.muted),
            ),
          ]);
        }
      case final AccessRead<PublicEvents> problem:
        children.add(publicReadProblem(problem, what: 'calendar'));
    }
    return MemberTabPage(
      title: 'Calendar',
      reloadKey: const Key('calendar-reload'),
      onReload: s.loading ? null : _reload,
      children: children,
    );
  }
}

/// Story 6.1, mobile: one published event with both endpoints, the place and
/// the description. Opened from the Calendar or Home; a withdrawn event says
/// so instead of showing an old copy.
class EventDetailScreen extends ConsumerWidget {
  const EventDetailScreen({super.key, required this.eventId});

  final String eventId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = ChurchColors.of(context);
    final layout = ChurchLayout.of(context);
    final s = ref.watch(publicEventProvider(eventId));
    final ctl = ref.read(publicEventProvider(eventId).notifier);
    final children = <Widget>[];
    switch (s.result) {
      case null:
        children.add(
          const RequestStateBanner(
            key: Key('event-loading'),
            tone: StatusTone.info,
            busy: true,
            title: 'Loading the event…',
            message: 'Asking the church server.',
          ),
        );
      case AccessReadOk(value: PublicEventRead(:final event)):
        if (staleNotice(s, what: 'event', key: 'event-stale') case final n?) {
          children.addAll([n, const SizedBox(height: 16)]);
        }
        if (event == null) {
          children.addAll([
            RequestStateBanner(
              key: const Key('event-gone'),
              tone: StatusTone.neutral,
              title: 'Not on the calendar',
              message: 'This event is no longer on the calendar.',
              actions: [
                BannerAction(
                  'Open the calendar',
                  () => context.go(CalendarPaths.calendar),
                  key: const Key('event-gone-calendar'),
                  primary: true,
                ),
              ],
            ),
          ]);
        } else {
          final rsvp = event.rsvp;
          children.addAll([
            if (event.poster case final poster?) ...[
              _EventPosterView(poster: poster),
              const SizedBox(height: 16),
            ],
            Semantics(
              header: true,
              child: Text(
                event.title,
                key: const Key('event-title'),
                style: ChurchType.mobileScreenTitle.copyWith(color: c.ink),
              ),
            ),
            const SizedBox(height: 16),
            DetailTable(
              key: const Key('event-details'),
              rows: [
                (label: 'Starts', value: churchLongWhen(event.startsAt)),
                (label: 'Ends', value: churchLongWhen(event.endsAt)),
                (label: 'Where', value: event.location),
                if (rsvp != null) (label: 'Places', value: rsvp.placesText),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'Times are church time (Kafue).',
              style: ChurchType.secondary.copyWith(color: c.muted),
            ),
            if (rsvp != null) ...[
              const SizedBox(height: ChurchGeometry.sectionGap),
              _EventRsvpSection(event: event, rsvp: rsvp),
            ],
            if (!event.endedAt(DateTime.now())) ...[
              const SizedBox(height: ChurchGeometry.sectionGap),
              _EventCalendarExport(event: event),
            ],
            const SizedBox(height: ChurchGeometry.sectionGap),
            const CardLabel('About this event'),
            const SizedBox(height: 8),
            Text(
              event.description,
              key: const Key('event-description'),
              style: ChurchType.body.copyWith(color: c.ink),
            ),
          ]);
        }
      case final AccessRead<PublicEventRead> problem:
        children.add(publicReadProblem(problem, what: 'event'));
    }
    final reload = s.loading ? null : ctl.reload;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Event'),
        actions: [
          FocusRing(
            radius: 22,
            child: IconButton(
              key: const Key('event-reload'),
              tooltip: 'Reload',
              onPressed: reload,
              icon: const Icon(Icons.refresh),
            ),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: () async => reload?.call(),
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

/// Story 6.11: the poster in full (its own shape, never cropped), with its
/// text alternative. A poster that does not load says so.
class _EventPosterView extends ConsumerWidget {
  const _EventPosterView({required this.poster});

  final PublicEventPoster poster;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = ChurchColors.of(context);
    final url = ref
        .read(bannerRepositoryProvider)
        .publicFileUrl(poster.image.path);
    return ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: ColoredBox(
        color: c.surface2,
        child: AspectRatio(
          aspectRatio: poster.image.width / poster.image.height,
          child: Image.network(
            url.toString(),
            key: const Key('event-poster'),
            fit: BoxFit.contain,
            semanticLabel: poster.altText,
            errorBuilder: (context, _, _) => Center(
              key: const Key('event-poster-unavailable'),
              child: Text(
                'Poster unavailable',
                style: ChurchType.secondary.copyWith(color: c.muted),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Story 6.11: an event's RSVP. Everyone reads the counts; a guest is asked
/// to sign in, a signed-in account without member access is told plainly
/// that RSVP is for members, and an approved member answers. Nothing here
/// names who else is going.
class _EventRsvpSection extends ConsumerWidget {
  const _EventRsvpSection({required this.event, required this.rsvp});

  final PublicEvent event;
  final PublicEventRsvp rsvp;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = ChurchColors.of(context);
    final muted = ChurchType.secondary.copyWith(color: c.muted);
    final signedIn =
        ref.watch(accountProvider.select((s) => s.accountId)) != null;
    final access = ref.watch(myAccessProvider.select((s) => s.result));
    final Widget answer;
    if (!rsvp.open) {
      answer = Text(
        'RSVP is closed: the event has started.',
        key: const Key('event-rsvp-closed'),
        style: muted,
      );
    } else if (!signedIn) {
      answer = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Church members sign in to say they are coming.', style: muted),
          const SizedBox(height: 10),
          FocusRing(
            child: OutlinedButton(
              key: const Key('event-rsvp-sign-in'),
              onPressed: () => context.push(ClientPaths.signIn),
              child: const Text('Sign in to RSVP'),
            ),
          ),
        ],
      );
    } else if (access is AccessReadDenied<MemberGrants>) {
      answer = Text(
        'RSVP is for approved church members.',
        key: const Key('event-rsvp-members-only'),
        style: muted,
      );
    } else {
      answer = _MemberRsvp(event: event, rsvp: rsvp);
    }
    return Column(
      key: const Key('event-rsvp'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [const CardLabel('RSVP'), const SizedBox(height: 8), answer],
    );
  }
}

/// What the RSVP section says after an answer: (tone, sentence).
(StatusTone, String) _rsvpNoticeText(RsvpNotice n) => switch (n) {
  RsvpNotice.going => (
    StatusTone.success,
    'You\'re going. Your place is saved.',
  ),
  RsvpNotice.cancelled => (
    StatusTone.success,
    'Your RSVP is cancelled. Your place is free for someone else.',
  ),
  RsvpNotice.full => (StatusTone.warning, 'No places are left.'),
  RsvpNotice.closed => (
    StatusTone.warning,
    'RSVP is closed: the event has started.',
  ),
  RsvpNotice.off => (StatusTone.warning, 'This event no longer takes RSVPs.'),
  RsvpNotice.notPublic => (
    StatusTone.warning,
    'This event is no longer on the calendar.',
  ),
  RsvpNotice.notGoing => (StatusTone.neutral, 'You had no RSVP to cancel.'),
  RsvpNotice.membersOnly => (
    StatusTone.warning,
    'RSVP is for approved church members.',
  ),
  RsvpNotice.signInAgain => (StatusTone.warning, 'Please sign in again.'),
  RsvpNotice.notAvailable => (
    StatusTone.warning,
    'The church server could not do this now. Try again later.',
  ),
  RsvpNotice.refused => (StatusTone.danger, 'The church server refused this.'),
  RsvpNotice.unconfirmed => (
    StatusTone.warning,
    'We couldn\'t tell whether your answer arrived. Check again sends the '
        'same answer, so it can\'t count twice.',
  ),
  RsvpNotice.notSent => (
    StatusTone.neutral,
    'This build has no server configured, so nothing was sent.',
  ),
};

/// Story 6.11: an approved member's own RSVP and its two answers.
class _MemberRsvp extends ConsumerWidget {
  const _MemberRsvp({required this.event, required this.rsvp});

  final PublicEvent event;
  final PublicEventRsvp rsvp;

  Future<void> _cancel(BuildContext context, WidgetRef ref) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => ChurchDialog(
        title: 'Cancel your RSVP?',
        content: const Text(
          'Your place is given up. If the event fills, you may not get it back.',
        ),
        actions: [
          FocusRing(
            child: TextButton(
              key: const Key('event-rsvp-keep'),
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Keep my place'),
            ),
          ),
          FocusRing(
            child: FilledButton(
              key: const Key('event-rsvp-cancel-confirm'),
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Cancel RSVP'),
            ),
          ),
        ],
      ),
    );
    if (ok == true) {
      await ref.read(eventRsvpProvider(event.eventId).notifier).cancel();
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = ChurchColors.of(context);
    final muted = ChurchType.secondary.copyWith(color: c.muted);
    final s = ref.watch(eventRsvpProvider(event.eventId));
    final ctl = ref.read(eventRsvpProvider(event.eventId).notifier);
    final busy = s.busy;
    final children = <Widget>[];
    switch (s.result) {
      case null:
        children.add(
          Text(
            'Checking your RSVP…',
            key: const Key('event-rsvp-loading'),
            style: muted,
          ),
        );
      case AccessReadOk(:final value) when value.going:
        // A wrap, not a row: large text or a narrow phone puts the action
        // under the status instead of cutting it off.
        children.add(
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 12,
            runSpacing: 8,
            children: [
              const StatusLabel(
                key: Key('event-rsvp-going'),
                label: 'You\'re going',
                tone: StatusTone.success,
              ),
              FocusRing(
                child: TextButton(
                  key: const Key('event-rsvp-cancel'),
                  onPressed: busy ? null : () => _cancel(context, ref),
                  child: const Text('Cancel RSVP'),
                ),
              ),
            ],
          ),
        );
      case AccessReadOk() when rsvp.full:
        children.add(
          Text(
            'Full: no places are left.',
            key: const Key('event-rsvp-full'),
            style: ChurchType.body.copyWith(color: c.ink),
          ),
        );
      case AccessReadOk():
        children.add(
          FocusRing(
            child: FilledButton(
              key: const Key('event-rsvp-going-button'),
              onPressed: busy ? null : ctl.going,
              child: Text(busy ? 'Sending…' : 'I\'m going'),
            ),
          ),
        );
      case AccessReadDenied():
        children.add(
          Text(
            'RSVP is for approved church members.',
            key: const Key('event-rsvp-members-only'),
            style: muted,
          ),
        );
      case AccessReadFailed(:final unreachable):
        children.add(
          Text(
            unreachable
                ? 'No connection: we couldn\'t check your RSVP.'
                : 'We couldn\'t check your RSVP. Try again later.',
            key: const Key('event-rsvp-failed'),
            style: ChurchType.body.copyWith(color: c.ink),
          ),
        );
        children.add(
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: FocusRing(
              child: TextButton(
                key: const Key('event-rsvp-retry'),
                onPressed: s.loading ? null : ctl.reload,
                child: const Text('Try again'),
              ),
            ),
          ),
        );
    }
    if (s.notice case final n?) {
      final (tone, text) = _rsvpNoticeText(n);
      children.addAll([
        const SizedBox(height: 8),
        Semantics(
          liveRegion: true,
          child: Text(
            text,
            key: Key('event-rsvp-notice-${n.name}'),
            style: ChurchType.secondary.copyWith(
              color: tone == StatusTone.danger ? c.redFg : c.ink,
            ),
          ),
        ),
        if (n == RsvpNotice.unconfirmed)
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: FocusRing(
              child: TextButton(
                key: const Key('event-rsvp-check-again'),
                onPressed: busy ? null : ctl.checkAgain,
                child: const Text('Check again'),
              ),
            ),
          ),
      ]);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    );
  }
}

/// Story 6.11: Add to calendar for an event that has not ended, with the
/// copy caveat and what the phone said. The same handoff as a duty's.
class _EventCalendarExport extends ConsumerStatefulWidget {
  const _EventCalendarExport({required this.event});

  final PublicEvent event;

  @override
  ConsumerState<_EventCalendarExport> createState() =>
      _EventCalendarExportState();
}

class _EventCalendarExportState extends ConsumerState<_EventCalendarExport> {
  var _exporting = false;
  CalendarHandoff? _result;

  Future<void> _export(BuildContext button) async {
    // The share sheet points at the button (an iPad popover needs it).
    final box = button.findRenderObject();
    ShareOrigin? origin;
    if (box is RenderBox && box.hasSize) {
      final o = box.localToGlobal(Offset.zero);
      origin = ShareOrigin(o.dx, o.dy, box.size.width, box.size.height);
    }
    setState(() => _exporting = true);
    final result = await ref
        .read(dutyCalendarExportProvider)
        .export(
          fileName: EventCalendar.fileName(widget.event),
          ics: EventCalendar.ics(widget.event, now: DateTime.now()),
          origin: origin,
        );
    if (!mounted) return;
    setState(() {
      _exporting = false;
      _result = result;
    });
    announce(context, _text(result));
  }

  static String _text(CalendarHandoff r) => switch (r) {
    CalendarHandoff.shared =>
      'Calendar file shared. Check the calendar app you chose; this copy '
          'won\'t update if the event changes.',
    CalendarHandoff.handedOver =>
      'Calendar file handed to your phone. We can\'t tell whether it was '
          'saved; this copy won\'t update if the event changes.',
    CalendarHandoff.dismissed => 'Not added: the share sheet was closed.',
    CalendarHandoff.unavailable =>
      'Add to calendar isn\'t available in this version of the app.',
    CalendarHandoff.failed =>
      'Couldn\'t hand over the calendar file. Try again.',
  };

  @override
  Widget build(BuildContext context) {
    final c = ChurchColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FocusRing(
          child: Builder(
            builder: (button) => OutlinedButton.icon(
              key: const Key('event-calendar'),
              onPressed: _exporting ? null : () => _export(button),
              icon: const Icon(Icons.event_outlined),
              label: const Text('Add to calendar'),
            ),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          EventCalendar.staleCaveat,
          textAlign: TextAlign.center,
          style: ChurchType.secondary.copyWith(color: c.muted),
        ),
        if (_result case final r?)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(_text(r), key: const Key('event-calendar-result')),
          ),
      ],
    );
  }
}

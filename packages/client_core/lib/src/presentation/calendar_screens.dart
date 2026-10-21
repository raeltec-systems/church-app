import 'package:church_design_system/church_design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../application/content_controllers.dart';
import '../domain/access_grants.dart';
import '../domain/church_time.dart';
import '../domain/content_events.dart';
import 'church_widgets.dart';

// Story 6.1 (mobile): the public Calendar tab and an event's detail, read by
// everyone, signed in or not, from the published projection only. Every time
// is church time (Africa/Lusaka), whatever zone the phone uses. A failed read
// never looks like an empty calendar.

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
    return Semantics(
      button: true,
      label: '${e.title}, $when, ${e.location}',
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
        if (value.events.isEmpty) {
          children.add(
            ChurchCard(
              key: const Key('calendar-empty'),
              child: Text(
                'No events are published yet. Church events appear here as '
                'soon as the church publishes them.',
                style: ChurchType.body.copyWith(color: c.muted),
              ),
            ),
          );
        }
        // Grouped by the church month of each start, in the server's order.
        final groups = <String, List<PublicEvent>>{};
        for (final e in value.events) {
          groups.putIfAbsent(churchMonthTitle(e.startsAt), () => []).add(e);
        }
        for (final (i, MapEntry(key: month, value: inMonth))
            in groups.entries.indexed) {
          if (i > 0) children.add(const SizedBox(height: 22));
          children.addAll([
            SectionHeader(key: Key('calendar-month-$i'), title: month),
            const SizedBox(height: 10),
            EventRowsCard(
              rows: [
                for (final e in inMonth)
                  PublicEventRow(
                    event: e,
                    onTap: () => context.push(CalendarPaths.event(e.eventId)),
                  ),
              ],
            ),
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
          children.addAll([
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
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'Times are church time (Kafue).',
              style: ChurchType.secondary.copyWith(color: c.muted),
            ),
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

/// Story 6.1 (Home, everyone): the next published events, at most three,
/// each opening its detail, and a way to the whole calendar. Entry 14 turns
/// these into poster cards.
class ComingUpSection extends ConsumerWidget {
  const ComingUpSection({super.key});

  static const shown = 3;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = ChurchColors.of(context);
    final s = ref.watch(publicEventsProvider);
    final Widget body = switch (s.result) {
      null => Text(
        'Loading the calendar…',
        key: const Key('coming-up-loading'),
        style: ChurchType.secondary.copyWith(color: c.muted),
      ),
      AccessReadOk(:final value) when value.events.isEmpty => Text(
        'No events are published yet.',
        key: const Key('coming-up-empty'),
        style: ChurchType.body.copyWith(color: c.muted),
      ),
      AccessReadOk(:final value) => EventRowsCard(
        key: const Key('coming-up-list'),
        rows: [
          for (final e in value.events.take(shown))
            PublicEventRow(
              event: e,
              onTap: () => context.push(CalendarPaths.event(e.eventId)),
            ),
        ],
      ),
      AccessReadFailed(:final unreachable) => Text(
        unreachable
            ? 'No connection: we couldn\'t reach the church server, so no '
                  'events are shown. This is not an empty calendar.'
            : 'Couldn\'t load the calendar. Try again later.',
        key: const Key('coming-up-failed'),
        style: ChurchType.body.copyWith(color: c.ink),
      ),
      AccessReadDenied() => Text(
        'The calendar is not available from this app right now.',
        key: const Key('coming-up-unavailable'),
        style: ChurchType.body.copyWith(color: c.ink),
      ),
    };
    return Column(
      key: const Key('coming-up'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SectionHeader(title: 'Coming up'),
        const SizedBox(height: 8),
        body,
        const SizedBox(height: 4),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: FocusRing(
            child: TextButton(
              key: const Key('coming-up-calendar'),
              style: TextButton.styleFrom(padding: EdgeInsets.zero),
              onPressed: () => context.go(CalendarPaths.calendar),
              child: const Text('See the calendar'),
            ),
          ),
        ),
      ],
    );
  }
}

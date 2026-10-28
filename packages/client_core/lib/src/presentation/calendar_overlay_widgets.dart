import 'package:church_design_system/church_design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../application/access_controllers.dart' show myAccessProvider;
import '../application/calendar_overlay_controllers.dart';
import '../application/duties_controllers.dart' show myDutiesProvider;
import '../application/providers.dart' show accountProvider;
import '../domain/access_grants.dart';
import '../domain/calendar_overlays.dart';
import '../domain/church_time.dart';
import '../domain/duties.dart' show MyDuties;
import 'church_widgets.dart';
import 'duties_screens.dart' show DutyPaths;
import 'shell_routing.dart' show ClientPaths;

// Epic 6 entry 19 (mobile): the signed-in member's own duties and cell
// meetings laid over the public Calendar. Only a member with live access
// sees the two switches; guests and Pending applicants see the public
// calendar alone. Each item is marked as the member's own (My duty, My
// cell) and opens the duty's detail or My cell. Nothing here is cached:
// the overlays are read live and shown only while switched on.

/// The overlays are offered: signed in and the member access read answered
/// with live access. A guest, a Pending applicant (no member access) or an
/// access read that failed sees none.
bool calendarOverlaysOffered(WidgetRef ref) {
  final signedIn =
      ref.watch(accountProvider.select((s) => s.accountId)) != null;
  final access = ref.watch(myAccessProvider.select((s) => s.result));
  return signedIn && access is AccessReadOk<MemberGrants>;
}

/// What the switched-on overlays have to show, read live.
class CalendarOverlayView {
  const CalendarOverlayView({
    required this.items,
    required this.loading,
    required this.dutiesProblem,
    required this.cellProblem,
  });

  static const none = CalendarOverlayView(
    items: [],
    loading: false,
    dutiesProblem: null,
    cellProblem: null,
  );

  final List<CalendarOverlayItem> items;
  final bool loading;

  /// The duties read did not answer (never shown as "no duties").
  final AccessRead<MyDuties>? dutiesProblem;

  /// The cell meetings read did not answer.
  final AccessRead<MyCellMeetingsWindow>? cellProblem;
}

/// Watches the overlay reads for the switches that are on.
CalendarOverlayView watchCalendarOverlays(WidgetRef ref, {DateTime? now}) {
  if (!calendarOverlaysOffered(ref)) return CalendarOverlayView.none;
  final on = ref.watch(calendarOverlaySwitchesProvider);
  if (!on.any) return CalendarOverlayView.none;
  MyDuties? duties;
  AccessRead<MyDuties>? dutiesProblem;
  MyCellMeetingsWindow? cell;
  AccessRead<MyCellMeetingsWindow>? cellProblem;
  var loading = false;
  if (on.duties) {
    final s = ref.watch(myDutiesProvider);
    switch (s.result) {
      case AccessReadOk(:final value):
        duties = value;
      case null:
        loading = true;
      case final AccessRead<MyDuties> problem:
        dutiesProblem = problem;
    }
  }
  if (on.cell) {
    final s = ref.watch(myCellMeetingsProvider);
    switch (s.result) {
      case AccessReadOk(:final value):
        cell = value;
      case null:
        loading = true;
      case final AccessRead<MyCellMeetingsWindow> problem:
        cellProblem = problem;
    }
  }
  return CalendarOverlayView(
    items: calendarOverlayItems(
      now: now ?? DateTime.now(),
      duties: duties,
      cell: cell,
    ),
    loading: loading,
    dutiesProblem: dutiesProblem,
    cellProblem: cellProblem,
  );
}

/// Asks the switched-on overlay reads again (the Calendar's reload).
void reloadCalendarOverlays(WidgetRef ref) {
  if (!calendarOverlaysOffered(ref)) return;
  final on = ref.read(calendarOverlaySwitchesProvider);
  if (on.duties && !ref.read(myDutiesProvider).loading) {
    ref.read(myDutiesProvider.notifier).reload();
  }
  if (on.cell && !ref.read(myCellMeetingsProvider).loading) {
    ref.read(myCellMeetingsProvider.notifier).reload();
  }
}

/// The two overlay switches and, under them, what the overlays could not
/// load. Members only (the caller checks [calendarOverlaysOffered]).
class CalendarOverlaySwitchBar extends ConsumerWidget {
  const CalendarOverlaySwitchBar({super.key, required this.view});

  final CalendarOverlayView view;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = ChurchColors.of(context);
    final on = ref.watch(calendarOverlaySwitchesProvider);
    final ctl = ref.read(calendarOverlaySwitchesProvider.notifier);
    final muted = ChurchType.secondary.copyWith(color: c.muted);
    final notes = <Widget>[];
    if (view.loading) {
      notes.add(
        Text(
          'Loading your items…',
          key: const Key('calendar-overlay-loading'),
          style: muted,
        ),
      );
    }
    if (view.dutiesProblem case final p?) {
      notes.add(
        _OverlayProblem(
          key: const Key('calendar-overlay-duties-failed'),
          what: 'your duties',
          problem: p,
        ),
      );
    }
    if (view.cellProblem case final p?) {
      notes.add(
        _OverlayProblem(
          key: const Key('calendar-overlay-cell-failed'),
          what: 'your cell meetings',
          problem: p,
        ),
      );
    }
    if (on.any && !view.loading) {
      notes.add(
        Text(
          'Your own items for the next 31 days are marked.',
          key: const Key('calendar-overlay-window'),
          style: muted,
        ),
      );
    }
    return Column(
      key: const Key('calendar-overlays'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            FilterChip(
              key: const Key('calendar-overlay-duties'),
              label: const Text('My duties'),
              selected: on.duties,
              onSelected: (v) {
                ctl.setDuties(v);
                if (v && !ref.read(myDutiesProvider).loading) {
                  ref.read(myDutiesProvider.notifier).reload();
                }
              },
            ),
            FilterChip(
              key: const Key('calendar-overlay-cell'),
              label: const Text('My cell'),
              selected: on.cell,
              onSelected: (v) {
                ctl.setCell(v);
                if (v && !ref.read(myCellMeetingsProvider).loading) {
                  ref.read(myCellMeetingsProvider.notifier).reload();
                }
              },
            ),
          ],
        ),
        for (final n in notes) ...[const SizedBox(height: 8), n],
        const SizedBox(height: 16),
      ],
    );
  }
}

/// An overlay read that did not answer, said plainly (never an empty list).
class _OverlayProblem extends StatelessWidget {
  const _OverlayProblem({super.key, required this.what, required this.problem});

  final String what;
  final AccessRead<Object?> problem;

  @override
  Widget build(BuildContext context) {
    final (title, message) = switch (problem) {
      AccessReadFailed(:final unreachable) when unreachable => (
        'No connection',
        'We couldn\'t load $what. The church calendar is shown without them.',
      ),
      AccessReadDenied() => (
        'Not available',
        'We couldn\'t show $what right now.',
      ),
      _ => ('Couldn\'t load', 'We couldn\'t load $what. Try again later.'),
    };
    return RequestStateBanner(
      tone: StatusTone.warning,
      icon: Icons.error_outline,
      title: title,
      message: message,
    );
  }
}

const _weekdays = [
  'Monday',
  'Tuesday',
  'Wednesday',
  'Thursday',
  'Friday',
  'Saturday',
  'Sunday',
];
const _months = [
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

/// One of the member's own items in a Calendar month: the date badge, what
/// it is, when (and where, for a duty) and its mark (My duty or My cell). A
/// cancelled cell meeting stays listed and says so.
class CalendarOverlayRow extends StatelessWidget {
  const CalendarOverlayRow({super.key, required this.item});

  final CalendarOverlayItem item;

  @override
  Widget build(BuildContext context) {
    final c = ChurchColors.of(context);
    final i = item;
    final duty = i.kind == CalendarOverlayKind.duty;
    final clock = ChurchTime.timeText;
    final span = i.endsAt == null
        ? clock(i.startsAt)
        : '${clock(i.startsAt)}–${clock(i.endsAt!)}';
    final String when;
    if (duty) {
      final time = i.dueOnly
          ? 'Done by this day'
          : i.reportingAt != null && i.reportingAt!.isBefore(i.startsAt)
          ? 'Report ${clock(i.reportingAt!)}'
          : span;
      when = i.place == null ? time : '$time · ${i.place}';
    } else if (i.cancelled) {
      when = 'Cancelled · was $span';
    } else if (i.moved) {
      when = '$span · moved from its usual time';
    } else {
      when = span;
    }
    final title = !duty && i.cancelled ? 'Cell meeting cancelled' : i.title;
    final mark = duty ? 'My duty' : 'My cell';
    final w = ChurchTime.wall(i.startsAt);
    final spokenDate =
        '${_weekdays[w.weekday - 1]} ${w.day} ${_months[w.month - 1]}';
    return Semantics(
      button: true,
      label: '$mark: $title, $spokenDate, $when',
      excludeSemantics: true,
      child: FocusRing(
        radius: 4,
        child: InkWell(
          key: Key('overlay-row-${i.kind.name}-${i.id}'),
          onTap: () => context.push(
            duty ? DutyPaths.assignment(i.id) : ClientPaths.myCell,
          ),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ChurchDateBadge(at: i.startsAt),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: ChurchType.itemTitle.copyWith(
                          color: i.cancelled ? c.muted : c.ink,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        when,
                        key: Key('overlay-when-${i.kind.name}-${i.id}'),
                        style: ChurchType.secondary.copyWith(color: c.muted),
                      ),
                      const SizedBox(height: 6),
                      StatusLabel(
                        key: Key('overlay-mark-${i.kind.name}-${i.id}'),
                        label: mark,
                        tone: duty ? StatusTone.info : StatusTone.success,
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

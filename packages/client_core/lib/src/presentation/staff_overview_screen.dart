import 'package:church_design_system/church_design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../application/access_controllers.dart';
import '../application/providers.dart';
import '../application/cell_controllers.dart';
import '../application/duties_controllers.dart';
import '../application/followups_controllers.dart';
import '../application/review_controllers.dart';
import '../application/staff_view_controllers.dart';
import '../domain/access_grants.dart';
import '../domain/cell_meetings.dart';
import '../domain/cell_membership.dart';
import '../domain/church_time.dart';
import '../domain/duties.dart';
import '../domain/followups.dart';
import '../domain/membership_review.dart';
import 'shell_routing.dart';

// Staff web: the Overview. It answers one question for the role being
// viewed, "what needs me now?", from reads the screens already make: the
// figures first, then the list of things to resolve, each linking to the
// screen that resolves it. Nothing here is a new server read, and nothing
// the product has not built is shown.

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

String _today(DateTime now) {
  final w = ChurchTime.wall(now);
  return '${_weekdays[w.weekday - 1]} ${w.day} ${_months[w.month - 1]}';
}

String _shortDay(DateTime at) {
  final w = ChurchTime.wall(at);
  return '${_weekdays[w.weekday - 1].substring(0, 3)} ${w.day} '
      '${_months[w.month - 1].substring(0, 3)}';
}

String _plural(int n, String one, [String? many]) =>
    '$n ${n == 1 ? one : (many ?? '${one}s')}';

/// The state of one figure's read.
sealed class _Value {
  const _Value();
}

class _Loading extends _Value {
  const _Loading();
}

class _Unavailable extends _Value {
  const _Unavailable({required this.failed});

  /// True when the read failed (no connection or an unexpected answer);
  /// false when the server said no.
  final bool failed;
}

class _Count extends _Value {
  const _Count(this.n, {this.more = false, this.alarm = false});
  final int n;

  /// More exist than were read (a paged list).
  final bool more;

  /// A count above zero is bad news (gaps): its figure is set in red.
  final bool alarm;
}

class _Text extends _Value {
  const _Text(this.text);
  final String text;
}

_Value _unavailable(AccessRead<Object?>? r) => switch (r) {
  null => const _Loading(),
  AccessReadFailed() => const _Unavailable(failed: true),
  _ => const _Unavailable(failed: false),
};

class _Figure {
  const _Figure({
    required this.id,
    required this.label,
    required this.caption,
    required this.value,
    required this.route,
  });

  final String id;
  final String label;
  final String caption;
  final _Value value;
  final String route;
}

class _Attention {
  const _Attention({
    required this.id,
    required this.kind,
    required this.tone,
    required this.title,
    required this.detail,
    required this.route,
    this.action = 'Open',
  });

  final String id;
  final String kind;
  final StatusTone tone;
  final String title;
  final String detail;
  final String route;
  final String action;
}

/// The figures and the list for one view, built from the reads' states.
class _Board {
  final figures = <_Figure>[];
  final attention = <_Attention>[];

  /// Reads that failed or were refused, named for the list's footnote.
  final problems = <String>[];
}

class StaffOverviewScreen extends ConsumerStatefulWidget {
  const StaffOverviewScreen({super.key});

  @override
  ConsumerState<StaffOverviewScreen> createState() =>
      _StaffOverviewScreenState();
}

class _StaffOverviewScreenState extends ConsumerState<StaffOverviewScreen> {
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onResume: _reload);
    // Revisiting the Overview asks the server again for what it shows.
    Future.microtask(() => _reload(onlyKnown: true));
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  /// Reads again the providers this view uses ([onlyKnown]: only those that
  /// already answered once; the others load as they are first watched).
  void _reload({bool onlyKnown = false}) {
    if (!mounted) return;
    final g = ref.read(staffViewGrantsProvider);
    if (g == null) return;
    bool known(Object? result) => !onlyKnown || result != null;
    if (g.isAdmin) {
      if (known(ref.read(membershipReviewProvider).queueResult)) {
        ref.read(membershipReviewProvider.notifier).reload();
      }
      if (known(ref.read(cellAdminProvider).result)) {
        ref.read(cellAdminProvider.notifier).reload();
      }
      if (known(ref.read(dutyRotaProvider).result)) {
        ref.read(dutyRotaProvider.notifier).reload();
      }
      if (known(ref.read(followUpRoutingProvider).result)) {
        ref.read(followUpRoutingProvider.notifier).reload();
      }
    }
    if (servesACell(g)) {
      if (known(ref.read(cellLeaderProvider).result)) {
        ref.read(cellLeaderProvider.notifier).reload();
      }
      if (known(ref.read(cellMeetingsProvider).result)) {
        ref.read(cellMeetingsProvider.notifier).reload();
      }
    }
    if (givesSpecialAssignments(g) &&
        known(ref.read(dutySpecialProvider).result)) {
      ref.read(dutySpecialProvider.notifier).reload();
    }
    if (_readsCoverage(g) && known(ref.read(leaderAttentionProvider).result)) {
      final s = ref.read(leaderAttentionProvider);
      if (!s.loading && !s.busy) {
        ref.read(leaderAttentionProvider.notifier).reload();
      }
    }
    if (known(ref.read(myFollowUpsProvider).result)) {
      ref.read(myFollowUpsProvider.notifier).reload();
    }
  }

  static bool _readsCoverage(MemberGrants g) =>
      g.isAdmin || g.hasRole(ChurchRoles.pastor) || leadsADepartment(g);

  @override
  Widget build(BuildContext context) {
    final signedIn = ref.watch(
      accountProvider.select((s) => s.accountId != null),
    );
    if (!signedIn) return const StaffSignInLanding();
    final access = ref.watch(myAccessProvider);
    final grants = ref.watch(staffViewGrantsProvider);
    final view = ref.watch(staffViewProvider);
    final now = DateTime.now();
    final c = ChurchColors.of(context);
    final layout = ChurchLayout.of(context);

    final children = <Widget>[];
    String subtitle;
    if (grants == null) {
      subtitle = _today(now);
      children.add(
        access.result == null
            ? const RequestStateBanner(
                key: Key('overview-loading'),
                tone: StatusTone.info,
                busy: true,
                title: 'Loading…',
                message: 'Asking the church server what you can see.',
              )
            : _NoMemberAccess(onOpen: () => context.go(ClientPaths.account)),
      );
    } else {
      final board = _build(grants, view);
      subtitle = switch (view ?? _soleRole(grants)) {
        StaffRole.admin => 'Church-wide · ${_today(now)}',
        StaffRole.pastor => 'The whole church · ${_today(now)}',
        StaffRole.cellLeader => _cellScope(now),
        null => _today(now),
      };
      if (board.figures.isNotEmpty) {
        children.addAll([
          _FigureStrip(figures: board.figures),
          const SizedBox(height: ChurchGeometry.sectionGap),
        ]);
      }
      children.add(_AttentionList(board: board));
    }

    return ChurchPageScaffold(
      title: 'Overview',
      subtitle: subtitle,
      actions: [
        if (grants != null)
          staffReloadButton(const Key('overview-reload'), _reload),
      ],
      body: SingleChildScrollView(
        padding: layout.pagePadding,
        child: Align(
          alignment: AlignmentDirectional.topStart,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: layout.contentMaxWidth),
            child: DefaultTextStyle.merge(
              style: layout.body.copyWith(color: c.ink),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: children,
              ),
            ),
          ),
        ),
      ),
    );
  }

  static StaffRole? _soleRole(MemberGrants g) {
    final roles = staffRolesOf(g);
    return roles.length == 1 ? roles.single : null;
  }

  String _cellScope(DateTime now) {
    final cells = ref.read(cellLeaderProvider).value?.cells;
    if (cells == null || cells.isEmpty) return _today(now);
    final names = cells.map((c) => c.name).join(', ');
    return '$names · ${_today(now)}';
  }

  _Board _build(MemberGrants g, StaffRole? view) {
    final board = _Board();
    final role = view ?? _soleRole(g);
    final admin = g.isAdmin && (role == StaffRole.admin || role == null);
    final pastor =
        g.hasRole(ChurchRoles.pastor) &&
        (role == StaffRole.pastor || role == null);
    final cellLeader =
        servesACell(g) && (role == StaffRole.cellLeader || role == null);
    if (admin) _admin(board);
    if (pastor) _pastor(board, withGaps: !admin);
    if (cellLeader) _cellLeader(board);
    if (!admin && !pastor && leadsADepartment(g)) _departments(board);
    _mine(board, alone: board.figures.isEmpty);
    return board;
  }

  // ------------------------------------------------------------------ Admin

  void _admin(_Board b) {
    final review = ref.watch(membershipReviewProvider);
    final q = review.queueResult;
    b.figures.add(
      _Figure(
        id: 'applications',
        label: 'Membership applications',
        caption: 'Waiting for review',
        value: q is AccessReadOk<ReviewQueue>
            ? _Count(review.applications.length, more: review.queueNext != null)
            : _unavailable(q),
        route: ClientPaths.adminMembers,
      ),
    );
    if (q is AccessReadOk<ReviewQueue>) {
      for (final a in review.applications.take(4)) {
        final app = a.application;
        final dup = a.candidates.isNotEmpty;
        b.attention.add(
          _Attention(
            id: 'application-${a.id}',
            kind: dup ? 'Check identity' : 'Application',
            tone: dup ? StatusTone.warning : StatusTone.info,
            title: '${app.fullName} asked to join',
            detail: [
              app.phoneUsername,
              if (dup) _plural(a.candidates.length, 'possible existing record'),
            ].join(' · '),
            route: ClientPaths.adminMembers,
            action: 'Review',
          ),
        );
      }
    } else if (q != null) {
      b.problems.add('applications');
    }

    final cells = ref.watch(cellAdminProvider).result;
    b.figures.add(
      _Figure(
        id: 'cell-requests',
        label: 'Cell requests',
        caption: 'Waiting for a cell decision',
        value: cells is AccessReadOk<CellAdminOverview>
            ? _Count(cells.value.requests.length)
            : _unavailable(cells),
        route: ClientPaths.adminCells,
      ),
    );
    if (cells is AccessReadOk<CellAdminOverview>) {
      for (final r in cells.value.requests.take(4)) {
        b.attention.add(
          _Attention(
            id: 'cell-request-${r.requestId}',
            kind: r.followUp ? 'Church office' : 'Cell request',
            tone: r.followUp ? StatusTone.warning : StatusTone.info,
            title: r.displayName,
            detail: r.followUp
                ? 'Needs the church office to choose a cell'
                : 'Asked for ${r.requestedCellName ?? 'a cell'}'
                      '${r.currentCellName == null ? '' : ' (now in ${r.currentCellName})'}',
            route: ClientPaths.adminCells,
          ),
        );
      }
    } else if (cells != null) {
      b.problems.add('cell requests');
    }

    _gaps(b, churchWide: true);

    final rota = ref.watch(dutyRotaProvider).result;
    var drafts = 0;
    if (rota is AccessReadOk<DutyRota>) {
      for (final d in rota.value.departments) {
        for (final s in d.series) {
          drafts += s.draftSlots;
          if (s.draftSlots > 0) {
            b.attention.add(
              _Attention(
                id: 'drafts-${s.seriesId}',
                kind: 'Draft',
                tone: StatusTone.neutral,
                title: '${s.dutyName}: ${_plural(s.draftSlots, 'draft slot')}',
                detail: '${d.name} · not yet published to members',
                route: ClientPaths.dutyRota,
              ),
            );
          }
        }
      }
    } else if (rota != null) {
      b.problems.add('the rota');
    }
    b.figures.add(
      _Figure(
        id: 'drafts',
        label: 'Draft rota slots',
        caption: 'Not yet published',
        value: rota is AccessReadOk<DutyRota>
            ? _Count(drafts)
            : _unavailable(rota),
        route: ClientPaths.dutyRota,
      ),
    );

    final routing = ref.watch(followUpRoutingProvider).result;
    var overdue = 0;
    if (routing is AccessReadOk<FollowUpAdminRouting>) {
      final late = routing.value.tasks
          .where((t) => t.state.active && t.overdue)
          .toList();
      overdue = late.length;
      for (final t in late.take(3)) {
        b.attention.add(
          _Attention(
            id: 'followup-${t.taskId}',
            kind: 'Follow-up',
            tone: StatusTone.warning,
            title: t.purposeLabel,
            detail:
                '${t.owner.displayName ?? 'Owner not shown'} · was due '
                '${_shortDay(t.actionableAt)}',
            route: ClientPaths.adminFollowUps,
          ),
        );
      }
    } else if (routing != null) {
      b.problems.add('follow-ups');
    }
    b.figures.add(
      _Figure(
        id: 'followups-overdue',
        label: 'Follow-ups overdue',
        caption: 'Past their due date',
        value: routing is AccessReadOk<FollowUpAdminRouting>
            ? _Count(overdue, more: routing.value.truncated, alarm: true)
            : _unavailable(routing),
        route: ClientPaths.adminFollowUps,
      ),
    );
  }

  /// This week's duty gaps: every department the reader sees ([churchWide],
  /// Admin and Pastor) or only those they lead or deputise.
  void _gaps(_Board b, {required bool churchWide}) {
    final r = ref.watch(leaderAttentionProvider).result;
    if (r is AccessReadOk<DutyCoverage>) {
      final departments = r.value.departments
          .where((d) => churchWide || d.full)
          .toList();
      var gaps = 0;
      for (final d in departments) {
        final n = d.counts.unfilled + d.counts.declined + d.counts.overdue;
        gaps += n;
        if (n == 0) continue;
        b.attention.insert(
          0,
          _Attention(
            id: 'gaps-${d.departmentId}',
            kind: 'Duty',
            tone: StatusTone.danger,
            title: '${d.name}: ${_plural(n, 'gap')} this week',
            detail: [
              if (d.counts.unfilled > 0) '${d.counts.unfilled} unfilled',
              if (d.counts.declined > 0) '${d.counts.declined} declined',
              if (d.counts.overdue > 0) '${d.counts.overdue} overdue answers',
              '${d.counts.confirmed} of ${d.counts.required} confirmed',
            ].join(' · '),
            route: ClientPaths.dutyCoverage,
          ),
        );
      }
      b.figures.add(
        _Figure(
          id: 'duty-gaps',
          label: churchWide ? 'Duty gaps this week' : 'Gaps in your duties',
          caption: 'Unfilled, declined or overdue',
          value: _Count(gaps, more: r.value.truncated, alarm: true),
          route: ClientPaths.dutyCoverage,
        ),
      );
    } else {
      if (r != null) b.problems.add('duty coverage');
      b.figures.add(
        _Figure(
          id: 'duty-gaps',
          label: churchWide ? 'Duty gaps this week' : 'Gaps in your duties',
          caption: 'Unfilled, declined or overdue',
          value: _unavailable(r),
          route: ClientPaths.dutyCoverage,
        ),
      );
    }
  }

  // ----------------------------------------------------------------- Pastor

  void _pastor(_Board b, {required bool withGaps}) {
    final r = ref.watch(dutySpecialProvider).result;
    if (r is AccessReadOk<SpecialAssignments>) {
      final needs = r.value.assignments.where((a) => a.needsSomeone).toList();
      final outcomes = r.value.assignments.where((a) => a.outcomeDue).toList();
      b.figures.addAll([
        _Figure(
          id: 'special-needs-someone',
          label: 'Special assignments to fill',
          caption: 'Nobody holds them, or declined',
          value: _Count(needs.length, alarm: true),
          route: ClientPaths.dutySpecial,
        ),
        _Figure(
          id: 'special-outcomes',
          label: 'Outcomes to record',
          caption: 'Special assignments that are past',
          value: _Count(outcomes.length, more: r.value.truncated),
          route: ClientPaths.dutySpecial,
        ),
      ]);
      for (final a in needs.take(4)) {
        final declined = a.holder != null;
        b.attention.add(
          _Attention(
            id: 'special-needs-${a.occurrenceId}',
            kind: declined ? 'Declined' : 'Vacant',
            tone: StatusTone.danger,
            title: a.dutyName,
            detail: declined
                ? '${a.holder!.displayName ?? 'The member'} can\'t make it · '
                      '${_shortDay(a.times.startsAt)}'
                : 'Nobody holds it · ${_shortDay(a.times.startsAt)}',
            route: ClientPaths.dutySpecial,
          ),
        );
      }
      for (final a in outcomes.take(4)) {
        b.attention.add(
          _Attention(
            id: 'special-outcome-${a.occurrenceId}',
            kind: 'Outcome',
            tone: StatusTone.neutral,
            title: a.dutyName,
            detail:
                '${a.holder?.displayName ?? 'Held'} · '
                '${_shortDay(a.times.startsAt)} · outcome not recorded',
            route: ClientPaths.dutySpecial,
            action: 'Record',
          ),
        );
      }
    } else {
      if (r != null) b.problems.add('special assignments');
      b.figures.add(
        _Figure(
          id: 'special-needs-someone',
          label: 'Special assignments to fill',
          caption: 'Nobody holds them, or declined',
          value: _unavailable(r),
          route: ClientPaths.dutySpecial,
        ),
      );
    }
    if (withGaps) _gaps(b, churchWide: true);
  }

  // ------------------------------------------------------------ Cell leader

  void _cellLeader(_Board b) {
    final q = ref.watch(cellLeaderProvider).result;
    if (q is AccessReadOk<LeaderQueue>) {
      final requests = [
        for (final cell in q.value.cells)
          for (final r in cell.requests) (cell, r),
      ];
      b.figures.add(
        _Figure(
          id: 'my-cell-requests',
          label: 'Requests to join',
          caption: 'Waiting for your confirmation',
          value: _Count(requests.length),
          route: ClientPaths.cellLeader,
        ),
      );
      for (final (cell, r) in requests.take(4)) {
        b.attention.add(
          _Attention(
            id: 'my-cell-request-${r.requestId}',
            kind: 'Cell request',
            tone: StatusTone.info,
            title: r.displayName,
            detail: 'Asked to join ${cell.name}',
            route: ClientPaths.cellLeader,
          ),
        );
      }
    } else {
      if (q != null) b.problems.add('your cell');
      b.figures.add(
        _Figure(
          id: 'my-cell-requests',
          label: 'Requests to join',
          caption: 'Waiting for your confirmation',
          value: _unavailable(q),
          route: ClientPaths.cellLeader,
        ),
      );
    }

    final m = ref.watch(cellMeetingsProvider).result;
    if (m is AccessReadOk<CellMeetingsBoard>) {
      final now = DateTime.now();
      CellMeeting? next;
      String? nextCell;
      var unrecorded = 0;
      for (final cell in m.value.cells) {
        for (final meeting in cell.meetings) {
          if (meeting.cancelled || !meeting.startsAt.isAfter(now)) continue;
          if (next == null || meeting.startsAt.isBefore(next.startsAt)) {
            next = meeting;
            nextCell = cell.name;
          }
        }
        for (final r in cell.recent) {
          if (r.status != MeetingStatus.unrecorded) continue;
          unrecorded++;
          b.attention.add(
            _Attention(
              id: 'unrecorded-${r.meeting.meetingId}',
              kind: 'Record',
              tone: StatusTone.warning,
              title: '${cell.name}: ${_shortDay(r.meeting.startsAt)}',
              detail: 'Say whether it was held and who led each part',
              route: ClientPaths.cellMeetings,
              action: 'Record',
            ),
          );
        }
      }
      b.figures.addAll([
        _Figure(
          id: 'next-meeting',
          label: 'Next meeting',
          caption: next == null
              ? 'None scheduled'
              : '${ChurchTime.timeText(next.startsAt)} · $nextCell',
          value: next == null
              ? const _Text('—')
              : _Text(_shortDay(next.startsAt)),
          route: ClientPaths.cellMeetings,
        ),
        _Figure(
          id: 'meetings-to-record',
          label: 'Meetings to record',
          caption: 'In the last four weeks',
          value: _Count(unrecorded),
          route: ClientPaths.cellMeetings,
        ),
      ]);
    } else {
      if (m != null) b.problems.add('cell meetings');
      b.figures.add(
        _Figure(
          id: 'next-meeting',
          label: 'Next meeting',
          caption: 'Your cell',
          value: _unavailable(m),
          route: ClientPaths.cellMeetings,
        ),
      );
    }
  }

  // ----------------------------------------------- Department leaders, me

  void _departments(_Board b) => _gaps(b, churchWide: false);

  void _mine(_Board b, {required bool alone}) {
    final r = ref.watch(myFollowUpsProvider).result;
    if (r is AccessReadOk<MyFollowUps>) {
      final late = r.value.active.where((t) => t.routing.overdue).toList();
      for (final t in late.take(3)) {
        b.attention.add(
          _Attention(
            id: 'my-followup-${t.routing.taskId}',
            kind: 'Your follow-up',
            tone: StatusTone.warning,
            title: t.routing.purposeLabel,
            detail: 'Was due ${_shortDay(t.routing.actionableAt)}',
            route: ClientPaths.myFollowUps,
          ),
        );
      }
      if (alone) {
        b.figures.add(
          _Figure(
            id: 'my-followups-overdue',
            label: 'Your follow-ups overdue',
            caption: _plural(r.value.active.length, 'open task'),
            value: _Count(late.length, alarm: true),
            route: ClientPaths.myFollowUps,
          ),
        );
      }
    } else if (r is AccessReadFailed) {
      b.problems.add('your follow-ups');
    }
  }
}

/// The figures as type in one white card split by 1 px lines, each opening
/// the screen that explains it.
class _FigureStrip extends StatelessWidget {
  const _FigureStrip({required this.figures});

  final List<_Figure> figures;

  @override
  Widget build(BuildContext context) {
    final c = ChurchColors.of(context);
    return LayoutBuilder(
      builder: (context, box) {
        final perRow = (box.maxWidth / 210).floor().clamp(1, figures.length);
        final rows = <List<_Figure>>[];
        for (var i = 0; i < figures.length; i += perRow) {
          rows.add(
            figures.sublist(
              i,
              i + perRow > figures.length ? figures.length : i + perRow,
            ),
          );
        }
        return ChurchCard(
          key: const Key('overview-figures'),
          radius: 12,
          padding: EdgeInsets.zero,
          child: Column(
            children: [
              for (var r = 0; r < rows.length; r++)
                DecoratedBox(
                  decoration: BoxDecoration(
                    border: r == 0
                        ? null
                        : Border(top: BorderSide(color: c.line)),
                  ),
                  child: IntrinsicHeight(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (var i = 0; i < rows[r].length; i++) ...[
                          if (i > 0) VerticalDivider(width: 1, color: c.line),
                          Expanded(child: _FigureCell(figure: rows[r][i])),
                        ],
                      ],
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

class _FigureCell extends StatelessWidget {
  const _FigureCell({required this.figure});

  final _Figure figure;

  @override
  Widget build(BuildContext context) {
    final c = ChurchColors.of(context);
    const big = TextStyle(
      fontFamily: ChurchFonts.heading,
      fontSize: 30,
      fontWeight: FontWeight.w700,
      height: 1.1,
      fontFeatures: [FontFeature.tabularFigures()],
    );
    final f = figure;
    final (Widget value, String spoken) = switch (f.value) {
      _Loading() => (
        Container(
          width: 36,
          height: 30,
          margin: const EdgeInsets.symmetric(vertical: 2),
          decoration: BoxDecoration(
            color: c.surface2,
            borderRadius: BorderRadius.circular(4),
          ),
        ),
        'loading',
      ),
      // A grey dash at caption size, never at the figure's size (it would
      // read as loading).
      _Unavailable(:final failed) => (
        SizedBox(
          height: 33,
          child: Align(
            alignment: AlignmentDirectional.bottomStart,
            child: Text(
              '—',
              style: ChurchType.staffBody.copyWith(color: c.muted),
            ),
          ),
        ),
        failed ? 'couldn\'t load' : 'not available to you',
      ),
      _Count(:final n, :final more, :final alarm) => (
        Text(
          more ? '$n+' : '$n',
          style: big.copyWith(color: alarm && n > 0 ? c.redFg : c.brand),
        ),
        more ? 'more than $n' : '$n',
      ),
      _Text(:final text) => (
        Text(text, style: big.copyWith(color: c.brand, fontSize: 24)),
        text,
      ),
    };
    final caption = switch (f.value) {
      _Unavailable(:final failed) =>
        failed ? 'Couldn\'t load. Try Reload.' : 'Not available to you',
      _ => f.caption,
    };
    return Semantics(
      button: true,
      label: '${f.label}: $spoken. $caption',
      excludeSemantics: true,
      child: FocusRing(
        radius: 4,
        child: InkWell(
          key: Key('overview-figure-${f.id}'),
          onTap: () => context.go(f.route),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                value,
                const SizedBox(height: 6),
                Text(
                  f.label,
                  style: ChurchType.staffBody.copyWith(
                    color: c.ink,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  caption,
                  style: ChurchType.secondary.copyWith(
                    color: c.muted,
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The handoff's Needs attention list: a pale chip naming the kind, what it
/// is, one line of detail and the action that resolves it.
class _AttentionList extends StatelessWidget {
  const _AttentionList({required this.board});

  final _Board board;

  @override
  Widget build(BuildContext context) {
    final c = ChurchColors.of(context);
    final items = board.attention;
    final rows = <Widget>[];
    for (var i = 0; i < items.length; i++) {
      rows.add(_AttentionRow(item: items[i], divider: i > 0));
    }
    return ChurchCard(
      key: const Key('overview-attention'),
      radius: 12,
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 14),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: c.line)),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Semantics(
                    header: true,
                    child: Text(
                      'Needs attention',
                      style: ChurchType.cardTitle.copyWith(
                        color: c.ink,
                        fontSize: 17,
                      ),
                    ),
                  ),
                ),
                if (items.isNotEmpty)
                  Text(
                    _plural(items.length, 'item'),
                    style: ChurchType.secondary.copyWith(color: c.muted),
                  ),
              ],
            ),
          ),
          if (items.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 18),
              child: Text(
                board.problems.isEmpty
                    ? 'Nothing needs your attention right now.'
                    : 'Nothing else to show: some lists could not be read.',
                key: const Key('overview-attention-empty'),
                style: ChurchType.staffBody.copyWith(color: c.muted),
              ),
            ),
          ...rows,
          if (board.problems.isNotEmpty)
            Container(
              key: const Key('overview-problems'),
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 14),
              decoration: BoxDecoration(
                border: Border(top: BorderSide(color: c.line)),
              ),
              child: Text(
                'Not included: ${board.problems.join(', ')} (not available '
                'or could not be read). This is not an empty list.',
                style: ChurchType.secondary.copyWith(color: c.muted),
              ),
            ),
        ],
      ),
    );
  }
}

class _AttentionRow extends StatelessWidget {
  const _AttentionRow({required this.item, required this.divider});

  final _Attention item;
  final bool divider;

  @override
  Widget build(BuildContext context) {
    final c = ChurchColors.of(context);
    return Container(
      key: Key('overview-attention-${item.id}'),
      constraints: const BoxConstraints(minHeight: 64),
      padding: const EdgeInsets.fromLTRB(20, 10, 16, 10),
      decoration: BoxDecoration(
        border: divider ? Border(top: BorderSide(color: c.line)) : null,
      ),
      child: Row(
        children: [
          SizedBox(
            width: 128,
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              child: StatusLabel(label: item.kind, tone: item.tone),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.title,
                  style: ChurchType.staffBody.copyWith(
                    color: c.ink,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  item.detail,
                  style: ChurchType.secondary.copyWith(
                    color: c.muted,
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          FocusRing(
            child: OutlinedButton(
              key: Key('overview-open-${item.id}'),
              onPressed: () => context.go(item.route),
              style: OutlinedButton.styleFrom(
                minimumSize: const Size(72, 40),
                padding: const EdgeInsets.symmetric(horizontal: 14),
                textStyle: const TextStyle(
                  fontFamily: ChurchFonts.body,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
              child: Text(item.action),
            ),
          ),
        ],
      ),
    );
  }
}

class _NoMemberAccess extends StatelessWidget {
  const _NoMemberAccess({required this.onOpen});

  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) => RequestStateBanner(
    key: const Key('overview-no-member-access'),
    tone: StatusTone.neutral,
    icon: Icons.badge_outlined,
    title: 'No member access yet',
    message:
        'This account is not linked to a church member with staff work, so '
        'there is nothing to show here. My account says what the church '
        'knows about it.',
    actions: [
      BannerAction(
        'Open My account',
        onOpen,
        key: const Key('overview-open-account'),
        primary: true,
      ),
    ],
  );
}

/// Staff web while signed out: the church's mark, the product's name and
/// one way in. Nothing about the platform is shown before sign-in.
class StaffSignInLanding extends StatelessWidget {
  const StaffSignInLanding({super.key});

  @override
  Widget build(BuildContext context) {
    final c = ChurchColors.of(context);
    return Scaffold(
      backgroundColor: c.bg,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 400),
              child: Column(
                key: const Key('staff-landing'),
                mainAxisSize: MainAxisSize.min,
                children: [
                  const ChurchLogo(size: 96),
                  const SizedBox(height: 20),
                  Semantics(
                    header: true,
                    child: Text(
                      'BICC Kafue staff',
                      textAlign: TextAlign.center,
                      style: ChurchType.staffPageTitle.copyWith(
                        color: c.brand,
                        fontSize: 28,
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Members, cells and duties for the church office, the '
                    'pastors and the leaders.',
                    textAlign: TextAlign.center,
                    style: ChurchType.secondary.copyWith(
                      color: c.muted,
                      fontSize: 15,
                    ),
                  ),
                  const SizedBox(height: 28),
                  SizedBox(
                    width: double.infinity,
                    child: FocusRing(
                      child: FilledButton(
                        key: const Key('landing-sign-in'),
                        onPressed: () => context.go(ClientPaths.signIn),
                        child: const Text('Sign in'),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

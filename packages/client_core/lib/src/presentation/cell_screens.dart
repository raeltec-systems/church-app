import 'package:church_design_system/church_design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../application/cell_controllers.dart';
import '../application/duties_controllers.dart'
    show DutyNotice, myDutiesProvider;
import '../domain/access_grants.dart';
import '../domain/cell_meetings.dart';
import '../domain/cell_membership.dart';
import '../domain/cell_programmes.dart';
import '../domain/church_time.dart';
import '../domain/duties.dart';
import '../domain/membership_application.dart';
import 'church_widgets.dart';

// Story 2.6: cell setup and confirmation on staff web (Admin, leaders) and
// the member's own cell on mobile. Every list comes from a server-checked
// read and every action is a server-checked command; hiding a button is
// never the control.

(StatusTone, String, String) _noticeText(CellNotice n, CellAction? a) {
  final who = a?.subject ?? 'this';
  return switch (n) {
    CellNotice.cellCreated => (
      StatusTone.success,
      'Cell added',
      '$who is set up. Add its leader next.',
    ),
    CellNotice.cellUpdated => (
      StatusTone.success,
      'Cell updated',
      '$who was saved.',
    ),
    CellNotice.staffAssigned => (
      StatusTone.success,
      'Role given',
      '$who can now act for this cell. The change applies on their next step.',
    ),
    CellNotice.staffRemoved => (
      StatusTone.success,
      'Role removed',
      '$who no longer has this cell\'s access.',
    ),
    CellNotice.requested => (
      StatusTone.success,
      'Request sent',
      'Nothing moves until the cell\'s leader or the church office confirms it.',
    ),
    CellNotice.confirmed => (
      StatusTone.success,
      'Confirmed',
      '$who\'s cell is confirmed. Any earlier cell\'s private access ended.',
    ),
    CellNotice.referred => (
      StatusTone.success,
      'Passed to the church office',
      'An Admin will follow up with $who.',
    ),
    CellNotice.declined => (
      StatusTone.success,
      'Not confirmed',
      '$who\'s request was closed.',
    ),
    CellNotice.cancelled => (
      StatusTone.success,
      'Request cancelled',
      'Nothing was changed.',
    ),
    CellNotice.changedElsewhere => (
      StatusTone.warning,
      'Changed elsewhere',
      'This was changed in another tab or by someone else. The list was '
          'reloaded; check it and try again.',
    ),
    CellNotice.openRequest => (
      StatusTone.warning,
      'A request is already open',
      'Wait for it to be decided, or cancel it first.',
    ),
    CellNotice.sameCell => (
      StatusTone.neutral,
      'Already in that cell',
      'Nothing was changed.',
    ),
    CellNotice.selfAction => (
      StatusTone.warning,
      'Not allowed',
      'Someone else must decide your own cell membership. Nothing was changed.',
    ),
    CellNotice.invalid => (
      StatusTone.danger,
      'Check the form',
      'Some answers need fixing before this can be sent.',
    ),
    CellNotice.notAllowed => (
      StatusTone.warning,
      'Not allowed',
      'Your account cannot do this now. Nothing was changed.',
    ),
    CellNotice.signInAgain => (
      StatusTone.warning,
      'Please sign in again',
      'This sign-in is no longer valid. Nothing was changed.',
    ),
    CellNotice.notFound => (
      StatusTone.neutral,
      'Not found',
      'That request or person is gone. The list was reloaded.',
    ),
    CellNotice.notAvailable => (
      StatusTone.neutral,
      'Not available yet',
      'Cell membership cannot be changed here until the church approves '
          'personal data handling.',
    ),
    CellNotice.refused => (
      StatusTone.warning,
      'Not changed',
      'The server refused the change. The list was reloaded.',
    ),
    CellNotice.unconfirmed => (
      StatusTone.warning,
      'Not confirmed',
      'We don\'t know whether the change for $who was made. Check again: '
          'the same request is sent, so it can\'t apply twice.',
    ),
    CellNotice.notSent => (
      StatusTone.neutral,
      'Not sent',
      'This build has no server configured, so nothing was sent.',
    ),
    CellNotice.scheduleSet => (
      StatusTone.success,
      'Schedule saved',
      '$who\'s meetings for the next 12 weeks follow it. Moved and cancelled '
          'meetings keep their changes.',
    ),
    CellNotice.meetingMoved => (
      StatusTone.success,
      'Meeting moved',
      'Only $who changed. Its other weeks stay as they are.',
    ),
    CellNotice.meetingCancelled => (
      StatusTone.success,
      'Meeting cancelled',
      '$who is cancelled. You can bring it back while it is still ahead.',
    ),
    CellNotice.meetingReinstated => (
      StatusTone.success,
      'Meeting brought back',
      '$who is on again at its usual time and venue.',
    ),
    CellNotice.meetingStarted => (
      StatusTone.warning,
      'Already started',
      'That meeting has started, so it can no longer be changed.',
    ),
    CellNotice.alreadyCancelled => (
      StatusTone.warning,
      'Already cancelled',
      'Someone cancelled that meeting already. The list was reloaded.',
    ),
    CellNotice.remindersSet => (
      StatusTone.success,
      'Reminders saved',
      '$who\'s members are reminded at the new times from the next meeting.',
    ),
    CellNotice.programmeCreated => (
      StatusTone.success,
      'Programme started',
      'Add its parts below. Members don\'t see a draft.',
    ),
    CellNotice.programmeSaved => (
      StatusTone.success,
      'Draft saved',
      'Members don\'t see it yet. Parts without a person are shown as gaps.',
    ),
    CellNotice.programmeCancelled => (
      StatusTone.success,
      'Programme cancelled',
      'It is kept, read-only. Anyone it gave a part to is told.',
    ),
    CellNotice.meetingCancelledAlready => (
      StatusTone.warning,
      'Meeting cancelled',
      'That meeting is cancelled, so its programme cannot be planned.',
    ),
    CellNotice.programmeNotDraft => (
      StatusTone.warning,
      'No longer a draft',
      'This programme was published or cancelled elsewhere. The page was '
          'reloaded.',
    ),
    CellNotice.programmePublished => (
      StatusTone.success,
      'Published to members',
      'Members of the cell see it now. Everyone with a part is asked to '
          'accept it.',
    ),
    CellNotice.meetingHasProgramme => (
      StatusTone.warning,
      'Programme published',
      'This meeting\'s programme is published, so the meeting can\'t be moved '
          'or cancelled here. Cancel the programme on Plan first.',
    ),
    CellNotice.leaderConfirmed => (
      StatusTone.success,
      'Confirmed by leader',
      'Recorded as their answer, with your name, how and why.',
    ),
    CellNotice.absenceSent => (
      StatusTone.success,
      'Your leader is told',
      'They know you can\'t come. A part you hold is still yours until you '
          'answer it.',
    ),
    CellNotice.absenceChanged => (
      StatusTone.success,
      'Note changed',
      'Your leader sees the new note.',
    ),
    CellNotice.absenceWithdrawn => (
      StatusTone.success,
      'Glad you can come',
      'Your leader is told you can come after all.',
    ),
    CellNotice.programmePartRefused
        when a?.command == CellRecordCommands.recordLeaders =>
      (
        StatusTone.warning,
        'Not saved',
        'Check the parts below. A change needs a reason, and only members of '
            'this cell can be chosen (name anyone else as a guest).',
      ),
    CellNotice.programmePartRefused => (
      StatusTone.warning,
      'Not published',
      'A part could not be given to its person. See the part below.',
    ),
    CellNotice.meetingRecorded => (
      StatusTone.success,
      'Recorded',
      'The meeting record is saved with your name.',
    ),
    CellNotice.recordCorrected => (
      StatusTone.success,
      'Corrected',
      'The earlier value is kept with its reason.',
    ),
    CellNotice.leadersRecorded => (
      StatusTone.success,
      'Saved',
      'Who led is saved with your name. The plan and duty answers are '
          'unchanged.',
    ),
    CellNotice.handoverResolved => (
      StatusTone.success,
      'Handover done',
      '$who has a leader again.',
    ),
    CellNotice.leaderRequired => (
      StatusTone.warning,
      'Still no leader',
      'Give $who a leader or assistant who can use the app first.',
    ),
    CellNotice.leadsCurrentCell => (
      StatusTone.warning,
      'Leads their cell',
      '$who leads or assists their current cell. Remove that role first '
          '(Admin cells), then move them.',
    ),
    CellNotice.meetingNotStarted => (
      StatusTone.warning,
      'Not started yet',
      'A meeting is recorded once it has started.',
    ),
  };
}

Widget _readProblem<T>(AccessRead<T> r, String needs) => switch (r) {
  AccessReadOk() => const SizedBox.shrink(),
  AccessReadDenied(:final denial) => RequestStateBanner(
    key: Key('cells-denied-${denial.name}'),
    tone: StatusTone.warning,
    icon: Icons.lock_outline,
    title: switch (denial) {
      AccessDenial.signedOut => 'Not signed in',
      AccessDenial.untrustedSession => 'Please sign in again',
      AccessDenial.notGranted => 'Not available to you',
      AccessDenial.notLinked => 'No member access yet',
      AccessDenial.unavailable => 'Not available yet',
      _ => 'Access review required',
    },
    message: denial == AccessDenial.notGranted
        ? '$needs Permissions are checked by the server each time.'
        : 'Nothing is shown until the server allows it.',
  ),
  AccessReadFailed(:final unreachable) => RequestStateBanner(
    key: const Key('cells-failed'),
    tone: StatusTone.danger,
    icon: unreachable ? Icons.cloud_off_outlined : Icons.error_outline,
    title: unreachable ? 'No connection' : 'Couldn\'t load',
    message: unreachable
        ? 'We couldn\'t reach the church server. Nothing is shown until it '
              'answers.'
        : 'The server answered in an unexpected way. Try again later.',
  ),
};

/// The page frame shared by the three cells screens: notice, read problem,
/// content and a reload button.
class _CellsPage<T> extends ConsumerStatefulWidget {
  const _CellsPage({
    required this.title,
    required this.provider,
    required this.needs,
    required this.loading,
    required this.body,
    this.tabRoot = false,
    this.subtitle,
    this.headerAction,
  });

  final String title;

  /// Staff web: one line about the data under the page title.
  final String? subtitle;

  /// Staff web: the screen's main action in the page header.
  final Widget? Function(BuildContext context, T value, CellsState<T> state)?
  headerAction;
  final NotifierProvider<CellsController<T>, CellsState<T>> provider;
  final String needs;
  final String loading;

  /// A member tab (My duties, My cell): the handoff's in-page title with a
  /// refresh button and pull to refresh instead of an app bar and Reload.
  final bool tabRoot;
  final Widget Function(BuildContext context, T value, CellsState<T> state)
  body;

  @override
  ConsumerState<_CellsPage<T>> createState() => _CellsPageState<T>();
}

class _CellsPageState<T> extends ConsumerState<_CellsPage<T>> {
  late final AppLifecycleListener _lifecycle;
  final _noticeFocus = FocusNode(debugLabel: 'cells notice');

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onResume: _reload);
    // Revisiting the screen asks the server again.
    if (ref.read(widget.provider).result != null) Future.microtask(_reload);
  }

  void _reload() {
    if (mounted) ref.read(widget.provider.notifier).reload();
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    _noticeFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = ChurchColors.of(context);
    final layout = ChurchLayout.of(context);
    final s = ref.watch(widget.provider);
    final ctl = ref.read(widget.provider.notifier);
    ref.listen(widget.provider.select((x) => x.notice), (prev, next) {
      if (next == null || next == prev) return;
      final (_, title, message) = _noticeText(
        next,
        ref.read(widget.provider).noticeAction,
      );
      announce(context, '$title. $message');
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _noticeFocus.context != null) {
          _noticeFocus.requestFocus();
        }
      });
    });
    final children = <Widget>[];
    if (s.pending case final p?) {
      children.add(
        RequestStateBanner(
          key: const Key('cells-pending'),
          tone: StatusTone.info,
          busy: true,
          title: 'Sending…',
          message: 'Waiting for the server about ${p.subject}.',
        ),
      );
    } else if (s.notice case final n?) {
      final (tone, title, message) = _noticeText(n, s.noticeAction);
      children.add(
        RequestStateBanner(
          key: Key('cells-notice-${n.name}'),
          focusNode: _noticeFocus,
          tone: tone,
          title: title,
          message: message,
          actions: [
            if (n == CellNotice.unconfirmed)
              BannerAction(
                'Check again',
                ctl.checkAgain,
                key: const Key('cells-check-again'),
                primary: true,
              ),
            BannerAction(
              'Dismiss',
              ctl.dismissNotice,
              key: const Key('cells-dismiss'),
            ),
          ],
        ),
      );
    }
    if (children.isNotEmpty) {
      children.add(const SizedBox(height: ChurchGeometry.sectionGap));
    }
    final result = s.result;
    if (result == null) {
      children.add(
        RequestStateBanner(
          key: const Key('cells-loading'),
          tone: StatusTone.info,
          busy: true,
          title: widget.loading,
          message: 'Asking the church server.',
        ),
      );
    } else if (result case AccessReadOk(:final value)) {
      children.add(widget.body(context, value, s));
    } else {
      children.add(_readProblem(result, widget.needs));
    }
    if (widget.tabRoot) {
      return MemberTabPage(
        title: widget.title,
        reloadKey: const Key('cells-reload'),
        onReload: s.loading || s.busy ? null : ctl.reload,
        children: children,
      );
    }
    // On the phone a pushed screen refreshes from its bar (and by pulling);
    // staff web has Reload in the page header, after the main action.
    final phone = !identical(layout, ChurchLayout.staff);
    final reload = s.loading || s.busy ? null : ctl.reload;
    final main = switch ((widget.headerAction, result)) {
      (final f?, AccessReadOk(:final value)) when !phone => f(
        context,
        value,
        s,
      ),
      _ => null,
    };
    return ChurchPageScaffold(
      title: widget.title,
      subtitle: widget.subtitle,
      actions: phone
          ? [
              FocusRing(
                radius: 22,
                child: IconButton(
                  key: const Key('cells-reload'),
                  tooltip: 'Reload',
                  onPressed: reload,
                  icon: const Icon(Icons.refresh),
                ),
              ),
              const SizedBox(width: 4),
            ]
          : [?main, staffReloadButton(const Key('cells-reload'), reload)],
      body: SafeArea(
        child: RefreshIndicator(
          notificationPredicate: (n) => phone && n.depth == 0,
          onRefresh: () async => reload?.call(),
          child: SingleChildScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: layout.pagePadding,
            child: Center(
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
        ),
      ),
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => ChurchCard(
    radius: identical(ChurchLayout.of(context), ChurchLayout.staff)
        ? 12
        : ChurchGeometry.mobileCardRadius,
    child: child,
  );
}

Widget _heading(BuildContext context, String text, {Key? key}) => Padding(
  padding: const EdgeInsets.only(bottom: 8),
  child: Semantics(
    header: true,
    child: Text(
      text,
      key: key,
      style: ChurchType.cardTitle.copyWith(color: ChurchColors.of(context).ink),
    ),
  ),
);

Widget _muted(BuildContext context, String text) => Text(
  text,
  style: ChurchType.secondary.copyWith(color: ChurchColors.of(context).muted),
);

String _asked(String choice, String? cellName) => switch (choice) {
  'cell' => 'Asked for ${cellName ?? 'a cell'}',
  'not_sure' => 'Not sure which cell',
  _ => 'Not in a cell yet',
};

// ---------------------------------------------------------------------------
// Staff web, Admin: cells, leaders, requests and the follow-up queue
// ---------------------------------------------------------------------------

/// Story 2.6, staff web, Admin only: set up cells, give leader and assistant
/// scopes (through the audited 2.3 grant command), confirm or decline open
/// requests, and resolve the follow-up queue (no cell chosen, or passed on
/// by a leader). Cell membership is confirmed separately from church
/// approval. The Admin role gives no cell-private content.
class CellAdminScreen extends StatelessWidget {
  const CellAdminScreen({super.key});

  @override
  Widget build(BuildContext context) => _CellsPage<CellAdminOverview>(
    title: 'Cells',
    subtitle: 'Leaders, requests to join and confirmed membership',
    provider: cellAdminProvider,
    needs: 'Cells needs the Admin role.',
    loading: 'Loading cells…',
    body: (context, o, s) => _AdminBody(overview: o, state: s),
  );
}

/// The handoff's two panes: the cells down the left (each with its open
/// requests counted), the chosen cell on the right with its leaders, its
/// requests to join and its confirmed members. Requests with no cell (the
/// church office's follow-up) come first, across the page.
class _AdminBody extends ConsumerStatefulWidget {
  const _AdminBody({required this.overview, required this.state});
  final CellAdminOverview overview;
  final CellsState<CellAdminOverview> state;

  @override
  ConsumerState<_AdminBody> createState() => _AdminBodyState();
}

class _AdminBodyState extends ConsumerState<_AdminBody> {
  String? _selected;

  @override
  Widget build(BuildContext context) {
    final overview = widget.overview;
    final state = widget.state;
    final c = ChurchColors.of(context);
    // A request for a cell that is not on the list is handled with the
    // follow-up, so nothing waits out of sight.
    final followUp = overview.requests
        .where((r) => r.followUp || overview.cell(r.requestedCellId) == null)
        .toList();
    final waiting = overview.requests
        .where((r) => !r.followUp && overview.cell(r.requestedCellId) != null)
        .toList();
    final selected =
        overview.cell(_selected) ??
        (overview.cells.isEmpty ? null : overview.cells.first);
    List<AdminCellRequest> waitingFor(AdminCell cell) =>
        waiting.where((r) => r.requestedCellId == cell.cellId).toList();

    final followUpBlock = _Card(
      key: const Key('follow-up-block'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _heading(
            context,
            'Follow-up (${followUp.length})',
            key: const Key('follow-up-heading'),
          ),
          _muted(
            context,
            'No cell chosen yet, or the leader passed it to the church '
            'office. Confirm into the cell you checked with its leader, or '
            'close it.',
          ),
          const SizedBox(height: 8),
          if (followUp.isEmpty)
            Text(
              'Nothing to follow up.',
              key: const Key('no-follow-up'),
              style: ChurchType.staffBody.copyWith(color: c.muted),
            ),
          for (var i = 0; i < followUp.length; i++)
            _AdminRequestCard(
              key: Key(
                'admin-request-${followUp[i].requestId}-r'
                '${followUp[i].memberRevision}',
              ),
              request: followUp[i],
              overview: overview,
              busy: state.busy,
              divider: i > 0,
            ),
        ],
      ),
    );

    final list = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 0, 4, 4),
          child: Text(
            overview.cells.length == 1
                ? '1 cell'
                : '${overview.cells.length} cells',
            style: ChurchType.secondary.copyWith(color: c.muted),
          ),
        ),
        for (final cell in overview.cells)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: _CellListItem(
              cell: cell,
              requests: waitingFor(cell).length,
              selected: cell.cellId == selected?.cellId,
              onTap: () => setState(() => _selected = cell.cellId),
            ),
          ),
        const SizedBox(height: 4),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: _CreateCellForm(busy: state.busy),
        ),
      ],
    );

    final Widget detail;
    if (selected == null) {
      detail = _Card(
        child: Text(
          'No cells yet. Add the first one; it needs a leader before members '
          'can be confirmed into it.',
          key: const Key('no-cells'),
          style: ChurchType.staffBody.copyWith(color: c.muted),
        ),
      );
    } else {
      final requests = waitingFor(selected);
      final roster =
          overview.members.where((m) => m.cellId == selected.cellId).toList()
            ..sort((a, b) => a.displayName.compareTo(b.displayName));
      detail = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _AdminCellCard(
            key: Key('admin-cell-${selected.cellId}-r${selected.revision}'),
            cell: selected,
            overview: overview,
            busy: state.busy,
          ),
          const SizedBox(height: 16),
          _Card(
            key: Key('cell-requests-${selected.cellId}'),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _heading(context, 'Requests to join (${requests.length})'),
                _muted(
                  context,
                  'The cell\'s leader confirms these. You may confirm after '
                  'checking with the leader.',
                ),
                const SizedBox(height: 8),
                if (requests.isEmpty)
                  Text(
                    'No requests are waiting.',
                    key: const Key('no-waiting'),
                    style: ChurchType.staffBody.copyWith(color: c.muted),
                  ),
                for (var i = 0; i < requests.length; i++)
                  _AdminRequestCard(
                    key: Key(
                      'admin-request-${requests[i].requestId}-r'
                      '${requests[i].memberRevision}',
                    ),
                    request: requests[i],
                    overview: overview,
                    busy: state.busy,
                    divider: i > 0,
                  ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          _Card(
            key: Key('cell-roster-${selected.cellId}'),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _heading(
                  context,
                  'Confirmed members (${selected.memberCount})',
                ),
                if (roster.isEmpty)
                  _muted(
                    context,
                    selected.memberCount == 0
                        ? 'Nobody is confirmed in this cell yet.'
                        : 'Their names are not in this list.',
                  )
                else ...[
                  if (roster.length != selected.memberCount)
                    _muted(
                      context,
                      'Showing ${roster.length} of ${selected.memberCount}.',
                    ),
                  const SizedBox(height: 4),
                  LayoutBuilder(
                    builder: (context, box) {
                      final perRow = (box.maxWidth / 220).floor().clamp(1, 4);
                      final w = (box.maxWidth - (perRow - 1) * 12) / perRow;
                      return Wrap(
                        spacing: 12,
                        runSpacing: 10,
                        children: [
                          for (final m in roster)
                            SizedBox(
                              width: w,
                              child: Row(
                                children: [
                                  InitialsAvatar(name: m.displayName, size: 32),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: Text(
                                      m.displayName,
                                      overflow: TextOverflow.ellipsis,
                                      style: ChurchType.staffBody.copyWith(
                                        color: c.ink,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                        ],
                      );
                    },
                  ),
                ],
              ],
            ),
          ),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        followUpBlock,
        const SizedBox(height: ChurchGeometry.sectionGap),
        LayoutBuilder(
          builder: (context, box) {
            if (box.maxWidth < 860) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  list,
                  const SizedBox(height: ChurchGeometry.sectionGap),
                  detail,
                ],
              );
            }
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(width: 300, child: list),
                const SizedBox(width: 20),
                Expanded(child: detail),
              ],
            );
          },
        ),
        const SizedBox(height: ChurchGeometry.sectionGap),
        _MoveMemberForm(overview: overview, busy: state.busy),
      ],
    );
  }
}

/// One cell in the left pane: name, area and members, its leader, and the
/// requests waiting for it; the chosen one has the handoff's 2 px blue edge.
class _CellListItem extends StatelessWidget {
  const _CellListItem({
    required this.cell,
    required this.requests,
    required this.selected,
    required this.onTap,
  });

  final AdminCell cell;
  final int requests;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = ChurchColors.of(context);
    final leader = cell.leaders.isEmpty
        ? null
        : cell.leaders.map((s) => s.displayName).join(', ');
    return Semantics(
      selected: selected,
      button: true,
      child: FocusRing(
        radius: 14,
        child: Material(
          color: c.surface,
          shape: RoundedRectangleBorder(
            side: BorderSide(
              color: selected ? c.accent : c.line,
              width: selected ? 2 : 1,
            ),
            borderRadius: BorderRadius.circular(12),
          ),
          child: InkWell(
            key: Key('cell-list-${cell.cellId}'),
            onTap: onTap,
            borderRadius: BorderRadius.circular(12),
            child: Padding(
              padding: EdgeInsets.all(selected ? 13 : 14),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          cell.name,
                          style: ChurchType.staffBody.copyWith(
                            color: c.ink,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '${cell.broadArea} · ${cell.memberCount} '
                          '${cell.memberCount == 1 ? 'member' : 'members'}',
                          style: ChurchType.secondary.copyWith(
                            color: c.muted,
                            fontSize: 13,
                          ),
                        ),
                        Text(
                          cell.handoverPending
                              ? 'Needs a leader'
                              : leader == null
                              ? 'No leader yet'
                              : 'Leader $leader',
                          style: ChurchType.secondary.copyWith(
                            color: cell.handoverPending || leader == null
                                ? c.amberFg
                                : c.muted,
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (requests > 0) ...[
                    const SizedBox(width: 8),
                    Semantics(
                      label: '$requests waiting',
                      excludeSemantics: true,
                      child: StaffNavBadge(count: requests),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// One request to join or move: who, what they asked, and the decision (the
/// cell checked, Confirm cell, or close it). A row inside its section.
class _AdminRequestCard extends ConsumerStatefulWidget {
  const _AdminRequestCard({
    super.key,
    required this.request,
    required this.overview,
    required this.busy,
    this.divider = false,
  });
  final AdminCellRequest request;
  final CellAdminOverview overview;
  final bool busy;
  final bool divider;

  @override
  ConsumerState<_AdminRequestCard> createState() => _AdminRequestCardState();
}

class _AdminRequestCardState extends ConsumerState<_AdminRequestCard> {
  late String? _cellId = widget.request.requestedCellId;

  @override
  Widget build(BuildContext context) {
    final c = ChurchColors.of(context);
    final r = widget.request;
    final ctl = ref.read(cellAdminProvider.notifier);
    final id = r.requestId;
    final can = !widget.busy && !r.ownRecord;
    final active = widget.overview.cells.where((c) => c.active).toList();
    final detail = [
      _asked(r.choice, r.requestedCellName),
      if (r.currentCellName != null) 'now in ${r.currentCellName}',
      if (r.referred)
        'passed on by the leader'
            '${r.reason == null ? '' : ': ${r.reason!.label}'}',
    ].join(' · ');
    return Container(
      key: Key('admin-request-card-$id'),
      padding: const EdgeInsets.symmetric(vertical: 12),
      decoration: BoxDecoration(
        border: widget.divider ? Border(top: BorderSide(color: c.line)) : null,
      ),
      child: Wrap(
        spacing: 16,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        alignment: WrapAlignment.spaceBetween,
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 220, maxWidth: 420),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      r.displayName,
                      style: ChurchType.staffBody.copyWith(
                        color: c.ink,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    StatusLabel(
                      label: r.kind == 'change' ? 'Change of cell' : 'Joining',
                      tone: r.referred ? StatusTone.warning : StatusTone.info,
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  detail,
                  style: ChurchType.secondary.copyWith(color: c.muted),
                ),
                if (r.ownRecord)
                  Text(
                    'Your own record: someone else must decide this',
                    style: ChurchType.secondary.copyWith(color: c.amberFg),
                  ),
              ],
            ),
          ),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              DropdownButton<String>(
                key: Key('confirm-cell-$id'),
                hint: const Text('Choose the cell you checked'),
                value: _cellId,
                items: [
                  for (final c in active)
                    DropdownMenuItem(value: c.cellId, child: Text(c.name)),
                ],
                onChanged: can ? (v) => setState(() => _cellId = v) : null,
              ),
              FocusRing(
                child: FilledButton(
                  key: Key('admin-confirm-$id'),
                  onPressed: can && _cellId != null
                      ? () => ctl.confirm(r, cellId: _cellId)
                      : null,
                  child: const Text('Confirm cell'),
                ),
              ),
              FocusRing(
                child: OutlinedButton(
                  key: Key('admin-decline-$id'),
                  onPressed: can
                      ? () => ctl.decline(r, CellDeclineReason.noCellForNow)
                      : null,
                  child: const Text('Close: no cell for now'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _AdminCellCard extends ConsumerStatefulWidget {
  const _AdminCellCard({
    super.key,
    required this.cell,
    required this.overview,
    required this.busy,
  });
  final AdminCell cell;
  final CellAdminOverview overview;
  final bool busy;

  @override
  ConsumerState<_AdminCellCard> createState() => _AdminCellCardState();
}

class _AdminCellCardState extends ConsumerState<_AdminCellCard> {
  String? _memberId;
  String _kind = CellScopeKinds.leader;

  @override
  Widget build(BuildContext context) {
    final c = ChurchColors.of(context);
    final cell = widget.cell;
    final ctl = ref.read(cellAdminProvider.notifier);
    final id = cell.cellId;
    final busy = widget.busy;
    CellMemberRow? picked;
    for (final m in widget.overview.members) {
      if (m.memberId == _memberId) picked = m;
    }
    Widget staffRow(CellStaff st, String kind) => Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Row(
        children: [
          InitialsAvatar(name: st.displayName, size: 32),
          const SizedBox(width: 10),
          Expanded(
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: st.displayName,
                    style: ChurchType.staffBody.copyWith(
                      color: c.ink,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  TextSpan(
                    text: kind == CellScopeKinds.leader
                        ? '  Leader'
                        : '  Assistant',
                    style: ChurchType.secondary.copyWith(color: c.muted),
                  ),
                ],
              ),
            ),
          ),
          FocusRing(
            child: TextButton(
              key: Key('remove-$kind-$id-${st.memberId}'),
              onPressed: busy ? null : () => ctl.removeStaff(cell, st, kind),
              child: const Text('Remove'),
            ),
          ),
        ],
      ),
    );
    Widget fact(String label, String value) => Expanded(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: ChurchType.secondary.copyWith(
                color: c.muted,
                fontSize: 13,
              ),
            ),
            const SizedBox(height: 2),
            Text(value, style: ChurchType.staffBody.copyWith(color: c.ink)),
          ],
        ),
      ),
    );
    return _Card(
      key: Key('admin-cell-card-$id'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Semantics(
                      header: true,
                      child: Text(
                        cell.name,
                        style: ChurchType.cardTitle.copyWith(color: c.ink),
                      ),
                    ),
                    StatusLabel(
                      label: cell.listed ? 'Listed for sign-up' : 'Not listed',
                      tone: cell.listed
                          ? StatusTone.success
                          : StatusTone.neutral,
                    ),
                    if (cell.isSynthetic)
                      Text(
                        'Synthetic test record',
                        style: ChurchType.secondary.copyWith(
                          color: c.muted,
                          fontSize: 13,
                        ),
                      ),
                  ],
                ),
              ),
              FocusRing(
                child: TextButton(
                  key: Key('toggle-listed-$id'),
                  onPressed: busy
                      ? null
                      : () => ctl.setListed(cell, !cell.listed),
                  child: Text(
                    cell.listed ? 'Hide from sign-up' : 'List for sign-up',
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          // What the church and applicants know of the cell, as one divided
          // strip.
          Container(
            decoration: BoxDecoration(
              color: c.bg,
              borderRadius: BorderRadius.circular(10),
            ),
            child: IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  fact('Broad area', cell.broadArea),
                  VerticalDivider(width: 1, color: c.line),
                  fact('Shown at sign-up as', cell.signupLabel ?? '—'),
                  VerticalDivider(width: 1, color: c.line),
                  fact('Confirmed members', '${cell.memberCount}'),
                ],
              ),
            ),
          ),
          // Story 5.9: the cell's last leader left with a programme published
          // ahead; once it has a leader or assistant again, mark it done.
          if (cell.handoverPending) ...[
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.fromLTRB(12, 6, 6, 6),
              decoration: BoxDecoration(
                color: c.amberBg,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  StatusLabel(
                    key: Key('cell-handover-$id'),
                    label: 'Needs a leader: a programme is published ahead',
                    tone: StatusTone.warning,
                  ),
                  FocusRing(
                    child: OutlinedButton(
                      key: Key('cell-handover-done-$id'),
                      onPressed: busy ? null : () => ctl.resolveHandover(cell),
                      child: const Text('Mark handover done'),
                    ),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 14),
          CardLabel('Leader and assistants'),
          const SizedBox(height: 6),
          if (cell.leaders.isEmpty)
            _muted(context, 'No leader yet: only an Admin can confirm.'),
          for (final st in cell.leaders) staffRow(st, CellScopeKinds.leader),
          for (final st in cell.assistants)
            staffRow(st, CellScopeKinds.assistant),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              DropdownButton<String>(
                key: Key('staff-member-$id'),
                hint: const Text('Choose a member'),
                value: _memberId,
                items: [
                  for (final m in widget.overview.members)
                    DropdownMenuItem(
                      value: m.memberId,
                      child: Text(m.displayName),
                    ),
                ],
                onChanged: busy ? null : (v) => setState(() => _memberId = v),
              ),
              DropdownButton<String>(
                key: Key('staff-kind-$id'),
                value: _kind,
                items: const [
                  DropdownMenuItem(
                    value: CellScopeKinds.leader,
                    child: Text('Leader'),
                  ),
                  DropdownMenuItem(
                    value: CellScopeKinds.assistant,
                    child: Text('Assistant'),
                  ),
                ],
                onChanged: busy
                    ? null
                    : (v) => setState(() => _kind = v ?? _kind),
              ),
              FocusRing(
                child: OutlinedButton(
                  key: Key('assign-staff-$id'),
                  onPressed: busy || picked == null
                      ? null
                      : () => ctl.assignStaff(cell, picked!, _kind),
                  child: const Text('Give this role'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _CreateCellForm extends ConsumerStatefulWidget {
  const _CreateCellForm({required this.busy});
  final bool busy;

  @override
  ConsumerState<_CreateCellForm> createState() => _CreateCellFormState();
}

class _CreateCellFormState extends ConsumerState<_CreateCellForm> {
  final _name = TextEditingController();
  final _label = TextEditingController();
  final _area = TextEditingController();

  @override
  void dispose() {
    _name.dispose();
    _label.dispose();
    _area.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final errors = ref.watch(cellAdminProvider.select((s) => s.fieldErrors));
    String? err(String k) => switch (errors[k]) {
      null => null,
      'required' => 'Required',
      _ =>
        'Check this (while personal data is not approved, start with '
            '"SYNTHETIC ")',
    };
    Widget field(
      String key,
      TextEditingController c,
      String label,
      String wire,
    ) => Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: TextField(
        key: Key(key),
        controller: c,
        enabled: !widget.busy,
        maxLength: 80,
        decoration: InputDecoration(labelText: label, errorText: err(wire)),
      ),
    );
    return _Card(
      key: const Key('create-cell'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _heading(context, 'Add a cell'),
          _muted(
            context,
            'The sign-up label and broad area are all an applicant sees. '
            'Never put a home address or phone number here.',
          ),
          const SizedBox(height: 8),
          field('create-cell-name', _name, 'Cell name (staff)', 'name'),
          field(
            'create-cell-label',
            _label,
            'Label shown at sign-up',
            'signup_label',
          ),
          field('create-cell-area', _area, 'Broad area', 'broad_area'),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: ListenableBuilder(
              listenable: Listenable.merge([_name, _label, _area]),
              builder: (context, _) {
                final ok = [
                  _name,
                  _label,
                  _area,
                ].every((c) => c.text.trim().isNotEmpty);
                return FocusRing(
                  child: FilledButton(
                    key: const Key('create-cell-save'),
                    onPressed: widget.busy || !ok
                        ? null
                        : () => ref
                              .read(cellAdminProvider.notifier)
                              .createCell(
                                name: _name.text,
                                signupLabel: _label.text,
                                broadArea: _area.text,
                              ),
                    child: const Text('Add cell'),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// Opens a join/move request for a member (for example one without a login);
/// it then waits for the cell's leader or an Admin like any request.
class _MoveMemberForm extends ConsumerStatefulWidget {
  const _MoveMemberForm({required this.overview, required this.busy});
  final CellAdminOverview overview;
  final bool busy;

  @override
  ConsumerState<_MoveMemberForm> createState() => _MoveMemberFormState();
}

class _MoveMemberFormState extends ConsumerState<_MoveMemberForm> {
  String? _memberId;
  String? _cellId;

  @override
  Widget build(BuildContext context) {
    final o = widget.overview;
    CellMemberRow? member;
    for (final m in o.members) {
      if (m.memberId == _memberId) member = m;
    }
    final cell = o.cell(_cellId);
    final listed = o.cells.where((c) => c.signupRevision != null).toList();
    return _Card(
      key: const Key('move-member'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _heading(context, 'Request a cell for a member'),
          _muted(
            context,
            'For someone without the app, or a change agreed with them. The '
            'request still needs the cell\'s leader or an Admin to confirm.',
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              DropdownButton<String>(
                key: const Key('move-member-member'),
                hint: const Text('Member'),
                value: _memberId,
                items: [
                  for (final m in o.members)
                    DropdownMenuItem(
                      value: m.memberId,
                      child: Text(
                        '${m.displayName}'
                        '${m.cellId == null ? '' : ' (${o.cell(m.cellId)?.name ?? 'in a cell'})'}',
                      ),
                    ),
                ],
                onChanged: widget.busy
                    ? null
                    : (v) => setState(() => _memberId = v),
              ),
              DropdownButton<String>(
                key: const Key('move-member-cell'),
                hint: const Text('Cell'),
                value: _cellId,
                items: [
                  for (final c in listed)
                    DropdownMenuItem(value: c.cellId, child: Text(c.name)),
                ],
                onChanged: widget.busy
                    ? null
                    : (v) => setState(() => _cellId = v),
              ),
              FocusRing(
                child: OutlinedButton(
                  key: const Key('move-member-send'),
                  onPressed:
                      widget.busy ||
                          member == null ||
                          cell == null ||
                          member.openRequestId != null
                      ? null
                      : () => ref
                            .read(cellAdminProvider.notifier)
                            .requestFor(member!, cell),
                  child: const Text('Send request'),
                ),
              ),
            ],
          ),
          if (member?.openRequestId != null)
            _muted(context, 'This member already has an open request above.'),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Staff web, leaders and assistants
// ---------------------------------------------------------------------------

/// Story 2.6, staff web: the cells the caller leads or assists. A leader
/// confirms the requests for their own cell (joining or moving in), or
/// passes one to the church office; nobody confirms their own membership.
/// The page answers "who is waiting to join my cell?" first: the requests
/// with their two decisions, then the cell's confirmed members.
class CellLeaderScreen extends StatelessWidget {
  const CellLeaderScreen({super.key});

  @override
  Widget build(BuildContext context) => _CellsPage<LeaderQueue>(
    title: 'My cell group',
    subtitle: 'Your cell\'s members and requests to join',
    provider: cellLeaderProvider,
    needs: 'This page is for cell leaders and assistants.',
    loading: 'Loading your cell…',
    body: (context, q, s) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (q.cells.isEmpty)
          _Card(
            child: Text(
              'You don\'t lead or assist a cell right now.',
              key: const Key('leader-no-cells'),
              style: ChurchType.staffBody.copyWith(
                color: ChurchColors.of(context).muted,
              ),
            ),
          ),
        for (var i = 0; i < q.cells.length; i++) ...[
          if (i > 0) const SizedBox(height: 32),
          _LeaderCellCard(cell: q.cells[i], busy: s.busy),
        ],
      ],
    ),
  );
}

/// One cell the caller leads or assists: its name and area, the requests to
/// join (leaders only: assistants read), then the confirmed members.
class _LeaderCellCard extends ConsumerWidget {
  const _LeaderCellCard({required this.cell, required this.busy});
  final LeaderCell cell;
  final bool busy;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = ChurchColors.of(context);
    final waiting = cell.requests.length;
    final members = cell.members.length;
    return Column(
      key: Key('leader-cell-${cell.cellId}'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          header: true,
          child: Text(
            cell.name,
            style: ChurchType.sectionTitle.copyWith(color: c.ink, fontSize: 20),
          ),
        ),
        const SizedBox(height: 2),
        Text(
          [
            cell.broadArea,
            _mtgPlural(members, 'member'),
            cell.isLeader ? 'You lead this cell' : 'You assist this cell',
          ].join(' · '),
          style: ChurchType.secondary.copyWith(color: c.muted),
        ),
        const SizedBox(height: 14),
        if (cell.isLeader) ...[
          StaffSection(
            title: 'Requests to join',
            subtitle:
                'Confirm people you know belong to this cell. Anyone you '
                'don\'t know goes to the church office.',
            trailing: Text(
              waiting == 0 ? 'None waiting' : '$waiting waiting',
              style: ChurchType.figures.copyWith(
                color: waiting == 0 ? c.muted : c.ink,
              ),
            ),
            bodyPadding: EdgeInsets.zero,
            child: cell.requests.isEmpty
                ? Padding(
                    padding: const EdgeInsets.fromLTRB(20, 16, 20, 18),
                    child: Text(
                      'No one is waiting.',
                      key: Key('leader-no-requests-${cell.cellId}'),
                      style: ChurchType.staffBody.copyWith(color: c.muted),
                    ),
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (var i = 0; i < cell.requests.length; i++)
                        _leadRequestRow(
                          context,
                          ref,
                          cell.requests[i],
                          divider: i > 0,
                        ),
                    ],
                  ),
          ),
          const SizedBox(height: 16),
        ],
        StaffSection(
          title: 'Members',
          trailing: Text(
            '$members',
            style: ChurchType.figures.copyWith(color: c.muted),
          ),
          child: cell.members.isEmpty
              ? Text(
                  'No confirmed members yet.',
                  style: ChurchType.staffBody.copyWith(color: c.muted),
                )
              : LayoutBuilder(
                  builder: (context, box) {
                    final perRow = (box.maxWidth / 220).floor().clamp(1, 4);
                    final w = (box.maxWidth - (perRow - 1) * 12) / perRow;
                    return Wrap(
                      spacing: 12,
                      runSpacing: 12,
                      children: [
                        for (final m in cell.members)
                          SizedBox(
                            width: w,
                            child: Row(
                              children: [
                                InitialsAvatar(name: m.displayName, size: 32),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Text(
                                    m.displayName,
                                    key: Key(
                                      'roster-${cell.cellId}-${m.memberId}',
                                    ),
                                    overflow: TextOverflow.ellipsis,
                                    style: ChurchType.staffBody.copyWith(
                                      color: c.ink,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                      ],
                    );
                  },
                ),
        ),
      ],
    );
  }

  /// One request: who, what they asked (one pale pill), and the two
  /// decisions on the right (below on a phone).
  Widget _leadRequestRow(
    BuildContext context,
    WidgetRef ref,
    LeaderRequest r, {
    required bool divider,
  }) {
    final c = ChurchColors.of(context);
    final ctl = ref.read(cellLeaderProvider.notifier);
    final can = !busy && !r.ownRecord;
    final who = Row(
      children: [
        InitialsAvatar(name: r.displayName, size: 36),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: 8,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(
                    r.displayName,
                    style: ChurchType.staffBody.copyWith(
                      color: c.ink,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  StatusLabel(
                    label: r.kind == 'change'
                        ? 'Moving from another cell'
                        : 'Joining',
                    tone: StatusTone.info,
                  ),
                ],
              ),
              if (r.ownRecord) ...[
                const SizedBox(height: 2),
                Wrap(
                  spacing: 6,
                  children: [
                    Text(
                      'Your own request',
                      style: ChurchType.secondary.copyWith(
                        color: c.amberFg,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      'Someone else must decide it.',
                      style: ChurchType.secondary.copyWith(color: c.muted),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ],
    );
    Widget actions(WrapAlignment align) => Wrap(
      spacing: 8,
      runSpacing: 8,
      alignment: align,
      children: [
        FocusRing(
          child: FilledButton(
            key: Key('leader-confirm-${r.requestId}'),
            style: _mtgCompact(),
            onPressed: can ? () => ctl.confirm(r) : null,
            child: const Text('Confirm in this cell'),
          ),
        ),
        FocusRing(
          child: OutlinedButton(
            key: Key('leader-refer-${r.requestId}'),
            style: _mtgCompact(),
            onPressed: can
                ? () => ctl.refer(r, CellDeclineReason.notKnownToLeader)
                : null,
            child: const Text('I don\'t know them: ask the office'),
          ),
        ),
      ],
    );
    return StaffTableRow(
      key: Key('leader-request-${r.requestId}'),
      divider: divider,
      minHeight: 64,
      child: LayoutBuilder(
        builder: (context, box) => box.maxWidth < 640
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  who,
                  const SizedBox(height: 8),
                  actions(WrapAlignment.start),
                ],
              )
            : Row(
                children: [
                  Expanded(child: who),
                  const SizedBox(width: 16),
                  actions(WrapAlignment.end),
                ],
              ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Mobile: the member's own cell
// ---------------------------------------------------------------------------

/// Story 2.6, mobile: the member's confirmed cell (separate from church
/// membership), their open request, and a request to join or change cell.
/// A request moves nobody until the cell's leader or the church office
/// confirms it.
class MyCellScreen extends StatelessWidget {
  const MyCellScreen({super.key});

  @override
  Widget build(BuildContext context) => _CellsPage<MyCellView>(
    title: 'My cell',
    tabRoot: true,
    provider: myCellProvider,
    needs: 'Your cell is shown once you have member access.',
    loading: 'Loading your cell…',
    body: (context, v, s) => _MyCellBody(view: v, busy: s.busy),
  );
}

class _MyCellBody extends ConsumerStatefulWidget {
  const _MyCellBody({required this.view, required this.busy});
  final MyCellView view;
  final bool busy;

  @override
  ConsumerState<_MyCellBody> createState() => _MyCellBodyState();
}

class _MyCellBodyState extends ConsumerState<_MyCellBody> {
  String? _optionId;
  bool _changing = false;

  /// A quiet pill on the navy hero.
  Widget _heroPill(String text, {IconData? icon}) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
    decoration: BoxDecoration(
      color: Colors.white.withValues(alpha: 0.14),
      borderRadius: BorderRadius.circular(99),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (icon != null) ...[
          Icon(icon, size: 14, color: Colors.white),
          const SizedBox(width: 4),
        ],
        Flexible(
          child: Text(
            text,
            style: ChurchType.chip.copyWith(color: Colors.white),
          ),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final cell = widget.view.cell;
    final ctl = ref.read(myCellProvider.notifier);
    final open = cell.openRequest;
    final primary = cell.primary;
    final optionsRead = widget.view.options;
    final choices = switch (optionsRead) {
      AccessReadOk(:final value) =>
        value.where((o) => o.cellId != primary?.cellId).toList(),
      _ => const <CellOption>[],
    };
    CellOption? picked;
    for (final o in choices) {
      if (o.cellId == _optionId) picked = o;
    }
    final soft = Colors.white.withValues(alpha: 0.8);
    // Story 2.6: no request form until the member asks for it (a member with
    // no cell sees it straight away).
    final showForm = primary == null || _changing;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        KeyedSubtree(
          key: const Key('my-cell-current'),
          child: primary == null
              ? _Card(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _heading(context, 'Cell group'),
                      const Text(
                        'No confirmed cell yet.',
                        key: Key('my-cell-none'),
                      ),
                      const SizedBox(height: 8),
                      _muted(
                        context,
                        'Your church membership and your cell are confirmed '
                        'separately.',
                      ),
                    ],
                  ),
                )
              : HeroCard(
                  watermark: HeroWatermark.corner,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Semantics(
                        header: true,
                        child: Text(
                          primary.label,
                          key: const Key('my-cell-label'),
                          style: ChurchType.mobileScreenTitle.copyWith(
                            color: Colors.white,
                            fontSize: 24,
                          ),
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        primary.broadArea,
                        style: ChurchType.body.copyWith(color: soft),
                      ),
                      const SizedBox(height: 14),
                      Wrap(
                        spacing: 8,
                        runSpacing: 6,
                        children: [
                          _heroPill('Confirmed', icon: Icons.check),
                          if (DateTime.tryParse(primary.since) case final at?)
                            _heroPill(
                              'Member since '
                              '${_monthsShort[ChurchTime.wall(at).month - 1]} '
                              '${ChurchTime.wall(at).year}',
                            ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Text(
                        'Your church membership and your cell are confirmed '
                        'separately.',
                        style: ChurchType.secondary.copyWith(color: soft),
                      ),
                    ],
                  ),
                ),
        ),
        const SizedBox(height: 16),
        // Story 5.1: when and where the cell meets next is the member's
        // first question after which cell.
        if (cell.meetings case final meetings?) ...[
          _NextMeetingCard(meetings: meetings),
          const SizedBox(height: 16),
          // Story 5.5: the next meeting's programme, the member's own part
          // first ("You're on") with its real answer.
          if (meetings.next case final next?) ...[
            _MyCellProgrammeCard(
              key: ValueKey('my-cell-programme-${next.meetingId}'),
              meetingId: next.meetingId,
            ),
            const SizedBox(height: 16),
          ],
        ],
        const SizedBox(height: 12),
        if (open != null)
          _Card(
            key: const Key('my-cell-request'),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _heading(context, 'Your request'),
                Text(
                  open.choice == 'cell'
                      ? '${open.kind == 'change' ? 'Move to' : 'Join'} '
                            '${open.label ?? 'a cell'}'
                      : _asked(open.choice, null),
                ),
                StatusLabel(
                  label: open.referred || open.choice != 'cell'
                      ? 'With the church office'
                      : 'Waiting for the cell leader',
                  tone: StatusTone.info,
                ),
                const SizedBox(height: 8),
                FocusRing(
                  child: OutlinedButton(
                    key: const Key('my-cell-cancel'),
                    onPressed: widget.busy
                        ? null
                        : () => ctl.cancel(cell, open),
                    child: const Text('Cancel my request'),
                  ),
                ),
              ],
            ),
          )
        else ...[
          if (cell.lastDecision case final d? when d.state == 'declined')
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: StatusLabel(
                key: const Key('my-cell-declined'),
                label:
                    'Your last request was not confirmed'
                    '${d.reason == null ? '' : ': ${d.reason!.label}'}',
                tone: StatusTone.neutral,
              ),
            ),
          if (!showForm)
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: FocusRing(
                child: OutlinedButton.icon(
                  key: const Key('my-cell-change-open'),
                  onPressed: widget.busy
                      ? null
                      : () => setState(() => _changing = true),
                  icon: const Icon(Icons.swap_horiz),
                  label: const Text('Ask to change cell'),
                ),
              ),
            )
          else
            _Card(
              key: const Key('my-cell-change'),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _heading(
                    context,
                    primary == null
                        ? 'Ask to join a cell'
                        : 'Ask to change cell',
                  ),
                  if (optionsRead is! AccessReadOk<List<CellOption>>) ...[
                    // The chooser read failed or was refused: say so, never
                    // pretend that no cells are listed.
                    KeyedSubtree(
                      key: const Key('my-cell-options-problem'),
                      child: _readProblem(
                        optionsRead,
                        'The cell list is not available to you.',
                      ),
                    ),
                    const SizedBox(height: 8),
                    FocusRing(
                      child: OutlinedButton.icon(
                        key: const Key('my-cell-options-retry'),
                        onPressed: widget.busy ? null : ctl.reload,
                        icon: const Icon(Icons.refresh),
                        label: const Text('Try again'),
                      ),
                    ),
                  ] else if (choices.isEmpty)
                    const Text(
                      'No other cells are listed right now.',
                      key: Key('my-cell-no-options'),
                    )
                  else
                    RadioGroup<String>(
                      groupValue: _optionId,
                      onChanged: (v) {
                        if (!widget.busy) setState(() => _optionId = v);
                      },
                      child: Column(
                        children: [
                          for (final o in choices)
                            RadioListTile<String>(
                              key: Key('my-cell-option-${o.cellId}'),
                              value: o.cellId,
                              contentPadding: EdgeInsets.zero,
                              title: Text(o.label),
                              subtitle: Text(o.broadArea),
                            ),
                        ],
                      ),
                    ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      FocusRing(
                        child: FilledButton(
                          key: const Key('my-cell-send'),
                          onPressed: widget.busy || picked == null
                              ? null
                              : () => ctl.requestChange(cell, picked!),
                          child: const Text('Send request'),
                        ),
                      ),
                      if (primary != null)
                        FocusRing(
                          child: TextButton(
                            key: const Key('my-cell-change-close'),
                            onPressed: widget.busy
                                ? null
                                : () => setState(() {
                                    _changing = false;
                                    _optionId = null;
                                  }),
                            child: const Text('Not now'),
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
        ],
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Story 5.1: meetings (staff web) and the next meeting (mobile My cell)
// ---------------------------------------------------------------------------

// Meeting times are shown in church time (Africa/Lusaka), whatever zone the
// device is set to.
String _meetingClock(BuildContext context, DateTime at) {
  final w = ChurchTime.wall(at);
  return MaterialLocalizations.of(context).formatTimeOfDay(
    TimeOfDay(hour: w.hour, minute: w.minute),
    alwaysUse24HourFormat: true,
  );
}

const _monthsShort = [
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

/// "Friday 27 Feb" in church time.
String _meetingDay(BuildContext context, DateTime at) {
  final w = ChurchTime.wall(at);
  return '${weekdayName(w.weekday)} ${w.day} ${_monthsShort[w.month - 1]}';
}

/// "Friday 27 Feb · 18:00–19:30" in church time.
String _meetingWhen(BuildContext context, CellMeeting m) =>
    '${_meetingDay(context, m.startsAt)} · ${_meetingClock(context, m.startsAt)}'
    '–${_meetingClock(context, m.endsAt)}';

/// An icon and a line (venue, map pin) in a meeting card.
Widget _infoRow(BuildContext context, IconData icon, Widget text, {Key? key}) {
  final c = ChurchColors.of(context);
  return Padding(
    key: key,
    padding: const EdgeInsets.only(top: 10),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ExcludeSemantics(child: Icon(icon, size: 20, color: c.muted)),
        const SizedBox(width: 10),
        Expanded(child: text),
      ],
    ),
  );
}

/// "Fri 6 Mar" in church time: a table's date column.
String _mtgShortDay(DateTime at) {
  final w = ChurchTime.wall(at);
  return '${weekdayName(w.weekday).substring(0, 3)} ${w.day} '
      '${_monthsShort[w.month - 1]}';
}

/// "18:00–19:30" in church time.
String _mtgTimes(BuildContext context, CellMeeting m) =>
    '${_meetingClock(context, m.startsAt)}–${_meetingClock(context, m.endsAt)}';

String _mtgPlural(int n, String one) => '$n ${n == 1 ? one : '${one}s'}';

/// A row or header action: a 44 px target at 14/600 that takes only its own
/// width.
ButtonStyle _mtgCompact() => const ButtonStyle(
  minimumSize: WidgetStatePropertyAll(Size(0, ChurchGeometry.minTarget)),
  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
  padding: WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 14)),
  textStyle: WidgetStatePropertyAll(
    TextStyle(
      fontFamily: ChurchFonts.body,
      fontSize: 14,
      fontWeight: FontWeight.w600,
    ),
  ),
);

/// A row's text action (Plan, Move, Cancel): tighter than [_mtgCompact].
ButtonStyle _mtgRowAction() => _mtgCompact().copyWith(
  padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 10)),
);

/// A fact of a meeting card: a grey label over its value.
Widget _mtgFact(BuildContext context, String label, Widget value) {
  final c = ChurchColors.of(context);
  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: [
      Text(
        label,
        style: ChurchType.secondary.copyWith(color: c.muted, fontSize: 13),
      ),
      const SizedBox(height: 2),
      value,
    ],
  );
}

/// Form fields side by side on a wide form, stacked below 560 px.
Widget _mtgFieldRow(List<Widget> fields) => LayoutBuilder(
  builder: (context, box) {
    if (box.maxWidth < 560) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final f in fields)
            Padding(padding: const EdgeInsets.only(bottom: 12), child: f),
        ],
      );
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < fields.length; i++) ...[
            if (i > 0) const SizedBox(width: 12),
            Expanded(child: fields[i]),
          ],
        ],
      ),
    );
  },
);

/// Story 5.1, staff web: each cell's weekly schedule and its meetings for
/// the next 12 weeks. An Admin sets the schedule (and sees only that a
/// venue is set unless they also lead or assist the cell); the cell's
/// leader or an Admin moves, cancels or brings back one meeting at a time;
/// an assistant reads. Every meeting keeps its id through every change.
///
/// Each cell answers "when is the next meeting, is it planned, and which
/// past meetings still need recording?": the next meeting and the last four
/// weeks side by side, then the next 12 weeks as a table.
class CellMeetingsScreen extends StatelessWidget {
  const CellMeetingsScreen({super.key});

  @override
  Widget build(BuildContext context) => _CellsPage<CellMeetingsBoard>(
    title: 'Cell meetings',
    subtitle: 'The next meeting, the weeks ahead and the last four weeks',
    provider: cellMeetingsProvider,
    needs: 'This page is for cell leaders, assistants and Admins.',
    loading: 'Loading cell meetings…',
    body: (context, board, s) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (board.cells.isEmpty)
          _Card(
            child: Text(
              'No cells to show.',
              key: const Key('meetings-no-cells'),
              style: ChurchType.staffBody.copyWith(
                color: ChurchColors.of(context).muted,
              ),
            ),
          ),
        for (var i = 0; i < board.cells.length; i++) ...[
          if (i > 0) const SizedBox(height: 40),
          _MeetingCellCard(
            key: Key('meeting-cell-${board.cells[i].cellId}'),
            cell: board.cells[i],
            busy: s.busy,
          ),
        ],
      ],
    ),
  );
}

class _MeetingCellCard extends ConsumerStatefulWidget {
  const _MeetingCellCard({super.key, required this.cell, required this.busy});
  final StaffMeetingCell cell;
  final bool busy;

  @override
  ConsumerState<_MeetingCellCard> createState() => _MeetingCellCardState();
}

class _MeetingCellCardState extends ConsumerState<_MeetingCellCard> {
  String? _moving;
  bool _editing = false;

  @override
  Widget build(BuildContext context) {
    final c = ChurchColors.of(context);
    final cell = widget.cell;
    final busy = widget.busy;
    final schedule = cell.schedule;
    final now = DateTime.now().toUtc();
    final id = cell.cellId;
    CellMeeting? next;
    for (final m in cell.meetings) {
      if (!m.cancelled && m.endsAt.isAfter(now)) {
        next = m;
        break;
      }
    }
    final changed = cell.meetings.where((m) => m.moved || m.cancelled).length;
    final unrecorded = cell.recent
        .where((r) => r.status == MeetingStatus.unrecorded)
        .length;
    final unrecordedLabel = unrecorded == 0
        ? null
        : StatusLabel(
            key: Key('meeting-unrecorded-$id'),
            label: unrecorded == 1
                ? '1 recent meeting not recorded'
                : '$unrecorded recent meetings not recorded',
            tone: StatusTone.warning,
          );
    Widget header(bool narrow) => Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Semantics(
                header: true,
                child: Text(
                  cell.name,
                  style: ChurchType.sectionTitle.copyWith(
                    color: c.ink,
                    fontSize: 20,
                  ),
                ),
              ),
              const SizedBox(height: 2),
              Text(
                [
                  switch (cell.role) {
                    MeetingRole.leader => 'You lead this cell',
                    MeetingRole.assistant => 'You assist this cell',
                    MeetingRole.admin => 'Admin',
                  },
                  if (cell.isSynthetic) 'Synthetic test record',
                ].join(' · '),
                style: ChurchType.secondary.copyWith(color: c.muted),
              ),
              // Story 5.8: past meetings waiting for their record (under
              // the name on a phone, on the right otherwise).
              if (narrow && unrecordedLabel != null) ...[
                const SizedBox(height: 6),
                unrecordedLabel,
              ],
            ],
          ),
        ),
        if (!narrow && unrecordedLabel != null) ...[
          const SizedBox(width: 12),
          unrecordedLabel,
        ],
      ],
    );
    return LayoutBuilder(
      builder: (context, box) {
        final narrow = box.maxWidth < 600;
        final nextCard = _mtgNextCard(
          context,
          next,
          changed,
          now,
          narrow: narrow,
        );
        final recent = _mtgRecent(context, wide: box.maxWidth >= 380);
        final top = box.maxWidth >= 900
            ? IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(flex: 3, child: nextCard),
                    const SizedBox(width: 16),
                    Expanded(flex: 2, child: recent),
                  ],
                ),
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [nextCard, const SizedBox(height: 16), recent],
              );
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            header(narrow),
            const SizedBox(height: 14),
            top,
            if (schedule != null) ...[
              const SizedBox(height: 16),
              _mtgAhead(context, now, busy, wide: box.maxWidth >= 720),
            ],
            // Setting the weekly rule is rare (Admin): open only for a cell
            // without one, otherwise behind a button after the meetings.
            if (cell.canSetSchedule) ...[
              const SizedBox(height: 16),
              if (schedule == null || _editing)
                _ScheduleForm(
                  cell: cell,
                  busy: busy,
                  onCancel: schedule == null
                      ? null
                      : () => setState(() => _editing = false),
                )
              else
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: FocusRing(
                    child: OutlinedButton(
                      key: Key('schedule-edit-$id'),
                      style: _mtgCompact(),
                      onPressed: busy
                          ? null
                          : () => setState(() => _editing = true),
                      child: const Text('Change the weekly schedule'),
                    ),
                  ),
                ),
            ],
          ],
        );
      },
    );
  }

  /// The card's answer: when the cell meets next, where, and the one job
  /// (plan its programme).
  Widget _mtgNextCard(
    BuildContext context,
    CellMeeting? next,
    int changed,
    DateTime now, {
    required bool narrow,
  }) {
    final c = ChurchColors.of(context);
    final cell = widget.cell;
    final schedule = cell.schedule;
    final id = cell.cellId;
    if (schedule == null) {
      return StaffSection(
        title: 'Next meeting',
        child: Text(
          cell.canSetSchedule
              ? 'No meeting schedule yet. Set it below.'
              : 'No meeting schedule yet. The church office sets it.',
          key: Key('meeting-no-schedule-$id'),
          style: ChurchType.staffBody.copyWith(color: c.muted),
        ),
      );
    }
    final canPlan =
        next != null &&
        cell.role != MeetingRole.admin &&
        !next.cancelled &&
        next.startsAt.isAfter(now);
    final otherVenue = next != null && next.venueMoved && next.venue != null;
    final value = ChurchType.staffBody.copyWith(color: c.ink);
    final Widget pin;
    if (schedule.mapPin case final p?) {
      pin = SelectableText(
        p.text,
        style: ChurchType.figures.copyWith(color: c.ink),
      );
    } else if (schedule.pinSet && schedule.venue == null) {
      pin = Text('Set', key: Key('meeting-pin-$id'), style: value);
    } else {
      pin = Text(
        'Not set',
        key: Key('meeting-pin-$id'),
        style: value.copyWith(color: c.muted),
      );
    }
    final plan = canPlan
        ? FocusRing(
            child: FilledButton(
              key: Key('meeting-next-plan-$id'),
              style: _mtgCompact(),
              onPressed: () => context.go(CellPaths.plan(next.meetingId)),
              child: const Text('Plan the programme'),
            ),
          )
        : null;
    final usually = _mtgFact(
      context,
      'Usually',
      Text(schedule.summary, key: Key('meeting-schedule-$id'), style: value),
    );
    final venue = _mtgFact(
      context,
      otherVenue ? 'Venue this time' : 'Venue',
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            otherVenue
                ? next.venue!
                : schedule.venue ??
                      'Set (only the cell\'s leader, assistant and members '
                          'see it)',
            key: Key('meeting-venue-$id'),
            style: value,
          ),
          if (otherVenue && schedule.venue != null)
            Text(
              'Usually ${schedule.venue}',
              style: ChurchType.secondary.copyWith(
                color: c.muted,
                fontSize: 13,
              ),
            ),
        ],
      ),
    );
    final mapPin = _mtgFact(context, 'Map pin', pin);
    return StaffSection(
      title: 'Next meeting',
      subtitle: 'Church time. The venue is private to the cell.',
      trailing: narrow ? null : plan,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (next != null) ...[
                ChurchDateBadge(at: next.startsAt, tone: DateBadgeTone.info),
                const SizedBox(width: 14),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      next == null
                          ? 'No meeting in the next 12 weeks'
                          : '${_meetingDay(context, next.startsAt)} · '
                                '${_mtgTimes(context, next)}',
                      key: Key('meeting-next-$id'),
                      style: ChurchType.sectionTitle.copyWith(color: c.ink),
                    ),
                    if (next?.moved ?? false) ...[
                      const SizedBox(height: 6),
                      StatusLabel(
                        label: next!.venueMoved
                            ? 'Moved, other venue'
                            : 'Moved from its usual time',
                        tone: StatusTone.warning,
                      ),
                    ],
                    if (changed > 0) ...[
                      const SizedBox(height: 4),
                      Text(
                        '$changed of the next ${cell.meetings.length} '
                        'meetings ${changed == 1 ? 'is' : 'are'} moved or '
                        'cancelled.',
                        style: ChurchType.secondary.copyWith(
                          color: c.muted,
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
          if (narrow && plan != null) ...[
            const SizedBox(height: 12),
            Align(alignment: AlignmentDirectional.centerStart, child: plan),
          ],
          const SizedBox(height: 16),
          Container(height: 1, color: c.line),
          const SizedBox(height: 14),
          if (narrow)
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                usually,
                const SizedBox(height: 12),
                venue,
                const SizedBox(height: 12),
                mapPin,
              ],
            )
          else
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: usually),
                const SizedBox(width: 16),
                Expanded(flex: 2, child: venue),
                const SizedBox(width: 16),
                Expanded(child: mapPin),
              ],
            ),
          const SizedBox(height: 14),
          // Story 5.2: the cell's reminders; the leader or an Admin changes
          // them.
          _RemindersRow(cell: cell, schedule: schedule, busy: widget.busy),
        ],
      ),
    );
  }

  /// Story 5.8: the last four weeks, newest first: held or not (one pill),
  /// and the record action (the leader or assistant records it on the
  /// meeting's page).
  Widget _mtgRecent(BuildContext context, {required bool wide}) {
    final c = ChurchColors.of(context);
    final cell = widget.cell;
    const cols = [
      StaffColumn('Meeting', flex: 3),
      StaffColumn('Record', width: 112),
      StaffColumn('', width: 92, numeric: true),
    ];
    return StaffSection(
      title: 'Last 4 weeks',
      subtitle: cell.role == MeetingRole.admin
          ? 'Held or not, as the cell recorded it.'
          : 'Record each meeting once it has happened.',
      bodyPadding: EdgeInsets.zero,
      child: cell.recent.isEmpty
          ? Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 18),
              child: Text(
                'No meetings in the last four weeks.',
                style: ChurchType.staffBody.copyWith(color: c.muted),
              ),
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (wide)
                  const StaffTableHeader(
                    columns: cols,
                    padding: EdgeInsets.fromLTRB(20, 10, 12, 8),
                  ),
                for (var i = 0; i < cell.recent.length; i++)
                  _mtgRecentRow(
                    context,
                    cell.recent[i],
                    cols,
                    divider: i > 0,
                    wide: wide,
                  ),
              ],
            ),
    );
  }

  Widget _mtgRecentRow(
    BuildContext context,
    RecentMeeting r,
    List<StaffColumn> cols, {
    required bool divider,
    required bool wide,
  }) {
    final c = ChurchColors.of(context);
    final cell = widget.cell;
    final m = r.meeting;
    final when = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          _mtgShortDay(m.startsAt),
          style: ChurchType.staffBody.copyWith(
            color: c.ink,
            fontWeight: FontWeight.w600,
          ),
        ),
        Text(
          _mtgTimes(context, m),
          style: ChurchType.figures.copyWith(color: c.muted, fontSize: 13),
        ),
      ],
    );
    final status =
        _statusLabel(r.status) ??
        Text('—', style: ChurchType.staffBody.copyWith(color: c.muted));
    final Widget action =
        cell.role != MeetingRole.admin && r.status != MeetingStatus.cancelled
        ? FocusRing(
            child: TextButton(
              key: Key('recent-open-${m.meetingId}'),
              style: _mtgRowAction(),
              onPressed: () => context.go(CellPaths.plan(m.meetingId)),
              child: Text(
                r.status == MeetingStatus.unrecorded ? 'Record' : 'Open',
                semanticsLabel:
                    '${r.status == MeetingStatus.unrecorded ? 'Record' : 'Open'}'
                    ' the meeting of ${_mtgShortDay(m.startsAt)}',
              ),
            ),
          )
        : const SizedBox.shrink();
    return StaffTableRow(
      key: Key('recent-${m.meetingId}'),
      divider: divider,
      padding: const EdgeInsets.fromLTRB(20, 4, 12, 4),
      child: wide
          ? StaffColumnsRow(columns: cols, cells: [when, status, action])
          : Row(
              children: [
                Expanded(child: when),
                status,
                action,
              ],
            ),
    );
  }

  /// The next 12 weeks as a table: date, time, what differs (another
  /// venue, people to tell directly), one state pill and the row's actions.
  Widget _mtgAhead(
    BuildContext context,
    DateTime now,
    bool busy, {
    required bool wide,
  }) {
    final c = ChurchColors.of(context);
    final cell = widget.cell;
    const cols = [
      StaffColumn('Date', width: 104),
      StaffColumn('Time', width: 108),
      StaffColumn('This meeting', flex: 3),
      StaffColumn('State', width: 150),
      StaffColumn('', width: 236, numeric: true),
    ];
    final rows = <Widget>[];
    for (var i = 0; i < cell.meetings.length; i++) {
      final m = cell.meetings[i];
      rows.add(
        _mtgAheadRow(context, m, cols, now, busy, divider: i > 0, wide: wide),
      );
      if (_moving == m.meetingId && !m.cancelled) {
        rows.add(
          _MoveMeetingForm(
            key: Key('meeting-move-form-${m.meetingId}'),
            meeting: m,
            busy: busy,
            onClose: () => setState(() => _moving = null),
          ),
        );
      }
    }
    return StaffSection(
      title: 'Next 12 weeks',
      trailing: Text(
        _mtgPlural(cell.meetings.length, 'meeting'),
        style: ChurchType.figures.copyWith(color: c.muted),
      ),
      bodyPadding: EdgeInsets.zero,
      child: cell.meetings.isEmpty
          ? Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 18),
              child: Text(
                'No meetings in the next 12 weeks.',
                style: ChurchType.staffBody.copyWith(color: c.muted),
              ),
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (wide) const StaffTableHeader(columns: cols),
                ...rows,
              ],
            ),
    );
  }

  Widget _mtgAheadRow(
    BuildContext context,
    CellMeeting m,
    List<StaffColumn> cols,
    DateTime now,
    bool busy, {
    required bool divider,
    required bool wide,
  }) {
    final c = ChurchColors.of(context);
    final cell = widget.cell;
    final ctl = ref.read(cellMeetingsProvider.notifier);
    final day = _mtgShortDay(m.startsAt);
    final notes = <Widget>[
      if (m.venueMoved && m.venue != null)
        Text(
          'At ${m.venue}',
          style: ChurchType.staffBody.copyWith(color: c.ink),
        ),
      // Story 5.2: members the app could not reach about this meeting; the
      // leader tells them directly.
      if (m.contactNeeds.isNotEmpty)
        Text(
          'Tell directly: '
          '${m.contactNeeds.map((n) => n.displayName).join(', ')}',
          key: Key('meeting-contact-${m.meetingId}'),
          style: ChurchType.secondary.copyWith(
            color: c.amberFg,
            fontWeight: FontWeight.w600,
          ),
        ),
    ];
    final Widget state = m.cancelled
        ? const StatusLabel(label: 'Cancelled', tone: StatusTone.danger)
        : m.moved
        ? StatusLabel(
            label: m.venueMoved ? 'Moved, other venue' : 'Moved',
            tone: StatusTone.warning,
          )
        : Text(
            'As usual',
            style: ChurchType.secondary.copyWith(color: c.muted),
          );
    // The server checks a cancelled meeting against its usual time (it comes
    // back there), any other against its own.
    final changeable =
        cell.canChange &&
        (m.cancelled ? m.nominalStartsAt : m.startsAt).isAfter(now);
    Widget act(String key, String label, String spoken, VoidCallback? on) =>
        FocusRing(
          child: TextButton(
            key: Key(key),
            style: _mtgRowAction(),
            onPressed: on,
            child: Text(label, semanticsLabel: '$spoken $day'),
          ),
        );
    final actions = Wrap(
      alignment: wide ? WrapAlignment.end : WrapAlignment.start,
      children: [
        // Story 5.3: the cell's leader or assistant plans the meeting's
        // programme (the server decides; Admin alone reads counts on the
        // page itself).
        if (cell.role != MeetingRole.admin &&
            !m.cancelled &&
            m.startsAt.isAfter(now))
          act(
            'meeting-plan-${m.meetingId}',
            'Plan',
            'Plan the meeting of',
            () => context.go(CellPaths.plan(m.meetingId)),
          ),
        if (changeable && !m.cancelled) ...[
          act(
            'meeting-move-${m.meetingId}',
            'Move',
            'Move the meeting of',
            busy
                ? null
                : () => setState(
                    () => _moving = _moving == m.meetingId ? null : m.meetingId,
                  ),
          ),
          act(
            'meeting-cancel-${m.meetingId}',
            'Cancel',
            'Cancel the meeting of',
            busy ? null : () => ctl.cancel(m),
          ),
        ] else if (changeable && m.nominalStartsAt.isAfter(now))
          act(
            'meeting-reinstate-${m.meetingId}',
            'Bring it back',
            'Bring back the meeting of',
            busy ? null : () => ctl.reinstate(m),
          ),
      ],
    );
    final dayText = Text(
      day,
      style: ChurchType.staffBody.copyWith(
        color: m.cancelled ? c.muted : c.ink,
        fontWeight: FontWeight.w600,
      ),
    );
    final timeText = Text(
      _mtgTimes(context, m),
      style: ChurchType.figures.copyWith(color: m.cancelled ? c.muted : c.ink),
    );
    return StaffTableRow(
      key: Key('meeting-${m.meetingId}'),
      divider: divider,
      padding: EdgeInsets.fromLTRB(20, 2, wide ? 12 : 16, 2),
      child: wide
          ? StaffColumnsRow(
              columns: cols,
              cells: [
                dayText,
                timeText,
                notes.isEmpty
                    ? const SizedBox.shrink()
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: notes,
                      ),
                state,
                actions,
              ],
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    dayText,
                    const SizedBox(width: 10),
                    Expanded(child: timeText),
                    state,
                  ],
                ),
                ...notes,
                actions,
              ],
            ),
    );
  }
}

class _ScheduleForm extends ConsumerStatefulWidget {
  const _ScheduleForm({required this.cell, required this.busy, this.onCancel});
  final StaffMeetingCell cell;
  final bool busy;

  /// Closes the form without saving (a change to an existing schedule).
  final VoidCallback? onCancel;

  @override
  ConsumerState<_ScheduleForm> createState() => _ScheduleFormState();
}

class _ScheduleFormState extends ConsumerState<_ScheduleForm> {
  late int _weekday = widget.cell.schedule?.weekday ?? 4;
  late final _start = TextEditingController(
    text: widget.cell.schedule?.startTime ?? '18:00',
  );
  late final _end = TextEditingController(
    text: widget.cell.schedule?.endTime ?? '19:30',
  );
  final _venue = TextEditingController();
  final _lat = TextEditingController();
  final _lng = TextEditingController();
  bool _clearPin = false;

  @override
  void dispose() {
    _start.dispose();
    _end.dispose();
    _venue.dispose();
    _lat.dispose();
    _lng.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cell = widget.cell;
    final errors = ref.watch(cellMeetingsProvider.select((s) => s.fieldErrors));
    final first = cell.schedule == null;
    String? err(String k) => switch (errors[k]) {
      null => null,
      'required' => 'Required',
      'before_start' => 'End after the start',
      'too_long' => 'At most 6 hours',
      _ when k == 'venue' =>
        'Check this (while personal data is not approved, start with '
            '"SYNTHETIC ")',
      _ => 'Check this',
    };
    final lat = double.tryParse(_lat.text.trim());
    final lng = double.tryParse(_lng.text.trim());
    final pinTyped = _lat.text.trim().isNotEmpty || _lng.text.trim().isNotEmpty;
    final pinOk =
        !pinTyped ||
        (lat != null && lng != null && lat.abs() <= 90 && lng.abs() <= 180);
    final id = cell.cellId;
    return StaffSection(
      key: Key('schedule-form-$id'),
      title: first ? 'Set the weekly meeting' : 'Change the weekly meeting',
      subtitle:
          'Church time. The next 12 weeks follow it; moved and cancelled '
          'meetings keep their changes.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _mtgFieldRow([
            DropdownButtonFormField<int>(
              key: Key('schedule-weekday-$id'),
              initialValue: _weekday,
              decoration: const InputDecoration(labelText: 'Day'),
              items: [
                for (var d = 1; d <= 7; d++)
                  DropdownMenuItem(value: d, child: Text(weekdayName(d))),
              ],
              onChanged: widget.busy
                  ? null
                  : (v) => setState(() => _weekday = v ?? _weekday),
            ),
            TextField(
              key: Key('schedule-start-$id'),
              controller: _start,
              enabled: !widget.busy,
              decoration: InputDecoration(
                labelText: 'Starts (HH:MM)',
                errorText: err('start_time'),
              ),
            ),
            TextField(
              key: Key('schedule-end-$id'),
              controller: _end,
              enabled: !widget.busy,
              decoration: InputDecoration(
                labelText: 'Ends (HH:MM)',
                errorText: err('end_time'),
              ),
            ),
          ]),
          TextField(
            key: Key('schedule-venue-$id'),
            controller: _venue,
            enabled: !widget.busy,
            maxLength: 120,
            decoration: InputDecoration(
              labelText: first ? 'Venue' : 'New venue (leave empty to keep it)',
              errorText: err('venue'),
            ),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 4),
          _mtgFieldRow([
            TextField(
              key: Key('schedule-lat-$id'),
              controller: _lat,
              enabled: !widget.busy,
              decoration: InputDecoration(
                labelText: 'Map pin latitude (optional)',
                errorText: pinOk ? err('map_pin') : 'Check the pin',
              ),
              onChanged: (_) => setState(() {}),
            ),
            TextField(
              key: Key('schedule-lng-$id'),
              controller: _lng,
              enabled: !widget.busy,
              decoration: const InputDecoration(
                labelText: 'Map pin longitude (optional)',
              ),
              onChanged: (_) => setState(() {}),
            ),
          ]),
          if (cell.schedule?.pinSet ?? false)
            Row(
              children: [
                Checkbox(
                  key: Key('schedule-clear-pin-$id'),
                  value: _clearPin,
                  onChanged: widget.busy
                      ? null
                      : (v) => setState(() => _clearPin = v ?? false),
                ),
                const Flexible(child: Text('Remove the map pin')),
              ],
            ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FocusRing(
                child: FilledButton(
                  key: Key('schedule-save-$id'),
                  onPressed:
                      widget.busy ||
                          !pinOk ||
                          (first && _venue.text.trim().isEmpty)
                      ? null
                      : () => ref
                            .read(cellMeetingsProvider.notifier)
                            .setSchedule(
                              cell,
                              weekday: _weekday,
                              startTime: _start.text,
                              endTime: _end.text,
                              venue: _venue.text,
                              pin: pinTyped && lat != null && lng != null
                                  ? MeetingMapPin(lat: lat, lng: lng)
                                  : null,
                              clearPin: _clearPin && !pinTyped,
                            ),
                  child: const Text('Save schedule'),
                ),
              ),
              if (widget.onCancel case final close?)
                FocusRing(
                  child: TextButton(
                    key: Key('schedule-cancel-$id'),
                    onPressed: widget.busy ? null : close,
                    child: const Text('Keep as is'),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Moves one meeting: a panel under its row in the table, the fields side
/// by side, church time.
class _MoveMeetingForm extends ConsumerStatefulWidget {
  const _MoveMeetingForm({
    super.key,
    required this.meeting,
    required this.busy,
    required this.onClose,
  });
  final CellMeeting meeting;
  final bool busy;
  final VoidCallback onClose;

  @override
  ConsumerState<_MoveMeetingForm> createState() => _MoveMeetingFormState();
}

class _MoveMeetingFormState extends ConsumerState<_MoveMeetingForm> {
  late final _date = TextEditingController(
    text: ChurchTime.dateText(widget.meeting.startsAt),
  );
  late final _start = TextEditingController(
    text: ChurchTime.timeText(widget.meeting.startsAt),
  );
  late final _end = TextEditingController(
    text: ChurchTime.timeText(widget.meeting.endsAt),
  );
  final _venue = TextEditingController();
  bool _regularVenue = false;

  @override
  void dispose() {
    _date.dispose();
    _start.dispose();
    _end.dispose();
    _venue.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = ChurchColors.of(context);
    final m = widget.meeting;
    final errors = ref.watch(cellMeetingsProvider.select((s) => s.fieldErrors));
    final starts = ChurchTime.parse(_date.text, _start.text);
    final ends = ChurchTime.parse(_date.text, _end.text);
    final ok = starts != null && ends != null && ends.isAfter(starts);
    String? err(String k) => switch (errors[k]) {
      null => null,
      'past' => 'Must be in the future',
      'out_of_range' => 'Within 30 days of the usual date',
      'before_start' => 'End after the start',
      'too_long' => 'At most 6 hours',
      _ => 'Check this',
    };
    return Container(
      margin: const EdgeInsets.fromLTRB(20, 0, 16, 14),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
      decoration: BoxDecoration(
        color: c.bg,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Move only this meeting',
            style: ChurchType.staffBody.copyWith(
              color: c.ink,
              fontWeight: FontWeight.w600,
            ),
          ),
          Text(
            'Now ${_meetingWhen(context, m)}. Church time. Its other weeks '
            'stay as they are.',
            style: ChurchType.secondary.copyWith(color: c.muted),
          ),
          const SizedBox(height: 12),
          _mtgFieldRow([
            TextField(
              key: Key('move-date-${m.meetingId}'),
              controller: _date,
              enabled: !widget.busy,
              decoration: InputDecoration(
                labelText: 'Date (YYYY-MM-DD)',
                errorText: err('starts_at'),
              ),
              onChanged: (_) => setState(() {}),
            ),
            TextField(
              key: Key('move-start-${m.meetingId}'),
              controller: _start,
              enabled: !widget.busy,
              decoration: const InputDecoration(labelText: 'Starts'),
              onChanged: (_) => setState(() {}),
            ),
            TextField(
              key: Key('move-end-${m.meetingId}'),
              controller: _end,
              enabled: !widget.busy,
              decoration: InputDecoration(
                labelText: 'Ends',
                errorText: err('ends_at'),
              ),
              onChanged: (_) => setState(() {}),
            ),
          ]),
          TextField(
            key: Key('move-venue-${m.meetingId}'),
            controller: _venue,
            enabled: !widget.busy && !_regularVenue,
            maxLength: 120,
            decoration: InputDecoration(
              labelText: 'Venue for this meeting (leave empty to keep it)',
              errorText: err('venue'),
            ),
          ),
          if (m.venueMoved)
            Row(
              children: [
                Checkbox(
                  key: Key('move-regular-venue-${m.meetingId}'),
                  value: _regularVenue,
                  onChanged: widget.busy
                      ? null
                      : (v) => setState(() => _regularVenue = v ?? false),
                ),
                const Flexible(child: Text('Use the usual venue')),
              ],
            ),
          const SizedBox(height: 4),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FocusRing(
                child: FilledButton(
                  key: Key('move-save-${m.meetingId}'),
                  onPressed: widget.busy || !ok
                      ? null
                      : () => ref
                            .read(cellMeetingsProvider.notifier)
                            .move(
                              m,
                              startsAt: starts,
                              endsAt: ends,
                              venue: _regularVenue ? null : _venue.text,
                              regularVenue: _regularVenue,
                            ),
                  child: const Text('Move this meeting'),
                ),
              ),
              FocusRing(
                child: TextButton(
                  key: Key('move-cancel-${m.meetingId}'),
                  onPressed: widget.busy ? null : widget.onClose,
                  child: const Text('Keep as is'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Mobile My cell: the confirmed cell's next meeting with its private venue,
/// and the cancelled meetings before it. Kept in memory only (never stored
/// for offline reading).
class _NextMeetingCard extends StatelessWidget {
  const _NextMeetingCard({required this.meetings});
  final MyCellMeetings meetings;

  @override
  Widget build(BuildContext context) {
    final c = ChurchColors.of(context);
    final next = meetings.next;
    return _Card(
      key: const Key('my-cell-next-meeting'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const CardLabel('Next meeting'),
          const SizedBox(height: 12),
          for (final m in meetings.cancelled)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: StatusLabel(
                key: Key('my-cell-cancelled-${m.meetingId}'),
                label:
                    'Cancelled: ${_meetingDay(context, m.nominalStartsAt)}, '
                    '${_meetingClock(context, m.nominalStartsAt)}',
                tone: StatusTone.neutral,
              ),
            ),
          if (next == null)
            const Text(
              'No meeting is planned in the next 12 weeks.',
              key: Key('my-cell-no-meeting'),
            )
          else ...[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ChurchDateBadge(at: next.startsAt, tone: DateBadgeTone.info),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _meetingDay(context, next.startsAt),
                        style: ChurchType.itemTitle.copyWith(color: c.ink),
                      ),
                      Text(
                        '${_meetingClock(context, next.startsAt)}'
                        '–${_meetingClock(context, next.endsAt)}',
                        key: const Key('my-cell-next-when'),
                        style: ChurchType.figures.copyWith(color: c.muted),
                      ),
                      if (next.moved) ...[
                        const SizedBox(height: 6),
                        const StatusLabel(
                          label: 'Moved from its usual time',
                          tone: StatusTone.warning,
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
            if (next.venue case final v?)
              _infoRow(
                context,
                Icons.place_outlined,
                Text(v, style: ChurchType.body.copyWith(color: c.ink)),
                key: const Key('my-cell-next-venue'),
              ),
            if (next.mapPin case final pin?)
              _infoRow(
                context,
                Icons.near_me_outlined,
                SelectableText(
                  'Map pin: ${pin.text}',
                  key: const Key('my-cell-next-pin'),
                  style: ChurchType.secondary.copyWith(color: c.ink),
                ),
              ),
          ],
          const SizedBox(height: 12),
          _muted(
            context,
            'Church time. Only confirmed members of your cell see where it '
            'meets.',
          ),
        ],
      ),
    );
  }
}

/// Story 5.2, staff web: the cell's meeting reminders. Everyone with the
/// card reads them; the cell's leader or an Admin changes them (at most
/// three offsets before the start, or the default of one day before).
class _RemindersRow extends ConsumerStatefulWidget {
  const _RemindersRow({
    required this.cell,
    required this.schedule,
    required this.busy,
  });
  final StaffMeetingCell cell;
  final MeetingSchedule schedule;
  final bool busy;

  @override
  ConsumerState<_RemindersRow> createState() => _RemindersRowState();
}

class _RemindersRowState extends ConsumerState<_RemindersRow> {
  bool _editing = false;
  late Set<String> _chosen = widget.schedule.reminders.toSet();

  @override
  Widget build(BuildContext context) {
    final cl = ChurchColors.of(context);
    final cell = widget.cell;
    final schedule = widget.schedule;
    final busy = widget.busy;
    final id = cell.cellId;
    final ctl = ref.read(cellMeetingsProvider.notifier);
    // The usual choices plus any offset already set (from another client
    // or the API), so saving never drops one silently.
    final choices = [
      ...meetingReminderChoices,
      for (final r in schedule.reminders)
        if (!meetingReminderChoices.contains(r)) r,
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: _mtgFact(
                context,
                'Reminders',
                Text(
                  '${schedule.remindersText}'
                  '${schedule.remindersDefault ? ' (usual)' : ''}',
                  key: Key('meeting-reminders-$id'),
                  style: ChurchType.staffBody.copyWith(color: cl.ink),
                ),
              ),
            ),
            if (cell.canChange && !_editing)
              FocusRing(
                child: TextButton(
                  key: Key('reminders-edit-$id'),
                  style: _mtgRowAction(),
                  onPressed: busy
                      ? null
                      : () => setState(() {
                          _chosen = schedule.reminders.toSet();
                          _editing = true;
                        }),
                  child: const Text('Change reminders'),
                ),
              ),
          ],
        ),
        if (_editing) ...[
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
            decoration: BoxDecoration(
              color: cl.bg,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Choose up to three. Members can snooze each one.',
                  style: ChurchType.secondary.copyWith(color: cl.muted),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    for (final c in choices)
                      FilterChip(
                        key: Key('reminder-choice-$id-$c'),
                        label: Text(reminderLabel(c)),
                        selected: _chosen.contains(c),
                        onSelected: busy
                            ? null
                            : (on) => setState(() {
                                if (on && _chosen.length < 3) {
                                  _chosen.add(c);
                                } else if (!on) {
                                  _chosen.remove(c);
                                }
                              }),
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    FocusRing(
                      child: FilledButton(
                        key: Key('reminders-save-$id'),
                        style: _mtgCompact(),
                        onPressed: busy
                            ? null
                            : () {
                                setState(() => _editing = false);
                                ctl.setReminders(cell, [
                                  for (final c in choices)
                                    if (_chosen.contains(c)) c,
                                ]);
                              },
                        child: Text(
                          _chosen.isEmpty
                              ? 'Save: no reminders'
                              : 'Save reminders',
                        ),
                      ),
                    ),
                    FocusRing(
                      child: TextButton(
                        key: Key('reminders-default-$id'),
                        style: _mtgRowAction(),
                        onPressed: busy
                            ? null
                            : () {
                                setState(() => _editing = false);
                                ctl.setReminders(cell, null);
                              },
                        child: const Text('Use the usual (1 day before)'),
                      ),
                    ),
                    FocusRing(
                      child: TextButton(
                        key: Key('reminders-cancel-$id'),
                        style: _mtgRowAction(),
                        onPressed: () => setState(() => _editing = false),
                        child: const Text('Keep as is'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Story 5.3, staff web: Plan meeting (programme drafts); 5.4 publishing
// ---------------------------------------------------------------------------

/// Routes of the cells screens that other screens link to.
abstract final class CellPaths {
  /// Story 5.3: one meeting's programme (`/cells/meetings/<id>/plan`).
  static String plan(String meetingId) => '/cells/meetings/$meetingId/plan';

  /// The member's own cell (mobile).
  static const myCell = '/my-cell';
}

/// Story 5.3, staff web: one meeting's programme. The cell's leader or
/// assistant drafts it (topic, scripture, study notes and timed parts with a
/// person from the cell or a department duty to show) and, from story 5.4,
/// publishes it: each part becomes a duty its person is asked to accept, and
/// members of the cell read the programme. Pastor oversight reads it; an
/// Admin-only reader sees counts. The page answers "is this meeting planned,
/// and who has said yes?" first; parts nobody leads are gaps.
class PlanMeetingScreen extends StatelessWidget {
  const PlanMeetingScreen({super.key, required this.meetingId});
  final String meetingId;

  @override
  Widget build(BuildContext context) => _CellsPage<ProgrammeRead>(
    title: 'Plan meeting',
    subtitle: 'The programme members see once it is published',
    provider: cellProgrammeProvider(meetingId),
    needs:
        'This page is for the cell\'s leader and assistant, and for pastors.',
    loading: 'Loading the programme…',
    body: (context, read, s) => _PlanBody(
      // A new programme or state starts the page afresh; a new revision of
      // the same draft is handled by the editor (it keeps unsaved edits).
      key: ValueKey(
        'plan-${read.programme?.programmeId}-${read.programme?.state.wire}',
      ),
      meetingId: meetingId,
      read: read,
      state: s,
    ),
  );
}

class _PlanBody extends ConsumerWidget {
  const _PlanBody({
    super.key,
    required this.meetingId,
    required this.read,
    required this.state,
  });
  final String meetingId;
  final ProgrammeRead read;
  final CellsState<ProgrammeRead> state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final m = read.meeting;
    final p = read.programme;
    final ctl = ref.read(cellProgrammeProvider(meetingId).notifier);
    final ahead = m.startsAt.isAfter(DateTime.now().toUtc());
    final open = ahead && !m.cancelled;
    final children = <Widget>[
      _muted(context, read.cellName),
      // The page's answer first: when the meeting is, and how planned.
      Text(
        _meetingWhen(context, m),
        key: const Key('plan-when'),
        style: ChurchType.sectionTitle.copyWith(
          color: ChurchColors.of(context).ink,
        ),
      ),
      const SizedBox(height: 4),
      Wrap(
        spacing: 8,
        runSpacing: 4,
        children: [
          if (m.cancelled)
            const StatusLabel(
              label: 'Meeting cancelled',
              tone: StatusTone.danger,
            )
          else
            ?_statusLabel(read.status, key: const Key('plan-status')),
          if (p == null)
            const StatusLabel(
              key: Key('plan-state-none'),
              label: 'No programme yet',
              tone: StatusTone.neutral,
            )
          else ...[
            StatusLabel(
              key: Key('plan-state-${p.state.wire}'),
              label: switch (p.state) {
                ProgrammeState.draft => 'Draft: members don\'t see it',
                ProgrammeState.published => 'Published to members',
                ProgrammeState.cancelled => 'Cancelled',
              },
              tone: switch (p.state) {
                ProgrammeState.draft => StatusTone.info,
                ProgrammeState.published => StatusTone.success,
                ProgrammeState.cancelled => StatusTone.neutral,
              },
            ),
            _partsLabel(p.partCount, p.gaps),
            if (p.published && read.duties.isNotEmpty)
              _answersLabel(read.duties.values),
          ],
        ],
      ),
      const SizedBox(height: 12),
    ];
    // Story 5.8: once the meeting has started, what happened comes first (the
    // server's status says so, not this device's clock).
    final status = read.status;
    if (read.full &&
        (read.record != null ||
            read.canRecord ||
            status == MeetingStatus.unrecorded)) {
      children.addAll([
        _RecordCard(meetingId: meetingId, read: read, state: state),
        const SizedBox(height: 12),
      ]);
    }
    // Story 5.7: who can't attend comes before the plan (a coverage warning).
    if (read.canEdit && read.absences.isNotEmpty) {
      children.addAll([
        _AbsencesCard(absences: read.absences),
        const SizedBox(height: 12),
      ]);
    }
    if (!read.full) {
      children.add(
        _muted(
          context,
          'Topic, notes, parts and names are only for the cell\'s leader, '
          'assistant and pastors.',
        ),
      );
    } else if (p == null) {
      if (read.canEdit && open) {
        children.add(
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: FocusRing(
              child: FilledButton(
                key: const Key('plan-create'),
                onPressed: state.busy ? null : () => ctl.create(m),
                child: const Text('Start the programme'),
              ),
            ),
          ),
        );
      } else {
        children.add(
          Text(
            !open
                ? (m.cancelled
                      ? 'This meeting is cancelled, so it has no programme.'
                      : 'This meeting has started, so it can no longer be '
                            'planned.')
                : 'The cell\'s leader or assistant plans this meeting.',
            key: const Key('plan-none'),
          ),
        );
      }
    } else if (p.draft && read.canEdit && open) {
      children.add(
        _ProgrammeEditor(
          meetingId: meetingId,
          read: read,
          programme: p,
          busy: state.busy,
          errors: state.fieldErrors,
        ),
      );
    } else if (p.published && read.canEdit) {
      // Story 5.6: the published programme, its unpublished changes first.
      children.add(
        _PublishedEditor(
          meetingId: meetingId,
          read: read,
          programme: p,
          busy: state.busy,
          errors: state.fieldErrors,
          open: open,
        ),
      );
    } else {
      if (p.draft && read.canEdit && !open) {
        children.add(
          _muted(
            context,
            m.cancelled
                ? 'This meeting is cancelled, so its programme can\'t change.'
                : 'This meeting has started, so its programme can\'t change.',
          ),
        );
      } else if (!read.canEdit) {
        children.add(_muted(context, 'Read only.'));
      }
      children.add(const SizedBox(height: 8));
      children.add(
        _ProgrammePreview(
          meeting: m,
          topic: p.topic,
          scripture: p.scripture,
          studyNotes: p.studyNotes,
          parts: [
            for (final part in p.parts)
              (
                start: ChurchTime.timeText(part.startsAt),
                end: ChurchTime.timeText(part.endsAt),
                label: part.label,
                who: part.assignee?.displayName ?? part.linkedLabel,
                leftCell: part.assignee != null && !part.assignee!.inCell,
              ),
          ],
          caption: null,
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    );
  }
}

/// "5 parts, 1 gap": the gap count is the data that matters, so it carries
/// the colour.
Widget _partsLabel(int parts, int gaps) => StatusLabel(
  key: const Key('plan-gaps'),
  label: parts == 0
      ? 'No parts yet'
      : '$parts ${parts == 1 ? 'part' : 'parts'}, '
            '${gaps == 0 ? 'no gaps' : '$gaps ${gaps == 1 ? 'gap' : 'gaps'}'}',
  tone: parts == 0
      ? StatusTone.neutral
      : gaps == 0
      ? StatusTone.success
      : StatusTone.warning,
);

/// Story 5.4: "2 of 3 accepted": who has said yes, once published.
Widget _answersLabel(Iterable<PartDuty> duties) {
  final asked = duties
      .where(
        (d) => switch (d.status) {
          PartDutyStatus.awaiting ||
          PartDutyStatus.accepted ||
          PartDutyStatus.declined => true,
          _ => false,
        },
      )
      .toList();
  final accepted = asked
      .where((d) => d.status == PartDutyStatus.accepted)
      .length;
  final declined = asked
      .where((d) => d.status == PartDutyStatus.declined)
      .length;
  return StatusLabel(
    key: const Key('plan-answers'),
    label: asked.isEmpty
        ? 'Nobody asked yet'
        : '$accepted of ${asked.length} accepted'
              '${declined == 0 ? '' : ', $declined declined'}',
    tone: declined > 0
        ? StatusTone.danger
        : accepted == asked.length
        ? StatusTone.success
        : StatusTone.info,
  );
}

typedef _PreviewPart = ({
  String start,
  String end,
  String label,
  String? who,
  bool leftCell,
});

/// One part as typed in the editor. [who] is `m:<member id>` (a person),
/// `d:<slot id>` (a department duty to show) or null (a gap).
class _PartRow {
  _PartRow({
    required this.key,
    this.partId,
    String label = '',
    required String start,
    required String end,
    this.who,
  }) : label = TextEditingController(text: label),
       start = TextEditingController(text: start),
       end = TextEditingController(text: end);

  final int key;
  final String? partId;
  final TextEditingController label;
  final TextEditingController start;
  final TextEditingController end;
  String? who;

  String? get assignee =>
      who != null && who!.startsWith('m:') ? who!.substring(2) : null;
  String? get linkedSlot =>
      who != null && who!.startsWith('d:') ? who!.substring(2) : null;

  String get snapshot => '$partId|${label.text}|${start.text}|${end.text}|$who';

  /// What the server stores for this row (no ids, trimmed text).
  String get content =>
      '${_oneLine(label.text)}|${start.text.trim()}|${end.text.trim()}|$who';

  void dispose() {
    label.dispose();
    start.dispose();
    end.dispose();
  }
}

/// Text as a single-line server field keeps it (trimmed, spaces collapsed).
String _oneLine(String v) => v.trim().replaceAll(RegExp(r'\s+'), ' ');

/// [p]'s content as the editor compares it (no part ids).
String _programmeContent(CellProgramme p) => [
  _oneLine(p.topic ?? ''),
  _oneLine(p.scripture ?? ''),
  (p.studyNotes ?? '').trim(),
  for (final part in p.parts)
    '${part.label}|${ChurchTime.timeText(part.startsAt)}|'
        '${ChurchTime.timeText(part.endsAt)}|${_whoOf(part)}',
].join('\n');

String? _whoOf(ProgrammePart p) => p.assignee != null
    ? 'm:${p.assignee!.memberId}'
    : p.linkedSlotId != null
    ? 'd:${p.linkedSlotId}'
    : null;

class _ProgrammeEditor extends ConsumerStatefulWidget {
  const _ProgrammeEditor({
    required this.meetingId,
    required this.read,
    required this.programme,
    required this.busy,
    required this.errors,
  });
  final String meetingId;
  final ProgrammeRead read;
  final CellProgramme programme;
  final bool busy;
  final Map<String, String> errors;

  @override
  ConsumerState<_ProgrammeEditor> createState() => _ProgrammeEditorState();
}

class _ProgrammeEditorState extends ConsumerState<_ProgrammeEditor> {
  final _topic = TextEditingController();
  final _scripture = TextEditingController();
  final _notes = TextEditingController();
  final _reason = TextEditingController();
  final List<_PartRow> _rows = [];
  int _nextKey = 0;
  bool _confirmCancel = false;

  /// The revision the typed draft started from, and its content.
  late int _base;
  late String _baseSnapshot;

  /// The server has a newer revision while the typed draft has changes.
  bool _stale = false;

  @override
  void initState() {
    super.initState();
    _load(widget.programme);
  }

  void _load(CellProgramme p) {
    _topic.text = p.topic ?? '';
    _scripture.text = p.scripture ?? '';
    _notes.text = p.studyNotes ?? '';
    for (final r in _rows) {
      r.dispose();
    }
    _rows
      ..clear()
      ..addAll([
        for (final part in p.parts)
          _PartRow(
            key: _nextKey++,
            partId: part.partId,
            label: part.label,
            start: ChurchTime.timeText(part.startsAt),
            end: ChurchTime.timeText(part.endsAt),
            who: _whoOf(part),
          ),
      ]);
    _base = p.revision;
    _baseSnapshot = _snapshot();
    _stale = false;
  }

  String _snapshot() => [
    _topic.text,
    _scripture.text,
    _notes.text,
    for (final r in _rows) r.snapshot,
  ].join('\n');

  bool get _dirty => _snapshot() != _baseSnapshot;

  /// The typed draft's content as the server would store it.
  String _typedContent() => [
    _oneLine(_topic.text),
    _oneLine(_scripture.text),
    _notes.text.replaceAll('\r\n', '\n').trim(),
    for (final r in _rows) r.content,
  ].join('\n');

  @override
  void didUpdateWidget(_ProgrammeEditor old) {
    super.didUpdateWidget(old);
    // A newer revision from the server (saved here, saved elsewhere, or the
    // meeting moved): start from it unless the typed draft has changes,
    // which are kept and flagged (5.3 review fix 10).
    // The leader's own save comes back as a newer revision with the same
    // content (5.4 review fix 1): that simply reloads.
    if (widget.programme.revision != _base) {
      if (!_dirty || _typedContent() == _programmeContent(widget.programme)) {
        _load(widget.programme);
      } else {
        _stale = true;
      }
    }
  }

  @override
  void dispose() {
    _topic.dispose();
    _scripture.dispose();
    _notes.dispose();
    _reason.dispose();
    for (final r in _rows) {
      r.dispose();
    }
    super.dispose();
  }

  void _addPart() {
    final m = widget.read.meeting;
    final meetingStart = ChurchTime.timeText(m.startsAt);
    final meetingEnd = ChurchTime.timeText(m.endsAt);
    final last = _rows.isEmpty ? '' : _rows.last.end.text.trim();
    final start = _clockMinutes(last) == null ? meetingStart : last;
    setState(
      () => _rows.add(
        _PartRow(
          key: _nextKey++,
          start: start,
          end: _plusMinutes(start, 15, cap: meetingEnd),
        ),
      ),
    );
  }

  List<ProgrammePartDraft> get _drafts => [
    for (final r in _rows)
      ProgrammePartDraft(
        partId: r.partId,
        label: r.label.text,
        startTime: r.start.text,
        endTime: r.end.text,
        assigneeMemberId: r.assignee,
        linkedSlotId: r.linkedSlot,
      ),
  ];

  @override
  Widget build(BuildContext context) {
    final read = widget.read;
    final m = read.meeting;
    final busy = widget.busy;
    final errors = widget.errors;
    final ctl = ref.read(cellProgrammeProvider(widget.meetingId).notifier);
    final window =
        '${ChurchTime.timeText(m.startsAt)}-${ChurchTime.timeText(m.endsAt)}';
    String? textError(String k, int max) => switch (errors[k]) {
      null => null,
      'too_long' => 'At most $max characters',
      _ => 'Use letters, numbers and punctuation',
    };
    final names = <String, String>{
      for (final r in read.roster) 'm:${r.memberId}': r.displayName,
      for (final l in read.linkable) 'd:${l.slotId}': l.label,
    };
    final dirty = _dirty;
    final overrideAsked =
        needsOverrideReason(errors) || errors.containsKey('override_reason');
    // Who the saved parts name that is no longer offered (kept so the row
    // shows who), from the current offer.
    final former = <String, String>{
      for (final part in widget.programme.parts)
        if (part.assignee case final a? when !a.inCell)
          'm:${a.memberId}': '${a.displayName} (left the cell)',
      for (final part in widget.programme.parts)
        if (part.linkedSlotId case final slot?
            when !read.linkable.any((l) => l.slotId == slot))
          'd:$slot':
              '${part.linkedLabel ?? 'Department duty'} (no longer offered)',
    };
    final editor = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_stale) ...[
          RequestStateBanner(
            key: const Key('plan-stale'),
            tone: StatusTone.warning,
            title: 'Changed elsewhere',
            message:
                'Someone saved this draft, or the meeting moved, since you '
                'started. Your edits are kept below; saving now replaces the '
                'other version.',
            actions: [
              BannerAction(
                'Load the latest',
                () => setState(() => _load(widget.programme)),
                key: const Key('plan-load-latest'),
              ),
            ],
          ),
          const SizedBox(height: 12),
        ],
        _Card(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                key: const Key('plan-topic'),
                controller: _topic,
                enabled: !busy,
                maxLength: 120,
                decoration: InputDecoration(
                  labelText: 'Bible study topic',
                  errorText: textError('topic', 120),
                ),
                onChanged: (_) => setState(() {}),
              ),
              TextField(
                key: const Key('plan-scripture'),
                controller: _scripture,
                enabled: !busy,
                maxLength: 120,
                decoration: InputDecoration(
                  labelText: 'Scripture',
                  errorText: textError('scripture', 120),
                ),
                onChanged: (_) => setState(() {}),
              ),
              TextField(
                key: const Key('plan-notes'),
                controller: _notes,
                enabled: !busy,
                maxLength: 2000,
                minLines: 2,
                maxLines: 6,
                decoration: InputDecoration(
                  labelText: 'Study notes (for the leader and assistant)',
                  errorText: textError('study_notes', 2000),
                ),
                onChanged: (_) => setState(() {}),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        _Card(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _heading(context, 'Programme'),
              _muted(
                context,
                'In time order, inside the meeting ($window, church time), '
                'without overlaps. A part without a person is a gap. A '
                'department duty can be shown on a part; it stays the '
                'department\'s.',
              ),
              const SizedBox(height: 8),
              if (_rows.isEmpty)
                const Text('No parts yet.', key: Key('plan-no-parts')),
              for (final (i, r) in _rows.indexed)
                _PartEditorRow(
                  key: ValueKey('part-row-${r.key}'),
                  index: i,
                  row: r,
                  roster: read.roster,
                  linkable: read.linkable,
                  former: former,
                  busy: busy,
                  error: _partErrorText(errors, i, window),
                  onChanged: () => setState(() {}),
                  onRemove: () {
                    // The refused save's errors were for the old rows
                    // (5.3 review fix 11).
                    ctl.clearFieldErrors();
                    setState(() {
                      _rows.remove(r);
                      r.dispose();
                    });
                  },
                ),
              const SizedBox(height: 4),
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: FocusRing(
                  child: OutlinedButton(
                    key: const Key('plan-add-part'),
                    onPressed: busy || _rows.length >= programmeMaxParts
                        ? null
                        : _addPart,
                    child: Text(
                      _rows.length >= programmeMaxParts
                          ? 'At most $programmeMaxParts parts'
                          : 'Add a part',
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        if (overrideAsked) ...[
          TextField(
            key: const Key('plan-override'),
            controller: _reason,
            enabled: !busy,
            maxLength: 280,
            decoration: InputDecoration(
              labelText: 'Why these people may still take their parts',
              helperText:
                  'Someone is on another duty at the same time. Change the '
                  'part, or give a reason to publish anyway.',
              errorText: errors['override_reason'] == null
                  ? null
                  : 'Check the reason',
            ),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 8),
        ],
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            FocusRing(
              child: OutlinedButton(
                key: const Key('plan-save'),
                onPressed: busy
                    ? null
                    : () => ctl.save(
                        widget.programme,
                        topic: _topic.text,
                        scripture: _scripture.text,
                        studyNotes: _notes.text,
                        parts: _drafts,
                      ),
                child: const Text('Save draft'),
              ),
            ),
            FocusRing(
              child: FilledButton(
                key: Key(
                  overrideAsked ? 'plan-publish-override' : 'plan-publish',
                ),
                onPressed:
                    busy ||
                        dirty ||
                        _stale ||
                        _rows.isEmpty ||
                        (overrideAsked && _reason.text.trim().isEmpty)
                    ? null
                    : () => ctl.publish(
                        widget.programme,
                        overrideReason: overrideAsked ? _reason.text : null,
                      ),
                child: Text(
                  overrideAsked
                      ? 'Publish with this reason'
                      : widget.programme.published
                      ? 'Publish changes'
                      : 'Publish to members',
                ),
              ),
            ),
            if (dirty)
              _muted(context, 'Save the draft to publish it.')
            else if (_rows.isEmpty)
              _muted(context, 'Add a part to publish.'),
            if (widget.programme.published)
              const SizedBox.shrink()
            else if (!_confirmCancel)
              FocusRing(
                child: TextButton(
                  key: const Key('plan-cancel'),
                  onPressed: busy
                      ? null
                      : () => setState(() => _confirmCancel = true),
                  child: const Text('Cancel this programme'),
                ),
              )
            else ...[
              const Text('Cancel it? It stays read-only.'),
              FocusRing(
                child: TextButton(
                  key: const Key('plan-cancel-confirm'),
                  onPressed: busy ? null : () => ctl.cancel(widget.programme),
                  child: const Text('Yes, cancel the programme'),
                ),
              ),
              FocusRing(
                child: TextButton(
                  key: const Key('plan-cancel-keep'),
                  onPressed: () => setState(() => _confirmCancel = false),
                  child: const Text('Keep it'),
                ),
              ),
            ],
          ],
        ),
      ],
    );
    final preview = _ProgrammePreview(
      meeting: m,
      topic: _topic.text.trim().isEmpty ? null : _topic.text.trim(),
      scripture: _scripture.text.trim().isEmpty ? null : _scripture.text.trim(),
      studyNotes: null,
      parts: [
        for (final r in _rows)
          (
            start: r.start.text.trim(),
            end: r.end.text.trim(),
            label: r.label.text.trim().isEmpty ? 'Untitled part' : r.label.text,
            who: r.who == null ? null : names[r.who] ?? former[r.who],
            leftCell: r.who != null && !names.containsKey(r.who),
          ),
      ],
      caption:
          'What members will see once it is published. They see nothing of '
          'a draft, and no answers or notes.',
    );
    return LayoutBuilder(
      builder: (context, box) => box.maxWidth >= 860
          ? Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: editor),
                const SizedBox(width: 16),
                SizedBox(width: 300, child: preview),
              ],
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [editor, const SizedBox(height: 16), preview],
            ),
    );
  }
}

String? _partErrorText(Map<String, String> errors, int index, String window) {
  final duty = partDutyError(errors, index, 'member_id');
  if (duty != null) {
    return switch (duty) {
      'overlap' => 'On another duty at this time',
      _ => 'This person can\'t be given this part',
    };
  }
  if (errors.keys.any((k) => k.startsWith('parts.$index.')) &&
      partDutyError(errors, index, 'override_reason') == null) {
    return 'Duties refused this part. Change it and try again.';
  }
  return switch (partError(errors, index)) {
    null => null,
    'label_required' => 'Name this part',
    'label_too_long' => 'At most 60 characters',
    'label_invalid' => 'Use letters, numbers and punctuation',
    'start_invalid' => 'Start as HH:MM',
    'end_invalid' || 'end_or_duration' => 'End as HH:MM',
    'end_before_start' => 'It must end after it starts',
    'outside_meeting' => 'Keep it inside the meeting ($window)',
    'out_of_order' => 'Starts before the part above: keep the time order',
    'overlap' => 'Overlaps the part above',
    'assignee_not_in_cell' => 'Choose someone in the cell, or nobody',
    'assignee_and_link' => 'A person or a department duty, not both',
    'published_kind' =>
      'Published with a person or with a department duty: remove this part '
          'and add a new one to change that',
    'link_unavailable' => 'That department duty is no longer offered',
    _ => 'Reload the page and try again',
  };
}

/// Minutes since midnight of a church-local `HH:MM`, or null.
int? _clockMinutes(String t) {
  final p = t.split(':');
  if (p.length != 2) return null;
  final h = int.tryParse(p[0]), m = int.tryParse(p[1]);
  if (h == null || m == null || h < 0 || h > 23 || m < 0 || m > 59) {
    return null;
  }
  return h * 60 + m;
}

/// `18:00` plus [minutes], no later than [cap] (both church-local `HH:MM`;
/// a cap before the start is after midnight). Never past 23:59: the next
/// day's time is written as such (`00:10`).
String _plusMinutes(String hhmm, int minutes, {required String cap}) {
  final start = _clockMinutes(hhmm);
  if (start == null) return hhmm;
  var end = _clockMinutes(cap);
  if (end != null && end < start) end += 24 * 60;
  var v = start + minutes;
  if (end != null && v > end) v = end;
  v %= 24 * 60;
  return '${(v ~/ 60).toString().padLeft(2, '0')}:'
      '${(v % 60).toString().padLeft(2, '0')}';
}

class _PartEditorRow extends StatelessWidget {
  const _PartEditorRow({
    super.key,
    required this.index,
    required this.row,
    required this.roster,
    required this.linkable,
    required this.former,
    required this.busy,
    required this.error,
    required this.onChanged,
    required this.onRemove,
  });
  final int index;
  final _PartRow row;
  final List<ProgrammeRosterMember> roster;
  final List<LinkableDuty> linkable;
  final Map<String, String> former;
  final bool busy;
  final String? error;
  final VoidCallback onChanged;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final c = ChurchColors.of(context);
    final n = index + 1;
    final value = row.who;
    final offered = <String>{
      for (final r in roster) 'm:${r.memberId}',
      for (final l in linkable) 'd:${l.slotId}',
    };
    final known = value == null || offered.contains(value);
    final who = DropdownButton<String?>(
      key: Key('part-assignee-$index'),
      isExpanded: true,
      value: value,
      hint: const Text('Nobody yet'),
      items: [
        const DropdownMenuItem<String?>(value: null, child: Text('Nobody yet')),
        for (final r in roster)
          DropdownMenuItem<String?>(
            value: 'm:${r.memberId}',
            child: Text(
              r.offApp ? '${r.displayName} (no app login)' : r.displayName,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        for (final l in linkable)
          DropdownMenuItem<String?>(
            value: 'd:${l.slotId}',
            child: Text(
              'Department duty: ${l.label}',
              overflow: TextOverflow.ellipsis,
            ),
          ),
        if (!known)
          DropdownMenuItem<String?>(
            value: value,
            child: Text(
              former[value] ?? 'Someone (left the cell)',
              overflow: TextOverflow.ellipsis,
            ),
          ),
      ],
      onChanged: busy
          ? null
          : (v) {
              row.who = v;
              onChanged();
            },
    );
    Widget clock(TextEditingController ctl, String label, String key) =>
        SizedBox(
          width: 92,
          child: TextField(
            key: Key('part-$key-$index'),
            controller: ctl,
            enabled: !busy,
            keyboardType: TextInputType.datetime,
            decoration: InputDecoration(labelText: label, hintText: 'HH:MM'),
            onChanged: (_) => onChanged(),
          ),
        );
    final label = TextField(
      key: Key('part-label-$index'),
      controller: row.label,
      enabled: !busy,
      maxLength: 60,
      decoration: InputDecoration(
        labelText: 'Part $n',
        counterText: '',
        hintText: 'Opening prayer',
      ),
      onChanged: (_) => onChanged(),
    );
    final remove = IconButton(
      key: Key('part-remove-$index'),
      tooltip: 'Remove part $n',
      onPressed: busy ? null : onRemove,
      icon: const Icon(Icons.close),
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Semantics(
        container: true,
        label: 'Part $n',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            LayoutBuilder(
              builder: (context, box) => box.maxWidth >= 560
                  ? Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        clock(row.start, 'Starts', 'start'),
                        const SizedBox(width: 8),
                        clock(row.end, 'Ends', 'end'),
                        const SizedBox(width: 8),
                        Expanded(flex: 3, child: label),
                        const SizedBox(width: 8),
                        Expanded(flex: 2, child: who),
                        remove,
                      ],
                    )
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          children: [
                            clock(row.start, 'Starts', 'start'),
                            const SizedBox(width: 8),
                            clock(row.end, 'Ends', 'end'),
                            const Spacer(),
                            remove,
                          ],
                        ),
                        label,
                        who,
                      ],
                    ),
            ),
            if (value == null)
              Text(
                'Gap: nobody leads this part yet',
                key: Key('part-gap-$index'),
                style: ChurchType.secondary.copyWith(color: c.amberFg),
              )
            else if (!known)
              Text(
                value.startsWith('d:')
                    ? 'That department duty is no longer offered. Choose '
                          'again.'
                    : 'This person has left the cell. Choose someone else.',
                style: ChurchType.secondary.copyWith(color: c.amberFg),
              ),
            if (error case final e?)
              Text(
                e,
                key: Key('part-error-$index'),
                style: ChurchType.secondary.copyWith(color: c.redFg),
              ),
          ],
        ),
      ),
    );
  }
}

/// Story 5.6: a published programme for its managers: unpublished changes
/// first (the banner publishes them while the editor is closed; once open,
/// the editor's own **Publish changes** checks what is typed), then who is
/// on, then **Change the programme** (the same editor). Members keep the last
/// publish until the changes are published.
class _PublishedEditor extends ConsumerStatefulWidget {
  const _PublishedEditor({
    required this.meetingId,
    required this.read,
    required this.programme,
    required this.busy,
    required this.errors,
    required this.open,
  });
  final String meetingId;
  final ProgrammeRead read;
  final CellProgramme programme;
  final bool busy;
  final Map<String, String> errors;

  /// The meeting is ahead and not cancelled.
  final bool open;

  @override
  ConsumerState<_PublishedEditor> createState() => _PublishedEditorState();
}

class _PublishedEditorState extends ConsumerState<_PublishedEditor> {
  late bool _editing = widget.programme.unpublishedChanges;

  @override
  Widget build(BuildContext context) {
    final p = widget.programme;
    final ctl = ref.read(cellProgrammeProvider(widget.meetingId).notifier);
    // A refusal that needs the editor (an overlap reason, a part to fix)
    // opens it (5.6 review fix 3).
    final editing =
        _editing ||
        needsOverrideReason(widget.errors) ||
        widget.errors.keys.any((k) => k.startsWith('parts.'));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.open && (p.unpublishedChanges || p.meetingChanged)) ...[
          RequestStateBanner(
            key: const Key('plan-unpublished'),
            tone: StatusTone.warning,
            title: p.meetingChanged
                ? 'The meeting changed since you published'
                : 'Changes not published yet',
            message: editing
                ? 'Members and everyone with a part still have the last '
                      'version. Publish your changes below.'
                : 'Members and everyone with a part still have the last '
                      'version. Publishing asks people again only where '
                      'their part changed.',
            actions: [
              if (!editing)
                BannerAction(
                  'Publish changes',
                  widget.busy ? null : () => ctl.publish(p),
                  key: const Key('plan-publish-changes'),
                  primary: true,
                ),
            ],
          ),
          const SizedBox(height: 12),
        ],
        _PublishedView(
          meetingId: widget.meetingId,
          read: widget.read,
          programme: p,
          busy: widget.busy,
          open: widget.open,
        ),
        if (widget.open)
          Padding(
            padding: const EdgeInsets.only(top: 16),
            child: editing
                ? _ProgrammeEditor(
                    meetingId: widget.meetingId,
                    read: widget.read,
                    programme: p,
                    busy: widget.busy,
                    errors: widget.errors,
                  )
                : Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: FocusRing(
                      child: OutlinedButton(
                        key: const Key('plan-change-published'),
                        onPressed: widget.busy
                            ? null
                            : () => setState(() => _editing = true),
                        child: const Text('Change the programme'),
                      ),
                    ),
                  ),
          ),
      ],
    );
  }
}

/// Story 5.4: a published programme for its managers: each part with who
/// leads it and their answer (colour only on the answer), what members see
/// now, and cancelling. Changing a published programme comes with 5.6.
class _PublishedView extends ConsumerStatefulWidget {
  const _PublishedView({
    required this.meetingId,
    required this.read,
    required this.programme,
    required this.busy,
    required this.open,
  });
  final String meetingId;
  final ProgrammeRead read;
  final CellProgramme programme;
  final bool busy;
  final bool open;

  @override
  ConsumerState<_PublishedView> createState() => _PublishedViewState();
}

class _PublishedViewState extends ConsumerState<_PublishedView> {
  bool _confirmCancel = false;

  /// Story 5.5: the part whose direct confirmation is being recorded.
  String? _confirming;
  ContactChannel _channel = ContactChannel.phone;
  final _reason = TextEditingController();

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  Widget _confirmForm(PartDuty d, bool busy) {
    final ctl = ref.read(cellProgrammeProvider(widget.meetingId).notifier);
    final draft = LeaderConfirmationDraft(
      channel: _channel,
      reason: _reason.text,
    );
    final ok = draft.errors().isEmpty;
    return Padding(
      padding: const EdgeInsets.only(left: 52, bottom: 12),
      child: Column(
        key: Key('confirm-form-${d.partId}'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _muted(
            context,
            'Record that they said yes to you directly. It shows as '
            'Confirmed by leader, with your name.',
          ),
          DropdownButton<ContactChannel>(
            key: Key('confirm-channel-${d.partId}'),
            value: _channel,
            items: [
              for (final c in ContactChannel.values)
                DropdownMenuItem(value: c, child: Text(c.label)),
            ],
            onChanged: busy
                ? null
                : (v) => setState(() => _channel = v ?? _channel),
          ),
          TextField(
            key: Key('confirm-reason-${d.partId}'),
            controller: _reason,
            enabled: !busy,
            maxLength: LeaderConfirmationDraft.reasonMax,
            decoration: const InputDecoration(
              labelText: 'What they said (short)',
              hintText: 'Said yes on the phone on Tuesday',
            ),
            onChanged: (_) => setState(() {}),
          ),
          Wrap(
            spacing: 8,
            children: [
              FocusRing(
                child: FilledButton(
                  key: Key('confirm-save-${d.partId}'),
                  onPressed: busy || !ok
                      ? null
                      // The form closes once the part shows the answer;
                      // a refusal keeps what was typed.
                      : () => ctl.confirmByLeader(d, draft),
                  child: const Text('Record: confirmed by leader'),
                ),
              ),
              FocusRing(
                child: TextButton(
                  key: Key('confirm-keep-${d.partId}'),
                  onPressed: busy
                      ? null
                      : () => setState(() => _confirming = null),
                  child: const Text('Not now'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final read = widget.read;
    final p = widget.programme;
    final busy = widget.busy;
    final ctl = ref.read(cellProgrammeProvider(widget.meetingId).notifier);
    final c = ChurchColors.of(context);
    final list = _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _heading(context, 'Who is on'),
          for (final part in p.parts) ...[
            Padding(
              key: Key('published-part-${part.partId}'),
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 52,
                    child: Text(
                      ChurchTime.timeText(part.startsAt),
                      style: ChurchType.secondary.copyWith(
                        color: c.muted,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(part.label),
                        Text(
                          part.assignee?.displayName ??
                              part.linkedLabel ??
                              'Nobody yet',
                          style: ChurchType.secondary.copyWith(color: c.muted),
                        ),
                      ],
                    ),
                  ),
                  if (read.duties[part.partId] case final d?)
                    Flexible(
                      child: Wrap(
                        spacing: 4,
                        runSpacing: 4,
                        alignment: WrapAlignment.end,
                        children: [
                          StatusLabel(
                            key: Key('published-status-${part.partId}'),
                            label:
                                part.linkedSlotId != null &&
                                    d.status == PartDutyStatus.open
                                ? 'Department duty: link ended'
                                : d.label,
                            tone: switch (d.status) {
                              PartDutyStatus.accepted ||
                              PartDutyStatus.departmentFilled =>
                                StatusTone.success,
                              PartDutyStatus.declined => StatusTone.danger,
                              PartDutyStatus.open ||
                              PartDutyStatus.departmentOpen =>
                                StatusTone.warning,
                              PartDutyStatus.awaiting => StatusTone.info,
                              PartDutyStatus.cancelled => StatusTone.neutral,
                            },
                          ),
                          if (d.needsContact)
                            const StatusLabel(
                              label: 'Tell directly',
                              tone: StatusTone.warning,
                            ),
                          if (read.absenceFor(part.partId) != null)
                            StatusLabel(
                              key: Key('published-absence-${part.partId}'),
                              label: 'Can\'t attend',
                              tone: StatusTone.warning,
                            ),
                          if (d.confirmable && _confirming != part.partId)
                            FocusRing(
                              child: TextButton(
                                key: Key('confirm-part-${part.partId}'),
                                onPressed: busy || !widget.open
                                    ? null
                                    : () => setState(() {
                                        _confirming = part.partId;
                                        _reason.clear();
                                      }),
                                child: const Text('They said yes directly'),
                              ),
                            ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
            if (_confirming == part.partId)
              if (read.duties[part.partId] case final d? when d.confirmable)
                _confirmForm(d, busy),
          ],
          _muted(
            context,
            'Each person answers in the app (My duties). A change reaches '
            'them when you publish it.',
          ),
        ],
      ),
    );
    final seen = read.membersSee;
    final preview = seen == null
        ? const SizedBox.shrink()
        : _ProgrammePreview(
            meeting: read.meeting,
            topic: seen.topic,
            scripture: seen.scripture,
            studyNotes: null,
            parts: [
              for (final part in seen.parts)
                (
                  start: ChurchTime.timeText(part.startsAt),
                  end: ChurchTime.timeText(part.endsAt),
                  label: part.label,
                  who: part.leader ?? part.department,
                  leftCell: false,
                ),
            ],
            caption: 'What members of the cell see now.',
          );
    final actions = Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        if (!_confirmCancel)
          FocusRing(
            child: TextButton(
              key: const Key('plan-cancel'),
              onPressed: busy || !widget.open
                  ? null
                  : () => setState(() => _confirmCancel = true),
              child: const Text('Cancel this programme'),
            ),
          )
        else ...[
          const Text(
            'Cancel it? Members stop seeing it, and everyone with a part is '
            'told.',
          ),
          FocusRing(
            child: TextButton(
              key: const Key('plan-cancel-confirm'),
              onPressed: busy ? null : () => ctl.cancel(p),
              child: const Text('Yes, cancel the programme'),
            ),
          ),
          FocusRing(
            child: TextButton(
              key: const Key('plan-cancel-keep'),
              onPressed: () => setState(() => _confirmCancel = false),
              child: const Text('Keep it'),
            ),
          ),
        ],
      ],
    );
    return LayoutBuilder(
      builder: (context, box) => box.maxWidth >= 860
          ? Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [list, const SizedBox(height: 12), actions],
                  ),
                ),
                const SizedBox(width: 16),
                SizedBox(width: 300, child: preview),
              ],
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                list,
                const SizedBox(height: 12),
                actions,
                const SizedBox(height: 16),
                preview,
              ],
            ),
    );
  }
}

/// The programme as a member's phone will show it once published: time,
/// part and who leads it. A gap reads "Open" in the warning colour.
class _ProgrammePreview extends StatelessWidget {
  const _ProgrammePreview({
    required this.meeting,
    required this.topic,
    required this.scripture,
    required this.studyNotes,
    required this.parts,
    required this.caption,
  });
  final CellMeeting meeting;
  final String? topic;
  final String? scripture;
  final String? studyNotes;
  final List<_PreviewPart> parts;
  final String? caption;

  @override
  Widget build(BuildContext context) {
    final c = ChurchColors.of(context);
    return Column(
      key: const Key('plan-preview'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (caption case final text?) ...[
          _muted(context, text),
          const SizedBox(height: 8),
        ],
        _Card(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _heading(context, 'Next meeting'),
              Text(
                _meetingWhen(context, meeting),
                style: ChurchType.sectionTitle.copyWith(color: c.ink),
              ),
              if (meeting.venue case final v?) Text(v),
              if (topic != null || scripture != null) ...[
                const SizedBox(height: 8),
                if (topic case final t?)
                  Text(t, style: ChurchType.cardTitle.copyWith(color: c.ink)),
                if (scripture case final s?)
                  Text(s, style: ChurchType.secondary.copyWith(color: c.muted)),
              ],
              if (studyNotes case final n?) ...[
                const SizedBox(height: 8),
                Text(n),
              ],
              const SizedBox(height: 8),
              if (parts.isEmpty)
                _muted(context, 'No parts yet.')
              else
                for (final p in parts)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(
                          width: 52,
                          child: Text(
                            p.start,
                            style: ChurchType.secondary.copyWith(
                              color: c.muted,
                              fontFeatures: const [
                                FontFeature.tabularFigures(),
                              ],
                            ),
                          ),
                        ),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(p.label),
                              Text(
                                p.who == null
                                    ? 'Open: nobody yet'
                                    : p.leftCell
                                    ? '${p.who} (left the cell)'
                                    : p.who!,
                                style: ChurchType.secondary.copyWith(
                                  color: p.who == null || p.leftCell
                                      ? c.amberFg
                                      : c.muted,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
            ],
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Story 5.5, mobile: You're on (My cell and Home)
// ---------------------------------------------------------------------------

/// The member's own Duties answer for a programme part, from My duties:
/// the duty, or why it is not known yet.
sealed class _OwnDuty {
  const _OwnDuty();
}

class _OwnDutyFound extends _OwnDuty {
  const _OwnDutyFound(this.duty);
  final MyDuty duty;
}

class _OwnDutyLoading extends _OwnDuty {
  const _OwnDutyLoading();
}

class _OwnDutyUnavailable extends _OwnDuty {
  const _OwnDutyUnavailable();
}

_OwnDuty _ownDuty(WidgetRef ref, String occurrenceId) {
  final s = ref.watch(myDutiesProvider);
  return switch (s.result) {
    null => const _OwnDutyLoading(),
    AccessReadOk(:final value) => () {
      for (final d in value.assignments) {
        if (d.occurrenceId == occurrenceId) return _OwnDutyFound(d);
      }
      // Listed in the programme but not (yet) in My duties: a reload is
      // under way, or the part changed.
      return s.loading ? const _OwnDutyLoading() : const _OwnDutyUnavailable();
    }(),
    _ => const _OwnDutyUnavailable(),
  };
}

/// The member's answer as the Duties read reports it (the colour is on the
/// answer only). The words match My duties.
(String, StatusTone) _ownAnswer(MyDuty d) => switch (d.response) {
  DutyResponse.pending => ('Awaiting your answer', StatusTone.warning),
  DutyResponse.accepted when d.confirmedByLeader => (
    'Confirmed by leader',
    StatusTone.success,
  ),
  DutyResponse.accepted => ('Accepted', StatusTone.success),
  DutyResponse.declined => ('Can\'t make it', StatusTone.neutral),
};

/// Story 5.5, mobile My cell: the next meeting's published programme. The
/// member's own part leads ("You're on") with its real answer, reporting
/// time and instructions, and Accept or Can't do it (the Duties response
/// commands, the same as My duties). Other people's parts show names only,
/// never answers. Nothing is shown of a draft.
class _MyCellProgrammeCard extends ConsumerStatefulWidget {
  const _MyCellProgrammeCard({super.key, required this.meetingId});
  final String meetingId;

  @override
  ConsumerState<_MyCellProgrammeCard> createState() =>
      _MyCellProgrammeCardState();
}

class _MyCellProgrammeCardState extends ConsumerState<_MyCellProgrammeCard> {
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onResume: _reload);
  }

  void _reload() {
    if (!mounted) return;
    ref.read(memberProgrammeProvider(widget.meetingId).notifier).reload();
    final d = ref.read(myDutiesProvider);
    if (!d.busy && !d.loading) ref.read(myDutiesProvider.notifier).reload();
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = ChurchColors.of(context);
    final s = ref.watch(memberProgrammeProvider(widget.meetingId));
    final result = s.result;
    if (result == null) {
      return _Card(
        key: const Key('my-cell-programme-loading'),
        child: _muted(context, 'Loading the programme…'),
      );
    }
    if (result is! AccessReadOk<MeetingProgrammeRead>) {
      return _Card(
        key: const Key('my-cell-programme-unavailable'),
        child: _muted(
          context,
          'The programme could not be loaded. Try again later.',
        ),
      );
    }
    final read = result.value;
    final p = read.programme;
    // Story 5.7: Can't come? is the member's to say whatever the programme.
    final absence = _AbsenceSection(meetingId: widget.meetingId, read: read);
    if (p == null) {
      return _Card(
        key: const Key('my-cell-programme-none'),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _muted(
              context,
              'The programme for this meeting is not published yet.',
            ),
            const SizedBox(height: 12),
            absence,
          ],
        ),
      );
    }
    return _Card(
      key: const Key('my-cell-programme'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // The member's first question: am I on, and have I answered?
          for (final part in p.parts)
            if (read.occurrenceOf(part.partId) case final occ?) ...[
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: c.blueBg,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: _YoureOn(
                  key: Key('my-cell-yours-${part.partId}'),
                  part: part,
                  own: _ownDuty(ref, occ),
                ),
              ),
              const SizedBox(height: 16),
            ],
          const CardLabel('Programme'),
          const SizedBox(height: 8),
          if (p.meetingChanged)
            Text(
              'The meeting moved. Your leader is updating the programme; '
              'the times below may change.',
              key: const Key('my-cell-programme-updating'),
              style: ChurchType.secondary.copyWith(color: c.amberFg),
            ),
          if (p.topic case final t?)
            Text(t, style: ChurchType.itemTitle.copyWith(color: c.ink)),
          if (p.scripture case final sc?)
            Text(sc, style: ChurchType.secondary.copyWith(color: c.muted)),
          const SizedBox(height: 4),
          for (final (i, part) in p.parts.indexed)
            Container(
              key: Key('my-cell-part-${part.partId}'),
              padding: const EdgeInsets.symmetric(vertical: 10),
              decoration: BoxDecoration(
                border: i == 0 ? null : Border(top: BorderSide(color: c.line)),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 56,
                    child: Text(
                      ChurchTime.timeText(part.startsAt),
                      style: ChurchType.programmeTime.copyWith(
                        color: c.muted,
                        height: 1.6,
                      ),
                    ),
                  ),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          part.label,
                          style: ChurchType.body.copyWith(
                            color: c.ink,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        if (read.occurrenceOf(part.partId) == null)
                          Text(
                            part.leader ?? part.department ?? 'Open',
                            style: ChurchType.secondary.copyWith(
                              color: c.muted,
                            ),
                          ),
                      ],
                    ),
                  ),
                  if (read.occurrenceOf(part.partId) != null)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: c.blueBg,
                        borderRadius: BorderRadius.circular(99),
                      ),
                      child: Text(
                        'You',
                        style: ChurchType.chip.copyWith(color: c.blueFg),
                      ),
                    ),
                ],
              ),
            ),
          const SizedBox(height: 12),
          Divider(height: 1, color: c.line),
          const SizedBox(height: 12),
          absence,
        ],
      ),
    );
  }
}

/// One of the member's own parts: what, when to report, the instructions,
/// and their answer. Accept or Can't do it while it waits (Can't do it asks
/// once more, as My duties does); Can't make it anymore after accepting.
/// Sending and a refused answer are said here, not only in My duties.
class _YoureOn extends ConsumerStatefulWidget {
  const _YoureOn({super.key, required this.part, required this.own});
  final ProjectionPart part;
  final _OwnDuty own;

  @override
  ConsumerState<_YoureOn> createState() => _YoureOnState();
}

class _YoureOnState extends ConsumerState<_YoureOn> {
  /// The answer waiting for the member's second tap.
  DutyResponse? _confirming;
  bool _withdrawing = false;

  @override
  Widget build(BuildContext context) {
    final c = ChurchColors.of(context);
    final part = widget.part;
    final s = ref.watch(myDutiesProvider);
    final ctl = ref.read(myDutiesProvider.notifier);
    final now = DateTime.now().toUtc();
    final children = <Widget>[
      Semantics(
        header: true,
        child: Text(
          'You\'re on',
          style: ChurchType.label.copyWith(color: c.blueFg),
        ),
      ),
      const SizedBox(height: 4),
      Text(
        '${part.label} · ${ChurchTime.timeText(part.startsAt)}'
        '–${ChurchTime.timeText(part.endsAt)}',
        style: ChurchType.itemTitle.copyWith(color: c.ink),
      ),
    ];
    switch (widget.own) {
      case _OwnDutyLoading():
        children.add(_muted(context, 'Loading your answer…'));
      case _OwnDutyUnavailable():
        children.add(
          _muted(
            context,
            'Your answer could not be loaded here. Open My duties to see '
            'and answer this part.',
          ),
        );
      case _OwnDutyFound(:final duty):
        final (label, tone) = _ownAnswer(duty);
        final mine =
            s.pending?.request.payload['assignment_id'] == duty.assignmentId ||
            s.noticeAction?.request.payload['assignment_id'] ==
                duty.assignmentId;
        final busy = s.busy;
        children.addAll([
          const SizedBox(height: 4),
          StatusLabel(
            key: Key('my-cell-status-${part.partId}'),
            label: label,
            tone: tone,
          ),
          if (duty.times.reportingAt case final r?)
            Text('Please arrive by ${ChurchTime.timeText(r)}'),
          if (duty.instructions case final i?) Text(i),
          if (mine && s.pending != null)
            _muted(context, 'Sending your answer…')
          else if (mine &&
              s.notice != null &&
              s.notice != DutyNotice.accepted &&
              s.notice != DutyNotice.declined &&
              s.notice != DutyNotice.withdrawn)
            Text(
              switch (s.notice) {
                DutyNotice.unconfirmed =>
                  'We don\'t know yet whether your answer arrived. Check '
                      'My duties.',
                DutyNotice.notSent =>
                  'Not sent: this build has no server configured.',
                _ =>
                  'Your answer was not recorded: this part changed or '
                      'could not be answered. Check My duties.',
              },
              key: Key('my-cell-answer-problem-${part.partId}'),
              style: ChurchType.secondary.copyWith(color: c.redFg),
            ),
        ]);
        if (duty.needsResponse(now) && duty.answerable) {
          children.add(const SizedBox(height: 8));
          if (_confirming == DutyResponse.declined) {
            children.add(
              Wrap(
                spacing: 8,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  const Text('Tell your leader you can\'t do this part?'),
                  FocusRing(
                    child: FilledButton(
                      key: Key('my-cell-decline-confirm-${part.partId}'),
                      onPressed: busy
                          ? null
                          : () {
                              setState(() => _confirming = null);
                              ctl.respond(duty, DutyResponse.declined);
                            },
                      child: const Text('Yes, I can\'t'),
                    ),
                  ),
                  FocusRing(
                    child: TextButton(
                      key: Key('my-cell-decline-keep-${part.partId}'),
                      onPressed: busy
                          ? null
                          : () => setState(() => _confirming = null),
                      child: const Text('Keep it'),
                    ),
                  ),
                ],
              ),
            );
          } else {
            children.add(
              Wrap(
                spacing: 8,
                children: [
                  FocusRing(
                    child: FilledButton(
                      key: Key('my-cell-accept-${part.partId}'),
                      onPressed: busy
                          ? null
                          : () => ctl.respond(duty, DutyResponse.accepted),
                      child: const Text('Accept'),
                    ),
                  ),
                  FocusRing(
                    child: OutlinedButton(
                      key: Key('my-cell-decline-${part.partId}'),
                      onPressed: busy
                          ? null
                          : () => setState(
                              () => _confirming = DutyResponse.declined,
                            ),
                      child: const Text('Can\'t do it'),
                    ),
                  ),
                ],
              ),
            );
          }
        } else if (duty.canWithdraw(now) && duty.answerable) {
          children.add(
            _withdrawing
                ? Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      const Text('Tell your leader you can\'t make it now?'),
                      FocusRing(
                        child: FilledButton(
                          key: Key('my-cell-withdraw-confirm-${part.partId}'),
                          onPressed: busy
                              ? null
                              : () {
                                  setState(() => _withdrawing = false);
                                  ctl.withdraw(duty);
                                },
                          child: const Text('Yes, I can\'t make it'),
                        ),
                      ),
                      FocusRing(
                        child: TextButton(
                          onPressed: busy
                              ? null
                              : () => setState(() => _withdrawing = false),
                          child: const Text('Keep it'),
                        ),
                      ),
                    ],
                  )
                : FocusRing(
                    child: TextButton(
                      key: Key('my-cell-withdraw-${part.partId}'),
                      onPressed: busy
                          ? null
                          : () => setState(() => _withdrawing = true),
                      child: const Text('Can\'t make it anymore'),
                    ),
                  ),
          );
        }
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: children,
    );
  }
}

/// Story 5.5, mobile Home: My cell, for a member with a confirmed cell: when
/// the cell meets next and, once the programme is published, the member's
/// own part and answer. Opens My cell. Hidden for anyone without a cell.
class MyCellHomeCard extends ConsumerWidget {
  const MyCellHomeCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(myCellProvider);
    final view = switch (s.result) {
      AccessReadOk(:final value) => value,
      _ => null,
    };
    final next = view?.cell.meetings?.next;
    if (view == null || view.cell.primary == null || next == null) {
      return const SizedBox.shrink();
    }
    final c = ChurchColors.of(context);
    return _Card(
      key: const Key('home-my-cell'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Semantics(
            header: true,
            child: Text(
              'My cell',
              style: ChurchType.cardTitle.copyWith(color: c.ink),
            ),
          ),
          Text(
            view.cell.primary!.label,
            style: ChurchType.secondary.copyWith(color: c.muted),
          ),
          const SizedBox(height: 14),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ChurchDateBadge(at: next.startsAt, tone: DateBadgeTone.info),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _meetingWhen(context, next),
                      key: const Key('home-my-cell-when'),
                      style: ChurchType.itemTitle.copyWith(color: c.ink),
                    ),
                    if (next.venue case final v?)
                      Text(
                        v,
                        style: ChurchType.secondary.copyWith(color: c.muted),
                      ),
                    const SizedBox(height: 6),
                    _HomeYoureOn(meetingId: next.meetingId),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          FocusRing(
            child: TextButton(
              key: const Key('home-my-cell-open'),
              style: TextButton.styleFrom(padding: EdgeInsets.zero),
              onPressed: () => context.go(CellPaths.myCell),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(child: Text('Open My cell')),
                  SizedBox(width: 4),
                  Icon(Icons.arrow_forward, size: 18),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// "You're on: Opening prayer, 18:00 · Awaiting your answer" (nothing when
/// the member has no part or nothing is published; says so when the
/// programme could not be loaded).
class _HomeYoureOn extends ConsumerWidget {
  const _HomeYoureOn({required this.meetingId});
  final String meetingId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final result = ref.watch(memberProgrammeProvider(meetingId)).result;
    switch (result) {
      case null:
        return const SizedBox.shrink();
      case AccessReadOk(:final value):
        final programme = value.programme;
        if (programme == null) return const SizedBox.shrink();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final part in programme.parts)
              if (value.occurrenceOf(part.partId) case final occ?)
                Wrap(
                  key: Key('home-my-cell-yours-${part.partId}'),
                  spacing: 8,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      'You\'re on: ${part.label}, '
                      '${ChurchTime.timeText(part.startsAt)}',
                    ),
                    if (_ownDuty(ref, occ) case _OwnDutyFound(:final duty))
                      Builder(
                        builder: (context) {
                          final (label, tone) = _ownAnswer(duty);
                          return StatusLabel(label: label, tone: tone);
                        },
                      ),
                  ],
                ),
          ],
        );
      default:
        return Text(
          'The programme could not be loaded.',
          key: const Key('home-my-cell-programme-unavailable'),
          style: ChurchType.secondary.copyWith(
            color: ChurchColors.of(context).muted,
          ),
        );
    }
  }
}

/// Story 5.7, mobile My cell: Can't come? The member tells the cell's
/// leaders they cannot attend this meeting, with an optional note, and may
/// change the note or say they can come after all. It never answers a duty:
/// a part the member holds stays theirs until they answer it (You're on).
class _AbsenceSection extends ConsumerStatefulWidget {
  const _AbsenceSection({required this.meetingId, required this.read});
  final String meetingId;
  final MeetingProgrammeRead read;

  @override
  ConsumerState<_AbsenceSection> createState() => _AbsenceSectionState();
}

class _AbsenceSectionState extends ConsumerState<_AbsenceSection> {
  bool _editing = false;
  bool _confirmWithdraw = false;
  final _note = TextEditingController();

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = ChurchColors.of(context);
    final s = ref.watch(memberProgrammeProvider(widget.meetingId));
    final ctl = ref.read(memberProgrammeProvider(widget.meetingId).notifier);
    final busy = s.busy;
    final notice = widget.read.myAbsence;
    final ahead = widget.read.meeting.startsAt.isAfter(DateTime.now().toUtc());
    final open = ahead && !widget.read.meeting.cancelled;
    final holdsPart = widget.read.yours.isNotEmpty;
    final absenceAction =
        s.noticeAction?.command.startsWith('cells.') == true &&
        s.noticeAction!.command.contains('cannot_attend');
    final children = <Widget>[_heading(context, 'Can\'t come?')];
    final sending = s.pending?.command.contains('cannot_attend') ?? false;
    // A form closes once the server has the notice; a refusal keeps what was
    // typed (5.7 review fix 8).
    if (_editing && !busy && absenceAction) {
      final n = s.notice;
      if (n == CellNotice.absenceSent || n == CellNotice.absenceChanged) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _editing) setState(() => _editing = false);
        });
      }
    }
    if (sending) {
      children.add(_muted(context, 'Sending…'));
    } else if (s.notice case final n? when absenceAction) {
      final (_, title, message) = _noticeText(n, s.noticeAction);
      children.add(
        Text(
          '$title. $message',
          key: Key('my-cell-absence-notice-${n.name}'),
          style: ChurchType.secondary.copyWith(
            color:
                n == CellNotice.absenceSent ||
                    n == CellNotice.absenceChanged ||
                    n == CellNotice.absenceWithdrawn
                ? c.muted
                : c.redFg,
          ),
        ),
      );
    }
    if (notice != null) {
      children.addAll([
        Text(
          'You told your leader you can\'t attend.',
          key: const Key('my-cell-absence-sent'),
        ),
        if (notice.note case final n?) _muted(context, 'Your note: $n'),
        if (holdsPart)
          Text(
            'Your part is still yours until you answer it above.',
            key: const Key('my-cell-absence-part'),
            style: ChurchType.secondary.copyWith(color: c.amberFg),
          ),
      ]);
    }
    if (!open) {
      if (notice == null) {
        children.add(_muted(context, 'This meeting can no longer be changed.'));
      }
    } else if (_editing) {
      children.addAll([
        TextField(
          key: const Key('my-cell-absence-note'),
          controller: _note,
          enabled: !busy,
          maxLength: CellAbsenceCommands.noteMax,
          decoration: const InputDecoration(
            labelText: 'A note for your leader (optional)',
            hintText: 'Travelling for work',
          ),
        ),
        Wrap(
          spacing: 8,
          children: [
            FocusRing(
              child: FilledButton(
                key: const Key('my-cell-absence-send'),
                onPressed: busy
                    ? null
                    : () {
                        if (notice == null) {
                          ctl.sendCannotAttend(_note.text);
                        } else {
                          ctl.changeCannotAttend(notice, _note.text);
                        }
                      },
                child: Text(
                  notice == null ? 'Tell my leader' : 'Save the note',
                ),
              ),
            ),
            FocusRing(
              child: TextButton(
                key: const Key('my-cell-absence-keep'),
                onPressed: busy ? null : () => setState(() => _editing = false),
                child: const Text('Not now'),
              ),
            ),
          ],
        ),
      ]);
    } else if (notice == null) {
      children.add(
        FocusRing(
          child: OutlinedButton(
            key: const Key('my-cell-absence-start'),
            onPressed: busy
                ? null
                : () => setState(() {
                    _note.clear();
                    _editing = true;
                  }),
            child: const Text('I can\'t attend'),
          ),
        ),
      );
    } else if (_confirmWithdraw) {
      children.add(
        Wrap(
          spacing: 8,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            const Text('Tell your leader you can come after all?'),
            FocusRing(
              child: FilledButton(
                key: const Key('my-cell-absence-withdraw-confirm'),
                onPressed: busy
                    ? null
                    : () {
                        setState(() => _confirmWithdraw = false);
                        ctl.withdrawCannotAttend(notice);
                      },
                child: const Text('Yes, I can come'),
              ),
            ),
            FocusRing(
              child: TextButton(
                onPressed: busy
                    ? null
                    : () => setState(() => _confirmWithdraw = false),
                child: const Text('Keep it'),
              ),
            ),
          ],
        ),
      );
    } else {
      children.add(
        Wrap(
          spacing: 8,
          children: [
            FocusRing(
              child: TextButton(
                key: const Key('my-cell-absence-change'),
                onPressed: busy
                    ? null
                    : () => setState(() {
                        _note.text = notice.note ?? '';
                        _editing = true;
                      }),
                child: const Text('Change the note'),
              ),
            ),
            FocusRing(
              child: TextButton(
                key: const Key('my-cell-absence-withdraw'),
                onPressed: busy
                    ? null
                    : () => setState(() => _confirmWithdraw = true),
                child: const Text('I can come after all'),
              ),
            ),
          ],
        ),
      );
    }
    return Column(
      key: const Key('my-cell-absence'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: children,
    );
  }
}

/// Story 5.7, staff web: who has said they cannot attend, with their note
/// (the cell's leader and assistant only).
class _AbsencesCard extends StatelessWidget {
  const _AbsencesCard({required this.absences});
  final List<StaffAbsence> absences;

  @override
  Widget build(BuildContext context) => _Card(
    key: const Key('plan-absences'),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _heading(context, 'Can\'t attend (${absences.length})'),
        for (final a in absences)
          Padding(
            key: Key('plan-absence-${a.memberId}'),
            padding: const EdgeInsets.only(bottom: 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(a.displayName),
                if (a.note case final n?) _muted(context, n),
                if (a.partIds.isNotEmpty)
                  const StatusLabel(
                    label:
                        'Holds a part: find someone or wait for their answer',
                    tone: StatusTone.warning,
                  ),
              ],
            ),
          ),
      ],
    ),
  );
}

// ---------------------------------------------------------------------------
// Story 5.8: after the meeting (held, who actually led each part)
// ---------------------------------------------------------------------------

/// "Held", "Not held", "Not recorded" or "Cancelled": the status is the data
/// that matters afterwards, so it carries the colour. Null while ahead.
StatusLabel? _statusLabel(MeetingStatus? status, {Key? key}) =>
    switch (status) {
      MeetingStatus.held => StatusLabel(
        key: key,
        label: 'Held',
        tone: StatusTone.success,
      ),
      MeetingStatus.notHeld => StatusLabel(
        key: key,
        label: 'Not held',
        tone: StatusTone.neutral,
      ),
      MeetingStatus.unrecorded => StatusLabel(
        key: key,
        label: 'Not recorded',
        tone: StatusTone.warning,
      ),
      MeetingStatus.cancelled => StatusLabel(
        key: key,
        label: 'Cancelled',
        tone: StatusTone.danger,
      ),
      MeetingStatus.scheduled || null => null,
    };

/// Story 5.8, Plan meeting once the meeting has started: was it held, and
/// who actually led each part. Every value is the leader's explicit choice
/// (the plan is never assumed), a change needs a reason, and the earlier
/// value stays visible. The plan and the duty answers are not touched.
///
/// One block: its state (Held / Not held) on the title row, who recorded
/// it, then the parts as a table (time, part, planned, who led, the action)
/// with "led as planned" one click away.
class _RecordCard extends ConsumerStatefulWidget {
  const _RecordCard({
    required this.meetingId,
    required this.read,
    required this.state,
  });
  final String meetingId;
  final ProgrammeRead read;
  final CellsState<ProgrammeRead> state;

  @override
  ConsumerState<_RecordCard> createState() => _RecordCardState();
}

class _RecordCardState extends ConsumerState<_RecordCard> {
  bool _correcting = false;
  final _reason = TextEditingController();

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = ChurchColors.of(context);
    final read = widget.read;
    final m = read.meeting;
    final record = read.record;
    final s = widget.state;
    final busy = s.busy;
    final ctl = ref.read(cellProgrammeProvider(widget.meetingId).notifier);
    final muted = ChurchType.secondary.copyWith(color: c.muted);
    if (record == null) {
      return StaffSection(
        key: const Key('plan-record'),
        title: 'After the meeting',
        child: read.canRecord
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Was this meeting held?',
                    style: ChurchType.staffBody.copyWith(
                      color: c.ink,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'Say what happened; who led each part comes next.',
                    style: muted,
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      FocusRing(
                        child: FilledButton(
                          key: const Key('record-held'),
                          style: _mtgCompact(),
                          onPressed: busy
                              ? null
                              : () => ctl.recordHeld(m, held: true),
                          child: const Text('Yes, it was held'),
                        ),
                      ),
                      FocusRing(
                        child: OutlinedButton(
                          key: const Key('record-not-held'),
                          style: _mtgCompact(),
                          onPressed: busy
                              ? null
                              : () => ctl.recordHeld(m, held: false),
                          child: const Text('It didn\'t happen'),
                        ),
                      ),
                    ],
                  ),
                ],
              )
            : Text(
                'Not recorded yet. The cell\'s leader or assistant records it.',
                key: const Key('record-none'),
                style: ChurchType.staffBody.copyWith(color: c.muted),
              ),
      );
    }
    final latest = record.history.isEmpty ? null : record.history.first;
    final children = <Widget>[
      if (latest != null)
        Text(
          'Recorded by ${latest.by ?? 'Removed member'}, '
          '${ChurchTime.dateText(latest.at)}',
          style: muted,
        ),
      if (latest?.reason case final r?)
        Text('Why it changed: $r', style: muted),
      // Earlier values, newest first.
      for (final h in record.history.skip(1))
        Text(
          'Earlier: ${h.held ? 'held' : 'not held'} '
          '(${h.by ?? 'Removed member'}, ${ChurchTime.dateText(h.at)})',
          style: muted,
        ),
    ];
    if (read.canRecord) {
      if (_correcting) {
        // A correction closes once the server has it; a refusal keeps it.
        if (s.notice == CellNotice.recordCorrected && !busy) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && _correcting) {
              setState(() => _correcting = false);
              _reason.clear();
            }
          });
        }
        children.add(
          Container(
            margin: const EdgeInsets.only(top: 10),
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
            decoration: BoxDecoration(
              color: c.bg,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  key: const Key('record-reason'),
                  controller: _reason,
                  maxLength: CellRecordCommands.reasonMax,
                  enabled: !busy,
                  decoration: InputDecoration(
                    labelText: 'Why is this changing?',
                    errorText: s.fieldErrors['reason'] == null
                        ? null
                        : 'Say why, briefly.',
                  ),
                  onChanged: (_) => setState(() {}),
                ),
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    FocusRing(
                      child: FilledButton(
                        key: const Key('record-correct-save'),
                        style: _mtgCompact(),
                        onPressed: busy || _reason.text.trim().isEmpty
                            ? null
                            : () => ctl.correctHeld(
                                m,
                                record,
                                held: !record.held,
                                reason: _reason.text,
                              ),
                        child: Text(
                          record.held ? 'Save: not held' : 'Save: held',
                        ),
                      ),
                    ),
                    FocusRing(
                      child: TextButton(
                        key: const Key('record-correct-cancel'),
                        style: _mtgRowAction(),
                        onPressed: busy
                            ? null
                            : () => setState(() => _correcting = false),
                        child: const Text('Keep it'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      } else {
        children.add(
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: FocusRing(
              child: TextButton(
                key: const Key('record-correct'),
                style: _mtgRowAction(),
                onPressed: busy
                    ? null
                    : () {
                        // A fresh form never closes on an earlier success
                        // (5.8 review fix 1).
                        ctl.dismissNotice();
                        setState(() => _correcting = true);
                      },
                child: Text(
                  record.held ? 'It wasn\'t held' : 'It was held after all',
                ),
              ),
            ),
          ),
        );
      }
    }
    final p = read.programme;
    if (record.held) {
      children.add(const SizedBox(height: 14));
      if (p == null || p.state == ProgrammeState.cancelled || p.parts.isEmpty) {
        children.addAll([
          _mtgPartsTitle(context, null),
          const Text(
            'This meeting had no programme, so there are no parts to record.',
            key: Key('record-no-parts'),
          ),
        ]);
      } else {
        // The main job in one click: every part not yet recorded whose
        // planned person is still in the cell, as planned (an explicit
        // choice; nothing is assumed).
        final asPlanned = [
          for (final part in p.parts)
            if (!record.actual.containsKey(part.partId) &&
                part.assignee != null &&
                part.assignee!.inCell)
              ActualLeaderDraft(
                partId: part.partId,
                memberId: part.assignee!.memberId,
              ),
        ];
        final missing = p.parts
            .where((part) => !record.actual.containsKey(part.partId))
            .length;
        final title = _mtgPartsTitle(
          context,
          missing == 0
              ? null
              : '$missing of ${p.parts.length} '
                    '${p.parts.length == 1 ? 'part' : 'parts'} not '
                    'recorded. Record who actually led, not who was planned.',
        );
        final allPlanned = read.canRecord && asPlanned.isNotEmpty
            ? FocusRing(
                child: FilledButton(
                  key: const Key('record-all-planned'),
                  style: _mtgCompact(),
                  onPressed: busy
                      ? null
                      : () => ctl.recordLeaders(m, record, asPlanned),
                  child: Text(
                    asPlanned.length == 1
                        ? '1 part was led as planned'
                        : '${asPlanned.length} parts were led as planned',
                  ),
                ),
              )
            : null;
        children.addAll([
          // The main job beside its title; under it on a phone.
          LayoutBuilder(
            builder: (context, box) => box.maxWidth < 560
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      title,
                      if (allPlanned != null) ...[
                        const SizedBox(height: 8),
                        allPlanned,
                      ],
                    ],
                  )
                : Row(
                    children: [
                      Expanded(child: title),
                      if (allPlanned != null) ...[
                        const SizedBox(width: 12),
                        allPlanned,
                      ],
                    ],
                  ),
          ),
          const SizedBox(height: 10),
          LayoutBuilder(
            builder: (context, box) {
              final wide = box.maxWidth >= 600;
              return DecoratedBox(
                decoration: BoxDecoration(
                  border: Border.all(color: c.line),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (wide)
                      const StaffTableHeader(
                        columns: _mtgPartColumns,
                        padding: EdgeInsets.fromLTRB(16, 10, 12, 8),
                      ),
                    for (var i = 0; i < p.parts.length; i++)
                      _ActualRow(
                        key: Key('record-part-${p.parts[i].partId}'),
                        meetingId: widget.meetingId,
                        meeting: m,
                        record: record,
                        part: p.parts[i],
                        roster: read.roster,
                        canRecord: read.canRecord,
                        state: s,
                        divider: i > 0,
                        wide: wide,
                      ),
                  ],
                ),
              );
            },
          ),
        ]);
      }
    }
    return StaffSection(
      key: const Key('plan-record'),
      title: 'After the meeting',
      trailing: _statusLabel(
        record.held ? MeetingStatus.held : MeetingStatus.notHeld,
        key: const Key('record-state'),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
    );
  }
}

/// "Who led each part" with its one grey line of what is still missing.
Widget _mtgPartsTitle(BuildContext context, String? line) {
  final c = ChurchColors.of(context);
  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Semantics(
        header: true,
        child: Text(
          'Who led each part',
          style: ChurchType.staffBody.copyWith(
            color: c.ink,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      if (line != null)
        Text(
          line,
          style: ChurchType.secondary.copyWith(color: c.muted, fontSize: 13),
        ),
    ],
  );
}

/// The parts table: the time (JetBrains Mono, a programme time), the part,
/// who was planned, who actually led (one pill) and the action.
const _mtgPartColumns = [
  StaffColumn('Time', width: 56),
  StaffColumn('Part', flex: 3),
  StaffColumn('Planned', flex: 3),
  StaffColumn('Who led', flex: 3),
  StaffColumn('', width: 92, numeric: true),
];

const _guestChoice = 'guest';
const _nobodyChoice = 'nobody';

/// One part afterwards: who was planned, who actually led (or that it is not
/// recorded), earlier values, and the leader's change with a reason.
class _ActualRow extends ConsumerStatefulWidget {
  const _ActualRow({
    super.key,
    required this.meetingId,
    required this.meeting,
    required this.record,
    required this.part,
    required this.roster,
    required this.canRecord,
    required this.state,
    this.divider = false,
    this.wide = true,
  });
  final String meetingId;
  final CellMeeting meeting;
  final MeetingRecord record;
  final ProgrammePart part;
  final List<ProgrammeRosterMember> roster;
  final bool canRecord;
  final CellsState<ProgrammeRead> state;

  /// A 1 px rule above (every row but the first).
  final bool divider;

  /// The table's columns; a two-line row when false (a phone).
  final bool wide;

  @override
  ConsumerState<_ActualRow> createState() => _ActualRowState();
}

class _ActualRowState extends ConsumerState<_ActualRow> {
  bool _editing = false;

  /// This editor sent its value and waits for the server's answer.
  bool _awaiting = false;

  /// A member id, [_guestChoice] or [_nobodyChoice].
  String? _choice;
  final _guest = TextEditingController();
  final _reason = TextEditingController();

  @override
  void dispose() {
    _guest.dispose();
    _reason.dispose();
    super.dispose();
  }

  void _open(ActualLeader? current) {
    final planned = widget.part.assignee;
    // A member no longer in the roster (left or removed) is not offered: the
    // leader chooses again (5.8 review fix 2).
    bool inRoster(String? id) => widget.roster.any((r) => r.memberId == id);
    setState(() {
      _editing = true;
      _awaiting = false;
      _choice = switch (current?.kind) {
        ActualLeaderKind.member =>
          inRoster(current!.memberId) ? current.memberId : null,
        ActualLeaderKind.guest => _guestChoice,
        ActualLeaderKind.nobody => _nobodyChoice,
        null =>
          planned != null && planned.inCell && inRoster(planned.memberId)
              ? planned.memberId
              : null,
      };
      _guest.text = current?.guestName ?? '';
      _reason.clear();
    });
  }

  /// This part's index in the last record_actual_leaders the page sent (one
  /// part from this editor, or every part from "led as planned"), so its
  /// field errors land on this part (5.8 review fix 3).
  int? _sentIndex(CellsState<ProgrammeRead> s) {
    final a = s.noticeAction;
    if (a == null || a.command != CellRecordCommands.recordLeaders) return null;
    final parts = a.request.payload['parts'];
    if (parts is! List) return null;
    final i = parts.indexWhere(
      (p) => p is Map && p['part_id'] == widget.part.partId,
    );
    return i < 0 ? null : i;
  }

  @override
  Widget build(BuildContext context) {
    final c = ChurchColors.of(context);
    final part = widget.part;
    final current = widget.record.actual[part.partId];
    final s = widget.state;
    final busy = s.busy;
    final wide = widget.wide;
    final ctl = ref.read(cellProgrammeProvider(widget.meetingId).notifier);
    final sent = _sentIndex(s);
    // The editor closes once the server has saved what it sent; a refusal
    // keeps what was typed (5.8 review fix 1).
    if (_editing &&
        _awaiting &&
        !busy &&
        sent != null &&
        s.notice == CellNotice.leadersRecorded) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _editing) {
          setState(() {
            _editing = false;
            _awaiting = false;
          });
        }
      });
    }
    String? err(String field) =>
        sent == null ? null : s.fieldErrors['parts.$sent.$field'];
    final planned = part.assignee?.displayName ?? part.linkedLabel;
    final (label, tone) = switch (current) {
      null => ('Not recorded', StatusTone.warning),
      ActualLeader(kind: ActualLeaderKind.nobody) => (
        'Nobody led it',
        StatusTone.neutral,
      ),
      ActualLeader(substitute: true) => (
        'Stood in: ${current.who}',
        StatusTone.info,
      ),
      _ => ('Led by ${current.who}', StatusTone.success),
    };
    final muted = ChurchType.secondary.copyWith(color: c.muted, fontSize: 13);
    final time = Text(
      ChurchTime.timeText(part.startsAt),
      style: ChurchType.programmeTime.copyWith(color: c.ink),
    );
    final partLabel = Text(
      part.label,
      style: ChurchType.staffBody.copyWith(
        color: c.ink,
        fontWeight: FontWeight.w600,
      ),
    );
    final plannedText = Text(
      wide
          ? planned ?? 'Nobody (a gap)'
          : 'Planned: ${planned ?? 'nobody (a gap)'}',
      key: Key('record-planned-${part.partId}'),
      style: wide
          ? ChurchType.staffBody.copyWith(
              color: planned == null ? c.muted : c.ink,
            )
          : muted,
    );
    final who = StatusLabel(
      key: Key('record-actual-${part.partId}'),
      label: label,
      tone: tone,
    );
    final Widget action = widget.canRecord && !_editing
        ? FocusRing(
            child: TextButton(
              key: Key('record-edit-${part.partId}'),
              style: _mtgRowAction(),
              onPressed: busy ? null : () => _open(current),
              child: Text(
                current == null ? 'Record' : 'Change',
                semanticsLabel:
                    '${current == null ? 'Record' : 'Change'} who led '
                    '${part.label}',
              ),
            ),
          )
        : const SizedBox.shrink();
    final notes = <Widget>[
      if (current?.reason case final r?)
        Text('Why it changed: $r', style: muted),
      if (err('part_id') != null)
        Text(
          'This part is no longer in the programme. Reload.',
          style: muted.copyWith(color: c.redFg),
        ),
      if (err('member_id') != null)
        Text(
          'They are no longer in this cell: name them as a guest.',
          style: muted.copyWith(color: c.redFg),
        ),
      for (final e in current?.earlier ?? const <ActualLeader>[])
        Text(
          'Earlier: ${e.who} (${e.recordedBy ?? 'Removed member'})',
          style: muted,
        ),
    ];
    // Notes and the editor start under the part's name on a wide table.
    final indent = wide ? _mtgPartColumns.first.width! + 16 : 0.0;
    final children = <Widget>[
      if (wide)
        StaffColumnsRow(
          columns: _mtgPartColumns,
          cells: [time, partLabel, plannedText, who, action],
        )
      else ...[
        Row(
          children: [
            time,
            const SizedBox(width: 10),
            Expanded(child: partLabel),
          ],
        ),
        plannedText,
        const SizedBox(height: 4),
        Row(
          children: [
            Flexible(child: who),
            const Spacer(),
            action,
          ],
        ),
      ],
      if (notes.isNotEmpty)
        Padding(
          padding: EdgeInsetsDirectional.only(start: indent, top: 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: notes,
          ),
        ),
    ];
    if (_editing) {
      final choice = _choice;
      final needsReason = current != null;
      final ready =
          choice != null &&
          (choice != _guestChoice || _guest.text.trim().isNotEmpty) &&
          (!needsReason || _reason.text.trim().isNotEmpty);
      children.add(
        Container(
          margin: EdgeInsetsDirectional.only(start: indent, top: 8, bottom: 4),
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
          decoration: BoxDecoration(
            color: c.bg,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              DropdownButton<String>(
                key: Key('record-who-${part.partId}'),
                hint: const Text('Who led it?'),
                value: choice,
                items: [
                  for (final r in widget.roster)
                    DropdownMenuItem(
                      value: r.memberId,
                      child: Text(
                        r.memberId == part.assignee?.memberId
                            ? '${r.displayName} (planned)'
                            : r.displayName,
                      ),
                    ),
                  const DropdownMenuItem(
                    value: _guestChoice,
                    child: Text('Someone else (a guest)'),
                  ),
                  const DropdownMenuItem(
                    value: _nobodyChoice,
                    child: Text('Nobody led it'),
                  ),
                ],
                onChanged: busy ? null : (v) => setState(() => _choice = v),
              ),
              if (choice == _guestChoice)
                TextField(
                  key: Key('record-guest-${part.partId}'),
                  controller: _guest,
                  maxLength: CellRecordCommands.guestNameMax,
                  enabled: !busy,
                  decoration: InputDecoration(
                    labelText: 'Their name',
                    errorText: err('name') == null ? null : 'Type their name.',
                  ),
                  onChanged: (_) => setState(() {}),
                ),
              if (needsReason)
                TextField(
                  key: Key('record-part-reason-${part.partId}'),
                  controller: _reason,
                  maxLength: CellRecordCommands.reasonMax,
                  enabled: !busy,
                  decoration: InputDecoration(
                    labelText: 'Why is this changing?',
                    errorText: err('reason') == null
                        ? null
                        : 'Say why, briefly.',
                  ),
                  onChanged: (_) => setState(() {}),
                ),
              const SizedBox(height: 4),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  FocusRing(
                    child: FilledButton(
                      key: Key('record-save-${part.partId}'),
                      style: _mtgCompact(),
                      onPressed: busy || !ready
                          ? null
                          : () {
                              setState(() => _awaiting = true);
                              ctl.recordLeaders(widget.meeting, widget.record, [
                                ActualLeaderDraft(
                                  partId: part.partId,
                                  memberId:
                                      choice == _guestChoice ||
                                          choice == _nobodyChoice
                                      ? null
                                      : choice,
                                  guestName: choice == _guestChoice
                                      ? _guest.text
                                      : null,
                                  reason: needsReason ? _reason.text : null,
                                ),
                              ]);
                            },
                      child: const Text('Save'),
                    ),
                  ),
                  FocusRing(
                    child: TextButton(
                      key: Key('record-cancel-${part.partId}'),
                      style: _mtgRowAction(),
                      onPressed: busy
                          ? null
                          : () => setState(() => _editing = false),
                      child: const Text('Cancel'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
    }
    return StaffTableRow(
      divider: widget.divider,
      padding: const EdgeInsets.fromLTRB(16, 8, 12, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
    );
  }
}

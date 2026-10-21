import 'package:church_design_system/church_design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../application/cell_controllers.dart';
import '../domain/access_grants.dart';
import '../domain/cell_meetings.dart';
import '../domain/cell_membership.dart';
import '../domain/church_time.dart';
import '../domain/membership_application.dart';

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
  });

  final String title;
  final NotifierProvider<CellsController<T>, CellsState<T>> provider;
  final String needs;
  final String loading;
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
    children.addAll([
      const SizedBox(height: ChurchGeometry.sectionGap),
      Align(
        alignment: AlignmentDirectional.centerStart,
        child: FocusRing(
          child: OutlinedButton.icon(
            key: const Key('cells-reload'),
            onPressed: s.loading || s.busy ? null : ctl.reload,
            icon: const Icon(Icons.refresh),
            label: const Text('Reload'),
          ),
        ),
      ),
    ]);
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: SafeArea(
        child: SingleChildScrollView(
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
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final c = ChurchColors.of(context);
    return Material(
      color: c.surface,
      shape: RoundedRectangleBorder(
        side: BorderSide(color: c.line),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Padding(
        padding: const EdgeInsets.all(ChurchGeometry.cardPadding),
        child: child,
      ),
    );
  }
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
    provider: cellAdminProvider,
    needs: 'Cells needs the Admin role.',
    loading: 'Loading cells…',
    body: (context, o, s) => _AdminBody(overview: o, state: s),
  );
}

class _AdminBody extends ConsumerWidget {
  const _AdminBody({required this.overview, required this.state});
  final CellAdminOverview overview;
  final CellsState<CellAdminOverview> state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final followUp = overview.requests.where((r) => r.followUp).toList();
    final waiting = overview.requests.where((r) => !r.followUp).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _heading(
          context,
          'Follow-up (${followUp.length})',
          key: const Key('follow-up-heading'),
        ),
        _muted(
          context,
          'No cell chosen yet, or the leader passed it to the church office. '
          'Confirm into the cell you checked with its leader, or close it.',
        ),
        const SizedBox(height: 8),
        if (followUp.isEmpty)
          const Text('Nothing to follow up.', key: Key('no-follow-up')),
        for (final r in followUp) ...[
          _AdminRequestCard(
            key: Key('admin-request-${r.requestId}-r${r.memberRevision}'),
            request: r,
            overview: overview,
            busy: state.busy,
          ),
          const SizedBox(height: 12),
        ],
        const SizedBox(height: ChurchGeometry.sectionGap),
        _heading(context, 'Waiting for a leader (${waiting.length})'),
        _muted(
          context,
          'The cell\'s leader confirms these. You may confirm after checking '
          'with the leader.',
        ),
        const SizedBox(height: 8),
        if (waiting.isEmpty)
          const Text('No requests are waiting.', key: Key('no-waiting')),
        for (final r in waiting) ...[
          _AdminRequestCard(
            key: Key('admin-request-${r.requestId}-r${r.memberRevision}'),
            request: r,
            overview: overview,
            busy: state.busy,
          ),
          const SizedBox(height: 12),
        ],
        const SizedBox(height: ChurchGeometry.sectionGap),
        _heading(context, 'Cells (${overview.cells.length})'),
        for (final cell in overview.cells) ...[
          _AdminCellCard(
            key: Key('admin-cell-${cell.cellId}-r${cell.revision}'),
            cell: cell,
            overview: overview,
            busy: state.busy,
          ),
          const SizedBox(height: 12),
        ],
        _CreateCellForm(busy: state.busy),
        const SizedBox(height: ChurchGeometry.sectionGap),
        _MoveMemberForm(overview: overview, busy: state.busy),
      ],
    );
  }
}

class _AdminRequestCard extends ConsumerStatefulWidget {
  const _AdminRequestCard({
    super.key,
    required this.request,
    required this.overview,
    required this.busy,
  });
  final AdminCellRequest request;
  final CellAdminOverview overview;
  final bool busy;

  @override
  ConsumerState<_AdminRequestCard> createState() => _AdminRequestCardState();
}

class _AdminRequestCardState extends ConsumerState<_AdminRequestCard> {
  late String? _cellId = widget.request.requestedCellId;

  @override
  Widget build(BuildContext context) {
    final r = widget.request;
    final ctl = ref.read(cellAdminProvider.notifier);
    final id = r.requestId;
    final can = !widget.busy && !r.ownRecord;
    final active = widget.overview.cells.where((c) => c.active).toList();
    return _Card(
      key: Key('admin-request-card-$id'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              _heading(context, r.displayName),
              StatusLabel(
                label: r.kind == 'change' ? 'Change of cell' : 'Joining',
                tone: StatusTone.info,
              ),
              if (r.referred)
                StatusLabel(
                  label:
                      'Passed on by the leader'
                      '${r.reason == null ? '' : ': ${r.reason!.label}'}',
                  tone: StatusTone.warning,
                ),
            ],
          ),
          Text(_asked(r.choice, r.requestedCellName)),
          if (r.currentCellName != null) Text('Now in ${r.currentCellName}'),
          if (r.ownRecord)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: StatusLabel(
                label: 'Your own record: someone else must decide this',
                tone: StatusTone.warning,
              ),
            ),
          const SizedBox(height: 8),
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
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
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
    final cell = widget.cell;
    final ctl = ref.read(cellAdminProvider.notifier);
    final id = cell.cellId;
    final busy = widget.busy;
    CellMemberRow? picked;
    for (final m in widget.overview.members) {
      if (m.memberId == _memberId) picked = m;
    }
    Widget staffRow(CellStaff st, String kind) => Wrap(
      spacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text(st.displayName),
        StatusLabel(
          label: kind == CellScopeKinds.leader ? 'Leader' : 'Assistant',
          tone: StatusTone.neutral,
        ),
        FocusRing(
          child: TextButton(
            key: Key('remove-$kind-$id-${st.memberId}'),
            onPressed: busy ? null : () => ctl.removeStaff(cell, st, kind),
            child: const Text('Remove'),
          ),
        ),
      ],
    );
    return _Card(
      key: Key('admin-cell-card-$id'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              _heading(context, cell.name),
              StatusLabel(
                label: cell.listed ? 'Listed for sign-up' : 'Not listed',
                tone: cell.listed ? StatusTone.success : StatusTone.neutral,
              ),
              if (cell.isSynthetic)
                const StatusLabel(
                  label: 'Synthetic test record',
                  tone: StatusTone.neutral,
                ),
            ],
          ),
          Text('Area: ${cell.broadArea}'),
          if (cell.signupLabel != null)
            Text('Shown at sign-up as: ${cell.signupLabel}'),
          Text('Confirmed members: ${cell.memberCount}'),
          const SizedBox(height: 8),
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
class CellLeaderScreen extends StatelessWidget {
  const CellLeaderScreen({super.key});

  @override
  Widget build(BuildContext context) => _CellsPage<LeaderQueue>(
    title: 'My cell group',
    provider: cellLeaderProvider,
    needs: 'This page is for cell leaders and assistants.',
    loading: 'Loading your cell…',
    body: (context, q, s) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final cell in q.cells) ...[
          _LeaderCellCard(cell: cell, busy: s.busy),
          const SizedBox(height: 12),
        ],
      ],
    ),
  );
}

class _LeaderCellCard extends ConsumerWidget {
  const _LeaderCellCard({required this.cell, required this.busy});
  final LeaderCell cell;
  final bool busy;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ctl = ref.read(cellLeaderProvider.notifier);
    return _Card(
      key: Key('leader-cell-${cell.cellId}'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              _heading(context, cell.name),
              StatusLabel(
                label: cell.isLeader ? 'You lead this cell' : 'You assist',
                tone: StatusTone.info,
              ),
            ],
          ),
          Text('Area: ${cell.broadArea}'),
          const SizedBox(height: 12),
          if (cell.isLeader) ...[
            _heading(context, 'Requests to confirm (${cell.requests.length})'),
            if (cell.requests.isEmpty)
              Text(
                'No one is waiting.',
                key: Key('leader-no-requests-${cell.cellId}'),
              ),
            for (final r in cell.requests)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Wrap(
                  key: Key('leader-request-${r.requestId}'),
                  spacing: 8,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(r.displayName),
                    StatusLabel(
                      label: r.kind == 'change'
                          ? 'Moving from another cell'
                          : 'Joining',
                      tone: StatusTone.info,
                    ),
                    if (r.ownRecord)
                      const StatusLabel(
                        label: 'Your own request',
                        tone: StatusTone.warning,
                      ),
                    FocusRing(
                      child: FilledButton(
                        key: Key('leader-confirm-${r.requestId}'),
                        onPressed: busy || r.ownRecord
                            ? null
                            : () => ctl.confirm(r),
                        child: const Text('Confirm member of this cell'),
                      ),
                    ),
                    FocusRing(
                      child: OutlinedButton(
                        key: Key('leader-refer-${r.requestId}'),
                        onPressed: busy || r.ownRecord
                            ? null
                            : () => ctl.refer(
                                r,
                                CellDeclineReason.notKnownToLeader,
                              ),
                        child: const Text('I don\'t know them: ask the office'),
                      ),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 12),
          ],
          _heading(context, 'Members (${cell.members.length})'),
          if (cell.members.isEmpty) const Text('No confirmed members yet.'),
          for (final m in cell.members)
            Text(
              m.displayName,
              key: Key('roster-${cell.cellId}-${m.memberId}'),
            ),
        ],
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Story 5.1: when and where the cell meets next is the member's
        // first question, so it leads the screen.
        if (cell.meetings case final meetings?) ...[
          _NextMeetingCard(meetings: meetings),
          const SizedBox(height: 12),
        ],
        _Card(
          key: const Key('my-cell-current'),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _heading(context, 'Cell group'),
              if (primary == null)
                const Text('No confirmed cell yet.', key: Key('my-cell-none'))
              else ...[
                Text(primary.label, key: const Key('my-cell-label')),
                Text('Area: ${primary.broadArea}'),
                const StatusLabel(label: 'Confirmed', tone: StatusTone.success),
              ],
              const SizedBox(height: 8),
              _muted(
                context,
                'Your church membership and your cell are confirmed '
                'separately.',
              ),
            ],
          ),
        ),
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
          _Card(
            key: const Key('my-cell-change'),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _heading(
                  context,
                  primary == null ? 'Ask to join a cell' : 'Ask to change cell',
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
                FocusRing(
                  child: FilledButton(
                    key: const Key('my-cell-send'),
                    onPressed: widget.busy || picked == null
                        ? null
                        : () => ctl.requestChange(cell, picked!),
                    child: const Text('Send request'),
                  ),
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

String _meetingDay(BuildContext context, DateTime at) {
  final w = ChurchTime.wall(at);
  return '${weekdayName(w.weekday)} '
      '${MaterialLocalizations.of(context).formatMediumDate(w)}';
}

String _meetingWhen(BuildContext context, CellMeeting m) =>
    '${_meetingDay(context, m.startsAt)}, ${_meetingClock(context, m.startsAt)}'
    '-${_meetingClock(context, m.endsAt)}';

/// Story 5.1, staff web: each cell's weekly schedule and its meetings for
/// the next 12 weeks. An Admin sets the schedule (and sees only that a
/// venue is set unless they also lead or assist the cell); the cell's
/// leader or an Admin moves, cancels or brings back one meeting at a time;
/// an assistant reads. Every meeting keeps its id through every change.
class CellMeetingsScreen extends StatelessWidget {
  const CellMeetingsScreen({super.key});

  @override
  Widget build(BuildContext context) => _CellsPage<CellMeetingsBoard>(
    title: 'Cell meetings',
    provider: cellMeetingsProvider,
    needs: 'This page is for cell leaders, assistants and Admins.',
    loading: 'Loading cell meetings…',
    body: (context, board, s) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _muted(
          context,
          'Times are church time (Africa/Lusaka). The venue is private to '
          'the cell: its leader, assistant and confirmed members.',
        ),
        const SizedBox(height: 12),
        if (board.cells.isEmpty)
          const Text('No cells to show.', key: Key('meetings-no-cells')),
        for (final cell in board.cells) ...[
          _MeetingCellCard(
            key: Key('meeting-cell-${cell.cellId}'),
            cell: cell,
            busy: s.busy,
          ),
          const SizedBox(height: 12),
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
    final cell = widget.cell;
    final ctl = ref.read(cellMeetingsProvider.notifier);
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
    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              _heading(context, cell.name),
              StatusLabel(
                label: switch (cell.role) {
                  MeetingRole.leader => 'You lead this cell',
                  MeetingRole.assistant => 'You assist',
                  MeetingRole.admin => 'Admin',
                },
                tone: StatusTone.info,
              ),
              if (cell.isSynthetic)
                const StatusLabel(
                  label: 'Synthetic test record',
                  tone: StatusTone.neutral,
                ),
            ],
          ),
          if (schedule == null)
            Text(
              cell.canSetSchedule
                  ? 'No meeting schedule yet. Set it below.'
                  : 'No meeting schedule yet. The church office sets it.',
              key: Key('meeting-no-schedule-$id'),
            )
          else ...[
            // The card's answer first: when this cell meets next.
            Text(
              next == null
                  ? 'No meeting in the next 12 weeks'
                  : 'Next: ${_meetingWhen(context, next)}',
              key: Key('meeting-next-$id'),
              style: ChurchType.sectionTitle.copyWith(
                color: ChurchColors.of(context).ink,
              ),
            ),
            if (changed > 0)
              _muted(
                context,
                '$changed of the next ${cell.meetings.length} meetings '
                '${changed == 1 ? 'is' : 'are'} moved or cancelled.',
              ),
            const SizedBox(height: 8),
            Text(
              'Meets ${schedule.summary} (church time)',
              key: Key('meeting-schedule-$id'),
            ),
            Text(
              schedule.venue != null
                  ? 'Venue: ${schedule.venue}'
                  : 'Venue: set (only the cell\'s leader, assistant and '
                        'members see it)',
              key: Key('meeting-venue-$id'),
            ),
            if (schedule.mapPin case final pin?)
              SelectableText('Map pin: ${pin.text}')
            else if (schedule.pinSet && schedule.venue == null)
              const Text('Map pin: set'),
            // Story 5.2: the cell's reminders; the leader or an Admin
            // changes them.
            _RemindersRow(cell: cell, schedule: schedule, busy: busy),
          ],
          if (schedule != null) ...[
            const SizedBox(height: 12),
            _heading(context, 'Next 12 weeks'),
            if (cell.meetings.isEmpty)
              const Text('No meetings in the next 12 weeks.'),
            for (final m in cell.meetings) ...[
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Wrap(
                  key: Key('meeting-${m.meetingId}'),
                  spacing: 8,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(_meetingWhen(context, m)),
                    if (m.moved)
                      StatusLabel(
                        label: m.venueMoved ? 'Moved, other venue' : 'Moved',
                        tone: StatusTone.warning,
                      ),
                    if (m.cancelled)
                      const StatusLabel(
                        label: 'Cancelled',
                        tone: StatusTone.danger,
                      ),
                    if (m.venueMoved && m.venue != null) Text('at ${m.venue}'),
                    // Story 5.2: members the app could not reach about this
                    // meeting; the leader tells them directly.
                    if (m.contactNeeds.isNotEmpty)
                      StatusLabel(
                        key: Key('meeting-contact-${m.meetingId}'),
                        label:
                            'Tell directly: '
                            '${m.contactNeeds.map((n) => n.displayName).join(', ')}',
                        tone: StatusTone.warning,
                      ),
                    // The server checks a cancelled meeting against its usual
                    // time (it comes back there), any other against its own.
                    if (cell.canChange &&
                        (m.cancelled ? m.nominalStartsAt : m.startsAt).isAfter(
                          now,
                        )) ...[
                      if (!m.cancelled) ...[
                        FocusRing(
                          child: TextButton(
                            key: Key('meeting-move-${m.meetingId}'),
                            onPressed: busy
                                ? null
                                : () => setState(
                                    () => _moving = _moving == m.meetingId
                                        ? null
                                        : m.meetingId,
                                  ),
                            child: const Text('Move'),
                          ),
                        ),
                        FocusRing(
                          child: TextButton(
                            key: Key('meeting-cancel-${m.meetingId}'),
                            onPressed: busy ? null : () => ctl.cancel(m),
                            child: const Text('Cancel this meeting'),
                          ),
                        ),
                      ] else if (m.nominalStartsAt.isAfter(now))
                        FocusRing(
                          child: TextButton(
                            key: Key('meeting-reinstate-${m.meetingId}'),
                            onPressed: busy ? null : () => ctl.reinstate(m),
                            child: const Text('Bring it back'),
                          ),
                        ),
                    ],
                  ],
                ),
              ),
              if (_moving == m.meetingId && !m.cancelled)
                _MoveMeetingForm(
                  key: Key('meeting-move-form-${m.meetingId}'),
                  meeting: m,
                  busy: busy,
                ),
            ],
          ],
          // Setting the weekly rule is rare (Admin): open only for a cell
          // without one, otherwise behind a button after the meetings.
          if (cell.canSetSchedule) ...[
            const SizedBox(height: 12),
            if (schedule == null || _editing)
              _ScheduleForm(cell: cell, busy: busy)
            else
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: FocusRing(
                  child: OutlinedButton(
                    key: Key('schedule-edit-$id'),
                    onPressed: busy
                        ? null
                        : () => setState(() => _editing = true),
                    child: const Text('Change the schedule'),
                  ),
                ),
              ),
          ],
        ],
      ),
    );
  }
}

class _ScheduleForm extends ConsumerStatefulWidget {
  const _ScheduleForm({required this.cell, required this.busy});
  final StaffMeetingCell cell;
  final bool busy;

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
    return Column(
      key: Key('schedule-form-$id'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _heading(
          context,
          first ? 'Set the weekly meeting' : 'Change the weekly meeting',
        ),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            DropdownButton<int>(
              key: Key('schedule-weekday-$id'),
              value: _weekday,
              items: [
                for (var d = 1; d <= 7; d++)
                  DropdownMenuItem(value: d, child: Text(weekdayName(d))),
              ],
              onChanged: widget.busy
                  ? null
                  : (v) => setState(() => _weekday = v ?? _weekday),
            ),
            SizedBox(
              width: 120,
              child: TextField(
                key: Key('schedule-start-$id'),
                controller: _start,
                enabled: !widget.busy,
                decoration: InputDecoration(
                  labelText: 'Starts (HH:MM)',
                  errorText: err('start_time'),
                ),
              ),
            ),
            SizedBox(
              width: 120,
              child: TextField(
                key: Key('schedule-end-$id'),
                controller: _end,
                enabled: !widget.busy,
                decoration: InputDecoration(
                  labelText: 'Ends (HH:MM)',
                  errorText: err('end_time'),
                ),
              ),
            ),
          ],
        ),
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
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            SizedBox(
              width: 160,
              child: TextField(
                key: Key('schedule-lat-$id'),
                controller: _lat,
                enabled: !widget.busy,
                decoration: InputDecoration(
                  labelText: 'Map pin latitude',
                  errorText: pinOk ? err('map_pin') : 'Check the pin',
                ),
                onChanged: (_) => setState(() {}),
              ),
            ),
            SizedBox(
              width: 160,
              child: TextField(
                key: Key('schedule-lng-$id'),
                controller: _lng,
                enabled: !widget.busy,
                decoration: const InputDecoration(
                  labelText: 'Map pin longitude',
                ),
                onChanged: (_) => setState(() {}),
              ),
            ),
            if (cell.schedule?.pinSet ?? false)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Checkbox(
                    key: Key('schedule-clear-pin-$id'),
                    value: _clearPin,
                    onChanged: widget.busy
                        ? null
                        : (v) => setState(() => _clearPin = v ?? false),
                  ),
                  const Text('Remove the map pin'),
                ],
              ),
          ],
        ),
        const SizedBox(height: 8),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: FocusRing(
            child: FilledButton(
              key: Key('schedule-save-$id'),
              onPressed:
                  widget.busy || !pinOk || (first && _venue.text.trim().isEmpty)
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
        ),
      ],
    );
  }
}

class _MoveMeetingForm extends ConsumerStatefulWidget {
  const _MoveMeetingForm({
    super.key,
    required this.meeting,
    required this.busy,
  });
  final CellMeeting meeting;
  final bool busy;

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
    return Padding(
      padding: const EdgeInsets.only(bottom: 12, left: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _muted(
            context,
            'Move only this meeting (now ${_meetingWhen(context, m)}). '
            'Church time.',
          ),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              SizedBox(
                width: 150,
                child: TextField(
                  key: Key('move-date-${m.meetingId}'),
                  controller: _date,
                  enabled: !widget.busy,
                  decoration: InputDecoration(
                    labelText: 'Date (YYYY-MM-DD)',
                    errorText: err('starts_at'),
                  ),
                  onChanged: (_) => setState(() {}),
                ),
              ),
              SizedBox(
                width: 110,
                child: TextField(
                  key: Key('move-start-${m.meetingId}'),
                  controller: _start,
                  enabled: !widget.busy,
                  decoration: const InputDecoration(labelText: 'Starts'),
                  onChanged: (_) => setState(() {}),
                ),
              ),
              SizedBox(
                width: 110,
                child: TextField(
                  key: Key('move-end-${m.meetingId}'),
                  controller: _end,
                  enabled: !widget.busy,
                  decoration: InputDecoration(
                    labelText: 'Ends',
                    errorText: err('ends_at'),
                  ),
                  onChanged: (_) => setState(() {}),
                ),
              ),
            ],
          ),
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
                const Text('Use the usual venue'),
              ],
            ),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: FocusRing(
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
    final next = meetings.next;
    return _Card(
      key: const Key('my-cell-next-meeting'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _heading(context, 'Next meeting'),
          for (final c in meetings.cancelled)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: StatusLabel(
                key: Key('my-cell-cancelled-${c.meetingId}'),
                label:
                    'Cancelled: ${_meetingDay(context, c.nominalStartsAt)}, '
                    '${_meetingClock(context, c.nominalStartsAt)}',
                tone: StatusTone.neutral,
              ),
            ),
          if (next == null)
            const Text(
              'No meeting is planned in the next 12 weeks.',
              key: Key('my-cell-no-meeting'),
            )
          else ...[
            Text(
              _meetingWhen(context, next),
              key: const Key('my-cell-next-when'),
              style: ChurchType.sectionTitle.copyWith(
                color: ChurchColors.of(context).ink,
              ),
            ),
            if (next.moved)
              const StatusLabel(
                label: 'Moved from its usual time',
                tone: StatusTone.warning,
              ),
            if (next.venue case final v?)
              Text('Venue: $v', key: const Key('my-cell-next-venue')),
            if (next.mapPin case final pin?)
              SelectableText(
                'Map pin: ${pin.text}',
                key: const Key('my-cell-next-pin'),
              ),
          ],
          const SizedBox(height: 8),
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
    final cell = widget.cell;
    final schedule = widget.schedule;
    final busy = widget.busy;
    final id = cell.cellId;
    final ctl = ref.read(cellMeetingsProvider.notifier);
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                'Reminders: ${schedule.remindersText}'
                '${schedule.remindersDefault ? ' (usual)' : ''}',
                key: Key('meeting-reminders-$id'),
              ),
              if (cell.canChange && !_editing)
                FocusRing(
                  child: TextButton(
                    key: Key('reminders-edit-$id'),
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
            _muted(context, 'Choose up to three. Members can snooze each one.'),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                for (final c in meetingReminderChoices)
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
            const SizedBox(height: 4),
            Wrap(
              spacing: 8,
              children: [
                FocusRing(
                  child: FilledButton(
                    key: Key('reminders-save-$id'),
                    onPressed: busy
                        ? null
                        : () {
                            setState(() => _editing = false);
                            ctl.setReminders(cell, [
                              for (final c in meetingReminderChoices)
                                if (_chosen.contains(c)) c,
                            ]);
                          },
                    child: Text(
                      _chosen.isEmpty ? 'Save: no reminders' : 'Save reminders',
                    ),
                  ),
                ),
                FocusRing(
                  child: TextButton(
                    key: Key('reminders-default-$id'),
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
                    onPressed: () => setState(() => _editing = false),
                    child: const Text('Keep as is'),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

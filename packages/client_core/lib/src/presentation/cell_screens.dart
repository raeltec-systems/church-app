import 'package:church_design_system/church_design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../application/cell_controllers.dart';
import '../domain/access_grants.dart';
import '../domain/cell_membership.dart';
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
    final choices = widget.view.options
        .where((o) => o.cellId != primary?.cellId)
        .toList();
    CellOption? picked;
    for (final o in choices) {
      if (o.cellId == _optionId) picked = o;
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
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
                if (choices.isEmpty)
                  const Text('No other cells are listed right now.')
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

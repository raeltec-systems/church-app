import 'package:church_design_system/church_design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../application/duties_controllers.dart';
import '../domain/access_grants.dart';
import '../domain/church_time.dart';
import '../domain/duties.dart';

// Story 4.1: departments (Admin) and publishing with responses (leaders) on
// staff web, and the member's duties with Accept / Can't make it on mobile.
// Story 4.2: leaders change a published duty (a material change asks the
// member again and keeps the earlier answer in history; an instructions-only
// change keeps the answer), and an answer to an old version is refused with
// what changed.
// Every list comes from a server-checked read and every action is a
// server-checked command; hiding a button is never the control. An answer
// shows as Accepted only after the server confirmed it.

/// The member-facing duty routes (shared by both shells' router).
abstract final class DutyPaths {
  /// Mobile: the member's own duties.
  static const mine = '/duties';

  /// One assignment (the reminder contract's link `/duties/assignments/{id}`).
  static String assignment(String assignmentId) =>
      '/duties/assignments/$assignmentId';

  /// Staff web: leaders, deputies, Admin (and Pastor, read only).
  static const leader = '/duties/leader';

  /// Staff web, Admin only: departments, leaders, deputies and members.
  static const adminDepartments = '/admin/departments';
}

(StatusTone, String, String) _noticeText(
  DutyNotice n,
  DutyAction? a, [
  Map<String, String> fieldErrors = const {},
]) {
  final what = a?.subject ?? 'this';
  final changed = DutyFields.changedIn(fieldErrors);
  return switch (n) {
    DutyNotice.departmentCreated => (
      StatusTone.success,
      'Department added',
      '$what is set up. Give it a leader and add its members next.',
    ),
    DutyNotice.memberAdded => (
      StatusTone.success,
      'Member added',
      '$what now serves in this department.',
    ),
    DutyNotice.staffAssigned => (
      StatusTone.success,
      'Role given',
      '$what can now act for this department. The change applies on their '
          'next step.',
    ),
    DutyNotice.staffRemoved => (
      StatusTone.success,
      'Role removed',
      '$what no longer manages this department.',
    ),
    DutyNotice.published => (
      StatusTone.success,
      'Duty published',
      '$what was sent. The member is asked to accept or say they can\'t make '
          'it.',
    ),
    DutyNotice.accepted => (
      StatusTone.success,
      'Accepted',
      'Your leader now sees that you accepted $what.',
    ),
    DutyNotice.declined => (
      StatusTone.success,
      'Answer sent',
      'Your leader now sees that you can\'t make $what.',
    ),
    DutyNotice.revised => (
      StatusTone.success,
      'Duty changed',
      '$what was changed. The member is asked to answer again by the new '
          'deadline; their earlier answer is kept in the history.',
    ),
    DutyNotice.notesUpdated => (
      StatusTone.success,
      'Details updated',
      'The instructions for $what were updated. The member\'s answer stands; '
          'they get a notice to read the new details.',
    ),
    DutyNotice.superseded when changed.contains(DutyFields.memberId) => (
      StatusTone.warning,
      'This duty changed',
      'Your answer was not recorded: this duty is no longer assigned to you. '
          'Your current duties are listed here.',
    ),
    DutyNotice.superseded => (
      StatusTone.warning,
      'This duty changed',
      'Your answer was not recorded: the ${DutyFields.describe(changed)} '
          'changed since you opened it. The current version is shown; please '
          'answer it again.',
    ),
    DutyNotice.dutyCancelled => (
      StatusTone.neutral,
      'Cancelled',
      'This duty was cancelled, so it can no longer be answered.',
    ),
    DutyNotice.unchanged => (
      StatusTone.neutral,
      'Nothing changed',
      'The duty already has these details.',
    ),
    DutyNotice.changedElsewhere => (
      StatusTone.warning,
      'Changed elsewhere',
      'This was changed in another tab or by someone else. The list was '
          'reloaded; check it and try again.',
    ),
    DutyNotice.alreadyAnswered => (
      StatusTone.neutral,
      'Already answered',
      'This duty already has an answer. The list was reloaded.',
    ),
    DutyNotice.started => (
      StatusTone.neutral,
      'Already started',
      'This duty has started, so it can no longer be answered here. Speak to '
          'your leader.',
    ),
    DutyNotice.nameTaken => (
      StatusTone.warning,
      'Name in use',
      'A department with that name already exists.',
    ),
    DutyNotice.notInDepartment => (
      StatusTone.warning,
      'Not in this department',
      'Only the department\'s members can be given its duties. Ask an Admin '
          'to add them first.',
    ),
    DutyNotice.invalid => (
      StatusTone.danger,
      'Check the form',
      'Some answers need fixing before this can be sent.',
    ),
    DutyNotice.notAllowed => (
      StatusTone.warning,
      'Not allowed',
      'Your account cannot do this now. Nothing was changed.',
    ),
    DutyNotice.signInAgain => (
      StatusTone.warning,
      'Please sign in again',
      'This sign-in is no longer valid. Nothing was changed.',
    ),
    DutyNotice.notFound => (
      StatusTone.neutral,
      'Not found',
      'That duty, department or person is not available to you. The list '
          'was reloaded.',
    ),
    DutyNotice.notAvailable => (
      StatusTone.neutral,
      'Not available yet',
      'Duties cannot be changed here right now. Nothing was changed.',
    ),
    DutyNotice.refused => (
      StatusTone.warning,
      'Not changed',
      'The server refused the change. The list was reloaded.',
    ),
    DutyNotice.unconfirmed => (
      StatusTone.warning,
      'Not sent yet',
      'We don\'t know whether the change for $what reached the church '
          'server, so nothing is shown as done. Check again: the same request '
          'is sent, so it can\'t apply twice.',
    ),
    DutyNotice.notSent => (
      StatusTone.neutral,
      'Not sent',
      'This build has no server configured, so nothing was sent.',
    ),
  };
}

Widget _readProblem<T>(AccessRead<T> r, String needs) => switch (r) {
  AccessReadOk() => const SizedBox.shrink(),
  AccessReadDenied(:final denial) => RequestStateBanner(
    key: Key('duties-denied-${denial.name}'),
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
    key: const Key('duties-failed'),
    tone: StatusTone.danger,
    icon: unreachable ? Icons.cloud_off_outlined : Icons.error_outline,
    title: unreachable ? 'No connection' : 'Couldn\'t load',
    message: unreachable
        ? 'We couldn\'t reach the church server. This is not an empty rota: '
              'nothing is shown until it answers.'
        : 'The server answered in an unexpected way. Try again later.',
  ),
};

/// The page frame shared by the duties screens: notice, read problem,
/// content and a reload button.
class _DutiesPage<T> extends ConsumerStatefulWidget {
  const _DutiesPage({
    required this.title,
    required this.provider,
    required this.needs,
    required this.loading,
    required this.body,
  });

  final String title;
  final NotifierProvider<DutiesController<T>, DutiesState<T>> provider;
  final String needs;
  final String loading;
  final Widget Function(BuildContext context, T value, DutiesState<T> state)
  body;

  @override
  ConsumerState<_DutiesPage<T>> createState() => _DutiesPageState<T>();
}

class _DutiesPageState<T> extends ConsumerState<_DutiesPage<T>> {
  late final AppLifecycleListener _lifecycle;
  final _noticeFocus = FocusNode(debugLabel: 'duties notice');

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onResume: _reload);
    // Revisiting the screen asks the server again.
    if (ref.read(widget.provider).result != null) Future.microtask(_reload);
  }

  // Resume and revisit reloads wait while a command is in flight (its own
  // answer reloads the list).
  void _reload() {
    if (mounted && !ref.read(widget.provider).busy) {
      ref.read(widget.provider.notifier).reload();
    }
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
      final now = ref.read(widget.provider);
      final (_, title, message) = _noticeText(
        next,
        now.noticeAction,
        now.fieldErrors,
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
          key: const Key('duties-pending'),
          tone: StatusTone.info,
          busy: true,
          title: 'Sending…',
          message:
              'Waiting for the church server about ${p.subject}. Nothing is '
              'shown as done until it answers.',
        ),
      );
    } else if (s.notice case final n?) {
      final (tone, title, message) = _noticeText(
        n,
        s.noticeAction,
        s.fieldErrors,
      );
      children.add(
        RequestStateBanner(
          key: Key('duties-notice-${n.name}'),
          focusNode: _noticeFocus,
          tone: tone,
          title: title,
          message: message,
          actions: [
            if (n == DutyNotice.unconfirmed)
              BannerAction(
                'Check again',
                ctl.checkAgain,
                key: const Key('duties-check-again'),
                primary: true,
              ),
            BannerAction(
              'Dismiss',
              ctl.dismissNotice,
              key: const Key('duties-dismiss'),
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
          key: const Key('duties-loading'),
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
            key: const Key('duties-reload'),
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

// Every duty time is shown in church time (Africa/Lusaka), whatever zone the
// device is set to.
String _clock(BuildContext context, DateTime at) {
  final w = ChurchTime.wall(at);
  return MaterialLocalizations.of(context).formatTimeOfDay(
    TimeOfDay(hour: w.hour, minute: w.minute),
    alwaysUse24HourFormat: true,
  );
}

String _when(BuildContext context, DateTime at) =>
    '${MaterialLocalizations.of(context).formatMediumDate(ChurchTime.wall(at))} '
    '${_clock(context, at)}';

String _timesText(BuildContext context, DutyTimes t) {
  bool sameDay(DateTime a, DateTime b) {
    final x = ChurchTime.wall(a), y = ChurchTime.wall(b);
    return x.year == y.year && x.month == y.month && x.day == y.day;
  }

  return [
    _when(context, t.startsAt),
    if (t.endsAt case final e?)
      sameDay(t.startsAt, e)
          ? 'until ${_clock(context, e)}'
          : 'until ${_when(context, e)}',
    if (t.reportingAt case final r?) '(report at ${_clock(context, r)})',
    '(church time)',
  ].join(' ');
}

// Church-time form values for a stored instant (Africa/Lusaka).
String _dateField(DateTime at) {
  final w = ChurchTime.wall(at);
  String two(int v) => v.toString().padLeft(2, '0');
  return '${w.year.toString().padLeft(4, '0')}-${two(w.month)}-${two(w.day)}';
}

String _timeField(DateTime at) {
  final w = ChurchTime.wall(at);
  String two(int v) => v.toString().padLeft(2, '0');
  return '${two(w.hour)}:${two(w.minute)}';
}

(String, StatusTone) _responseLabel(DutyResponse r) => switch (r) {
  DutyResponse.accepted => ('Accepted', StatusTone.success),
  DutyResponse.declined => ('Can\'t make it', StatusTone.warning),
  DutyResponse.pending => ('Awaiting response', StatusTone.info),
};

String _accountLabel(AccountStanding a) => switch (a) {
  AccountStanding.appAccount => 'App account',
  AccountStanding.noLogin => 'No login',
  AccountStanding.accessReview => 'Access review',
};

// ---------------------------------------------------------------------------
// Staff web, Admin: departments
// ---------------------------------------------------------------------------

/// Story 4.1, staff web, Admin only: create departments, give the leader
/// and deputy scopes (through the audited 2.3 grant command) and add
/// approved members, including members without a login.
class DutyAdminScreen extends StatelessWidget {
  const DutyAdminScreen({super.key});

  @override
  Widget build(BuildContext context) => _DutiesPage<DutyAdminOverview>(
    title: 'Departments',
    provider: dutyAdminProvider,
    needs: 'Departments needs the Admin role.',
    loading: 'Loading departments…',
    body: (context, o, s) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _heading(context, 'Departments (${o.departments.length})'),
        if (o.membersTruncated)
          _muted(
            context,
            'Only the first 500 members (by name) can be chosen here.',
          ),
        if (o.departments.isEmpty)
          const Text('No departments yet.', key: Key('no-departments')),
        for (final d in o.departments) ...[
          _DepartmentCard(
            key: Key('department-${d.departmentId}-r${d.revision}'),
            department: d,
            overview: o,
            busy: s.busy,
          ),
          const SizedBox(height: 12),
        ],
        _CreateDepartmentForm(busy: s.busy),
      ],
    ),
  );
}

class _DepartmentCard extends ConsumerStatefulWidget {
  const _DepartmentCard({
    super.key,
    required this.department,
    required this.overview,
    required this.busy,
  });
  final AdminDepartment department;
  final DutyAdminOverview overview;
  final bool busy;

  @override
  ConsumerState<_DepartmentCard> createState() => _DepartmentCardState();
}

class _DepartmentCardState extends ConsumerState<_DepartmentCard> {
  String? _staffId;
  String _kind = DutyScopeKinds.leader;
  String? _memberId;

  DutyCandidate? _candidate(String? id) {
    for (final m in widget.overview.members) {
      if (m.memberId == id) return m;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final d = widget.department;
    final ctl = ref.read(dutyAdminProvider.notifier);
    final id = d.departmentId;
    final busy = widget.busy;
    final staff = _candidate(_staffId);
    final member = _candidate(_memberId);
    final addable = widget.overview.members
        .where((m) => !d.hasMember(m.memberId))
        .toList();
    Widget staffRow(DepartmentStaff st, String kind) => Wrap(
      spacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text(st.displayName),
        StatusLabel(
          label: kind == DutyScopeKinds.leader ? 'Leader' : 'Deputy',
          tone: StatusTone.neutral,
        ),
        FocusRing(
          child: TextButton(
            key: Key('remove-$kind-$id-${st.memberId}'),
            onPressed: busy ? null : () => ctl.removeStaff(d, st, kind),
            child: const Text('Remove'),
          ),
        ),
      ],
    );
    return _Card(
      key: Key('department-card-$id'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              _heading(context, d.name),
              if (d.isSynthetic)
                const StatusLabel(
                  label: 'Synthetic test record',
                  tone: StatusTone.neutral,
                ),
            ],
          ),
          if (d.leaders.isEmpty)
            _muted(context, 'No leader yet: only an Admin can publish duties.'),
          for (final st in d.leaders) staffRow(st, DutyScopeKinds.leader),
          for (final st in d.deputies) staffRow(st, DutyScopeKinds.deputy),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              DropdownButton<String>(
                key: Key('staff-member-$id'),
                hint: const Text('Choose a member'),
                value: staff?.memberId,
                items: [
                  for (final m in widget.overview.members)
                    DropdownMenuItem(
                      value: m.memberId,
                      child: Text(m.displayName),
                    ),
                ],
                onChanged: busy ? null : (v) => setState(() => _staffId = v),
              ),
              DropdownButton<String>(
                key: Key('staff-kind-$id'),
                value: _kind,
                items: const [
                  DropdownMenuItem(
                    value: DutyScopeKinds.leader,
                    child: Text('Leader'),
                  ),
                  DropdownMenuItem(
                    value: DutyScopeKinds.deputy,
                    child: Text('Deputy'),
                  ),
                ],
                onChanged: busy
                    ? null
                    : (v) => setState(() => _kind = v ?? _kind),
              ),
              FocusRing(
                child: OutlinedButton(
                  key: Key('assign-staff-$id'),
                  onPressed: busy || staff == null
                      ? null
                      : () => ctl.assignStaff(d, staff, _kind),
                  child: const Text('Give this role'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _heading(context, 'Members (${d.members.length})'),
          if (d.members.isEmpty) const Text('No members yet.'),
          for (final m in d.members)
            Wrap(
              key: Key('department-member-$id-${m.memberId}'),
              spacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(m.displayName),
                if (m.account != AccountStanding.appAccount)
                  StatusLabel(
                    label: _accountLabel(m.account),
                    tone: StatusTone.neutral,
                  ),
              ],
            ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              DropdownButton<String>(
                key: Key('add-member-$id'),
                hint: const Text('Add a member'),
                value: member?.memberId,
                items: [
                  for (final m in addable)
                    DropdownMenuItem(
                      value: m.memberId,
                      child: Text(
                        m.account == AccountStanding.noLogin
                            ? '${m.displayName} (no login)'
                            : m.displayName,
                      ),
                    ),
                ],
                onChanged: busy ? null : (v) => setState(() => _memberId = v),
              ),
              FocusRing(
                child: OutlinedButton(
                  key: Key('add-member-save-$id'),
                  onPressed:
                      busy || member == null || d.hasMember(member.memberId)
                      ? null
                      : () => ctl.addMember(d, member),
                  child: const Text('Add to department'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _CreateDepartmentForm extends ConsumerStatefulWidget {
  const _CreateDepartmentForm({required this.busy});
  final bool busy;

  @override
  ConsumerState<_CreateDepartmentForm> createState() =>
      _CreateDepartmentFormState();
}

class _CreateDepartmentFormState extends ConsumerState<_CreateDepartmentForm> {
  final _name = TextEditingController();

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final errors = ref.watch(dutyAdminProvider.select((s) => s.fieldErrors));
    final err = switch (errors['name']) {
      null => null,
      'required' => 'Required',
      _ =>
        'Check this (while personal data is not approved, start with '
            '"SYNTHETIC ")',
    };
    return _Card(
      key: const Key('create-department'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _heading(context, 'Add a department'),
          _muted(
            context,
            'For example ushering, cleaning or the preaching rota. Leaders and '
            'members are added on the department afterwards.',
          ),
          const SizedBox(height: 8),
          TextField(
            key: const Key('create-department-name'),
            controller: _name,
            enabled: !widget.busy,
            maxLength: 80,
            decoration: InputDecoration(
              labelText: 'Department name',
              errorText: err,
            ),
          ),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: ListenableBuilder(
              listenable: _name,
              builder: (context, _) => FocusRing(
                child: FilledButton(
                  key: const Key('create-department-save'),
                  onPressed: widget.busy || _name.text.trim().isEmpty
                      ? null
                      : () => ref
                            .read(dutyAdminProvider.notifier)
                            .createDepartment(_name.text),
                  child: const Text('Add department'),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Staff web, leaders: publish and see responses
// ---------------------------------------------------------------------------

/// Story 4.1, staff web: the departments the caller leads or deputises (an
/// Admin sees all; a Pastor sees all, read only). A leader publishes a duty
/// to one department member with a response deadline and sees each
/// position's answer.
class DutyLeaderScreen extends StatelessWidget {
  const DutyLeaderScreen({super.key});

  @override
  Widget build(BuildContext context) => _DutiesPage<DutyLeaderBoard>(
    title: 'Duties',
    provider: dutyLeaderProvider,
    needs: 'This page is for department leaders and deputies.',
    loading: 'Loading duties…',
    body: (context, b, s) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (b.departments.isEmpty)
          const Text('No departments yet.', key: Key('leader-no-departments')),
        for (final d in b.departments) ...[
          _LeaderDepartmentCard(department: d, busy: s.busy),
          const SizedBox(height: 12),
        ],
      ],
    ),
  );
}

class _LeaderDepartmentCard extends StatelessWidget {
  const _LeaderDepartmentCard({required this.department, required this.busy});
  final LeaderDepartment department;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final d = department;
    return _Card(
      key: Key('leader-department-${d.departmentId}'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              _heading(context, d.name),
              StatusLabel(label: d.capacityLabel, tone: StatusTone.info),
            ],
          ),
          _heading(context, 'Duties (${d.duties.length})'),
          if (d.dutiesTruncated)
            _muted(context, 'Only the first 200 duties are shown.'),
          if (d.duties.isEmpty)
            Text('No duties yet.', key: Key('no-duties-${d.departmentId}')),
          for (final duty in d.duties)
            _LeaderDutyRow(
              key: Key('leader-duty-row-${duty.occurrenceId}'),
              duty: duty,
              department: d,
              busy: busy,
            ),
          if (d.canPublish) ...[
            const SizedBox(height: 12),
            _PublishForm(
              key: Key('publish-${d.departmentId}'),
              department: d,
              busy: busy,
            ),
          ],
        ],
      ),
    );
  }
}

class _LeaderDutyRow extends StatefulWidget {
  const _LeaderDutyRow({
    super.key,
    required this.duty,
    required this.department,
    required this.busy,
  });
  final LeaderDuty duty;
  final LeaderDepartment department;
  final bool busy;

  @override
  State<_LeaderDutyRow> createState() => _LeaderDutyRowState();
}

class _LeaderDutyRowState extends State<_LeaderDutyRow> {
  bool _editing = false;

  @override
  void didUpdateWidget(_LeaderDutyRow old) {
    super.didUpdateWidget(old);
    // A new revision from the server closes the form (it was saved, or
    // someone else changed the duty: the form would edit stale values).
    if (old.duty.revision != widget.duty.revision) _editing = false;
  }

  @override
  Widget build(BuildContext context) {
    final duty = widget.duty;
    final id = duty.occurrenceId;
    final started = !duty.times.arriveBy.isAfter(DateTime.now());
    return Padding(
      key: Key('leader-duty-$id'),
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(duty.dutyName, style: ChurchType.cardTitle),
          Text(_timesText(context, duty.times)),
          if (duty.location case final l?) Text('Where: $l'),
          if (duty.instructions case final i?) Text('Instructions: $i'),
          Text(
            '${duty.accepted} of ${duty.positions.length} confirmed',
            key: Key('coverage-$id'),
          ),
          for (final p in duty.positions) ...[
            if (p.assignment case final a?)
              Wrap(
                spacing: 8,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(a.displayName ?? 'Removed member'),
                  Builder(
                    builder: (context) {
                      final (label, tone) = _responseLabel(a.response);
                      return StatusLabel(
                        key: Key('response-${a.assignmentId}'),
                        label: label,
                        tone: tone,
                      );
                    },
                  ),
                  if (a.changes case final c?)
                    StatusLabel(
                      key: Key('changed-${a.assignmentId}'),
                      label: 'Changed: ${DutyFields.describe(c)}',
                      tone: StatusTone.info,
                    ),
                  if (a.response == DutyResponse.pending)
                    _muted(
                      context,
                      'Answer by ${_when(context, a.responseDeadline)}',
                    ),
                  if (a.notesUpdatedAt case final u?)
                    _muted(context, 'Details updated ${_when(context, u)}'),
                  if (a.note case final n?)
                    Text('Note: $n', key: Key('note-${a.assignmentId}')),
                ],
              ),
            if (p.history.isNotEmpty) _History(position: p),
          ],
          if (widget.department.canPublish && !started) ...[
            if (!_editing)
              FocusRing(
                child: TextButton(
                  key: Key('edit-$id'),
                  onPressed: widget.busy
                      ? null
                      : () => setState(() => _editing = true),
                  child: const Text('Change this duty'),
                ),
              )
            else
              _EditDutyForm(
                key: Key('edit-form-$id-r${duty.revision}'),
                duty: duty,
                department: widget.department,
                busy: widget.busy,
                onClose: () => setState(() => _editing = false),
              ),
          ],
        ],
      ),
    );
  }
}

/// Story 4.2: the earlier assignments of a position with the answers they
/// had (kept, never reset), newest first.
class _History extends StatelessWidget {
  const _History({required this.position});
  final DutyPosition position;

  @override
  Widget build(BuildContext context) {
    return Padding(
      key: Key('history-${position.slotId}'),
      padding: const EdgeInsets.only(top: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _muted(context, 'Earlier versions (${position.history.length})'),
          for (final h in position.history)
            Padding(
              key: Key('history-${h.assignmentId}'),
              padding: const EdgeInsetsDirectional.only(start: 12),
              child: _muted(
                context,
                [
                  '${h.displayName ?? 'Removed member'}: '
                      '${_responseLabel(h.response).$1}',
                  if (h.respondedAt case final r?)
                    'answered ${_when(context, r)}',
                  if (h.provenance == 'member') 'by the member',
                  h.state == 'cancelled'
                      ? 'cancelled ${_when(context, h.endedAt)}'
                      : 'replaced by a change ${_when(context, h.endedAt)}',
                  if (h.note case final n?) 'note: $n',
                ].join(', '),
              ),
            ),
        ],
      ),
    );
  }
}

/// Story 4.2, staff web: change a published duty. Changing the duty, date,
/// times, place or person asks the member to answer again by a new answer-by
/// time (their earlier answer is kept); changing only the instructions keeps
/// the answer. The server decides; this form only explains it.
class _EditDutyForm extends ConsumerStatefulWidget {
  const _EditDutyForm({
    super.key,
    required this.duty,
    required this.department,
    required this.busy,
    required this.onClose,
  });
  final LeaderDuty duty;
  final LeaderDepartment department;
  final bool busy;
  final VoidCallback onClose;

  @override
  ConsumerState<_EditDutyForm> createState() => _EditDutyFormState();
}

class _EditDutyFormState extends ConsumerState<_EditDutyForm> {
  late final _name = TextEditingController(text: widget.duty.dutyName);
  late final _date = TextEditingController(
    text: _dateField(widget.duty.times.startsAt),
  );
  late final _start = TextEditingController(
    text: _timeField(widget.duty.times.startsAt),
  );
  late final _end = TextEditingController(
    text: switch (widget.duty.times.endsAt) {
      final e? => _timeField(e),
      null => '',
    },
  );
  late final _endDate = TextEditingController(
    text: switch (widget.duty.times.endsAt) {
      final e? when _dateField(e) != _dateField(widget.duty.times.startsAt) =>
        _dateField(e),
      _ => '',
    },
  );
  late final _reporting = TextEditingController(
    text: switch (widget.duty.times.reportingAt) {
      final r? => _timeField(r),
      null => '',
    },
  );
  late final _location = TextEditingController(
    text: widget.duty.location ?? '',
  );
  late final _instructions = TextEditingController(
    text: widget.duty.instructions ?? '',
  );
  final _deadlineDate = TextEditingController();
  final _deadlineTime = TextEditingController();
  late String? _memberId = widget.duty.memberId;

  List<TextEditingController> get _all => [
    _name,
    _date,
    _start,
    _end,
    _endDate,
    _reporting,
    _location,
    _instructions,
    _deadlineDate,
    _deadlineTime,
  ];

  @override
  void dispose() {
    for (final c in _all) {
      c.dispose();
    }
    super.dispose();
  }

  /// The edit, or null while a field cannot be read.
  DutyEdit? _edit() {
    final starts = ChurchTime.parse(_date.text, _start.text);
    final endDate = _endDate.text.trim().isEmpty ? _date.text : _endDate.text;
    final ends = _end.text.trim().isEmpty
        ? null
        : ChurchTime.parse(endDate, _end.text);
    final reporting = _reporting.text.trim().isEmpty
        ? null
        : ChurchTime.parse(_date.text, _reporting.text);
    final deadlineGiven =
        _deadlineDate.text.trim().isNotEmpty ||
        _deadlineTime.text.trim().isNotEmpty;
    final deadline = deadlineGiven
        ? ChurchTime.parse(_deadlineDate.text, _deadlineTime.text)
        : null;
    if (_name.text.trim().isEmpty ||
        starts == null ||
        (_end.text.trim().isNotEmpty && ends == null) ||
        (_endDate.text.trim().isNotEmpty && _end.text.trim().isEmpty) ||
        (_reporting.text.trim().isNotEmpty && reporting == null) ||
        (deadlineGiven && deadline == null)) {
      return null;
    }
    return DutyEdit(
      duty: widget.duty,
      dutyName: _name.text,
      startsAt: starts,
      endsAt: ends,
      reportingAt: reporting,
      location: _location.text,
      instructions: _instructions.text,
      memberId: _memberId,
      responseDeadline: deadline,
    );
  }

  String _memberName(String? id) {
    for (final m in widget.department.members) {
      if (m.memberId == id) return m.displayName;
    }
    return 'the member';
  }

  @override
  Widget build(BuildContext context) {
    final duty = widget.duty;
    final id = duty.occurrenceId;
    final s = ref.watch(dutyLeaderProvider);
    // Only this form's own refusal names its fields.
    final mine =
        s.noticeAction?.command == DutyCommands.revise &&
        s.noticeAction?.request.payload['occurrence_id'] == id;
    final errors = mine ? s.fieldErrors : const <String, String>{};
    String? err(String wire) => switch (errors[wire]) {
      null => null,
      'required' => 'Required',
      'past' => 'This is in the past',
      'after_start' => 'Must be before the duty starts',
      'before_start' => 'Must be after the start',
      'not_in_department' => 'Not a member of this department',
      'not_material' =>
        'Only needed when the duty, time, place or person '
            'changes',
      _ => 'Check this',
    };
    Widget field(
      String key,
      TextEditingController c,
      String label, {
      String? wire,
      String? hint,
      int maxLength = 80,
      int maxLines = 1,
    }) => Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: TextField(
        key: Key('$key-$id'),
        controller: c,
        enabled: !widget.busy,
        maxLength: maxLength,
        maxLines: maxLines,
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          errorText: wire == null ? null : err(wire),
        ),
      ),
    );
    final inRoster = widget.department.members.any(
      (m) => m.memberId == _memberId,
    );
    return _Card(
      key: Key('edit-card-$id'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _heading(context, 'Change this duty'),
          _muted(
            context,
            'Changing the duty, date, times, place or person asks the member '
            'to answer again by a new answer-by time; their earlier answer is '
            'kept. Changing only the instructions keeps their answer. Times '
            'are church time (Lusaka).',
          ),
          const SizedBox(height: 8),
          field('edit-name', _name, 'Duty', wire: 'duty_name'),
          field(
            'edit-date',
            _date,
            'Date',
            hint: 'YYYY-MM-DD',
            wire: 'starts_at',
            maxLength: 10,
          ),
          field(
            'edit-start',
            _start,
            'Start time',
            hint: 'HH:MM',
            maxLength: 5,
          ),
          field(
            'edit-end',
            _end,
            'End time (optional)',
            hint: 'HH:MM',
            wire: 'ends_at',
            maxLength: 5,
          ),
          field(
            'edit-end-date',
            _endDate,
            'End date, if it ends on a later day (optional)',
            hint: 'YYYY-MM-DD',
            maxLength: 10,
          ),
          field(
            'edit-reporting',
            _reporting,
            'Reporting time, if earlier than the start (optional)',
            hint: 'HH:MM',
            wire: 'reporting_at',
            maxLength: 5,
          ),
          field(
            'edit-location',
            _location,
            'Location (optional)',
            wire: 'location',
            maxLength: 120,
          ),
          field(
            'edit-instructions',
            _instructions,
            'Instructions (optional)',
            wire: 'instructions',
            maxLength: 1000,
            maxLines: 3,
          ),
          DropdownButton<String>(
            key: Key('edit-member-$id'),
            hint: const Text('Who'),
            value: inRoster ? _memberId : null,
            isExpanded: true,
            items: [
              for (final m in widget.department.members)
                DropdownMenuItem(
                  value: m.memberId,
                  child: Text(
                    m.account == AccountStanding.noLogin
                        ? '${m.displayName} (no login: contact them directly)'
                        : m.displayName,
                  ),
                ),
            ],
            onChanged: widget.busy
                ? null
                : (v) => setState(() => _memberId = v),
          ),
          if (err('member_id') case final e?)
            Text(e, style: TextStyle(color: ChurchColors.of(context).redFg)),
          const SizedBox(height: 8),
          field(
            'edit-deadline-date',
            _deadlineDate,
            'New answer by: date (needed when the member must answer again)',
            hint: 'YYYY-MM-DD',
            wire: 'response_deadline',
            maxLength: 10,
          ),
          field(
            'edit-deadline-time',
            _deadlineTime,
            'New answer by: time',
            hint: 'HH:MM',
            maxLength: 5,
          ),
          ListenableBuilder(
            listenable: Listenable.merge(_all),
            builder: (context, _) {
              final edit = _edit();
              final changed = edit?.changed ?? const <String>[];
              final material = edit?.material ?? false;
              final ready =
                  edit != null &&
                  changed.isNotEmpty &&
                  (!material || edit.responseDeadline != null);
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (changed.isNotEmpty)
                    Text(
                      material
                          ? '${_memberName(edit!.memberId)} will be asked to '
                                'answer again (changed: '
                                '${DutyFields.describe(changed)}).'
                          : 'Only the instructions change: the answer '
                                'stands.',
                      key: Key('edit-summary-$id'),
                    ),
                  if (material && edit?.responseDeadline == null)
                    _muted(context, 'Set the new answer-by date and time.'),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      FocusRing(
                        child: FilledButton(
                          key: Key('edit-save-$id'),
                          onPressed: widget.busy || !ready
                              ? null
                              : () => ref
                                    .read(dutyLeaderProvider.notifier)
                                    .revise(edit, edit.duty.dutyName),
                          child: const Text('Save the change'),
                        ),
                      ),
                      FocusRing(
                        child: TextButton(
                          key: Key('edit-cancel-$id'),
                          onPressed: widget.busy ? null : widget.onClose,
                          child: const Text('Close without saving'),
                        ),
                      ),
                    ],
                  ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

class _PublishForm extends ConsumerStatefulWidget {
  const _PublishForm({super.key, required this.department, required this.busy});
  final LeaderDepartment department;
  final bool busy;

  @override
  ConsumerState<_PublishForm> createState() => _PublishFormState();
}

class _PublishFormState extends ConsumerState<_PublishForm> {
  final _name = TextEditingController();
  final _date = TextEditingController();
  final _start = TextEditingController();
  final _end = TextEditingController();
  final _endDate = TextEditingController();
  final _reporting = TextEditingController();
  final _location = TextEditingController();
  final _instructions = TextEditingController();
  final _deadlineDate = TextEditingController();
  final _deadlineTime = TextEditingController();
  String? _memberId;

  List<TextEditingController> get _all => [
    _name,
    _date,
    _start,
    _end,
    _endDate,
    _reporting,
    _location,
    _instructions,
    _deadlineDate,
    _deadlineTime,
  ];

  @override
  void dispose() {
    for (final c in _all) {
      c.dispose();
    }
    super.dispose();
  }

  DutyDraft? _draft() {
    final member = _memberId;
    // Church time (Africa/Lusaka), whatever zone this computer uses.
    final starts = ChurchTime.parse(_date.text, _start.text);
    final deadline = ChurchTime.parse(_deadlineDate.text, _deadlineTime.text);
    final endDate = _endDate.text.trim().isEmpty ? _date.text : _endDate.text;
    final ends = _end.text.trim().isEmpty
        ? null
        : ChurchTime.parse(endDate, _end.text);
    final reporting = _reporting.text.trim().isEmpty
        ? null
        : ChurchTime.parse(_date.text, _reporting.text);
    if (member == null ||
        _name.text.trim().isEmpty ||
        starts == null ||
        deadline == null ||
        (_end.text.trim().isNotEmpty && ends == null) ||
        (_endDate.text.trim().isNotEmpty && _end.text.trim().isEmpty) ||
        (_reporting.text.trim().isNotEmpty && reporting == null)) {
      return null;
    }
    return DutyDraft(
      departmentId: widget.department.departmentId,
      dutyName: _name.text,
      startsAt: starts,
      endsAt: ends,
      reportingAt: reporting,
      location: _location.text,
      instructions: _instructions.text,
      memberId: member,
      responseDeadline: deadline,
    );
  }

  @override
  Widget build(BuildContext context) {
    final d = widget.department;
    final id = d.departmentId;
    final st = ref.watch(dutyLeaderProvider);
    // Only a publish refusal names this form's fields (not an edit's).
    final errors = st.noticeAction?.command == DutyCommands.publish
        ? st.fieldErrors
        : const <String, String>{};
    String? err(String wire) => switch (errors[wire]) {
      null => null,
      'required' => 'Required',
      'past' => 'This is in the past',
      'after_start' => 'Must be before the duty starts',
      'before_start' => 'Must be after the start',
      'not_in_department' => 'Not a member of this department',
      _ => 'Check this',
    };
    Widget field(
      String key,
      TextEditingController c,
      String label, {
      String? wire,
      String? hint,
      int maxLength = 80,
      int maxLines = 1,
    }) => Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: TextField(
        key: Key('$key-$id'),
        controller: c,
        enabled: !widget.busy,
        maxLength: maxLength,
        maxLines: maxLines,
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          errorText: wire == null ? null : err(wire),
        ),
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _heading(context, 'Publish a duty'),
        _muted(
          context,
          'One person, one position. They are asked to accept or say they '
          'can\'t make it by the deadline you set. Times are church time '
          '(Lusaka), whatever this computer\'s clock is set to.',
        ),
        const SizedBox(height: 8),
        field('publish-name', _name, 'Duty', wire: 'duty_name'),
        field(
          'publish-date',
          _date,
          'Date',
          hint: 'YYYY-MM-DD',
          wire: 'starts_at',
          maxLength: 10,
        ),
        field(
          'publish-start',
          _start,
          'Start time',
          hint: 'HH:MM',
          maxLength: 5,
        ),
        field(
          'publish-end',
          _end,
          'End time (optional)',
          hint: 'HH:MM',
          wire: 'ends_at',
          maxLength: 5,
        ),
        field(
          'publish-end-date',
          _endDate,
          'End date, if it ends on a later day (optional)',
          hint: 'YYYY-MM-DD',
          maxLength: 10,
        ),
        field(
          'publish-reporting',
          _reporting,
          'Reporting time, if earlier than the start (optional)',
          hint: 'HH:MM',
          wire: 'reporting_at',
          maxLength: 5,
        ),
        field(
          'publish-location',
          _location,
          'Location (optional)',
          wire: 'location',
          maxLength: 120,
        ),
        field(
          'publish-instructions',
          _instructions,
          'Instructions (optional)',
          wire: 'instructions',
          maxLength: 1000,
          maxLines: 3,
        ),
        DropdownButton<String>(
          key: Key('publish-member-$id'),
          hint: const Text('Who'),
          value: _memberId,
          isExpanded: true,
          items: [
            for (final m in d.members)
              DropdownMenuItem(
                value: m.memberId,
                child: Text(
                  m.account == AccountStanding.noLogin
                      ? '${m.displayName} (no login: contact them directly)'
                      : m.displayName,
                ),
              ),
          ],
          onChanged: widget.busy ? null : (v) => setState(() => _memberId = v),
        ),
        if (err('member_id') case final e?)
          Text(e, style: TextStyle(color: ChurchColors.of(context).redFg)),
        if (d.members.isEmpty)
          _muted(context, 'This department has no members yet.'),
        const SizedBox(height: 8),
        field(
          'publish-deadline-date',
          _deadlineDate,
          'Answer by: date',
          hint: 'YYYY-MM-DD',
          wire: 'response_deadline',
          maxLength: 10,
        ),
        field(
          'publish-deadline-time',
          _deadlineTime,
          'Answer by: time',
          hint: 'HH:MM',
          maxLength: 5,
        ),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: ListenableBuilder(
            listenable: Listenable.merge(_all),
            builder: (context, _) {
              final draft = _draft();
              return FocusRing(
                child: FilledButton(
                  key: Key('publish-save-$id'),
                  onPressed: widget.busy || draft == null
                      ? null
                      : () => ref
                            .read(dutyLeaderProvider.notifier)
                            .publish(draft, draft.dutyName.trim()),
                  child: const Text('Publish'),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Mobile: the member's duties
// ---------------------------------------------------------------------------

/// Story 4.1, mobile: the member's duties across departments: Needs a
/// response, Upcoming and Past. Accept or Can't make it (with an optional
/// note) shows as done only after the server confirmed it.
class MyDutiesScreen extends StatelessWidget {
  const MyDutiesScreen({super.key, this.assignmentId});

  /// Set when opened from a reminder (`/duties/assignments/<id>`): only that
  /// duty is shown, in full.
  final String? assignmentId;

  @override
  Widget build(BuildContext context) => _DutiesPage<MyDuties>(
    title: assignmentId == null ? 'My duties' : 'Duty',
    provider: myDutiesProvider,
    needs: 'Your duties are shown once you have member access.',
    loading: 'Loading your duties…',
    body: (context, v, s) => assignmentId == null
        ? _MyDutiesList(duties: v, busy: s.busy)
        : _OneDuty(duties: v, assignmentId: assignmentId!, busy: s.busy),
  );
}

class _MyDutiesList extends StatelessWidget {
  const _MyDutiesList({required this.duties, required this.busy});
  final MyDuties duties;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final needs = duties.assignments
        .where((a) => a.needsResponse(now))
        .toList();
    final upcoming = duties.assignments
        .where((a) => !a.needsResponse(now) && !a.startedAt(now))
        .toList();
    final past = duties.assignments.where((a) => a.startedAt(now)).toList()
      ..sort((a, b) => b.times.startsAt.compareTo(a.times.startsAt));
    if (needs.isEmpty && upcoming.isEmpty && past.isEmpty) {
      return const Text(
        'You have no upcoming duties.',
        key: Key('my-duties-empty'),
      );
    }
    List<Widget> section(String title, List<MyDuty> list, bool full) => [
      _heading(context, '$title (${list.length})'),
      if (list.isEmpty) _muted(context, 'None.'),
      for (final a in list) ...[
        _DutyCard(duty: a, busy: busy, full: full),
        const SizedBox(height: 12),
      ],
      const SizedBox(height: 8),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (duties.truncated)
          Text(
            'Only your next 200 duties are shown.',
            key: const Key('my-duties-truncated'),
          ),
        ...section('Needs a response', needs, false),
        ...section('Upcoming', upcoming, false),
        if (past.isNotEmpty) ...section('Past', past, false),
      ],
    );
  }
}

class _OneDuty extends StatelessWidget {
  const _OneDuty({
    required this.duties,
    required this.assignmentId,
    required this.busy,
  });
  final MyDuties duties;
  final String assignmentId;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final duty = duties.findCurrent(assignmentId);
    if (duty == null) {
      return const RequestStateBanner(
        key: Key('duty-not-available'),
        tone: StatusTone.neutral,
        title: 'Not available',
        message:
            'This duty is no longer yours or no longer current. Your current '
            'duties are under My duties.',
      );
    }
    if (duty.assignmentId != assignmentId) {
      // Story 4.2: an old reminder or link for an earlier version.
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const RequestStateBanner(
            key: Key('duty-was-changed'),
            tone: StatusTone.info,
            title: 'This duty changed',
            message:
                'It changed since that message. This is the current version; '
                'your answer is needed for it.',
          ),
          const SizedBox(height: 12),
          _DutyCard(duty: duty, busy: busy, full: true),
        ],
      );
    }
    return _DutyCard(duty: duty, busy: busy, full: true);
  }
}

class _DutyCard extends ConsumerStatefulWidget {
  const _DutyCard({required this.duty, required this.busy, required this.full});
  final MyDuty duty;
  final bool busy;

  /// Show every detail (the deep-linked view); the list shows a summary.
  final bool full;

  @override
  ConsumerState<_DutyCard> createState() => _DutyCardState();
}

class _DutyCardState extends ConsumerState<_DutyCard> {
  final _note = TextEditingController();

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final a = widget.duty;
    final id = a.assignmentId;
    final ctl = ref.read(myDutiesProvider.notifier);
    final now = DateTime.now();
    final (label, tone) = _responseLabel(a.response);
    final canAnswer = a.needsResponse(now);
    // Honest states (FR My duties): Sending while the request is out, Not
    // sent while its outcome is unknown; Accepted only from the server.
    final sending = ref.watch(
      myDutiesProvider.select(
        (s) => s.pending?.request.payload['assignment_id'] == id,
      ),
    );
    final unsent = ref.watch(
      myDutiesProvider.select(
        (s) => s.unconfirmed?.request.payload['assignment_id'] == id,
      ),
    );
    final (shown, shownTone) = !canAnswer
        ? (label, tone)
        : sending
        ? ('Sending…', StatusTone.info)
        : unsent
        ? ('Not sent', StatusTone.warning)
        : (label, tone);
    return _Card(
      key: Key('my-duty-$id'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _heading(context, a.dutyName),
          Text(a.departmentName),
          Text(_timesText(context, a.times)),
          if (a.location case final l?) Text('Where: $l'),
          if (a.changes case final c?) ...[
            const SizedBox(height: 4),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                StatusLabel(
                  key: Key('duty-changed-$id'),
                  label: 'Changed',
                  tone: StatusTone.info,
                ),
                Text('What changed: ${DutyFields.describe(c)}.'),
              ],
            ),
            if (a.previousResponse case final p?)
              _muted(
                context,
                'Your earlier answer was "${_responseLabel(p).$1}". '
                        '${a.response == DutyResponse.pending ? 'Please answer again.' : ''}'
                    .trim(),
              ),
          ],
          if (a.notesUpdatedAt case final u?)
            _muted(
              context,
              'Details updated ${_when(context, u)}. Your answer stands.',
            ),
          if (widget.full)
            if (a.instructions case final i?) ...[
              const SizedBox(height: 4),
              Text('Instructions: $i', key: Key('duty-instructions-$id')),
            ],
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              StatusLabel(
                key: Key('my-duty-status-$id'),
                label: shown,
                tone: shownTone,
              ),
              if (a.response == DutyResponse.pending)
                _muted(
                  context,
                  'Answer by ${_when(context, a.responseDeadline)}',
                ),
            ],
          ),
          if (a.note case final n?) Text('Your note: $n'),
          if (canAnswer) ...[
            const SizedBox(height: 8),
            TextField(
              key: Key('duty-note-$id'),
              controller: _note,
              enabled: !widget.busy,
              maxLength: 280,
              decoration: const InputDecoration(
                labelText: 'Note for your leader (optional)',
              ),
            ),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FocusRing(
                  child: FilledButton(
                    key: Key('duty-accept-$id'),
                    onPressed: widget.busy
                        ? null
                        : () => ctl.respond(
                            a,
                            DutyResponse.accepted,
                            note: _note.text,
                          ),
                    child: const Text('Accept'),
                  ),
                ),
                FocusRing(
                  child: OutlinedButton(
                    key: Key('duty-decline-$id'),
                    onPressed: widget.busy
                        ? null
                        : () => ctl.respond(
                            a,
                            DutyResponse.declined,
                            note: _note.text,
                          ),
                    child: const Text('Can\'t make it'),
                  ),
                ),
              ],
            ),
          ],
          if (!widget.full)
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: FocusRing(
                child: TextButton(
                  key: Key('duty-open-$id'),
                  onPressed: () => context.push(DutyPaths.assignment(id)),
                  child: const Text('Details'),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

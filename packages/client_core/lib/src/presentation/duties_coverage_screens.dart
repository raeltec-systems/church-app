part of 'duties_screens.dart';

// Story 4.9: the coverage queue (staff web and mobile), the leader's
// essential actions (contact, record a contact attempt, Confirmed by leader,
// (re)assign, cancel a position), the leader Home Needs attention card and
// Pastor's church-wide view of gaps. Contact details come only from the
// server's scoped read (the department's leaders and deputies); Admin and
// Pastor see the operational view. Every action is a server-checked command
// and nothing shows as done until the server answers.

const _coverageNeeds =
    'The coverage queue is for the leaders and deputies of a department, and '
    'for Pastor and Admin oversight.';

String _channelPast(ContactChannel c) => switch (c) {
  ContactChannel.phone => 'by phone',
  ContactChannel.message => 'by message',
  ContactChannel.inPerson => 'in person',
  ContactChannel.other => 'another way',
};

StatusTone _coverageTone(CoverageStatus s) => switch (s) {
  CoverageStatus.confirmed => StatusTone.success,
  CoverageStatus.unfilled ||
  CoverageStatus.overdue ||
  CoverageStatus.declined => StatusTone.danger,
  CoverageStatus.changed => StatusTone.warning,
  CoverageStatus.awaiting => StatusTone.info,
};

String _countsText(CoverageCounts c) => [
  '${c.confirmed} of ${c.required} confirmed',
  '${c.unfilled} unfilled',
  '${c.overdue} overdue',
  '${c.declined} declined or changed',
  '${c.needsContact} need contact',
  if (c.conflicts > 0) '${c.conflicts} with overlapping duties',
  if (c.overdueFollowUps > 0) '${c.overdueFollowUps} follow-ups overdue',
  if (c.vacated > 0) '${c.vacated} need a new person',
].join(', ');

/// Story 4.9: `/duties/coverage`.
class DutyCoverageScreen extends StatelessWidget {
  const DutyCoverageScreen({super.key});

  @override
  Widget build(BuildContext context) => _DutiesPage<DutyCoverage>(
    title: 'Coverage',
    provider: dutyCoverageProvider,
    needs: _coverageNeeds,
    loading: 'Loading coverage…',
    body: (context, value, state) => _CoverageBody(value: value, state: state),
  );
}

class _CoverageBody extends ConsumerStatefulWidget {
  const _CoverageBody({required this.value, required this.state});
  final DutyCoverage value;
  final DutiesState<DutyCoverage> state;

  @override
  ConsumerState<_CoverageBody> createState() => _CoverageBodyState();
}

class _CoverageBodyState extends ConsumerState<_CoverageBody> {
  var _filter = CoverageFilter.all;
  late final _from = TextEditingController(text: widget.value.from);
  late final _duty = TextEditingController(text: widget.value.duty ?? '');
  late int _days = ref.read(dutyCoverageQueryProvider).days;
  String? _fromError;
  late String? _department = ref.read(dutyCoverageQueryProvider).departmentId;

  @override
  void dispose() {
    _from.dispose();
    _duty.dispose();
    super.dispose();
  }

  void _apply() {
    final from = _from.text.trim();
    // Review N7: a malformed date is shown as an error, never silently replaced by today.
    final valid =
        from.isEmpty ||
        (RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(from) &&
            ChurchTime.parse(from, '00:00') != null);
    setState(() => _fromError = valid ? null : 'Use YYYY-MM-DD');
    if (!valid) return;
    ref
        .read(dutyCoverageProvider.notifier)
        .setQuery(
          CoverageQuery(
            from: RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(from) ? from : null,
            days: _days,
            departmentId: _department,
            duty: _duty.text.trim().isEmpty ? null : _duty.text.trim(),
          ),
        );
  }

  @override
  Widget build(BuildContext context) {
    final v = widget.value;
    final busy = widget.state.busy;
    final operational = v.departments.where((d) => !d.full).toList();
    final children = <Widget>[
      _muted(
        context,
        'Duties from ${v.from} to ${v.to} (church time) that have not '
        'started${v.duty == null ? '' : ', duty matching "${v.duty}"'}.',
      ),
      const SizedBox(height: 8),
      Wrap(
        spacing: 12,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.end,
        children: [
          SizedBox(
            width: 160,
            child: TextField(
              key: const Key('coverage-from'),
              controller: _from,
              decoration: InputDecoration(
                labelText: 'From (YYYY-MM-DD)',
                errorText: _fromError,
              ),
            ),
          ),
          DropdownButton<int>(
            key: const Key('coverage-days'),
            value: _days,
            items: [
              for (final d in const [7, 14, 31])
                DropdownMenuItem(value: d, child: Text('$d days')),
            ],
            onChanged: (d) => setState(() => _days = d ?? 7),
          ),
          SizedBox(
            width: 200,
            child: TextField(
              key: const Key('coverage-duty'),
              controller: _duty,
              maxLength: 80,
              decoration: const InputDecoration(
                labelText: 'Duty name contains',
                counterText: '',
              ),
            ),
          ),
          if (v.departments.length > 1 || _department != null)
            DropdownButton<String?>(
              key: const Key('coverage-department'),
              value: _department,
              items: [
                const DropdownMenuItem<String?>(
                  value: null,
                  child: Text('All departments'),
                ),
                for (final d in v.departments)
                  DropdownMenuItem<String?>(
                    value: d.departmentId,
                    child: Text(d.name),
                  ),
              ],
              onChanged: (d) => setState(() => _department = d),
            ),
          FocusRing(
            child: OutlinedButton(
              key: const Key('coverage-apply'),
              onPressed: busy ? null : _apply,
              child: const Text('Show'),
            ),
          ),
        ],
      ),
      const SizedBox(height: 12),
      if (v.truncated)
        const RequestStateBanner(
          key: Key('coverage-truncated'),
          tone: StatusTone.warning,
          title: 'Showing the first 1000 positions',
          message:
              'The counts cover every position; choose fewer days or one '
              'department to list the rest.',
        ),
    ];
    // Pastor's (and the Admin's) church-wide view of gaps.
    if (operational.isNotEmpty) {
      final t = v.totals;
      children.addAll([
        _heading(
          context,
          'Gaps across the church',
          key: const Key('coverage-church-wide'),
        ),
        _muted(
          context,
          'Operational view: positions and their state only. Contact details '
          'and notes are for each department\'s leaders and deputies.',
        ),
        Text(_countsText(t), key: const Key('coverage-church-totals')),
        for (final d in v.departments)
          Text(
            '${d.name}: ${_countsText(d.counts)}',
            key: Key('coverage-summary-${d.departmentId}'),
          ),
        const SizedBox(height: ChurchGeometry.sectionGap),
      ]);
    }
    final all = [for (final d in v.departments) ...d.positions];
    children.add(
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final f in CoverageFilter.values)
            ChoiceChip(
              key: Key('coverage-filter-${f.name}'),
              label: Text('${f.label} (${all.where(f.matches).length})'),
              selected: _filter == f,
              onSelected: (_) => setState(() => _filter = f),
            ),
        ],
      ),
    );
    if (v.departments.isEmpty) {
      children.add(_muted(context, 'No departments to show.'));
    }
    for (final d in v.departments) {
      final shown = d.positions.where(_filter.matches).toList();
      children.addAll([
        const SizedBox(height: ChurchGeometry.sectionGap),
        _heading(context, d.name, key: Key('coverage-dept-${d.departmentId}')),
        Text(
          _countsText(d.counts),
          key: Key('coverage-counts-${d.departmentId}'),
        ),
        if (!d.full)
          _muted(
            context,
            d.canManage
                ? 'Admin view: you can reassign or cancel positions; contact '
                      'details and notes are for the department\'s leaders.'
                : 'Pastor oversight (read only).',
          ),
        const SizedBox(height: 8),
        if (shown.isEmpty)
          _muted(
            context,
            _filter == CoverageFilter.all
                ? 'No duties in these dates.'
                : 'Nothing here for "${_filter.label}".',
          ),
        for (final p in shown) ...[
          _CoverageCard(
            key: Key('coverage-card-${p.slotId}'),
            department: d,
            position: p,
            busy: busy,
            fieldErrors: widget.state.fieldErrors,
            lastAction: widget.state.noticeAction,
          ),
          const SizedBox(height: 8),
        ],
      ]);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    );
  }
}

enum _CoverageForm { none, attempt, confirm, assign, cancel }

class _CoverageCard extends ConsumerStatefulWidget {
  const _CoverageCard({
    super.key,
    required this.department,
    required this.position,
    required this.busy,
    required this.fieldErrors,
    required this.lastAction,
  });

  final CoverageDepartment department;
  final CoveragePosition position;
  final bool busy;
  final Map<String, String> fieldErrors;
  final DutyAction? lastAction;

  @override
  ConsumerState<_CoverageCard> createState() => _CoverageCardState();
}

class _CoverageCardState extends ConsumerState<_CoverageCard> {
  var _form = _CoverageForm.none;
  var _channel = ContactChannel.phone;
  var _outcome = ContactOutcome.noAnswer;
  final _note = TextEditingController();
  final _reason = TextEditingController();
  final _override = TextEditingController();
  final _date = TextEditingController();
  final _time = TextEditingController();
  String? _who;
  String? _launch;
  String? _localError;

  /// The request this card sent last (its success closes the form).
  String? _sent;

  @override
  void dispose() {
    _note.dispose();
    _reason.dispose();
    _override.dispose();
    _date.dispose();
    _time.dispose();
    super.dispose();
  }

  CoveragePosition get p => widget.position;

  void _open(_CoverageForm f) {
    setState(() {
      _form = _form == f ? _CoverageForm.none : f;
      _localError = null;
      if (f == _CoverageForm.attempt && _date.text.isEmpty) {
        // A day from now, or an hour before the duty when that is sooner.
        final start = p.times.arriveBy;
        var next = DateTime.now().toUtc().add(const Duration(days: 1));
        final latest = start.subtract(const Duration(hours: 1));
        if (next.isAfter(latest)) next = latest;
        _date.text = ChurchTime.dateText(next);
        _time.text = ChurchTime.timeText(next);
      }
    });
  }

  Future<void> _send(Future<void> Function() action) async {
    await action();
    final s = ref.read(dutyCoverageProvider);
    if (!mounted) return;
    _sent = s.noticeAction?.request.requestId;
    const done = {
      DutyNotice.contactRecorded,
      DutyNotice.leaderConfirmed,
      DutyNotice.positionCancelled,
      DutyNotice.occurrenceCancelled,
      DutyNotice.positionGiven,
    };
    if (s.notice != null && done.contains(s.notice) && _sent != null) {
      setState(() {
        _form = _CoverageForm.none;
        _note.clear();
        _reason.clear();
        _override.clear();
        _date.clear();
        _time.clear();
        _who = null;
      });
    }
  }

  Future<void> _contact(DutyContactRoute r, bool call) async {
    final launcher = ref.read(contactLauncherProvider);
    final result = call
        ? await launcher.call(r.phone)
        : await launcher.message(r.phone);
    if (!mounted) return;
    setState(
      () => _launch = switch (result) {
        ContactLaunch.opened =>
          'Opened your ${call ? 'phone' : 'messaging'} app. Nothing is sent '
              'or recorded by this app: record the attempt below.',
        ContactLaunch.failed =>
          'This device could not open the ${call ? 'phone' : 'messaging'} '
              'app. Use the number shown.',
        ContactLaunch.unavailable =>
          '${call ? 'Calling' : 'Messaging'} isn\'t available here. Use the '
              'number shown.',
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final d = widget.department;
    final a = p.assignment;
    final busy = widget.busy;
    final started = !p.times.arriveBy.isAfter(DateTime.now());
    // Review S2: a leader's own duty is answered in My duties, not as contact work.
    final own =
        a != null &&
        a.memberId ==
            ref.watch(myAccessProvider.select((s) => s.grants?.memberId));
    final routes = a == null
        ? const <DutyContactRoute>[]
        : d.routesOf(a.memberId);
    final mine = widget.lastAction?.request.requestId == _sent && _sent != null;
    final errors = mine ? widget.fieldErrors : const <String, String>{};
    final lines = <Widget>[
      Text(
        p.title,
        style: ChurchType.cardTitle.copyWith(
          color: ChurchColors.of(context).ink,
        ),
      ),
      Text(
        '${_timesText(context, p.times)}'
        '${p.location == null ? '' : '. ${p.location}'}',
      ),
      const SizedBox(height: 4),
      Wrap(
        spacing: 8,
        runSpacing: 4,
        children: [
          StatusLabel(
            key: Key('coverage-status-${p.slotId}'),
            label: a?.confirmedByLeader ?? false
                ? 'Confirmed by leader'
                : (a?.priorAcceptedAt != null &&
                          a?.response == DutyResponse.declined
                      ? 'Can\'t make it anymore'
                      : p.status.label),
            tone: _coverageTone(p.status),
          ),
          if (a?.shortNotice ?? false)
            const StatusLabel(label: 'Short notice', tone: StatusTone.warning),
          // Story 4.12: the person given it can no longer serve (never why).
          if (p.vacated)
            StatusLabel(
              key: Key('coverage-vacated-${p.slotId}'),
              label: 'Needs a new person',
              tone: StatusTone.warning,
            ),
          if (p.needsContact != null)
            StatusLabel(
              key: Key('coverage-needs-contact-${p.slotId}'),
              label: 'Needs contact',
              tone: StatusTone.warning,
            ),
          if (p.overlaps > 0)
            StatusLabel(
              label:
                  'Overlaps ${p.overlaps} other ${p.overlaps == 1 ? 'duty' : 'duties'}',
              tone: StatusTone.warning,
            ),
        ],
      ),
    ];
    if (p.vacated) {
      lines.add(
        _muted(
          context,
          'The person given this position can no longer serve it. Give it to '
          'someone else.',
        ),
      );
    }
    if (a != null) {
      lines.addAll([
        const SizedBox(height: 4),
        Text(
          a.account == AccountStanding.noLogin
              ? '${a.name} (no login: contact them directly)'
              : a.name,
          key: Key('coverage-who-${p.slotId}'),
        ),
        if (a.response == DutyResponse.pending)
          Text(
            'Answer by ${_when(context, a.responseDeadline)}'
            '${a.deadlineSource == DutyDeadlineSource.churchDefault ? ' (church default)' : ''}',
          ),
        if (a.confirmation case final c?)
          Text(
            'Confirmed by leader ${_channelPast(c.channel)}'
            '${c.by == null ? '' : ', recorded by ${c.by}'}, '
            '${_when(context, c.at)}'
            '${c.reason == null ? '' : ': "${c.reason}"'}',
            key: Key('coverage-confirmation-${p.slotId}'),
          ),
        if (a.changes case final ch? when p.status == CoverageStatus.changed)
          Text('Changed: ${DutyFields.describe(ch)}. They are asked again.'),
        if (a.note case final n?) Text('Their note: "$n"'),
        if (p.needsContact case final nc?) _muted(context, nc.text),
      ]);
    }
    if (p.followUp case final f?) {
      final last = f.lastAttempt;
      lines.addAll([
        const SizedBox(height: 4),
        Text(
          '${f.attempts} contact ${f.attempts == 1 ? 'attempt' : 'attempts'}; '
          'latest ${_when(context, last.at)} ${_channelPast(last.channel)}'
          '${last.by == null ? '' : ' by ${last.by}'}: ${last.outcome.label}'
          '${last.note == null ? '' : ' ("${last.note}")'}.',
          key: Key('coverage-attempts-${p.slotId}'),
        ),
        Text(
          'Next follow-up ${_when(context, f.nextFollowUpAt)}'
          '${f.overdue ? ' (overdue)' : ''}',
          key: Key('coverage-next-${p.slotId}'),
        ),
        if (f.taskId case final t?)
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton(
              key: Key('coverage-task-${p.slotId}'),
              onPressed: () => context.go(FollowUpPaths.task(t)),
              child: const Text('Open the follow-up task'),
            ),
          ),
      ]);
    }
    if (routes.isNotEmpty && a?.response != DutyResponse.accepted) {
      lines.add(const SizedBox(height: 4));
      for (final r in routes) {
        lines.add(
          Wrap(
            spacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text('${r.label}: ${r.phone}'),
              TextButton(
                key: Key('coverage-call-${p.slotId}-${r.phone}'),
                onPressed: () => _contact(r, true),
                child: const Text('Call'),
              ),
              TextButton(
                key: Key('coverage-message-${p.slotId}-${r.phone}'),
                onPressed: () => _contact(r, false),
                child: const Text('Message'),
              ),
            ],
          ),
        );
      }
    }
    if (_launch case final l?) {
      lines.add(Text(l, key: Key('coverage-launch-${p.slotId}')));
    }
    if (own && p.contactable) {
      lines.add(
        _muted(context, 'This is your own duty: answer it in My duties.'),
      );
    }
    final actions = <Widget>[
      if (d.canContact && p.contactable && !started && !own)
        OutlinedButton(
          key: Key('coverage-attempt-${p.slotId}'),
          onPressed: busy ? null : () => _open(_CoverageForm.attempt),
          child: const Text('Record contact attempt'),
        ),
      if (d.canContact && p.confirmable && !started && !own)
        OutlinedButton(
          key: Key('coverage-confirm-${p.slotId}'),
          onPressed: busy ? null : () => _open(_CoverageForm.confirm),
          child: const Text('Confirmed by leader'),
        ),
      if (d.canManage && !started)
        OutlinedButton(
          key: Key('coverage-assign-${p.slotId}'),
          onPressed: busy ? null : () => _open(_CoverageForm.assign),
          child: Text(a == null ? 'Assign' : 'Reassign'),
        ),
      if (d.canManage && !started)
        OutlinedButton(
          key: Key('coverage-cancel-${p.slotId}'),
          onPressed: busy ? null : () => _open(_CoverageForm.cancel),
          child: const Text('Cancel position'),
        ),
    ];
    if (actions.isNotEmpty) {
      lines.addAll([
        const SizedBox(height: 8),
        Wrap(spacing: 8, runSpacing: 8, children: actions),
      ]);
    }
    final form = switch (_form) {
      _CoverageForm.none => null,
      _CoverageForm.attempt => _attemptForm(context, errors),
      _CoverageForm.confirm => _confirmForm(context, errors),
      _CoverageForm.assign => _assignForm(context, errors),
      _CoverageForm.cancel => _cancelForm(context),
    };
    if (form != null) {
      lines.addAll([const SizedBox(height: 8), form]);
    }
    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: lines,
      ),
    );
  }

  Widget _attemptForm(BuildContext context, Map<String, String> errors) {
    final busy = widget.busy;
    final next = ChurchTime.parse(_date.text.trim(), _time.text.trim());
    String? nextError =
        _localError ??
        switch (errors['next_follow_up_at']) {
          null => null,
          'past' => 'Must be in the future',
          'after_start' => 'Must be before the duty starts',
          _ => 'Check the date and time',
        };
    return Column(
      key: Key('coverage-attempt-form-${p.slotId}'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _muted(
          context,
          'Practical only: no pastoral or medical detail. Seen by this '
          'department\'s leaders and deputies.',
        ),
        DropdownButtonFormField<ContactChannel>(
          key: Key('coverage-attempt-channel-${p.slotId}'),
          initialValue: _channel,
          decoration: const InputDecoration(labelText: 'How'),
          items: [
            for (final c in ContactChannel.values)
              DropdownMenuItem(value: c, child: Text(c.label)),
          ],
          onChanged: busy ? null : (c) => setState(() => _channel = c!),
        ),
        DropdownButtonFormField<ContactOutcome>(
          key: Key('coverage-attempt-outcome-${p.slotId}'),
          initialValue: _outcome,
          decoration: const InputDecoration(labelText: 'What happened'),
          items: [
            for (final o in ContactOutcome.values)
              DropdownMenuItem(value: o, child: Text(o.label)),
          ],
          onChanged: busy ? null : (o) => setState(() => _outcome = o!),
        ),
        TextField(
          key: Key('coverage-attempt-note-${p.slotId}'),
          controller: _note,
          enabled: !busy,
          maxLength: ContactAttemptDraft.noteMax,
          maxLines: 2,
          decoration: const InputDecoration(labelText: 'Note (optional)'),
        ),
        Wrap(
          spacing: 12,
          children: [
            SizedBox(
              width: 170,
              child: TextField(
                key: Key('coverage-attempt-date-${p.slotId}'),
                controller: _date,
                enabled: !busy,
                onChanged: (_) => setState(() => _localError = null),
                decoration: InputDecoration(
                  labelText: 'Next follow-up date',
                  helperText: 'YYYY-MM-DD, church time',
                  errorText: nextError,
                ),
              ),
            ),
            SizedBox(
              width: 120,
              child: TextField(
                key: Key('coverage-attempt-time-${p.slotId}'),
                controller: _time,
                enabled: !busy,
                onChanged: (_) => setState(() => _localError = null),
                decoration: const InputDecoration(labelText: 'Time (HH:MM)'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: FilledButton(
            key: Key('coverage-attempt-save-${p.slotId}'),
            onPressed: busy || next == null
                ? null
                : () {
                    final draft = ContactAttemptDraft(
                      channel: _channel,
                      outcome: _outcome,
                      note: _note.text,
                      nextFollowUpAt: next,
                    );
                    final e = draft.errors(startsAt: p.times.arriveBy);
                    if (e.isNotEmpty) {
                      setState(
                        () => _localError = switch (e['next_follow_up_at']) {
                          'past' => 'Must be in the future',
                          'after_start' => 'Must be before the duty starts',
                          _ => 'Check the note',
                        },
                      );
                      return;
                    }
                    _send(
                      () => ref
                          .read(dutyCoverageProvider.notifier)
                          .recordAttempt(p, draft),
                    );
                  },
            child: const Text('Save contact attempt'),
          ),
        ),
      ],
    );
  }

  Widget _confirmForm(BuildContext context, Map<String, String> errors) {
    final busy = widget.busy;
    final a = p.assignment!;
    final reasonOk = _reason.text.trim().isNotEmpty;
    return Column(
      key: Key('coverage-confirm-form-${p.slotId}'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _muted(
          context,
          'Use this only when ${a.name} confirmed by phone or in person. It is '
          'labelled Confirmed by leader, with you, the time and your reason, '
          'and is kept apart from an answer in the app. Opening a reminder '
          'never counts as a confirmation.',
        ),
        DropdownButtonFormField<ContactChannel>(
          key: Key('coverage-confirm-channel-${p.slotId}'),
          initialValue: _channel,
          decoration: const InputDecoration(labelText: 'How they confirmed'),
          items: [
            for (final c in ContactChannel.values)
              DropdownMenuItem(value: c, child: Text(c.label)),
          ],
          onChanged: busy ? null : (c) => setState(() => _channel = c!),
        ),
        TextField(
          key: Key('coverage-confirm-reason-${p.slotId}'),
          controller: _reason,
          enabled: !busy,
          maxLength: LeaderConfirmationDraft.reasonMax,
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(
            labelText: 'Reason (required)',
            errorText: errors['reason'] == null ? null : 'Give a short reason',
          ),
        ),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: FilledButton(
            key: Key('coverage-confirm-save-${p.slotId}'),
            onPressed: busy || !reasonOk
                ? null
                : () => _send(
                    () => ref
                        .read(dutyCoverageProvider.notifier)
                        .confirm(
                          p,
                          LeaderConfirmationDraft(
                            channel: _channel,
                            reason: _reason.text,
                          ),
                        ),
                  ),
            child: const Text('Record Confirmed by leader'),
          ),
        ),
      ],
    );
  }

  Widget _assignForm(BuildContext context, Map<String, String> errors) {
    final busy = widget.busy;
    final a = p.assignment;
    final members = widget.department.members;
    DepartmentMember? chosen;
    for (final m in members) {
      if (m.memberId == _who) chosen = m;
    }
    return Column(
      key: Key('coverage-assign-form-${p.slotId}'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _muted(
          context,
          [
            'The answer-by time is the church default.',
            if (a != null)
              '${a.name} is told the position is no longer theirs and their '
                  'reminders stop.',
          ].join(' '),
        ),
        _CandidatePicker(
          pickerKey: 'coverage-who-picker-${p.slotId}',
          members: [
            for (final m in members)
              if (m.memberId != a?.memberId) m,
          ],
          value: _who,
          onChanged: (v) => setState(() => _who = v),
          reason: _override,
          busy: busy,
          query: CandidateQuery.slot(p.slotId),
          reasonError: errors['override_reason'],
        ),
        const SizedBox(height: 8),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: FilledButton(
            key: Key('coverage-assign-save-${p.slotId}'),
            onPressed: busy || chosen == null
                ? null
                : () => _send(
                    () => ref
                        .read(dutyCoverageProvider.notifier)
                        .assign(
                          p,
                          chosen!.memberId,
                          chosen.displayName,
                          reason: _override.text,
                        ),
                  ),
            child: const Text('Give this position'),
          ),
        ),
      ],
    );
  }

  Widget _cancelForm(BuildContext context) {
    final busy = widget.busy;
    final a = p.assignment;
    final notify = a != null && a.response != DutyResponse.declined;
    return Column(
      key: Key('coverage-cancel-form-${p.slotId}'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          [
            p.positionsLeft <= 1
                ? 'This is the duty\'s last position: the whole duty on '
                      '${_when(context, p.times.startsAt)} is cancelled.'
                : 'Only this position is cancelled; the other positions stay.',
            if (notify) '${a.name} gets a cancellation notice.',
          ].join(' '),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          children: [
            FilledButton(
              key: Key('coverage-cancel-confirm-${p.slotId}'),
              style: FilledButton.styleFrom(
                backgroundColor: ChurchColors.of(context).redFg,
              ),
              onPressed: busy
                  ? null
                  : () => _send(
                      () => ref
                          .read(dutyCoverageProvider.notifier)
                          .cancelPosition(p),
                    ),
              child: Text(
                p.positionsLeft <= 1 ? 'Cancel the duty' : 'Cancel position',
              ),
            ),
            OutlinedButton(
              key: Key('coverage-cancel-keep-${p.slotId}'),
              onPressed: () => setState(() => _form = _CoverageForm.none),
              child: const Text('Keep it'),
            ),
          ],
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Mobile Home: the leader's Needs attention card
// ---------------------------------------------------------------------------

/// Story 4.9 (mobile Home): for leaders and deputies of a department: this
/// week's Unfilled, Overdue, Declined and Needs contact counts, current
/// coverage, overlapping duties and overdue follow-ups, and Open coverage.
/// Nothing is shown to anyone else; a failed read never looks empty.
class LeaderNeedsAttentionCard extends ConsumerStatefulWidget {
  const LeaderNeedsAttentionCard({super.key});

  @override
  ConsumerState<LeaderNeedsAttentionCard> createState() =>
      _LeaderNeedsAttentionCardState();
}

class _LeaderNeedsAttentionCardState
    extends ConsumerState<LeaderNeedsAttentionCard> {
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onResume: _reload);
    // Revisiting Home reads again (only for a leader: nobody else's Home
    // ever asks for coverage).
    if (leadsADepartment(ref.read(myAccessProvider).grants) &&
        ref.read(leaderAttentionProvider).result != null) {
      Future.microtask(_reload);
    }
  }

  void _reload() {
    if (!mounted || !leadsADepartment(ref.read(myAccessProvider).grants)) {
      return;
    }
    final s = ref.read(leaderAttentionProvider);
    if (!s.busy && !s.loading) {
      ref.read(leaderAttentionProvider.notifier).reload();
    }
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final grants = ref.watch(myAccessProvider.select((s) => s.grants));
    if (!leadsADepartment(grants)) return const SizedBox.shrink();
    final c = ChurchColors.of(context);
    final s = ref.watch(leaderAttentionProvider);
    final on = c.onPrimary;
    final text = ChurchType.body.copyWith(color: on);
    final children = <Widget>[
      Semantics(
        header: true,
        child: Text(
          'Needs attention',
          style: ChurchType.cardTitle.copyWith(color: on),
        ),
      ),
      const SizedBox(height: 8),
    ];
    switch (s.result) {
      case null:
        children.add(
          Text(
            'Loading this week\'s coverage…',
            key: const Key('home-attention-loading'),
            style: text,
          ),
        );
      case AccessReadDenied():
        children.add(
          Text(
            'Coverage is not available to you right now.',
            key: const Key('home-attention-denied'),
            style: text,
          ),
        );
      case AccessReadFailed(:final unreachable):
        children.add(
          Text(
            unreachable
                ? 'No connection: we couldn\'t reach the church server. This '
                      'is not an empty list.'
                : 'Couldn\'t load coverage. Try again later.',
            key: const Key('home-attention-failed'),
            style: text,
          ),
        );
      case AccessReadOk(:final value):
        final t = value.managedTotals;
        Widget tile(String label, int n, String key) => Expanded(
          child: Semantics(
            label: '$label: $n',
            excludeSemantics: true,
            child: Column(
              key: Key('home-attention-$key'),
              children: [
                Text(
                  '$n',
                  style: ChurchType.cardTitle.copyWith(color: on, fontSize: 24),
                ),
                Text(label, style: text, textAlign: TextAlign.center),
              ],
            ),
          ),
        );
        children.addAll([
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              tile('Unfilled', t.unfilled, 'unfilled'),
              tile('Overdue', t.overdue, 'overdue'),
              tile('Declined or changed', t.declined, 'declined'),
              tile('Needs contact', t.needsContact, 'needs-contact'),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'This week: ${t.confirmed} of ${t.required} positions confirmed.',
            key: const Key('home-attention-coverage'),
            style: text,
          ),
          if (t.conflicts > 0)
            Text(
              '${t.conflicts} assigned with an overlapping duty.',
              key: const Key('home-attention-conflicts'),
              style: text,
            ),
          if (t.overdueFollowUps > 0)
            Text(
              '${t.overdueFollowUps} contact follow-ups overdue.',
              key: const Key('home-attention-follow-ups'),
              style: text,
            ),
          if (!t.needsAttention)
            Text(
              'Nothing needs your attention this week.',
              key: const Key('home-attention-clear'),
              style: text,
            ),
        ]);
    }
    children.addAll([
      const SizedBox(height: 8),
      Align(
        alignment: AlignmentDirectional.centerStart,
        child: FocusRing(
          child: TextButton(
            key: const Key('home-attention-open'),
            style: TextButton.styleFrom(foregroundColor: on),
            onPressed: () => context.go(DutyPaths.coverage),
            child: const Text('Open coverage'),
          ),
        ),
      ),
      // Story 4.10: the outcomes of past duties (mobile leaders).
      Align(
        alignment: AlignmentDirectional.centerStart,
        child: FocusRing(
          child: TextButton(
            key: const Key('home-attention-outcomes'),
            style: TextButton.styleFrom(foregroundColor: on),
            onPressed: () => context.go(DutyPaths.outcomes),
            child: const Text('Record outcomes of past duties'),
          ),
        ),
      ),
    ]);
    return Padding(
      padding: const EdgeInsets.only(bottom: ChurchGeometry.sectionGap),
      child: Material(
        key: const Key('home-attention-card'),
        color: c.hero,
        borderRadius: BorderRadius.circular(ChurchGeometry.mobileCardRadius),
        child: Padding(
          padding: const EdgeInsets.all(ChurchGeometry.cardPadding),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: children,
          ),
        ),
      ),
    );
  }
}

part of 'duties_screens.dart';

// Story 4.10: completion outcomes (staff web and mobile). After a duty the
// department's leader or deputy records Completed, Excused or No-show with an
// optional short note, and corrects it with a reason; every earlier value
// stays visible with who recorded it and when. A member's assignment history
// is for the member and their department's leaders and deputies, for fair
// workload conversations; it is never a ranking. Response, coverage and
// completion are shown apart, and nothing is inferred from the time: a past
// duty nobody recorded says "Not recorded".

const _outcomesNeeds =
    'Outcomes are recorded by the leaders and deputies of a department.';

const _historyPrivacy =
    'Seen only by the member and their department\'s leaders and deputies, '
    'for fair workload conversations. It is not a ranking.';

StatusTone _outcomeTone(OutcomeState s) => switch (s) {
  OutcomeState.completed => StatusTone.success,
  OutcomeState.excused => StatusTone.info,
  OutcomeState.noShow => StatusTone.warning,
  OutcomeState.unrecorded => StatusTone.neutral,
  OutcomeState.upcoming => StatusTone.info,
  OutcomeState.none => StatusTone.neutral,
};

OutcomeState _stateOf(DutyOutcome o) => switch (o) {
  DutyOutcome.completed => OutcomeState.completed,
  DutyOutcome.excused => OutcomeState.excused,
  DutyOutcome.noShow => OutcomeState.noShow,
};

/// The current outcome, its note and (when corrected) the earlier values
/// with who recorded each, when, and the correction reasons.
class _OutcomeLines extends StatelessWidget {
  const _OutcomeLines({required this.record, required this.keyPrefix});

  final DutyOutcomeRecord record;
  final String keyPrefix;

  @override
  Widget build(BuildContext context) {
    final o = record;
    final current = o.trail.where((t) => t.revision == o.revision).firstOrNull;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            StatusLabel(
              key: Key('$keyPrefix-label'),
              label: 'Outcome: ${o.outcome.label}',
              tone: _outcomeTone(_stateOf(o.outcome)),
            ),
            if (o.corrected)
              const StatusLabel(label: 'Corrected', tone: StatusTone.info),
          ],
        ),
        _muted(
          context,
          'Recorded${o.recordedBy == null ? '' : ' by ${o.recordedBy}'} '
          '${_when(context, o.recordedAt)}'
          '${current?.reason == null ? '' : '. Reason: "${current!.reason}"'}',
        ),
        if (o.note case final n?)
          Text('Note: "$n"', key: Key('$keyPrefix-note')),
        for (final t in o.earlier)
          _muted(
            context,
            'Earlier: ${t.outcome.label}'
            '${t.note == null ? '' : ' ("${t.note}")'}, recorded'
            '${t.by == null ? '' : ' by ${t.by}'} ${_when(context, t.at)}'
            '${t.reason == null ? '' : '. Reason: "${t.reason}"'}',
          ),
      ],
    );
  }
}

/// Story 4.10: `/duties/outcomes`.
class DutyOutcomesScreen extends StatelessWidget {
  const DutyOutcomesScreen({super.key});

  @override
  Widget build(BuildContext context) => _DutiesPage<DutyOutcomes>(
    title: 'Outcomes',
    provider: dutyOutcomesProvider,
    needs: _outcomesNeeds,
    loading: 'Loading outcomes…',
    body: (context, value, state) => _OutcomesBody(value: value, state: state),
  );
}

class _OutcomesBody extends ConsumerStatefulWidget {
  const _OutcomesBody({required this.value, required this.state});
  final DutyOutcomes value;
  final DutiesState<DutyOutcomes> state;

  @override
  ConsumerState<_OutcomesBody> createState() => _OutcomesBodyState();
}

class _OutcomesBodyState extends ConsumerState<_OutcomesBody> {
  late final _from = TextEditingController(text: widget.value.from);
  late final _duty = TextEditingController(text: widget.value.duty ?? '');
  late int _days = ref.read(dutyOutcomesQueryProvider).days;
  late String? _department = ref.read(dutyOutcomesQueryProvider).departmentId;
  var _unrecordedOnly = false;
  String? _fromError;

  @override
  void dispose() {
    _from.dispose();
    _duty.dispose();
    super.dispose();
  }

  void _apply() {
    final from = _from.text.trim();
    final valid =
        from.isEmpty ||
        (RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(from) &&
            ChurchTime.parse(from, '00:00') != null);
    setState(() => _fromError = valid ? null : 'Use YYYY-MM-DD');
    if (!valid) return;
    ref
        .read(dutyOutcomesProvider.notifier)
        .setQuery(
          OutcomesQuery(
            from: from.isEmpty ? null : from,
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
    final children = <Widget>[
      _muted(
        context,
        'Duties from ${v.from} to ${v.to} (church time) that have started'
        '${v.duty == null ? '' : ', duty matching "${v.duty}"'}. An outcome is '
        'only what a leader records: a duty nobody recorded stays "Not '
        'recorded".',
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
              key: const Key('outcomes-from'),
              controller: _from,
              decoration: InputDecoration(
                labelText: 'From (YYYY-MM-DD)',
                errorText: _fromError,
              ),
            ),
          ),
          DropdownButton<int>(
            key: const Key('outcomes-days'),
            value: _days,
            items: [
              for (final d in const [7, 14, 31])
                DropdownMenuItem(value: d, child: Text('$d days')),
            ],
            onChanged: (d) => setState(() => _days = d ?? 14),
          ),
          SizedBox(
            width: 200,
            child: TextField(
              key: const Key('outcomes-duty'),
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
              key: const Key('outcomes-department'),
              value: _department,
              items: [
                const DropdownMenuItem<String?>(
                  value: null,
                  child: Text('All my departments'),
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
              key: const Key('outcomes-apply'),
              onPressed: busy ? null : _apply,
              child: const Text('Show'),
            ),
          ),
        ],
      ),
      const SizedBox(height: 8),
      FilterChip(
        key: const Key('outcomes-unrecorded-only'),
        label: const Text('Not recorded only'),
        selected: _unrecordedOnly,
        onSelected: (s) => setState(() => _unrecordedOnly = s),
      ),
      const SizedBox(height: 12),
      if (v.truncated)
        const RequestStateBanner(
          key: Key('outcomes-truncated'),
          tone: StatusTone.warning,
          title: 'Showing the latest 1000 positions',
          message:
              'The counts cover every position; choose fewer days or one '
              'department to list the rest.',
        ),
    ];
    if (v.departments.isEmpty) {
      children.add(_muted(context, 'No departments to show.'));
    }
    for (final d in v.departments) {
      final c = d.counts;
      final shown = d.positions
          .where(
            (p) =>
                !_unrecordedOnly ||
                p.assignment?.state == OutcomeState.unrecorded,
          )
          .toList();
      children.addAll([
        const SizedBox(height: ChurchGeometry.sectionGap),
        _heading(context, d.name, key: Key('outcomes-dept-${d.departmentId}')),
        Text(
          '${c.positions} positions: ${c.completed} completed, ${c.excused} '
          'excused, ${c.noShow} no-show, ${c.unrecorded} not recorded'
          '${c.unfilled > 0 ? ', ${c.unfilled} unfilled' : ''}',
          key: Key('outcomes-counts-${d.departmentId}'),
        ),
        const SizedBox(height: 8),
        if (shown.isEmpty)
          _muted(
            context,
            _unrecordedOnly
                ? 'Every outcome in these dates is recorded.'
                : 'No started duties in these dates.',
          ),
        for (final p in shown) ...[
          _OutcomeCard(
            key: Key('outcomes-card-${p.slotId}'),
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

enum _OutcomeForm { none, record, correct }

class _OutcomeCard extends ConsumerStatefulWidget {
  const _OutcomeCard({
    super.key,
    required this.position,
    required this.busy,
    required this.fieldErrors,
    required this.lastAction,
  });

  final OutcomePosition position;
  final bool busy;
  final Map<String, String> fieldErrors;
  final DutyAction? lastAction;

  @override
  ConsumerState<_OutcomeCard> createState() => _OutcomeCardState();
}

class _OutcomeCardState extends ConsumerState<_OutcomeCard> {
  var _form = _OutcomeForm.none;
  DutyOutcome? _choice;
  final _note = TextEditingController();
  final _reason = TextEditingController();
  String? _sent;

  @override
  void dispose() {
    _note.dispose();
    _reason.dispose();
    super.dispose();
  }

  OutcomePosition get p => widget.position;

  void _open(_OutcomeForm f) => setState(() {
    _form = _form == f ? _OutcomeForm.none : f;
    final o = p.assignment?.outcome;
    _choice = f == _OutcomeForm.correct ? o?.outcome : null;
    _note.text = f == _OutcomeForm.correct ? (o?.note ?? '') : '';
    _reason.clear();
  });

  Future<void> _save() async {
    final choice = _choice;
    if (choice == null) return;
    final correction = _form == _OutcomeForm.correct;
    final draft = OutcomeDraft(
      outcome: choice,
      note: _note.text,
      reason: correction ? _reason.text : null,
    );
    final ctl = ref.read(dutyOutcomesProvider.notifier);
    await (correction ? ctl.correct(p, draft) : ctl.record(p, draft));
    final s = ref.read(dutyOutcomesProvider);
    if (!mounted) return;
    _sent = s.noticeAction?.request.requestId;
    if (s.notice == DutyNotice.outcomeRecorded ||
        s.notice == DutyNotice.outcomeCorrected) {
      setState(() {
        _form = _OutcomeForm.none;
        _note.clear();
        _reason.clear();
        _choice = null;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final a = p.assignment;
    final busy = widget.busy;
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
    ];
    if (a == null) {
      lines.add(_muted(context, 'Nobody held this position.'));
      return _Card(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: lines,
        ),
      );
    }
    final mine = widget.lastAction?.request.requestId == _sent && _sent != null;
    final errors = mine ? widget.fieldErrors : const <String, String>{};
    lines.addAll([
      const SizedBox(height: 4),
      Text(
        a.own ? '${a.name} (you)' : a.name,
        key: Key('outcomes-who-${p.slotId}'),
      ),
      Wrap(
        spacing: 8,
        runSpacing: 4,
        children: [
          // The response is shown apart from the outcome.
          StatusLabel(
            key: Key('outcomes-response-${p.slotId}'),
            label: 'Answer: ${a.responseLabel}',
            tone: a.response == DutyResponse.accepted
                ? StatusTone.success
                : StatusTone.neutral,
          ),
          if (a.state == OutcomeState.unrecorded)
            StatusLabel(
              key: Key('outcomes-state-${p.slotId}'),
              label: 'Not recorded',
              tone: StatusTone.neutral,
            ),
        ],
      ),
      if (a.outcome case final o?)
        _OutcomeLines(record: o, keyPrefix: 'outcomes-outcome-${p.slotId}'),
    ]);
    if (a.own) {
      lines.add(
        _muted(
          context,
          'This is your own duty: another leader or deputy of the department '
          'records its outcome.',
        ),
      );
    }
    final actions = <Widget>[
      if (!a.own && a.outcome == null)
        OutlinedButton(
          key: Key('outcomes-record-${p.slotId}'),
          onPressed: busy ? null : () => _open(_OutcomeForm.record),
          child: const Text('Record outcome'),
        ),
      if (!a.own && a.outcome != null)
        OutlinedButton(
          key: Key('outcomes-correct-${p.slotId}'),
          onPressed: busy ? null : () => _open(_OutcomeForm.correct),
          child: const Text('Correct outcome'),
        ),
      TextButton(
        key: Key('outcomes-history-${p.slotId}'),
        onPressed: () => context.go(
          a.own ? DutyPaths.history : DutyPaths.memberHistory(a.memberId),
        ),
        child: Text(a.own ? 'My history' : 'History of ${a.name}'),
      ),
    ];
    lines.addAll([
      const SizedBox(height: 8),
      Wrap(spacing: 8, runSpacing: 8, children: actions),
    ]);
    if (_form != _OutcomeForm.none && !a.own) {
      lines.addAll([const SizedBox(height: 8), _formFor(context, a, errors)]);
    }
    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: lines,
      ),
    );
  }

  Widget _formFor(
    BuildContext context,
    OutcomeAssignment a,
    Map<String, String> errors,
  ) {
    final busy = widget.busy;
    final correction = _form == _OutcomeForm.correct;
    final reasonOk = !correction || _reason.text.trim().isNotEmpty;
    return Column(
      key: Key('outcomes-form-${p.slotId}'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _muted(
          context,
          correction
              ? 'The earlier value, who recorded it and when stay in the '
                    'history. Give a short reason for the correction.'
              : 'Only what happened. ${a.allowed.contains(DutyOutcome.noShow) ? '' : 'No-show is only for a duty they accepted. '}'
                    'Seen by ${a.name} and this department\'s leaders and '
                    'deputies.',
        ),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final o in a.allowed)
              ChoiceChip(
                key: Key('outcomes-choice-${p.slotId}-${o.wire}'),
                label: Text(o.label),
                selected: _choice == o,
                onSelected: busy ? null : (_) => setState(() => _choice = o),
              ),
          ],
        ),
        TextField(
          key: Key('outcomes-note-${p.slotId}'),
          controller: _note,
          enabled: !busy,
          maxLength: OutcomeDraft.noteMax,
          decoration: InputDecoration(
            labelText: 'Short note (optional)',
            errorText: errors['note'] == null ? null : 'Keep it short',
          ),
        ),
        if (correction)
          TextField(
            key: Key('outcomes-reason-${p.slotId}'),
            controller: _reason,
            enabled: !busy,
            maxLength: OutcomeDraft.reasonMax,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              labelText: 'Reason for the correction (required)',
              errorText: errors['reason'] == null
                  ? null
                  : 'Give a short reason',
            ),
          ),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: FilledButton(
            key: Key('outcomes-save-${p.slotId}'),
            onPressed: busy || _choice == null || !reasonOk ? null : _save,
            child: Text(correction ? 'Save correction' : 'Save outcome'),
          ),
        ),
      ],
    );
  }
}

/// Story 4.10: `/duties/history` (the reader's own) and
/// `/duties/history?member=<id>` (a member of a department the reader
/// leads or deputises).
class DutyHistoryScreen extends ConsumerStatefulWidget {
  const DutyHistoryScreen({super.key, this.memberId});

  final String? memberId;

  @override
  ConsumerState<DutyHistoryScreen> createState() => _DutyHistoryScreenState();
}

class _DutyHistoryScreenState extends ConsumerState<DutyHistoryScreen> {
  @override
  Widget build(BuildContext context) {
    final q = ref.watch(memberHistoryQueryProvider);
    if (q.memberId != widget.memberId) {
      // Never show another member's page while this one is opened.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          ref.read(memberHistoryProvider.notifier).open(widget.memberId);
        }
      });
      return const Center(
        key: Key('history-opening'),
        child: CircularProgressIndicator(),
      );
    }
    return _DutiesPage<MemberHistory>(
      title: widget.memberId == null ? 'My duty history' : 'Duty history',
      provider: memberHistoryProvider,
      needs:
          'A member\'s duty history is for the member and their department\'s '
          'leaders and deputies.',
      loading: 'Loading the duty history…',
      body: (context, v, s) => _HistoryBody(value: v, state: s),
    );
  }
}

class _HistoryBody extends ConsumerWidget {
  const _HistoryBody({required this.value, required this.state});
  final MemberHistory value;
  final DutiesState<MemberHistory> state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final v = value;
    final sum = v.summary;
    final q = ref.watch(memberHistoryQueryProvider);
    final ctl = ref.read(memberHistoryProvider.notifier);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _heading(
          context,
          v.self ? 'Your duties' : (v.displayName ?? 'A member'),
          key: const Key('history-who'),
        ),
        _muted(context, _historyPrivacy),
        if (!v.self && v.departmentNames.isNotEmpty)
          _muted(
            context,
            'Departments you lead: ${v.departmentNames.join(', ')}.',
          ),
        const SizedBox(height: 8),
        Text(
          'Last 12 months: ${sum.held} duties served or due '
          '(${sum.accepted} accepted, ${sum.confirmedByLeader} confirmed by '
          'leader, ${sum.declined} declined, ${sum.unanswered} never '
          'answered). Outcomes: ${sum.completed} completed, ${sum.excused} '
          'excused, ${sum.noShow} no-show, ${sum.unrecorded} not recorded. '
          '${sum.ended} reassigned or cancelled.',
          key: const Key('history-summary'),
        ),
        Text('${v.upcoming} upcoming.', key: const Key('history-upcoming')),
        const SizedBox(height: ChurchGeometry.sectionGap),
        if (v.entries.isEmpty)
          _muted(context, 'No duties yet.')
        else
          for (final e in v.entries) ...[
            _Card(
              key: Key('history-entry-${e.assignmentId}'),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    e.title,
                    style: ChurchType.cardTitle.copyWith(
                      color: ChurchColors.of(context).ink,
                    ),
                  ),
                  Text('${e.departmentName}. ${_timesText(context, e.times)}'),
                  Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    children: [
                      StatusLabel(
                        key: Key('history-state-${e.assignmentId}'),
                        label: e.stateLabel,
                        tone: StatusTone.neutral,
                      ),
                      if (e.outcome == null &&
                          e.outcomeState != OutcomeState.none)
                        StatusLabel(
                          key: Key('history-outcome-${e.assignmentId}'),
                          label: e.outcomeState.label,
                          tone: _outcomeTone(e.outcomeState),
                        ),
                    ],
                  ),
                  if (e.outcome case final o?)
                    _OutcomeLines(
                      record: o,
                      keyPrefix: 'history-outcome-${e.assignmentId}',
                    ),
                ],
              ),
            ),
            const SizedBox(height: 8),
          ],
        Wrap(
          spacing: 8,
          children: [
            if (q.pages.isNotEmpty)
              OutlinedButton(
                key: const Key('history-newer'),
                onPressed: state.busy ? null : ctl.newer,
                child: const Text('Newer'),
              ),
            if (v.next case final c?)
              OutlinedButton(
                key: const Key('history-older'),
                onPressed: state.busy ? null : () => ctl.older(c),
                child: const Text('Older'),
              ),
          ],
        ),
      ],
    );
  }
}

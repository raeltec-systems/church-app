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

/// Why a cell part has no result (the 5.8 meeting record is not a duty
/// outcome).
const _historyCellNote =
    'Leaders record outcomes for department duties. Cell programme parts '
    'show how they were answered.';

/// Special assignments: who else sees them and records their outcome.
const _historySpecialNote =
    'Special assignments are given by the Pastors, who see them and record '
    'their outcome.';

StatusTone _outcomeTone(OutcomeState s) => switch (s) {
  OutcomeState.completed => StatusTone.success,
  OutcomeState.excused => StatusTone.info,
  OutcomeState.noShow => StatusTone.warning,
  OutcomeState.unrecorded => StatusTone.neutral,
  OutcomeState.upcoming => StatusTone.info,
  OutcomeState.none => StatusTone.neutral,
  OutcomeState.notTracked => StatusTone.neutral,
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
    subtitle: 'What happened at duties that have started',
    provider: dutyOutcomesProvider,
    needs: _outcomesNeeds,
    loading: 'Loading outcomes…',
    body: (context, value, state) => _OutcomesBody(value: value, state: state),
  );
}

const _outWeekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
const _outMonths = [
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

/// "Sun 11 Oct, 08:30" in church time (the handoff's day before month).
String _outDayTime(DateTime at) {
  final w = ChurchTime.wall(at);
  return '${_outWeekdays[w.weekday - 1]} ${w.day} ${_outMonths[w.month - 1]}, '
      '${ChurchTime.timeText(at)}';
}

/// "1 Oct 2026" for a `YYYY-MM-DD` window end (as typed when unreadable).
String _outDate(String ymd) {
  final d = DateTime.tryParse(ymd);
  return d == null ? ymd : '${d.day} ${_outMonths[d.month - 1]} ${d.year}';
}

/// The table's columns on a wide screen: the position, who held it, their
/// answer (kept apart from the outcome), the outcome as the row's one
/// status mark, and the record action on the row's right edge.
const _outColumns = [
  StaffColumn('Position', flex: 3),
  StaffColumn('Member', flex: 3),
  StaffColumn('Answer', flex: 2),
  StaffColumn('Outcome', flex: 2),
  StaffColumn('', width: 176, numeric: true),
];

/// Below this width each position is a two-line row instead.
const _outWide = 860.0;

/// A compact button for a table row (36 px, 14 px label; with its focus
/// ring's room it keeps a 44 px target).
ButtonStyle _outRowButton(ButtonStyle? base) =>
    (base ?? const ButtonStyle()).copyWith(
      minimumSize: const WidgetStatePropertyAll(Size(0, 36)),
      padding: const WidgetStatePropertyAll(
        EdgeInsets.symmetric(horizontal: 14),
      ),
      textStyle: const WidgetStatePropertyAll(
        TextStyle(
          fontFamily: ChurchFonts.body,
          fontSize: 14,
          fontWeight: FontWeight.w600,
        ),
      ),
    );

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
    // Review S2: outcomes are about past duties; the window never passes today.
    final future = valid && from.isNotEmpty && OutcomesQuery.afterToday(from);
    setState(
      () => _fromError = !valid
          ? 'Use YYYY-MM-DD'
          : future
          ? 'Must not be after today'
          : null,
    );
    if (!valid || future) return;
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
    final c = ChurchColors.of(context);
    final v = widget.value;
    final busy = widget.state.busy;
    // The server's counts cover every position, also beyond a truncated list.
    var toRecord = 0, positions = 0;
    for (final d in v.departments) {
      toRecord += d.counts.unrecorded;
      positions += d.counts.positions;
    }
    // The pills count the rows in view.
    final listed = [for (final d in v.departments) ...d.positions];
    final listedUnrecorded = listed
        .where((p) => p.assignment?.state == OutcomeState.unrecorded)
        .length;
    final headline = positions == 0
        ? 'No duties have started in these dates'
        : toRecord == 0
        ? 'Every outcome in these dates is recorded'
        : '$toRecord ${toRecord == 1 ? 'position needs' : 'positions need'} '
              'an outcome';
    final children = <Widget>[
      // The screen's question first: how many outcomes are still to record.
      Semantics(
        header: true,
        child: Text(
          headline,
          key: const Key('outcomes-finding'),
          style: ChurchType.sectionTitle.copyWith(color: c.ink),
        ),
      ),
      const SizedBox(height: 4),
      _muted(
        context,
        '${positions == 1 ? '1 position' : '$positions positions'} at duties '
        'that started from ${_outDate(v.from)} to ${_outDate(v.to)} (church '
        'time)${v.duty == null ? '' : ', duty matching "${v.duty}"'}. An '
        'outcome is only what a leader records: a duty nobody recorded stays '
        '"Not recorded".',
      ),
      const SizedBox(height: 16),
      // The scope: the dates first, then the narrowing filters.
      Wrap(
        spacing: 12,
        runSpacing: 12,
        crossAxisAlignment: WrapCrossAlignment.center,
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
          SizedBox(
            width: 120,
            child: DropdownButtonFormField<int>(
              key: const Key('outcomes-days'),
              initialValue: _days,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'For'),
              items: [
                for (final d in const [7, 14, 31])
                  DropdownMenuItem(
                    value: d,
                    child: Text('$d days', overflow: TextOverflow.ellipsis),
                  ),
              ],
              onChanged: (d) => setState(() => _days = d ?? 14),
            ),
          ),
          SizedBox(
            width: 220,
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
            SizedBox(
              width: 240,
              child: DropdownButtonFormField<String?>(
                key: const Key('outcomes-department'),
                initialValue: _department,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Department'),
                items: [
                  const DropdownMenuItem<String?>(
                    value: null,
                    child: Text('All my departments'),
                  ),
                  for (final d in v.departments)
                    DropdownMenuItem<String?>(
                      value: d.departmentId,
                      child: Text(d.name, overflow: TextOverflow.ellipsis),
                    ),
                ],
                onChanged: (d) => setState(() => _department = d),
              ),
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
      const SizedBox(height: 12),
      StaffFilterPills<bool>(
        label: 'Show',
        selected: _unrecordedOnly,
        onChanged: (s) => setState(() => _unrecordedOnly = s),
        options: [
          StaffFilterOption(
            false,
            'All',
            count: listed.length,
            key: const Key('outcomes-filter-all'),
          ),
          StaffFilterOption(
            true,
            'Not recorded',
            count: listedUnrecorded,
            key: const Key('outcomes-unrecorded-only'),
          ),
        ],
      ),
      if (v.truncated) ...[
        const SizedBox(height: 12),
        const RequestStateBanner(
          key: Key('outcomes-truncated'),
          tone: StatusTone.warning,
          title: 'Showing the latest 1000 positions',
          message:
              'The counts cover every position; choose fewer days or one '
              'department to list the rest.',
        ),
      ],
    ];
    if (v.departments.isEmpty) {
      children.addAll([
        const SizedBox(height: ChurchGeometry.sectionGap),
        _muted(context, 'No departments to show.'),
      ]);
    }
    for (final d in v.departments) {
      children.addAll([
        const SizedBox(height: ChurchGeometry.sectionGap),
        _OutDepartment(
          department: d,
          unrecordedOnly: _unrecordedOnly,
          state: widget.state,
        ),
      ]);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    );
  }
}

/// One department: its name and totals over a table of its started
/// positions, grouped under each duty (its name, day and place once).
class _OutDepartment extends StatelessWidget {
  const _OutDepartment({
    required this.department,
    required this.unrecordedOnly,
    required this.state,
  });

  final OutcomeDepartment department;
  final bool unrecordedOnly;
  final DutiesState<DutyOutcomes> state;

  @override
  Widget build(BuildContext context) {
    final c = ChurchColors.of(context);
    final d = department;
    final k = d.counts;
    final shown = d.positions
        .where(
          (p) =>
              !unrecordedOnly || p.assignment?.state == OutcomeState.unrecorded,
        )
        .toList();
    // Positions of one duty arrive together: group them under the duty.
    final groups = <List<OutcomePosition>>[];
    for (final p in shown) {
      if (groups.isNotEmpty &&
          groups.last.first.occurrenceId == p.occurrenceId) {
        groups.last.add(p);
      } else {
        groups.add([p]);
      }
    }
    final counts = [
      '${k.unrecorded} not recorded',
      '${k.completed} completed',
      '${k.excused} excused',
      '${k.noShow} no-show',
      if (k.unfilled > 0) '${k.unfilled} unfilled',
      k.positions == 1 ? '1 position' : '${k.positions} positions',
    ];
    final countStyle = ChurchType.secondary.copyWith(
      color: c.muted,
      fontSize: 13,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    return LayoutBuilder(
      builder: (context, box) {
        final wide = box.maxWidth >= _outWide;
        final rows = <Widget>[];
        for (final (gi, g) in groups.indexed) {
          final first = g.first;
          rows.add(
            Container(
              padding: EdgeInsets.fromLTRB(20, gi == 0 ? 14 : 16, 20, 4),
              decoration: BoxDecoration(
                border: gi == 0 ? null : Border(top: BorderSide(color: c.line)),
              ),
              child: Wrap(
                spacing: 10,
                runSpacing: 2,
                crossAxisAlignment: WrapCrossAlignment.end,
                children: [
                  Text(
                    first.dutyName,
                    style: ChurchType.staffBody.copyWith(
                      color: c.ink,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    [
                      _outDayTime(first.times.startsAt),
                      ?first.location,
                    ].join(' · '),
                    style: ChurchType.secondary.copyWith(
                      color: c.muted,
                      fontSize: 13,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ),
            ),
          );
          for (final (i, p) in g.indexed) {
            rows.add(
              _OutRow(
                key: Key('outcomes-card-${p.slotId}'),
                position: p,
                wide: wide,
                divider: i > 0,
                busy: state.busy,
                fieldErrors: state.fieldErrors,
                lastAction: state.noticeAction,
              ),
            );
          }
        }
        return StaffTableFrame(
          children: [
            Container(
              padding: const EdgeInsets.fromLTRB(20, 14, 20, 12),
              decoration: BoxDecoration(
                border: Border(bottom: BorderSide(color: c.line)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Semantics(
                    header: true,
                    child: Text(
                      d.name,
                      key: Key('outcomes-dept-${d.departmentId}'),
                      style: ChurchType.cardTitle.copyWith(
                        color: c.ink,
                        fontSize: 17,
                      ),
                    ),
                  ),
                  const SizedBox(height: 2),
                  // Each figure stays whole on a narrow screen; its separator
                  // travels with the next one.
                  Semantics(
                    label: counts.join(', '),
                    excludeSemantics: true,
                    child: Wrap(
                      key: Key('outcomes-counts-${d.departmentId}'),
                      children: [
                        for (final (i, t) in counts.indexed)
                          Text(i == 0 ? t : ' · $t', style: countStyle),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            if (wide && shown.isNotEmpty)
              const StaffTableHeader(columns: _outColumns),
            if (shown.isEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 18),
                child: _muted(
                  context,
                  unrecordedOnly
                      ? 'Every outcome in these dates is recorded.'
                      : 'No started duties in these dates.',
                ),
              ),
            ...rows,
            if (shown.isNotEmpty) const SizedBox(height: 6),
          ],
        );
      },
    );
  }
}

enum _OutcomeForm { none, record, correct }

/// One started position: who held it, their answer, the outcome as the
/// row's one status mark and the action that records or corrects it; the
/// record's trail (who, when, the note, every earlier value) under it, and
/// the record form opening in place.
class _OutRow extends ConsumerStatefulWidget {
  const _OutRow({
    super.key,
    required this.position,
    required this.wide,
    required this.divider,
    required this.busy,
    required this.fieldErrors,
    required this.lastAction,
  });

  final OutcomePosition position;
  final bool wide;
  final bool divider;
  final bool busy;
  final Map<String, String> fieldErrors;
  final DutyAction? lastAction;

  @override
  ConsumerState<_OutRow> createState() => _OutRowState();
}

class _OutRowState extends ConsumerState<_OutRow> {
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
    final c = ChurchColors.of(context);
    final a = p.assignment;
    final busy = widget.busy;
    final small = ChurchType.secondary.copyWith(color: c.muted, fontSize: 13);
    final positionName = p.positionName ?? 'Position ${p.positionNo}';
    // Review N2: nothing is recorded about an erased member.
    final actionable = a != null && !a.own && !a.erased;

    final Widget who;
    if (a == null) {
      who = Text(
        'Nobody held it',
        style: ChurchType.staffBody.copyWith(color: c.muted),
      );
    } else if (a.erased) {
      who = Text(
        a.name,
        key: Key('outcomes-who-${p.slotId}'),
        style: ChurchType.staffBody.copyWith(color: c.muted),
      );
    } else {
      // The member's name opens their history (the link colour on the
      // name cell only).
      final label = a.own ? 'My history' : 'History of ${a.name}';
      // Shifted by the focus ring's room, so the name starts on the column's
      // edge like the header above it.
      who = Transform.translate(
        offset: const Offset(-(ChurchGeometry.focusRingWidth + 1), 0),
        child: FocusRing(
          radius: 6,
          child: Semantics(
            link: true,
            label: label,
            excludeSemantics: true,
            child: Tooltip(
              message: label,
              excludeFromSemantics: true,
              child: InkWell(
                key: Key('outcomes-history-${p.slotId}'),
                borderRadius: BorderRadius.circular(6),
                onTap: () => context.go(
                  a.own
                      ? DutyPaths.history
                      : DutyPaths.memberHistory(a.memberId),
                ),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 32),
                  child: Align(
                    alignment: AlignmentDirectional.centerStart,
                    widthFactor: 1,
                    child: Text(
                      a.own ? '${a.name} (you)' : a.name,
                      key: Key('outcomes-who-${p.slotId}'),
                      style: ChurchType.staffBody.copyWith(
                        color: c.link,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }

    final Widget mark;
    if (a == null) {
      mark = Text('—', style: ChurchType.staffBody.copyWith(color: c.muted));
    } else if (a.outcome case final o?) {
      mark = StatusLabel(
        key: Key('outcomes-outcome-${p.slotId}-label'),
        label: o.outcome.label,
        tone: _outcomeTone(_stateOf(o.outcome)),
      );
    } else if (a.state == OutcomeState.unrecorded) {
      mark = StatusLabel(
        key: Key('outcomes-state-${p.slotId}'),
        label: 'Not recorded',
        tone: StatusTone.neutral,
      );
    } else {
      mark = Text(a.state.label, style: small);
    }

    final Widget? action = !actionable
        ? null
        : a.outcome == null
        ? OutlinedButton(
            key: Key('outcomes-record-${p.slotId}'),
            style: _outRowButton(null),
            onPressed: busy ? null : () => _open(_OutcomeForm.record),
            child: const Text('Record outcome'),
          )
        : TextButton(
            key: Key('outcomes-correct-${p.slotId}'),
            style: _outRowButton(null),
            onPressed: busy ? null : () => _open(_OutcomeForm.correct),
            child: const Text('Correct outcome'),
          );

    // The evidence under the row: who recorded it and when, the note and
    // every earlier value; or why there is nothing to do.
    final notes = <Widget>[
      if (a?.outcome case final o?) ..._trail(context, o),
      if (a != null && a.own)
        Text(
          'Your own duty: another leader or deputy of the department records '
          'its outcome.',
          style: small,
        ),
      if (a != null && a.erased)
        Text(
          'This member\'s record was removed: no outcome is recorded.',
          style: small,
        ),
    ];
    final mine = widget.lastAction?.request.requestId == _sent && _sent != null;
    final errors = mine ? widget.fieldErrors : const <String, String>{};
    final form = _form != _OutcomeForm.none && actionable
        ? _formFor(context, a, errors)
        : null;

    final Widget line;
    if (widget.wide) {
      line = StaffColumnsRow(
        columns: _outColumns,
        cells: [
          Text(
            positionName,
            style: ChurchType.staffBody.copyWith(
              color: c.ink,
              fontWeight: FontWeight.w500,
            ),
          ),
          who,
          a == null
              ? Text('—', style: ChurchType.staffBody.copyWith(color: c.muted))
              : Text(
                  a.responseLabel,
                  key: Key('outcomes-response-${p.slotId}'),
                  style: ChurchType.secondary.copyWith(color: c.muted),
                ),
          mark,
          action == null ? const SizedBox.shrink() : FocusRing(child: action),
        ],
      );
    } else {
      line = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: who),
              const SizedBox(width: 8),
              mark,
            ],
          ),
          Row(
            children: [
              Expanded(
                child: Wrap(
                  spacing: 6,
                  children: [
                    Text(positionName, style: small),
                    if (a != null) ...[
                      Text('·', style: small),
                      Text(
                        'Answer: ${a.responseLabel}',
                        key: Key('outcomes-response-${p.slotId}'),
                        style: small,
                      ),
                    ],
                  ],
                ),
              ),
              // The one action, at the row's right edge.
              if (action != null) ...[
                const SizedBox(width: 8),
                FocusRing(child: action),
              ],
            ],
          ),
        ],
      );
    }
    return Container(
      decoration: BoxDecoration(
        color: form == null ? null : c.bg,
        border: widget.divider ? Border(top: BorderSide(color: c.line)) : null,
      ),
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 6),
      // Every row at one pitch, whether or not it carries an action.
      constraints: const BoxConstraints(minHeight: 66),
      alignment: AlignmentDirectional.centerStart,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          line,
          if (notes.isNotEmpty) ...[const SizedBox(height: 4), ...notes],
          if (form != null) ...[const SizedBox(height: 12), form],
        ],
      ),
    );
  }

  /// The recorded outcome's trail, newest first: who recorded it and when
  /// (and why, when corrected), its note, then every earlier value.
  List<Widget> _trail(BuildContext context, DutyOutcomeRecord o) {
    final small = ChurchType.secondary.copyWith(
      color: ChurchColors.of(context).muted,
      fontSize: 13,
    );
    final current = o.trail.where((t) => t.revision == o.revision).firstOrNull;
    final by = o.recordedBy == null ? '' : ' by ${o.recordedBy}';
    return [
      Text(
        '${o.corrected ? 'Corrected' : 'Recorded'}$by, '
        '${_outDayTime(o.recordedAt)}'
        '${current?.reason == null ? '' : '. Reason: "${current!.reason}"'}',
        style: small,
      ),
      if (o.note case final n?)
        Text(
          'Note: "$n"',
          key: Key('outcomes-outcome-${p.slotId}-note'),
          style: small,
        ),
      for (final t in o.earlier)
        Text(
          'Earlier: ${t.outcome.label}'
          '${t.note == null ? '' : ' ("${t.note}")'}, recorded'
          '${t.by == null ? '' : ' by ${t.by}'}, ${_outDayTime(t.at)}'
          '${t.reason == null ? '' : '. Reason: "${t.reason}"'}',
          style: small,
        ),
    ];
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
        const SizedBox(height: 8),
        StaffFilterPills<DutyOutcome?>(
          label: 'What happened',
          selected: _choice,
          onChanged: busy ? null : (o) => setState(() => _choice = o),
          options: [
            for (final o in a.allowed)
              StaffFilterOption<DutyOutcome?>(
                o,
                o.label,
                key: Key('outcomes-choice-${p.slotId}-${o.wire}'),
              ),
          ],
        ),
        const SizedBox(height: 8),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
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
              ],
            ),
          ),
        ),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: FocusRing(
            child: FilledButton(
              key: Key('outcomes-save-${p.slotId}'),
              onPressed: busy || _choice == null || !reasonOk ? null : _save,
              child: Text(correction ? 'Save correction' : 'Save outcome'),
            ),
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
    final c = ChurchColors.of(context);
    final v = value;
    final sum = v.summary;
    final q = ref.watch(memberHistoryQueryProvider);
    final ctl = ref.read(memberHistoryProvider.notifier);
    final nothing = sum.held == 0 && v.entries.isEmpty && q.pages.isEmpty;
    final muted = ChurchType.secondary.copyWith(color: c.muted);
    // The filter is offered only when the reader has more than one kind to
    // choose from (a leader reading a member never sees cell parts or
    // special assignments); each kind is offered while it has positions.
    final several = v.kindsPresent > 1;
    final what = switch (q.kind) {
      DutyOwnerKind.cell => 'cell programme parts',
      DutyOwnerKind.department => 'department duties',
      DutyOwnerKind.special => 'special assignments',
      _ => v.self ? 'duties' : 'duties in your departments',
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // A leader reading a member's history: whose it is, and through
        // which departments.
        if (!v.self) ...[
          _heading(
            context,
            v.displayName ?? 'A member',
            key: const Key('history-who'),
          ),
          if (v.departmentNames.isNotEmpty)
            Text(
              'Departments you lead: ${v.departmentNames.join(', ')}.',
              style: muted,
            ),
          const SizedBox(height: 16),
        ],
        if (several || q.kind != null) ...[
          RadioSegments<DutyOwnerKind?>(
            key: const Key('history-kinds'),
            label: 'Show',
            options: [
              SegmentOption(null, 'All (${v.allCount})'),
              if (v.departmentCount > 0 || q.kind == DutyOwnerKind.department)
                SegmentOption(
                  DutyOwnerKind.department,
                  'Departments (${v.departmentCount})',
                ),
              if (v.cellCount > 0 || q.kind == DutyOwnerKind.cell)
                SegmentOption(DutyOwnerKind.cell, 'Cell (${v.cellCount})'),
              if (v.specialCount > 0 || q.kind == DutyOwnerKind.special)
                SegmentOption(
                  DutyOwnerKind.special,
                  'Special (${v.specialCount})',
                ),
            ],
            selected: q.kind,
            onChanged: state.busy ? null : ctl.filter,
          ),
          const SizedBox(height: 16),
        ],
        if (nothing)
          _Card(
            key: const Key('history-summary'),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'No $what in the last 12 months',
                  style: ChurchType.itemTitle.copyWith(color: c.ink),
                ),
                const SizedBox(height: 4),
                Text(
                  v.upcoming == 0
                      ? 'Duties show here once their date has passed, with '
                            'how ${v.self ? 'you' : 'they'} answered and what '
                            'the leader recorded.'
                      : '${v.upcoming} upcoming. They show here once their '
                            'date has passed.',
                  key: const Key('history-upcoming'),
                  style: muted,
                ),
              ],
            ),
          )
        else
          _HistorySummaryCard(
            summary: sum,
            upcoming: v.upcoming,
            // Cell parts keep no outcome: no outcome figures for them alone.
            outcomes: q.kind != DutyOwnerKind.cell,
            // Special assignments: their outcome is the Pastors'.
            recordedBy: switch (q.kind) {
              DutyOwnerKind.special => 'What the Pastors recorded',
              DutyOwnerKind.department => 'What the leaders recorded',
              _ when v.specialCount > 0 => 'What was recorded',
              _ => 'What the leaders recorded',
            },
          ),
        if (v.entries.isNotEmpty) ...[
          const SizedBox(height: 16),
          ChurchCard(
            padding: EdgeInsets.zero,
            radius: identical(ChurchLayout.of(context), ChurchLayout.staff)
                ? 12
                : ChurchGeometry.mobileCardRadius,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final (i, e) in v.entries.indexed) ...[
                  if (i > 0) Divider(height: 1, indent: 78, color: c.line),
                  _HistoryRow(entry: e),
                ],
              ],
            ),
          ),
        ],
        if (q.pages.isNotEmpty || v.next != null) ...[
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: [
              // Review N6: keyboard focus is visible on the paging buttons.
              if (q.pages.isNotEmpty)
                FocusRing(
                  child: TextButton.icon(
                    key: const Key('history-newer'),
                    onPressed: state.busy ? null : ctl.newer,
                    icon: const Icon(Icons.arrow_upward, size: 18),
                    label: const Text('Newer duties'),
                  ),
                ),
              if (v.next case final cursor?)
                FocusRing(
                  child: TextButton.icon(
                    key: const Key('history-older'),
                    onPressed: state.busy ? null : () => ctl.older(cursor),
                    icon: const Icon(Icons.arrow_downward, size: 18),
                    label: const Text('Older duties'),
                  ),
                ),
            ],
          ),
        ],
        const SizedBox(height: 20),
        Text(_historyPrivacy, style: muted),
        if (v.cellCount > 0) ...[
          const SizedBox(height: 4),
          Text(_historyCellNote, style: muted),
        ],
        if (v.specialCount > 0) ...[
          const SizedBox(height: 4),
          Text(_historySpecialNote, style: muted),
        ],
      ],
    );
  }
}

/// The last 12 months as figures: three that answer "how have I done"
/// (assigned, completed or, for cell parts, accepted, and upcoming), then how
/// the member answered and what leaders recorded, a zero in grey.
class _HistorySummaryCard extends StatelessWidget {
  const _HistorySummaryCard({
    required this.summary,
    required this.upcoming,
    this.outcomes = true,
    this.recordedBy = 'What the leaders recorded',
  });
  final HistorySummary summary;
  final int upcoming;

  /// False for cell parts alone: they keep no outcome to count.
  final bool outcomes;

  /// The outcome figures' label (special assignments: the Pastors record).
  final String recordedBy;

  @override
  Widget build(BuildContext context) {
    final c = ChurchColors.of(context);
    final sum = summary;
    Widget figure(String label, int n, {Key? key}) => Expanded(
      child: Semantics(
        label: '$label: $n',
        excludeSemantics: true,
        child: Column(
          key: key,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '$n',
              style: ChurchType.mobileScreenTitle.copyWith(
                color: c.ink,
                fontWeight: FontWeight.w600,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
            const SizedBox(height: 2),
            Text(label, style: ChurchType.secondary.copyWith(color: c.muted)),
          ],
        ),
      ),
    );
    Widget divider() => Container(
      width: 1,
      height: 44,
      margin: const EdgeInsets.symmetric(horizontal: 14),
      color: c.line,
    );
    Widget row(String label, int n) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: ChurchType.secondary.copyWith(color: c.ink),
            ),
          ),
          Text(
            '$n',
            style: ChurchType.figures.copyWith(color: n == 0 ? c.muted : c.ink),
          ),
        ],
      ),
    );
    return _Card(
      key: const Key('history-summary'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const CardLabel('Last 12 months'),
          const SizedBox(height: 12),
          Row(
            children: [
              figure('Assigned', sum.held),
              divider(),
              outcomes
                  ? figure('Completed', sum.completed)
                  : figure('Accepted', sum.accepted + sum.confirmedByLeader),
              divider(),
              figure('Upcoming', upcoming, key: const Key('history-upcoming')),
            ],
          ),
          const SizedBox(height: 16),
          Divider(height: 1, color: c.line),
          const SizedBox(height: 12),
          const CardLabel('How the duties were answered'),
          const SizedBox(height: 4),
          row('Accepted', sum.accepted),
          row('Confirmed by a leader', sum.confirmedByLeader),
          row('Can\'t make it', sum.declined),
          row('Never answered', sum.unanswered),
          if (outcomes) ...[
            const SizedBox(height: 12),
            CardLabel(recordedBy),
            const SizedBox(height: 4),
            row('Completed', sum.completed),
            row('Excused', sum.excused),
            row('No-show', sum.noShow),
            row('Not recorded yet', sum.unrecorded),
          ],
          row('Reassigned or cancelled', sum.ended),
        ],
      ),
    );
  }
}

/// One past duty: date, duty, who gave it and the time with the member's
/// answer, and one mark for the result (the recorded outcome, or why there is
/// none). A cell part keeps no outcome, so its mark is the answer.
class _HistoryRow extends StatelessWidget {
  const _HistoryRow({required this.entry});
  final HistoryEntry entry;

  @override
  Widget build(BuildContext context) {
    final c = ChurchColors.of(context);
    final e = entry;
    final id = e.assignmentId;
    final muted = ChurchType.secondary.copyWith(color: c.muted);
    final ended = e.outcomeState == OutcomeState.none;
    final answerOnly = e.outcomeState == OutcomeState.notTracked;
    final answerTone = switch (e.response) {
      _ when e.confirmedByLeader => StatusTone.success,
      DutyResponse.accepted => StatusTone.success,
      DutyResponse.declined => StatusTone.neutral,
      DutyResponse.pending => StatusTone.warning,
    };
    return Padding(
      key: Key('history-entry-$id'),
      padding: const EdgeInsets.all(16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ChurchDateBadge(at: e.times.arriveBy),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  e.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: ChurchType.itemTitle.copyWith(color: c.ink),
                ),
                const SizedBox(height: 2),
                Text(
                  [
                    e.ownerName,
                    // Special assignments: a due date, never a time.
                    if (e.times.dueOn case final d?)
                      DutySpecial.dueText(d)
                    else
                      _clock(context, e.times.reportingAt ?? e.times.startsAt),
                    if (!ended && !answerOnly) e.stateLabel,
                  ].join(' · '),
                  key: ended || answerOnly ? null : Key('history-state-$id'),
                  style: muted,
                ),
                const SizedBox(height: 8),
                if (ended || answerOnly)
                  StatusLabel(
                    key: Key('history-state-$id'),
                    label: e.stateLabel,
                    tone: ended ? StatusTone.neutral : answerTone,
                  )
                else if (e.outcome case final o?)
                  _OutcomeLines(record: o, keyPrefix: 'history-outcome-$id')
                else
                  StatusLabel(
                    key: Key('history-outcome-$id'),
                    label: e.outcomeState.label,
                    tone: _outcomeTone(e.outcomeState),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

part of 'duties_screens.dart';

// Special assignments (owner decision 2026-10-21), staff web: the current
// Pastors give a member a duty that belongs to no department and no cell, at a
// fixed date and time or with a due date ("done by"); change it (a material
// change asks the member again), cancel it, record "Confirmed by the Pastor"
// after a call, and record and correct its outcome once its time or due date
// has passed. The screen answers "which special assignments need me?" first:
// past ones still to record and ones that need someone new, then what is
// coming, then the recorded past. One status mark per row; the details and
// the actions are on the opened row. Every list comes from a server-checked
// read and every action is a server-checked command.

const _specialNeeds = 'Special assignments are given by the Pastors.';

const _specialDeadlineHelp =
    'Leave the answer-by time empty for the church default: 2 weeks before '
    'for one a month or more away, 2 days before for one 3 days to a month '
    'away, otherwise 1 day before (for a due date, counted back from its end). '
    'When that has already passed it is Short notice: they are asked to answer '
    'now, so tell them directly.';

/// `/duties/special` (staff web; the Pastors).
class DutySpecialScreen extends StatelessWidget {
  const DutySpecialScreen({super.key});

  @override
  Widget build(BuildContext context) => _DutiesPage<SpecialAssignments>(
    title: 'Special assignments',
    subtitle: 'Duties the pastors give outside any department',
    provider: dutySpecialProvider,
    needs: _specialNeeds,
    loading: 'Loading special assignments…',
    // The screen's main job, in the page header on staff web.
    headerAction: (context, v, s) => _SpecGiveButton(busy: s.busy),
    body: (context, v, s) => _SpecialBody(value: v, state: s),
  );
}

/// Whether the give form is open: shared by the page header's button and
/// the body, and forgotten when the screen goes.
final _specGivingProvider = NotifierProvider.autoDispose<_SpecGiving, bool>(
  _SpecGiving.new,
);

class _SpecGiving extends Notifier<bool> {
  @override
  bool build() => false;

  void toggle() => state = !state;

  void close() => state = false;
}

/// "Give a special assignment" (or "Close the form" while it is open).
class _SpecGiveButton extends ConsumerWidget {
  const _SpecGiveButton({required this.busy});

  final bool busy;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final giving = ref.watch(_specGivingProvider);
    return FocusRing(
      child: FilledButton.icon(
        key: const Key('special-give'),
        onPressed: busy
            ? null
            : () => ref.read(_specGivingProvider.notifier).toggle(),
        icon: Icon(giving ? Icons.close : Icons.add),
        label: Text(giving ? 'Close the form' : 'Give a special assignment'),
      ),
    );
  }
}

/// "Due 30 Nov" or "Sat 4 Jan, 10:00–12:00" (church time).
String _specialWhen(BuildContext context, SpecialAssignment a) {
  final t = a.times;
  if (t.dueOn case final d?) return DutySpecial.dueText(d);
  final start = _outDayTime(t.startsAt);
  return t.endsAt == null ? start : '$start–${ChurchTime.timeText(t.endsAt!)}';
}

/// "Mon 30 Nov 2099" for a due date (a calendar date, no time).
String _specDate(DateTime d) =>
    '${_outWeekdays[d.weekday - 1]} ${d.day} ${_outMonths[d.month - 1]} '
    '${d.year}';

/// The one mark a row carries: the outcome once recorded, "Not recorded"
/// for a past one still to record, otherwise the member's answer (or that it
/// needs someone).
(String, StatusTone) _specialMark(SpecialAssignment a) {
  final h = a.holder;
  if (h == null) return ('Needs someone', StatusTone.warning);
  if (h.outcome case final o?) {
    return ('Outcome: ${o.outcome.label}', _outcomeTone(_stateOf(o.outcome)));
  }
  if (a.started) {
    return h.allowed.isEmpty
        ? (h.answerLabel, StatusTone.neutral)
        : ('Not recorded', StatusTone.neutral);
  }
  return switch (h.response) {
    _ when h.confirmedByLeader => (h.answerLabel, StatusTone.success),
    DutyResponse.accepted => (h.answerLabel, StatusTone.success),
    DutyResponse.declined => (h.answerLabel, StatusTone.warning),
    DutyResponse.pending => (h.answerLabel, StatusTone.info),
  };
}

/// The table's columns on a wide screen: when (or done by), the duty and its
/// place, who holds it, the row's one mark, the one action a row that needs
/// doing carries, and the chevron that opens the details.
const _specColumns = [
  StaffColumn('When', width: 196),
  StaffColumn('Assignment', flex: 4),
  StaffColumn('Who', flex: 3),
  StaffColumn('Answer or outcome', flex: 3),
  StaffColumn('', width: 150, numeric: true),
  StaffColumn('', width: 24),
];

/// Below this width each assignment is a two-line row with its date badge.
const _specWide = 860.0;

class _SpecialBody extends ConsumerStatefulWidget {
  const _SpecialBody({required this.value, required this.state});
  final SpecialAssignments value;
  final DutiesState<SpecialAssignments> state;

  @override
  ConsumerState<_SpecialBody> createState() => _SpecialBodyState();
}

class _SpecialBodyState extends ConsumerState<_SpecialBody> {
  String? _open;

  @override
  Widget build(BuildContext context) {
    final c = ChurchColors.of(context);
    final v = widget.value;
    final busy = widget.state.busy;
    final giving = ref.watch(_specGivingProvider);
    final needs = [
      for (final a in v.assignments)
        if (a.outcomeDue || a.needsSomeone) a,
    ];
    final upcoming = [
      for (final a in v.assignments)
        if (!a.started && !a.needsSomeone) a,
    ];
    final past = [
      for (final a in v.assignments)
        if (a.started && !a.outcomeDue) a,
    ];
    final toRecord = needs.where((a) => a.outcomeDue).length;
    final someone = needs.length - toRecord;
    // The screen's finding, first: what needs the Pastor now.
    final finding = needs.isEmpty
        ? (upcoming.isEmpty
              ? 'No special assignments are coming up.'
              : '${upcoming.length} coming up; nothing needs you now.')
        : [
            if (toRecord > 0)
              '$toRecord to record (${toRecord == 1 ? 'its' : 'their'} time '
                  'or due date has passed)',
            if (someone > 0)
              '$someone ${someone == 1 ? 'needs' : 'need'} someone new',
          ].join(' · ');

    Widget section(String title, List<SpecialAssignment> rows, String key) =>
        Padding(
          padding: const EdgeInsets.only(top: ChurchGeometry.sectionGap),
          child: LayoutBuilder(
            builder: (context, box) {
              final wide = box.maxWidth >= _specWide;
              return StaffTableFrame(
                children: [
                  Container(
                    padding: const EdgeInsets.fromLTRB(20, 14, 20, 12),
                    decoration: BoxDecoration(
                      border: Border(bottom: BorderSide(color: c.line)),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Semantics(
                            header: true,
                            child: Text(
                              title,
                              key: Key(key),
                              style: ChurchType.cardTitle.copyWith(
                                color: c.ink,
                                fontSize: 17,
                              ),
                            ),
                          ),
                        ),
                        Text(
                          rows.length == 1
                              ? '1 assignment'
                              : '${rows.length} assignments',
                          style: ChurchType.secondary.copyWith(
                            color: c.muted,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (wide) const StaffTableHeader(columns: _specColumns),
                  for (final (i, a) in rows.indexed)
                    _SpecialRow(
                      key: Key('special-row-${a.occurrenceId}'),
                      item: a,
                      members: v.members,
                      wide: wide,
                      divider: i > 0,
                      open: _open == a.occurrenceId,
                      busy: busy,
                      state: widget.state,
                      onToggle: () => setState(
                        () => _open = _open == a.occurrenceId
                            ? null
                            : a.occurrenceId,
                      ),
                    ),
                ],
              );
            },
          ),
        );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          header: true,
          child: Text(
            finding,
            key: const Key('special-finding'),
            style: ChurchType.sectionTitle.copyWith(color: c.ink),
          ),
        ),
        const SizedBox(height: 4),
        _muted(
          context,
          'Seen by the member and the Pastors only. Department and cell '
          'leaders see only that the member is busy at that time.',
        ),
        // On the phone the main job sits under the finding (staff web has
        // it in the page header).
        if (!isStaffLayout(context)) ...[
          const SizedBox(height: 12),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: _SpecGiveButton(busy: busy),
          ),
        ],
        if (giving) ...[
          const SizedBox(height: 16),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 760),
              child: _Card(
                child: _SpecialForm(
                  key: const Key('special-give-form'),
                  members: v.members,
                  membersTruncated: v.membersTruncated,
                  busy: busy,
                  state: widget.state,
                  onSent: () => ref.read(_specGivingProvider.notifier).close(),
                ),
              ),
            ),
          ),
        ],
        if (v.truncated) ...[
          const SizedBox(height: 12),
          const RequestStateBanner(
            key: Key('special-truncated'),
            tone: StatusTone.warning,
            title: 'Showing 500 special assignments',
            message:
                'There are more in the last 90 days and ahead; the soonest '
                'and the most recent are listed.',
          ),
        ],
        if (needs.isNotEmpty) section('Needs you', needs, 'special-needs'),
        if (upcoming.isNotEmpty)
          section('Coming up', upcoming, 'special-upcoming'),
        if (past.isNotEmpty) section('Past 90 days', past, 'special-past'),
        if (v.assignments.isEmpty) ...[
          const SizedBox(height: ChurchGeometry.sectionGap),
          ChurchCard(
            radius: churchCardRadiusOf(context),
            child: _muted(
              context,
              'No special assignments in the last 90 days or ahead. A special '
              'assignment belongs to no department and no cell: a church '
              'project, leading a service, a task from the church leadership.',
            ),
          ),
        ],
      ],
    );
  }
}

/// One special assignment: the row (when, the duty, who, one mark, and the
/// one action a row that needs doing carries), and when opened its details
/// and every action.
class _SpecialRow extends ConsumerStatefulWidget {
  const _SpecialRow({
    super.key,
    required this.item,
    required this.members,
    required this.wide,
    required this.divider,
    required this.open,
    required this.busy,
    required this.state,
    required this.onToggle,
  });

  final SpecialAssignment item;
  final List<DepartmentMember> members;
  final bool wide;
  final bool divider;
  final bool open;
  final bool busy;
  final DutiesState<SpecialAssignments> state;
  final VoidCallback onToggle;

  @override
  ConsumerState<_SpecialRow> createState() => _SpecialRowState();
}

enum _SpecialForms { none, change, confirm, record, correct }

class _SpecialRowState extends ConsumerState<_SpecialRow> {
  var _form = _SpecialForms.none;

  void _show(_SpecialForms f) {
    if (!widget.open) widget.onToggle();
    setState(() => _form = _form == f ? _SpecialForms.none : f);
  }

  Future<void> _cancel() async {
    final a = widget.item;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => ChurchDialog(
        title: 'Cancel ${a.dutyName}?',
        content: Text(
          a.holder == null
              ? 'Nobody holds it now. It is removed from the list.'
              : '${a.holder!.name} is told it is cancelled (unless they had '
                    'said they can\'t make it). Their answer is kept in the '
                    'history.',
        ),
        actions: [
          FocusRing(
            child: TextButton(
              key: const Key('special-cancel-no'),
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Keep it'),
            ),
          ),
          FocusRing(
            child: FilledButton(
              key: const Key('special-cancel-yes'),
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Cancel it'),
            ),
          ),
        ],
      ),
    );
    if (ok == true && mounted) {
      await ref.read(dutySpecialProvider.notifier).cancel(a);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = ChurchColors.of(context);
    final a = widget.item;
    final h = a.holder;
    final id = a.occurrenceId;
    final busy = widget.busy;
    final (mark, tone) = _specialMark(a);
    final muted = ChurchType.secondary.copyWith(color: c.muted);
    final who = h == null ? 'Nobody now' : (h.own ? '${h.name} (you)' : h.name);
    // The one action a row that needs doing shows without opening it.
    final Widget? rowAction = switch (a) {
      _ when a.outcomeDue && !(h?.own ?? false) => TextButton(
        key: Key('special-record-$id'),
        style: _outRowButton(null),
        onPressed: busy ? null : () => _show(_SpecialForms.record),
        child: const Text('Record outcome'),
      ),
      _ when a.needsSomeone => TextButton(
        key: Key('special-reassign-$id'),
        style: _outRowButton(null),
        onPressed: busy ? null : () => _show(_SpecialForms.change),
        child: const Text('Give to someone'),
      ),
      _ => null,
    };
    final chevron = Icon(
      widget.open ? Icons.expand_less : Icons.expand_more,
      color: c.muted,
      semanticLabel: widget.open ? 'Close details' : 'Open details',
    );
    final markLabel = StatusLabel(
      key: Key('special-mark-$id'),
      label: mark,
      tone: tone,
    );
    final Widget line;
    if (widget.wide) {
      line = Padding(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 4),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 58),
          child: StaffColumnsRow(
            columns: _specColumns,
            cells: [
              Text(
                _specialWhen(context, a),
                key: Key('special-when-$id'),
                style: ChurchType.staffBody.copyWith(
                  color: c.ink,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    a.dutyName,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: ChurchType.staffBody.copyWith(
                      color: c.ink,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (a.location case final l?)
                    Text(
                      l,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: muted.copyWith(fontSize: 13),
                    ),
                ],
              ),
              Text(
                who,
                key: Key('special-sub-$id'),
                style: ChurchType.staffBody.copyWith(
                  color: h == null ? c.muted : c.ink,
                ),
              ),
              markLabel,
              rowAction == null
                  ? const SizedBox.shrink()
                  : FocusRing(child: rowAction),
              chevron,
            ],
          ),
        ),
      );
    } else {
      line = Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _DateBadge(at: a.times.arriveBy),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    a.dutyName,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: ChurchType.itemTitle.copyWith(color: c.ink),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    [who, _specialWhen(context, a)].join(' · '),
                    key: Key('special-sub-$id'),
                    style: muted,
                  ),
                  const SizedBox(height: 8),
                  markLabel,
                  if (rowAction != null) ...[
                    const SizedBox(height: 4),
                    FocusRing(child: rowAction),
                  ],
                ],
              ),
            ),
            chevron,
          ],
        ),
      );
    }
    final summary = InkWell(
      key: Key('special-open-$id'),
      onTap: widget.onToggle,
      child: line,
    );
    return DecoratedBox(
      decoration: BoxDecoration(
        // The opened row and its details share one pale tint.
        color: widget.open ? c.bg : null,
        border: widget.divider ? Border(top: BorderSide(color: c.line)) : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          summary,
          if (widget.open)
            Padding(
              padding: EdgeInsets.fromLTRB(widget.wide ? 20 : 78, 0, 16, 16),
              child: Align(
                alignment: AlignmentDirectional.centerStart,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 760),
                  child: _details(context, a),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _details(BuildContext context, SpecialAssignment a) {
    final h = a.holder;
    final id = a.occurrenceId;
    final busy = widget.busy;
    final rows = <DetailRow>[
      if (a.times.dueOn case final d?)
        (label: 'Due', value: '${_specDate(d)} (done by 18:00)')
      else
        (label: 'When', value: '${_specialWhen(context, a)} (church time)'),
      if (a.location case final l?) (label: 'Location', value: l),
      if (h != null && h.response == DutyResponse.pending && !a.started)
        (
          label: 'Answer by',
          value: [
            _outDayTime(h.responseDeadline),
            if (h.deadlineSource == DutyDeadlineSource.churchDefault)
              '(church default)',
          ].join(' '),
        ),
      if (a.givenBy case final g?)
        (
          label: 'Given by',
          value: a.givenAt == null ? g : '$g, ${_outDayTime(a.givenAt!)}',
        ),
      if (h?.note case final n?) (label: 'Their note', value: n),
      if (h?.override case final o?)
        (label: 'Overlap', value: _overrideText(context, o)),
      if (h?.needsContact case final n?) (label: 'Contact them', value: n.text),
    ];
    final own = h?.own ?? false;
    final canChange = !a.started;
    final canConfirm =
        canChange &&
        h != null &&
        !own &&
        !h.erased &&
        h.response == DutyResponse.pending;
    final canRecord = a.outcomeDue && !own;
    final canCorrect =
        a.started && h?.outcome != null && !own && !(h?.erased ?? true);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DetailTable(rows: rows),
        if (a.instructions case final i?) ...[
          const SizedBox(height: 12),
          const CardLabel('Instructions'),
          const SizedBox(height: 6),
          Text(i, key: Key('special-instructions-$id')),
        ],
        if (h == null) ...[
          const SizedBox(height: 8),
          _muted(
            context,
            a.vacancy?.reason == null
                ? 'Nobody holds it now. Give it to someone, or cancel it.'
                : 'Nobody holds it now (${DutyVacancyReasons.label(a.vacancy!.reason!).toLowerCase()}). '
                      'Give it to someone, or cancel it.',
          ),
        ] else if (h.noLogin) ...[
          const SizedBox(height: 8),
          _muted(
            context,
            '${h.name} has no login: tell them directly, then record "Confirmed '
            'by the Pastor" when they agree.',
          ),
        ],
        if (h?.outcome case final o?) ...[
          const SizedBox(height: 8),
          _OutcomeLines(record: o, keyPrefix: 'special-outcome-$id'),
        ],
        if (own) ...[
          const SizedBox(height: 8),
          _muted(
            context,
            'This one is yours: answer it in My duties. Another Pastor records '
            'its outcome.',
          ),
        ],
        if (h?.erased ?? false) ...[
          const SizedBox(height: 8),
          _muted(context, 'This member\'s record was removed.'),
        ],
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            if (canChange)
              FocusRing(
                child: OutlinedButton(
                  key: Key('special-change-$id'),
                  onPressed: busy ? null : () => _show(_SpecialForms.change),
                  child: Text(h == null ? 'Give to someone' : 'Change'),
                ),
              ),
            if (canConfirm)
              FocusRing(
                child: OutlinedButton(
                  key: Key('special-confirm-$id'),
                  onPressed: busy ? null : () => _show(_SpecialForms.confirm),
                  child: const Text('They agreed by phone or in person'),
                ),
              ),
            if (canRecord)
              FocusRing(
                child: OutlinedButton(
                  key: Key('special-record-open-$id'),
                  onPressed: busy ? null : () => _show(_SpecialForms.record),
                  child: const Text('Record outcome'),
                ),
              ),
            if (canCorrect)
              FocusRing(
                child: OutlinedButton(
                  key: Key('special-correct-$id'),
                  onPressed: busy ? null : () => _show(_SpecialForms.correct),
                  child: const Text('Correct outcome'),
                ),
              ),
            if (canChange)
              FocusRing(
                child: TextButton(
                  key: Key('special-cancel-$id'),
                  style: TextButton.styleFrom(
                    foregroundColor: ChurchColors.of(context).redFg,
                  ),
                  onPressed: busy ? null : _cancel,
                  child: const Text('Cancel it'),
                ),
              ),
          ],
        ),
        if (_form == _SpecialForms.change && canChange) ...[
          const SizedBox(height: 12),
          _SpecialForm(
            key: Key('special-change-form-$id'),
            item: a,
            members: widget.members,
            busy: busy,
            state: widget.state,
            onSent: () => setState(() => _form = _SpecialForms.none),
          ),
        ],
        if (_form == _SpecialForms.confirm && canConfirm) ...[
          const SizedBox(height: 12),
          _SpecialConfirmForm(
            item: a,
            busy: busy,
            onSent: () => setState(() => _form = _SpecialForms.none),
          ),
        ],
        if ((_form == _SpecialForms.record && canRecord) ||
            (_form == _SpecialForms.correct && canCorrect)) ...[
          const SizedBox(height: 12),
          _SpecialOutcomeForm(
            item: a,
            correction: _form == _SpecialForms.correct,
            busy: busy,
            state: widget.state,
            onSent: () => setState(() => _form = _SpecialForms.none),
          ),
        ],
      ],
    );
  }
}

/// Give a special assignment, or (with [item]) change one: who, what, a fixed
/// time or a due date, where, instructions and an optional answer-by time.
class _SpecialForm extends ConsumerStatefulWidget {
  const _SpecialForm({
    super.key,
    required this.members,
    required this.busy,
    required this.state,
    required this.onSent,
    this.item,
    this.membersTruncated = false,
  });

  final SpecialAssignment? item;
  final List<DepartmentMember> members;
  final bool membersTruncated;
  final bool busy;
  final DutiesState<SpecialAssignments> state;
  final VoidCallback onSent;

  @override
  ConsumerState<_SpecialForm> createState() => _SpecialFormState();
}

class _SpecialFormState extends ConsumerState<_SpecialForm> {
  late final SpecialAssignment? _item = widget.item;
  late SpecialTiming _timing = _item?.timing ?? SpecialTiming.time;
  late final _name = TextEditingController(text: _item?.dutyName ?? '');
  late final _date = TextEditingController(
    text: _item == null || _item.isDue
        ? ''
        : ChurchTime.dateText(_item.times.startsAt),
  );
  late final _start = TextEditingController(
    text: _item == null || _item.isDue
        ? ''
        : ChurchTime.timeText(_item.times.startsAt),
  );
  late final _end = TextEditingController(
    text: _item?.times.endsAt == null
        ? ''
        : ChurchTime.timeText(_item!.times.endsAt!),
  );
  late final _due = TextEditingController(
    text: _item?.times.dueOn == null ? '' : ChurchTime.ymd(_item!.times.dueOn!),
  );
  late final _location = TextEditingController(text: _item?.location ?? '');
  late final _instructions = TextEditingController(
    text: _item?.instructions ?? '',
  );
  final _deadlineDate = TextEditingController();
  final _deadlineTime = TextEditingController();
  final _reason = TextEditingController();
  final _find = TextEditingController();
  // An erased holder cannot be chosen again (the picker lists real members).
  late String? _memberId = (_item?.holder?.erased ?? true)
      ? null
      : _item!.holder!.memberId;
  String? _sent;

  List<TextEditingController> get _all => [
    _name,
    _date,
    _start,
    _end,
    _due,
    _location,
    _instructions,
    _deadlineDate,
    _deadlineTime,
    _reason,
  ];

  @override
  void dispose() {
    for (final c in [..._all, _find]) {
      c.dispose();
    }
    super.dispose();
  }

  DateTime? get _startsAt => ChurchTime.parse(_date.text, _start.text);

  DateTime? get _endsAt =>
      _end.text.trim().isEmpty ? null : ChurchTime.parse(_date.text, _end.text);

  DateTime? get _dueOn => DutySpecial.parseDate(_due.text);

  bool get _deadlineEmpty =>
      _deadlineDate.text.trim().isEmpty && _deadlineTime.text.trim().isEmpty;

  DateTime? get _deadline => _deadlineEmpty
      ? null
      : ChurchTime.parse(_deadlineDate.text, _deadlineTime.text);

  /// The timing as typed, or null while it cannot be read.
  bool get _timingOk => switch (_timing) {
    SpecialTiming.time =>
      _startsAt != null &&
          (_end.text.trim().isEmpty ||
              (_endsAt != null && _endsAt!.isAfter(_startsAt!))),
    SpecialTiming.due => _dueOn != null,
  };

  /// The overlap check: a fixed time only (a due date never overlaps).
  CandidateQuery? _query() {
    if (_timing != SpecialTiming.time || !_timingOk) return null;
    final item = _item;
    if (item == null) {
      return CandidateQuery.special(startsAt: _startsAt!, endsAt: _endsAt);
    }
    return CandidateQuery.slot(
      item.slotId,
      startsAt: _startsAt,
      endsAt: _endsAt,
    );
  }

  SpecialDraft? _draft() {
    final member = _memberId;
    if (member == null ||
        _name.text.trim().isEmpty ||
        !_timingOk ||
        (!_deadlineEmpty && _deadline == null)) {
      return null;
    }
    return SpecialDraft(
      memberId: member,
      dutyName: _name.text,
      timing: _timing,
      startsAt: _timing == SpecialTiming.time ? _startsAt : null,
      endsAt: _timing == SpecialTiming.time ? _endsAt : null,
      dueOn: _timing == SpecialTiming.due ? _dueOn : null,
      location: _location.text,
      instructions: _instructions.text,
      responseDeadline: _deadline,
      overrideReason: _reason.text,
    );
  }

  SpecialEdit? _edit() {
    final item = _item;
    if (item == null ||
        _name.text.trim().isEmpty ||
        !_timingOk ||
        (!_deadlineEmpty && _deadline == null)) {
      return null;
    }
    final e = SpecialEdit(
      item: item,
      dutyName: _name.text,
      timing: _timing,
      startsAt: _timing == SpecialTiming.time ? _startsAt : null,
      endsAt: _timing == SpecialTiming.time ? _endsAt : null,
      dueOn: _timing == SpecialTiming.due ? _dueOn : null,
      location: _location.text,
      instructions: _instructions.text,
      memberId: _memberId,
      responseDeadline: _deadline,
      overrideReason: _reason.text,
    );
    return e.changed.isEmpty ? null : e;
  }

  Future<void> _save() async {
    final ctl = ref.read(dutySpecialProvider.notifier);
    if (_item == null) {
      final d = _draft();
      if (d == null) return;
      await ctl.give(d);
    } else {
      final e = _edit();
      if (e == null) return;
      await ctl.revise(e);
    }
    if (!mounted) return;
    final s = ref.read(dutySpecialProvider);
    _sent = s.noticeAction?.request.requestId;
    if (s.notice == DutyNotice.specialGiven ||
        s.notice == DutyNotice.revised ||
        s.notice == DutyNotice.notesUpdated) {
      widget.onSent();
    } else {
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final item = _item;
    final key = item == null ? 'special-new' : 'special-${item.occurrenceId}';
    final st = widget.state;
    // Only this form's own refusal names its fields.
    final mine = _sent != null && st.noticeAction?.request.requestId == _sent;
    final errors = mine ? st.fieldErrors : const <String, String>{};
    String? err(String wire) => switch (errors[wire]) {
      null => null,
      'required' => 'Required',
      'past' => 'This is in the past',
      'after_start' =>
        _timing == SpecialTiming.due
            ? 'Must be before the due date'
            : 'Must be before it starts',
      'before_start' => 'Must be after the start',
      'out_of_range' => 'At most two years ahead',
      'invalid' => 'Check this',
      'unknown' => 'Not an active member',
      'own' => 'Give it to someone else',
      'overlap' => 'Has another duty at that time',
      'with_starts_at' || 'with_due_on' => 'Choose a time or a due date',
      _ => 'Check this',
    };
    Widget field(
      String k,
      TextEditingController c,
      String label, {
      String? wire,
      String? hint,
      int maxLength = 80,
      int maxLines = 1,
      double? width,
    }) {
      final f = Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: TextField(
          key: Key('$key-$k'),
          controller: c,
          enabled: !widget.busy,
          maxLength: maxLength,
          maxLines: maxLines,
          decoration: InputDecoration(
            labelText: label,
            hintText: hint,
            counterText: maxLength <= 10 ? '' : null,
            errorText: wire == null ? null : err(wire),
          ),
        ),
      );
      return width == null ? f : SizedBox(width: width, child: f);
    }

    // The members to choose from, narrowed by the name typed (the chosen one
    // stays listed so the picker always shows them). Whoever holds it now is
    // listed even when the read left them out (beyond the first 1000).
    final needle = _find.text.trim().toLowerCase();
    final holder = item?.holder;
    final members = [
      if (holder != null &&
          !holder.erased &&
          !widget.members.any((m) => m.memberId == holder.memberId))
        DepartmentMember(
          memberId: holder.memberId,
          displayName: holder.name,
          account: holder.account ?? AccountStanding.appAccount,
        ),
      ...widget.members,
    ];
    final shown = [
      for (final m in members)
        if (needle.isEmpty ||
            m.displayName.toLowerCase().contains(needle) ||
            m.memberId == _memberId)
          m,
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _heading(
          context,
          item == null
              ? 'Give a special assignment'
              : 'Change ${item.dutyName}',
        ),
        _muted(
          context,
          item == null
              ? 'For a duty that belongs to no department and no cell. The '
                    'member is asked to accept or say they can\'t make it by the '
                    'answer-by time. Times are church time (Lusaka).'
              : 'A change to the duty, its time or due date, the place or who '
                    'holds it asks them to answer again; a change to the '
                    'instructions only keeps their answer.',
        ),
        const SizedBox(height: 12),
        field('name', _name, 'Duty', wire: 'duty_name'),
        RadioSegments<SpecialTiming>(
          key: Key('$key-timing'),
          label: 'When',
          options: const [
            SegmentOption(SpecialTiming.time, 'At a date and time'),
            SegmentOption(SpecialTiming.due, 'Done by a date'),
          ],
          selected: _timing,
          onChanged: widget.busy ? null : (t) => setState(() => _timing = t),
        ),
        const SizedBox(height: 12),
        if (_timing == SpecialTiming.time)
          Wrap(
            spacing: 12,
            children: [
              field(
                'date',
                _date,
                'Date',
                hint: 'YYYY-MM-DD',
                wire: 'starts_at',
                maxLength: 10,
                width: 170,
              ),
              field(
                'start',
                _start,
                'Start time',
                hint: 'HH:MM',
                maxLength: 5,
                width: 120,
              ),
              field(
                'end',
                _end,
                'End time (optional)',
                hint: 'HH:MM',
                wire: 'ends_at',
                maxLength: 5,
                width: 200,
              ),
            ],
          )
        else ...[
          field(
            'due',
            _due,
            'Due date',
            hint: 'YYYY-MM-DD',
            wire: 'due_on',
            maxLength: 10,
            width: 170,
          ),
          _muted(
            context,
            'Done by the end of that day (18:00 church time). A due date has '
            'no time, so it never overlaps their other duties.',
          ),
          const SizedBox(height: 8),
        ],
        field(
          'location',
          _location,
          'Location (optional)',
          wire: 'location',
          maxLength: 120,
        ),
        field(
          'instructions',
          _instructions,
          'Instructions (optional)',
          wire: 'instructions',
          maxLength: 1000,
          maxLines: 3,
        ),
        if (widget.members.length > 12)
          field('find', _find, 'Find a member', maxLength: 60),
        if (widget.membersTruncated)
          _muted(context, 'Only the first 1000 members (by name) are listed.'),
        ListenableBuilder(
          listenable: Listenable.merge([_date, _start, _end, _find]),
          builder: (context, _) => _CandidatePicker(
            pickerKey: '$key-member',
            members: shown,
            value: _memberId,
            query: _query(),
            reason: _reason,
            busy: widget.busy,
            reasonError: errors['override_reason'],
            onChanged: (v) => setState(() => _memberId = v),
          ),
        ),
        if (err('member_id') case final e?)
          Text(e, style: TextStyle(color: ChurchColors.of(context).redFg)),
        const SizedBox(height: 8),
        Wrap(
          spacing: 12,
          children: [
            field(
              'deadline-date',
              _deadlineDate,
              'Answer by: date (optional)',
              hint: 'YYYY-MM-DD',
              wire: 'response_deadline',
              maxLength: 10,
              width: 250,
            ),
            field(
              'deadline-time',
              _deadlineTime,
              'Answer by: time (optional)',
              hint: 'HH:MM',
              maxLength: 5,
              width: 240,
            ),
          ],
        ),
        _muted(context, _specialDeadlineHelp),
        const SizedBox(height: 12),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: ListenableBuilder(
            listenable: Listenable.merge(_all),
            builder: (context, _) {
              final ready = item == null ? _draft() != null : _edit() != null;
              return FocusRing(
                child: FilledButton(
                  key: Key('$key-save'),
                  onPressed: widget.busy || !ready ? null : _save,
                  child: Text(item == null ? 'Give it' : 'Save the change'),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

/// "They agreed by phone or in person": Confirmed by the Pastor, with how
/// and a short reason (kept apart from an answer in the app).
class _SpecialConfirmForm extends ConsumerStatefulWidget {
  const _SpecialConfirmForm({
    required this.item,
    required this.busy,
    required this.onSent,
  });

  final SpecialAssignment item;
  final bool busy;
  final VoidCallback onSent;

  @override
  ConsumerState<_SpecialConfirmForm> createState() =>
      _SpecialConfirmFormState();
}

class _SpecialConfirmFormState extends ConsumerState<_SpecialConfirmForm> {
  var _channel = ContactChannel.phone;
  final _reason = TextEditingController();

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    await ref
        .read(dutySpecialProvider.notifier)
        .confirm(
          widget.item,
          LeaderConfirmationDraft(channel: _channel, reason: _reason.text),
        );
    if (!mounted) return;
    if (ref.read(dutySpecialProvider).notice == DutyNotice.leaderConfirmed) {
      widget.onSent();
    }
  }

  @override
  Widget build(BuildContext context) {
    final id = widget.item.occurrenceId;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _muted(
          context,
          'Recorded as Confirmed by the Pastor with you and the time, kept apart '
          'from an answer in the app. Their answer reminders stop.',
        ),
        const SizedBox(height: 8),
        DropdownButton<ContactChannel>(
          key: Key('special-confirm-channel-$id'),
          value: _channel,
          items: [
            for (final c in ContactChannel.values)
              DropdownMenuItem(value: c, child: Text(c.label)),
          ],
          onChanged: widget.busy
              ? null
              : (c) => setState(() => _channel = c ?? ContactChannel.phone),
        ),
        TextField(
          key: Key('special-confirm-reason-$id'),
          controller: _reason,
          enabled: !widget.busy,
          maxLength: LeaderConfirmationDraft.reasonMax,
          onChanged: (_) => setState(() {}),
          decoration: const InputDecoration(
            labelText: 'Why you are recording it (required)',
            helperText: 'For example "said yes after the service".',
          ),
        ),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: FocusRing(
            child: FilledButton(
              key: Key('special-confirm-save-$id'),
              onPressed: widget.busy || _reason.text.trim().isEmpty
                  ? null
                  : _save,
              child: const Text('Record Confirmed by the Pastor'),
            ),
          ),
        ),
      ],
    );
  }
}

/// Record (or correct, with a reason) a special assignment's outcome once its
/// time or due date has passed. No-show only after an acceptance.
class _SpecialOutcomeForm extends ConsumerStatefulWidget {
  const _SpecialOutcomeForm({
    required this.item,
    required this.correction,
    required this.busy,
    required this.state,
    required this.onSent,
  });

  final SpecialAssignment item;
  final bool correction;
  final bool busy;
  final DutiesState<SpecialAssignments> state;
  final VoidCallback onSent;

  @override
  ConsumerState<_SpecialOutcomeForm> createState() =>
      _SpecialOutcomeFormState();
}

class _SpecialOutcomeFormState extends ConsumerState<_SpecialOutcomeForm> {
  late DutyOutcome? _choice = widget.correction
      ? widget.item.holder?.outcome?.outcome
      : null;
  late final _note = TextEditingController(
    text: widget.correction ? (widget.item.holder?.outcome?.note ?? '') : '',
  );
  final _reason = TextEditingController();

  @override
  void dispose() {
    _note.dispose();
    _reason.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final choice = _choice;
    if (choice == null) return;
    final draft = OutcomeDraft(
      outcome: choice,
      note: _note.text,
      reason: widget.correction ? _reason.text : null,
    );
    final ctl = ref.read(dutySpecialProvider.notifier);
    await (widget.correction
        ? ctl.correct(widget.item, draft)
        : ctl.record(widget.item, draft));
    if (!mounted) return;
    final n = ref.read(dutySpecialProvider).notice;
    if (n == DutyNotice.outcomeRecorded || n == DutyNotice.outcomeCorrected) {
      widget.onSent();
    }
  }

  @override
  Widget build(BuildContext context) {
    final a = widget.item;
    final h = a.holder!;
    final id = a.occurrenceId;
    final allowed = h.allowed;
    final reasonOk = !widget.correction || _reason.text.trim().isNotEmpty;
    return Column(
      key: Key('special-outcome-form-$id'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _muted(
          context,
          widget.correction
              ? 'The earlier value, who recorded it and when stay in the '
                    'history. Give a short reason for the correction.'
              : 'Only what happened. ${allowed.contains(DutyOutcome.noShow) ? '' : 'No-show is only for one they accepted. '}'
                    'Seen by ${h.name} and the Pastors.',
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final o in allowed)
              ChoiceChip(
                key: Key('special-choice-$id-${o.wire}'),
                label: Text(o.label),
                selected: _choice == o,
                onSelected: widget.busy
                    ? null
                    : (_) => setState(() => _choice = o),
              ),
          ],
        ),
        TextField(
          key: Key('special-outcome-note-$id'),
          controller: _note,
          enabled: !widget.busy,
          maxLength: OutcomeDraft.noteMax,
          decoration: const InputDecoration(labelText: 'Short note (optional)'),
        ),
        if (widget.correction)
          TextField(
            key: Key('special-outcome-reason-$id'),
            controller: _reason,
            enabled: !widget.busy,
            maxLength: OutcomeDraft.reasonMax,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(
              labelText: 'Reason for the correction (required)',
            ),
          ),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: FocusRing(
            child: FilledButton(
              key: Key('special-outcome-save-$id'),
              onPressed: widget.busy || _choice == null || !reasonOk
                  ? null
                  : _save,
              child: Text(
                widget.correction ? 'Save correction' : 'Save outcome',
              ),
            ),
          ),
        ),
      ],
    );
  }
}

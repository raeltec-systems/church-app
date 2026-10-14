part of 'duties_screens.dart';

// Story 4.3, staff web: rota series. A leader generates a repeating rota as
// drafts (members see nothing), plans who takes each position, publishes
// "N draft slots" after confirming, changes one date or this and the later
// dates, and cancels one date or this and the later dates. Every list comes
// from `api.duties_rota`; every action is a server-checked command, and
// nothing shows as done until the server answered.

/// Staff web: the rota grid (with an accessible list alternative).
class DutyRotaScreen extends StatelessWidget {
  const DutyRotaScreen({super.key});

  @override
  Widget build(BuildContext context) => _DutiesPage<DutyRota>(
    title: 'Rota',
    provider: dutyRotaProvider,
    needs: 'This page is for department leaders and deputies.',
    loading: 'Loading the rota…',
    body: (context, rota, s) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _muted(
          context,
          'Dates and times are church time (Lusaka). Drafts are seen only by '
          'the department\'s leaders, deputies, Admin and Pastor; nobody is '
          'asked until you publish.',
        ),
        const SizedBox(height: 12),
        if (rota.departments.isEmpty)
          const Text('No departments yet.', key: Key('rota-no-departments')),
        for (final d in rota.departments) ...[
          _RotaDepartmentCard(department: d, busy: s.busy),
          const SizedBox(height: 12),
        ],
      ],
    ),
  );
}

String _personName(String? displayName) => displayName ?? 'Removed member';

/// The words of one rota position, for the grid cell, the list and screen
/// readers alike.
String _positionText(RotaOccurrence o, RotaPosition p) {
  if (o.state == RotaState.cancelled) return 'Cancelled';
  if (o.state == RotaState.draft) {
    final d = p.draft;
    if (d == null) return 'Not planned';
    return 'Planned: ${_personName(d.displayName)}'
        '${d.available ? '' : ' (can\'t serve now)'}'
        '${_overlapText(d.overlaps, d.overrideReason != null)}';
  }
  final a = p.assignment;
  if (a == null) return 'Unfilled';
  return '${_personName(a.displayName)}: '
      '${_answerLabel(a.response, a.priorAcceptedAt).$1}'
      '${a.available ? '' : ' (can\'t serve now)'}'
      '${o.started ? '' : _overlapText(a.overlaps, a.override != null)}'
      // Story 4.8: Short notice and Needs contact.
      '${a.shortNotice && a.response == DutyResponse.pending && !o.started ? '; short notice' : ''}'
      '${a.needsContact != null ? '; needs contact' : ''}';
}

/// Story 4.8: the "church default" entry first, then the lead times.
List<DropdownMenuItem<String>> _leadItems() => [
  const DropdownMenuItem(
    value: DutyLeads.churchDefault,
    child: Text('the church default (by lead time)'),
  ),
  for (final (wire, label) in DutyLeads.choices)
    DropdownMenuItem(value: wire, child: Text(label)),
];

/// Story 4.4: "; overlaps 1 other duty (reason given)".
String _overlapText(int overlaps, bool reasoned) => overlaps == 0
    ? ''
    : '; overlaps $overlaps other ${overlaps == 1 ? 'duty' : 'duties'}'
          '${reasoned ? ' (reason given)' : ''}';

/// What a refused rota command's field code means, in words.
String _rotaError(String code) => switch (code) {
  'required' => 'Required',
  'past' => 'This is in the past: choose a later time',
  'passed' =>
    'For at least one date this answer-by time has already passed: choose a '
        'shorter time before the duty',
  'after_start' => 'Must be before the start',
  'before_start' => 'Must be after the start',
  'invalid' => 'Use HH:MM',
  'not_in_department' => 'Not a member of this department',
  'unknown' => 'This person can no longer serve',
  'unavailable' =>
    'Someone planned can no longer serve: plan someone else first',
  'overlap' =>
    'Has another duty at that time: give a reason, or choose someone else',
  'required_reassign' =>
    'Someone assigned can no longer serve: give that position to someone '
        'else first',
  _ => 'Check this',
};

/// The date a refusal names (`occurrence:<id>`), if it is in [series].
RotaOccurrence? _namedDate(RotaSeries series, Map<String, String> errors) {
  for (final k in errors.keys) {
    if (!k.startsWith('occurrence:')) continue;
    final id = k.substring('occurrence:'.length);
    for (final o in series.occurrences) {
      if (o.occurrenceId == id) return o;
    }
  }
  return null;
}

Widget _errorLine(BuildContext context, String text, {Key? key}) => Text(
  text,
  key: key,
  style: TextStyle(color: ChurchColors.of(context).redFg),
);

String _stateText(RotaOccurrence o) => switch (o.state) {
  RotaState.cancelled => 'Cancelled',
  RotaState.draft when o.started => 'Draft, not published (started)',
  RotaState.draft => 'Draft',
  RotaState.published when o.started => 'Started',
  RotaState.published => 'Published',
};

class _RotaDepartmentCard extends StatefulWidget {
  const _RotaDepartmentCard({required this.department, required this.busy});
  final RotaDepartment department;
  final bool busy;

  @override
  State<_RotaDepartmentCard> createState() => _RotaDepartmentCardState();
}

class _RotaDepartmentCardState extends State<_RotaDepartmentCard> {
  bool _creating = false;

  @override
  Widget build(BuildContext context) {
    final d = widget.department;
    return _Card(
      key: Key('rota-department-${d.departmentId}'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              _heading(context, d.name),
              StatusLabel(
                label: d.canManage
                    ? 'You manage this rota'
                    : 'Pastor oversight (read only)',
                tone: StatusTone.info,
              ),
            ],
          ),
          if (d.seriesTruncated)
            _muted(context, 'Only the first 50 rotas are shown.'),
          if (d.series.isEmpty)
            Text('No rotas yet.', key: Key('rota-none-${d.departmentId}')),
          for (final series in d.series)
            _SeriesView(
              key: Key('series-${series.seriesId}'),
              series: series,
              department: d,
              busy: widget.busy,
            ),
          if (d.canManage) ...[
            const SizedBox(height: 12),
            if (_creating)
              _NewSeriesForm(
                department: d,
                busy: widget.busy,
                onClose: () => setState(() => _creating = false),
              )
            else
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: FocusRing(
                  child: OutlinedButton.icon(
                    key: Key('rota-new-${d.departmentId}'),
                    onPressed: widget.busy
                        ? null
                        : () => setState(() => _creating = true),
                    icon: const Icon(Icons.add),
                    label: const Text('New rota'),
                  ),
                ),
              ),
          ],
        ],
      ),
    );
  }
}

/// One series: header, Publish N draft slots, the grid or the list, and the
/// selected date's actions.
class _SeriesView extends ConsumerStatefulWidget {
  const _SeriesView({
    super.key,
    required this.series,
    required this.department,
    required this.busy,
  });
  final RotaSeries series;
  final RotaDepartment department;
  final bool busy;

  @override
  ConsumerState<_SeriesView> createState() => _SeriesViewState();
}

class _SeriesViewState extends ConsumerState<_SeriesView> {
  bool _list = false;
  bool _publishing = false;
  String _lead = '2 days';
  String? _selected;

  @override
  void didUpdateWidget(_SeriesView old) {
    super.didUpdateWidget(old);
    // A new series revision (published, changed) closes the confirmation:
    // its N would be stale.
    if (old.series.revision != widget.series.revision) _publishing = false;
  }

  void _select(RotaOccurrence o) => setState(
    () => _selected = _selected == o.occurrenceId ? null : o.occurrenceId,
  );

  @override
  Widget build(BuildContext context) {
    final r = widget.series;
    final id = r.seriesId;
    final manage = widget.department.canManage;
    RotaOccurrence? selected;
    for (final o in r.occurrences) {
      if (o.occurrenceId == _selected) selected = o;
    }
    return Padding(
      padding: const EdgeInsets.only(top: 12, bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(r.dutyName, style: ChurchType.cardTitle),
          Text(
            '${r.repeatLabel} from ${r.fromDate} to ${r.untilDate}, '
            '${r.startTime}${r.endTime == null ? '' : '-${r.endTime}'} '
            '(church time). Positions: ${r.positions.join(', ')}.',
          ),
          if (r.location case final l?) Text('Where: $l'),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FocusRing(
                child: TextButton(
                  key: Key('rota-view-$id'),
                  onPressed: () => setState(() => _list = !_list),
                  child: Text(_list ? 'Show as grid' : 'Show as list'),
                ),
              ),
              if (manage && r.draftSlots > 0 && !_publishing)
                FocusRing(
                  child: FilledButton(
                    key: Key('rota-publish-$id'),
                    onPressed: widget.busy
                        ? null
                        : () => setState(() => _publishing = true),
                    child: Text(
                      'Publish ${r.draftSlots} draft '
                      '${r.draftSlots == 1 ? 'slot' : 'slots'}',
                    ),
                  ),
                ),
            ],
          ),
          if (_publishing) _publishPanel(context, r),
          const SizedBox(height: 8),
          if (_list)
            _RotaList(
              series: r,
              selected: _selected,
              onSelect: _select,
              manage: manage,
            )
          else
            _RotaGrid(series: r, selected: _selected, onSelect: _select),
          if (selected != null)
            _OccurrencePanel(
              key: Key(
                'occurrence-panel-${selected.occurrenceId}'
                '-r${selected.revision}-s${r.revision}',
              ),
              series: r,
              occurrence: selected,
              department: widget.department,
              busy: widget.busy,
              onClose: () => setState(() => _selected = null),
              onOpen: (id) => setState(() => _selected = id),
            ),
        ],
      ),
    );
  }

  Widget _publishPanel(BuildContext context, RotaSeries r) {
    final id = r.seriesId;
    final n = r.draftSlots;
    final planned = r.occurrences
        .where((o) => o.state == RotaState.draft && !o.started)
        .expand((o) => o.positions)
        .where((p) => p.draft != null)
        .length;
    final st = ref.watch(dutyRotaProvider);
    final mine =
        st.noticeAction?.command == DutyCommands.publishDrafts &&
        st.noticeAction?.request.payload['series_id'] == id;
    final errors = mine ? st.fieldErrors : const <String, String>{};
    final named = _namedDate(r, errors);
    final problem = errors['deadline_before'] ?? errors['member_id'];
    return _Card(
      key: Key('rota-publish-panel-$id'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _heading(context, 'Publish $n draft ${n == 1 ? 'slot' : 'slots'}?'),
          Text(
            '$planned planned ${planned == 1 ? 'person is' : 'people are'} '
            'asked to answer and get a notice; the other '
            '${n - planned} ${n - planned == 1 ? 'position stays' : 'positions stay'} '
            'unfilled. Dates that have started are not published.',
          ),
          const SizedBox(height: 8),
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              const Text('Answer by: '),
              DropdownButton<String>(
                key: Key('rota-publish-lead-$id'),
                value: _lead,
                items: _leadItems(),
                onChanged: widget.busy
                    ? null
                    : (v) => setState(() => _lead = v ?? _lead),
              ),
              const Text(' the reporting or start time'),
            ],
          ),
          if (problem != null)
            _errorLine(
              context,
              '${_rotaError(problem)}'
              '${named == null ? '' : ' (${_when(context, named.times.startsAt)})'}.',
              key: Key('rota-publish-error-$id'),
            ),
          if (named != null)
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: FocusRing(
                child: TextButton(
                  key: Key('rota-publish-open-${named.occurrenceId}'),
                  onPressed: () =>
                      setState(() => _selected = named.occurrenceId),
                  child: Text('Open ${_when(context, named.times.startsAt)}'),
                ),
              ),
            ),
          Wrap(
            spacing: 8,
            children: [
              FocusRing(
                child: FilledButton(
                  key: Key('rota-publish-confirm-$id'),
                  onPressed: widget.busy
                      ? null
                      : () => ref
                            .read(dutyRotaProvider.notifier)
                            .publishDrafts(r, n, DutyLeads.wire(_lead)),
                  child: Text('Publish $n draft ${n == 1 ? 'slot' : 'slots'}'),
                ),
              ),
              FocusRing(
                child: TextButton(
                  key: Key('rota-publish-cancel-$id'),
                  onPressed: () => setState(() => _publishing = false),
                  child: const Text('Not now'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// The grid: one row per date, one column per position. Each cell is a
/// labelled button (screen readers hear the date, position and status).
class _RotaGrid extends StatelessWidget {
  const _RotaGrid({
    required this.series,
    required this.selected,
    required this.onSelect,
  });
  final RotaSeries series;
  final String? selected;
  final void Function(RotaOccurrence) onSelect;

  @override
  Widget build(BuildContext context) {
    final c = ChurchColors.of(context);
    final names = series.positions;
    Widget cell(Widget child) =>
        Padding(padding: const EdgeInsets.all(6), child: child);
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Table(
        key: Key('rota-grid-${series.seriesId}'),
        defaultColumnWidth: const IntrinsicColumnWidth(),
        border: TableBorder.all(color: c.line),
        children: [
          TableRow(
            children: [
              cell(const Text('Date', style: ChurchType.cardTitle)),
              for (final n in names) cell(Text(n, style: ChurchType.cardTitle)),
              cell(const Text('Confirmed', style: ChurchType.cardTitle)),
            ],
          ),
          for (final o in series.occurrences)
            TableRow(
              decoration: o.occurrenceId == selected
                  ? BoxDecoration(color: c.line.withValues(alpha: 0.4))
                  : null,
              children: [
                cell(
                  Semantics(
                    button: true,
                    label:
                        '${_when(context, o.times.startsAt)}, '
                        '${_stateText(o)}. Open this date',
                    onTap: () => onSelect(o),
                    excludeSemantics: true,
                    child: FocusRing(
                      child: TextButton(
                        key: Key('rota-date-${o.occurrenceId}'),
                        onPressed: () => onSelect(o),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(_when(context, o.times.startsAt)),
                            Text(_stateText(o)),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                for (var i = 0; i < names.length; i++)
                  cell(
                    i < o.positions.length
                        ? Semantics(
                            label:
                                '${o.positions[i].label}, '
                                '${_when(context, o.times.startsAt)}: '
                                '${_positionText(o, o.positions[i])}',
                            excludeSemantics: true,
                            child: Text(
                              _positionText(o, o.positions[i]),
                              key: Key('rota-cell-${o.positions[i].slotId}'),
                            ),
                          )
                        : const SizedBox.shrink(),
                  ),
                cell(
                  Text(
                    o.state == RotaState.published
                        ? '${o.confirmed} of ${o.required}'
                        : '-',
                    key: Key('rota-confirmed-${o.occurrenceId}'),
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

/// The accessible list alternative: the same facts as plain text.
class _RotaList extends StatelessWidget {
  const _RotaList({
    required this.series,
    required this.selected,
    required this.onSelect,
    required this.manage,
  });
  final RotaSeries series;
  final String? selected;
  final void Function(RotaOccurrence) onSelect;
  final bool manage;

  @override
  Widget build(BuildContext context) => Column(
    key: Key('rota-list-${series.seriesId}'),
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      for (final o in series.occurrences)
        Padding(
          key: Key('rota-item-${o.occurrenceId}'),
          padding: const EdgeInsets.only(bottom: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Semantics(
                header: true,
                child: Text(
                  '${_timesText(context, o.times)}: ${_stateText(o)}',
                  style: ChurchType.cardTitle,
                ),
              ),
              if (o.state == RotaState.published)
                Text('${o.confirmed} of ${o.required} confirmed'),
              for (final p in o.positions)
                Text('${p.label}: ${_positionText(o, p)}'),
              FocusRing(
                child: TextButton(
                  key: Key('rota-open-${o.occurrenceId}'),
                  onPressed: () => onSelect(o),
                  child: Text(
                    '${o.occurrenceId == selected ? 'Close' : (manage && o.open ? 'Manage' : 'Details for')} '
                    '${_when(context, o.times.startsAt)}',
                  ),
                ),
              ),
            ],
          ),
        ),
    ],
  );
}

/// The selected date: details, who takes each position, change (this date
/// or this and later dates) and cancel (likewise).
class _OccurrencePanel extends ConsumerStatefulWidget {
  const _OccurrencePanel({
    super.key,
    required this.series,
    required this.occurrence,
    required this.department,
    required this.busy,
    required this.onClose,
    required this.onOpen,
  });
  final RotaSeries series;
  final RotaOccurrence occurrence;
  final RotaDepartment department;
  final bool busy;
  final VoidCallback onClose;

  /// Opens another date of the series (one a refusal named).
  final void Function(String occurrenceId) onOpen;

  @override
  ConsumerState<_OccurrencePanel> createState() => _OccurrencePanelState();
}

enum _Mode { view, change, cancel }

class _OccurrencePanelState extends ConsumerState<_OccurrencePanel> {
  _Mode _mode = _Mode.view;
  bool _future = false;

  /// Story 4.8: save the reminders for this and the later dates.
  bool _remindersFuture = false;
  String _lead = '2 days';
  final Map<String, String?> _pick = {};

  /// Story 4.4: the reason typed for each position, and for a change.
  final Map<String, TextEditingController> _reasons = {};
  final _changeReason = TextEditingController();

  TextEditingController _reasonFor(String slotId) =>
      _reasons.putIfAbsent(slotId, TextEditingController.new);
  late final _name = TextEditingController(text: widget.occurrence.dutyName);
  late final _start = TextEditingController(
    text: RotaEdit.hm(widget.occurrence.times.startsAt),
  );
  late final _end = TextEditingController(
    text: switch (widget.occurrence.times.endsAt) {
      final e? => RotaEdit.hm(e),
      null => '',
    },
  );
  late final _reporting = TextEditingController(
    text: switch (widget.occurrence.times.reportingAt) {
      final r? => RotaEdit.hm(r),
      null => '',
    },
  );
  late final _location = TextEditingController(
    text: widget.occurrence.location ?? '',
  );
  late final _instructions = TextEditingController(
    text: widget.occurrence.instructions ?? '',
  );
  late final _topic = TextEditingController(
    text: widget.occurrence.topic ?? '',
  );
  late final _scripture = TextEditingController(
    text: widget.occurrence.scripture ?? '',
  );

  List<TextEditingController> get _all => [
    _name,
    _start,
    _end,
    _reporting,
    _location,
    _instructions,
    _topic,
    _scripture,
  ];

  @override
  void dispose() {
    for (final c in [..._all, ..._reasons.values, _changeReason]) {
      c.dispose();
    }
    super.dispose();
  }

  RotaEdit get _edit => RotaEdit(
    occurrence: widget.occurrence,
    dutyName: _name.text,
    startTime: _start.text,
    endTime: _end.text,
    reportingTime: _reporting.text,
    location: _location.text,
    instructions: _instructions.text,
    topic: _topic.text,
    scripture: _scripture.text,
    lead: DutyLeads.wire(_lead),
    overrideReason: _changeReason.text,
  );

  Widget _leadPicker(String key, {String? error}) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          const Text('Answer by: '),
          DropdownButton<String>(
            key: Key(key),
            value: _lead,
            items: _leadItems(),
            onChanged: widget.busy
                ? null
                : (v) => setState(() => _lead = v ?? _lead),
          ),
          const Text(' the reporting or start time'),
        ],
      ),
      if (error != null) _errorLine(context, error, key: Key('$key-error')),
    ],
  );

  /// The field errors of this panel's last refused command of [commands].
  Map<String, String> _errorsFor(Set<String> commands, {String? slotId}) {
    final s = ref.watch(dutyRotaProvider);
    final a = s.noticeAction;
    if (a == null || !commands.contains(a.command)) return const {};
    final id = widget.occurrence.occurrenceId;
    final payload = a.request.payload;
    final ours = slotId != null
        ? payload['slot_id'] == slotId
        : payload['occurrence_id'] == id || payload['from_occurrence_id'] == id;
    return ours ? s.fieldErrors : const {};
  }

  @override
  Widget build(BuildContext context) {
    final o = widget.occurrence;
    final id = o.occurrenceId;
    final manage = widget.department.canManage && o.open;
    final ctl = ref.read(dutyRotaProvider.notifier);
    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _heading(context, '${o.dutyName}: ${_stateText(o)}'),
          Text(_timesText(context, o.times)),
          if (o.location case final l?) Text('Where: $l'),
          if (o.instructions case final i?) Text('Instructions: $i'),
          if (o.topic case final t?) Text('Topic: $t'),
          if (o.scripture case final sc?) Text('Scripture: $sc'),
          if (o.state == RotaState.published)
            Text(
              '${o.confirmed} of ${o.required} confirmed',
              key: Key('rota-coverage-$id'),
            ),
          const SizedBox(height: 8),
          for (final p in o.positions) _positionRow(context, o, p, manage),
          if (manage && o.state == RotaState.published)
            _leadPicker(
              'rota-assign-lead-$id',
              error: switch ([
                for (final p in o.positions)
                  ?_errorsFor({
                    DutyCommands.assignSlot,
                  }, slotId: p.slotId)['response_deadline'],
              ]) {
                [final e, ...] => _rotaError(e),
                _ => null,
              },
            ),
          const SizedBox(height: 8),
          // Story 4.8: this date's member reminders (or this and the later
          // dates'); nobody is asked to answer again.
          if (o.reminders case final rem?) ...[
            if (manage)
              CheckboxListTile(
                key: Key('rota-reminders-future-$id'),
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                value: _remindersFuture,
                onChanged: widget.busy
                    ? null
                    : (v) => setState(() => _remindersFuture = v ?? false),
                title: const Text('Reminders: this and later dates'),
              ),
            _RemindersEditor(
              key: Key('rota-reminders-$id-r${o.revision}'),
              keyPrefix: 'rota-$id',
              reminders: rem,
              canChange: manage,
              busy: widget.busy,
              saveLabel: _remindersFuture
                  ? 'Save for this and later dates'
                  : 'Save for this date',
              error: _errorsFor({DutyCommands.setReminders})['reminders'],
              onSave: (specs) => _remindersFuture
                  ? ctl.setSeriesReminders(widget.series, o, specs)
                  : ctl.setReminders(o, specs),
            ),
          ],
          if (manage && _mode == _Mode.view)
            Wrap(
              spacing: 8,
              children: [
                FocusRing(
                  child: OutlinedButton(
                    key: Key('rota-change-$id'),
                    onPressed: widget.busy
                        ? null
                        : () => setState(() {
                            _mode = _Mode.change;
                            _future = false;
                          }),
                    child: const Text('Change'),
                  ),
                ),
                FocusRing(
                  child: OutlinedButton(
                    key: Key('rota-cancel-$id'),
                    onPressed: widget.busy
                        ? null
                        : () => setState(() {
                            _mode = _Mode.cancel;
                            _future = false;
                          }),
                    child: const Text('Cancel date(s)…'),
                  ),
                ),
              ],
            ),
          if (manage && _mode != _Mode.view) _scopePicker(id),
          if (manage && _mode == _Mode.change) _changeForm(context, ctl),
          if (manage && _mode == _Mode.cancel) _cancelConfirm(context, ctl),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: FocusRing(
              child: TextButton(
                key: Key('rota-close-$id'),
                onPressed: widget.onClose,
                child: const Text('Close'),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _scopePicker(String id) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      RadioGroup<bool>(
        groupValue: _future,
        onChanged: (v) => setState(() => _future = v ?? false),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            RadioListTile<bool>(
              key: Key('rota-scope-this-$id'),
              value: false,
              title: const Text('This date only'),
            ),
            RadioListTile<bool>(
              key: Key('rota-scope-future-$id'),
              value: true,
              title: const Text('This and later dates'),
              subtitle: const Text(
                'Earlier dates and dates that have started are not changed.',
              ),
            ),
          ],
        ),
      ),
    ],
  );

  Widget _positionRow(
    BuildContext context,
    RotaOccurrence o,
    RotaPosition p,
    bool manage,
  ) {
    final current = o.state == RotaState.draft
        ? p.draft?.memberId
        : p.assignment?.memberId;
    final members = widget.department.members;
    final inRoster = members.any((m) => m.memberId == current);
    final picked = _pick.containsKey(p.slotId)
        ? _pick[p.slotId]
        : (inRoster ? current : null);
    final draft = o.state == RotaState.draft;
    final changed = picked != (inRoster ? current : null);
    final reason = _reasonFor(p.slotId);
    final errors = _errorsFor({DutyCommands.assignSlot}, slotId: p.slotId);
    final recorded = draft ? null : p.assignment?.override;
    final planned = draft ? p.draft?.overrideReason : null;
    return Padding(
      key: Key('rota-position-${p.slotId}'),
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('${p.label}: ${_positionText(o, p)}'),
          if (recorded != null)
            Text(
              _overrideText(context, recorded),
              key: Key('rota-override-${p.slotId}'),
            ),
          if (planned != null)
            Text(
              'Planned despite an overlap: "$planned"',
              key: Key('rota-planned-reason-${p.slotId}'),
            ),
          if (manage) ...[
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: _CandidatePicker(
                pickerKey: 'rota-pick-${p.slotId}',
                members: members,
                value: picked,
                allowNobody: draft,
                query: CandidateQuery.slot(p.slotId),
                reason: reason,
                busy: widget.busy,
                reasonError: errors['override_reason'],
                onChanged: (v) => setState(() => _pick[p.slotId] = v),
              ),
            ),
            ListenableBuilder(
              listenable: reason,
              builder: (context, _) {
                final given = DutyOverride.clean(reason.text);
                // A planned person can be kept with a new reason (after
                // Publish N named an overlap that appeared later).
                final newReason =
                    draft &&
                    !changed &&
                    picked != null &&
                    given != null &&
                    given != p.draft?.overrideReason;
                return FocusRing(
                  child: TextButton(
                    key: Key('rota-save-${p.slotId}'),
                    onPressed:
                        widget.busy ||
                            !(changed || newReason) ||
                            (!draft && picked == null)
                        ? null
                        : () => ref
                              .read(dutyRotaProvider.notifier)
                              .assignSlot(
                                o,
                                p,
                                picked,
                                lead: draft ? null : DutyLeads.wire(_lead),
                                subject: p.label,
                                overrideReason: reason.text,
                              ),
                    child: Text(
                      newReason
                          ? 'Save the reason'
                          : draft
                          ? 'Save plan'
                          : 'Give this position',
                    ),
                  ),
                );
              },
            ),
            if (errors['member_id'] case final e?)
              _errorLine(
                context,
                _rotaError(e),
                key: Key('rota-position-error-${p.slotId}'),
              ),
          ],
        ],
      ),
    );
  }

  Widget _changeForm(BuildContext context, DutyRotaController ctl) {
    final id = widget.occurrence.occurrenceId;
    final errors = _errorsFor({DutyCommands.revise, DutyCommands.reviseSeries});
    String? err(List<String> wires) {
      for (final w in wires) {
        if (errors[w] case final e?) return _rotaError(e);
      }
      return null;
    }

    final named = _namedDate(widget.series, errors);
    final leadError = err(['deadline_before', 'response_deadline']);
    final memberError = err(['member_id']);
    final reasonError = errors['override_reason'];

    Widget field(
      String key,
      TextEditingController c,
      String label, {
      List<String> wires = const [],
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
          errorText: err(wires),
        ),
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        field('rota-edit-name', _name, 'Duty', wires: ['duty_name']),
        field(
          'rota-edit-start',
          _start,
          'Start time',
          hint: 'HH:MM',
          maxLength: 5,
          wires: ['starts_at', 'start_time'],
        ),
        field(
          'rota-edit-end',
          _end,
          'End time (optional; earlier than the start means the next day)',
          hint: 'HH:MM',
          maxLength: 5,
          wires: ['ends_at', 'end_time'],
        ),
        field(
          'rota-edit-reporting',
          _reporting,
          'Reporting time (optional)',
          hint: 'HH:MM',
          maxLength: 5,
          wires: ['reporting_at', 'reporting_time'],
        ),
        field(
          'rota-edit-location',
          _location,
          'Location (optional)',
          maxLength: 120,
          wires: ['location'],
        ),
        field(
          'rota-edit-instructions',
          _instructions,
          'Instructions (optional)',
          maxLength: 1000,
          maxLines: 3,
          wires: ['instructions'],
        ),
        field(
          'rota-edit-topic',
          _topic,
          'Topic (optional)',
          maxLength: 120,
          wires: ['topic'],
        ),
        field(
          'rota-edit-scripture',
          _scripture,
          'Scripture (optional)',
          maxLength: 120,
          wires: ['scripture'],
        ),
        ListenableBuilder(
          listenable: Listenable.merge(_all),
          builder: (context, _) {
            final edit = _edit;
            final changed = edit.readable ? edit.changed : const <String>[];
            final published = widget.occurrence.state == RotaState.published;
            final asks = edit.readable && edit.needsLead;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (changed.isNotEmpty)
                  Text(
                    !published
                        ? 'Draft: changed ${DutyFields.describe(changed)}. '
                              'Nobody is told until you publish.'
                        : asks
                        ? 'Everyone assigned is asked to answer again '
                              '(changed: ${DutyFields.describe(changed)}); '
                              'their earlier answers are kept. People who '
                              'declined are asked again too.'
                        : 'Only ${DutyFields.describe(changed)} change: '
                              'answers stand.',
                    key: Key('rota-edit-summary-$id'),
                  ),
                if (asks ||
                    (_future && edit.readable && edit.material) ||
                    leadError != null)
                  _leadPicker('rota-edit-lead-$id', error: leadError),
                if (memberError != null)
                  _errorLine(
                    context,
                    memberError,
                    key: Key('rota-edit-member-error-$id'),
                  ),
                if (reasonError != null || _changeReason.text.isNotEmpty)
                  TextField(
                    key: Key('rota-edit-reason-$id'),
                    controller: _changeReason,
                    enabled: !widget.busy,
                    maxLength: DutyOverride.maxLength,
                    maxLines: 2,
                    decoration: InputDecoration(
                      labelText:
                          'Someone assigned has another duty at the new time. '
                          'Why keep them? (required)',
                      helperText:
                          'Recorded for every overlapping position of this '
                          'change; they still choose whether to accept.',
                      helperMaxLines: 2,
                      errorText: reasonError == null
                          ? null
                          : 'Give a reason, or choose other times',
                    ),
                  ),
                if (named != null && named.occurrenceId != id)
                  Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: FocusRing(
                      child: TextButton(
                        key: Key('rota-edit-open-${named.occurrenceId}'),
                        onPressed: () => widget.onOpen(named.occurrenceId),
                        child: Text(
                          'The problem is on '
                          '${_when(context, named.times.startsAt)}: open it',
                        ),
                      ),
                    ),
                  ),
                Wrap(
                  spacing: 8,
                  children: [
                    FocusRing(
                      child: FilledButton(
                        key: Key('rota-edit-save-$id'),
                        onPressed: widget.busy || changed.isEmpty
                            ? null
                            : () => _future
                                  ? ctl.reviseFuture(widget.series, edit)
                                  : ctl.reviseThis(edit),
                        child: Text(
                          _future
                              ? 'Save for this and later dates'
                              : 'Save for this date',
                        ),
                      ),
                    ),
                    FocusRing(
                      child: TextButton(
                        key: Key('rota-edit-close-$id'),
                        onPressed: () => setState(() => _mode = _Mode.view),
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
    );
  }

  Widget _cancelConfirm(BuildContext context, DutyRotaController ctl) {
    final o = widget.occurrence;
    final id = o.occurrenceId;
    final later = widget.series.occurrences
        .where(
          (x) =>
              x.open &&
              x.seriesDate.compareTo(o.seriesDate) >= 0 &&
              x.state != RotaState.cancelled,
        )
        .length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '${_future ? 'Cancel $later ${later == 1 ? 'date' : 'dates'} from '
                    '${_when(context, o.times.startsAt)}? Earlier dates are '
                    'kept.' : 'Cancel ${_when(context, o.times.startsAt)} only?'} '
          'People who were waiting to answer or had accepted get a "Duty '
          'cancelled" notice; people who declined and draft dates get none. '
          'Answers are kept in the history.',
          key: Key('rota-cancel-summary-$id'),
        ),
        Wrap(
          spacing: 8,
          children: [
            FocusRing(
              child: FilledButton(
                key: Key('rota-cancel-confirm-$id'),
                onPressed: widget.busy
                    ? null
                    : () => _future
                          ? ctl.cancelFuture(widget.series, o)
                          : ctl.cancelThis(o),
                child: Text(
                  _future ? 'Cancel these dates' : 'Cancel this date',
                ),
              ),
            ),
            FocusRing(
              child: TextButton(
                key: Key('rota-cancel-close-$id'),
                onPressed: () => setState(() => _mode = _Mode.view),
                child: const Text('Keep it'),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// Generate a repeating rota as drafts.
class _NewSeriesForm extends ConsumerStatefulWidget {
  const _NewSeriesForm({
    required this.department,
    required this.busy,
    required this.onClose,
  });
  final RotaDepartment department;
  final bool busy;
  final VoidCallback onClose;

  @override
  ConsumerState<_NewSeriesForm> createState() => _NewSeriesFormState();
}

class _NewSeriesFormState extends ConsumerState<_NewSeriesForm> {
  final _name = TextEditingController();
  final _interval = TextEditingController(text: '1');
  final _from = TextEditingController();
  final _until = TextEditingController();
  final _start = TextEditingController();
  final _end = TextEditingController();
  final _reporting = TextEditingController();
  final _location = TextEditingController();
  final _instructions = TextEditingController();
  final _topic = TextEditingController();
  final _scripture = TextEditingController();
  final _positions = TextEditingController();
  String _every = 'week';

  /// Story 4.8: the creator's member reminders for every date (off = the
  /// defaults).
  bool _customReminders = false;
  final Set<DutyReminderSpec> _reminders = {};

  List<TextEditingController> get _all => [
    _name,
    _interval,
    _from,
    _until,
    _start,
    _end,
    _reporting,
    _location,
    _instructions,
    _topic,
    _scripture,
    _positions,
  ];

  @override
  void dispose() {
    for (final c in _all) {
      c.dispose();
    }
    super.dispose();
  }

  SeriesDraft? get _draft => SeriesDraft.parse(
    departmentId: widget.department.departmentId,
    dutyName: _name.text,
    every: _every,
    interval: _interval.text,
    fromDate: _from.text,
    untilDate: _until.text,
    startTime: _start.text,
    endTime: _end.text,
    reportingTime: _reporting.text,
    location: _location.text,
    instructions: _instructions.text,
    topic: _topic.text,
    scripture: _scripture.text,
    positions: _positions.text,
  );

  @override
  Widget build(BuildContext context) {
    final id = widget.department.departmentId;
    final s = ref.watch(dutyRotaProvider);
    final mine = s.noticeAction?.command == DutyCommands.createSeries;
    final errors = mine ? s.fieldErrors : const <String, String>{};
    String? err(String wire) => switch (errors[wire]) {
      null => null,
      'required' => 'Required',
      'too_many' => 'At most 60 dates: choose an earlier end date',
      'out_of_range' => 'Too far: at most a year from the first date',
      'before_from' => 'Must be on or after the first date',
      'after_start' => 'Must be before the start',
      'duplicate' => 'Each position needs a different name',
      'no_occurrences' => 'No future date in this range',
      'past' => 'This is in the past',
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
    return _Card(
      key: Key('rota-new-form-$id'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _heading(context, 'New rota'),
          _muted(
            context,
            'The dates are made as drafts: plan who takes each position, '
            'then publish. Church time (Lusaka).',
          ),
          const SizedBox(height: 8),
          field('series-name', _name, 'Duty', wire: 'duty_name'),
          Row(
            children: [
              const Text('Repeats every '),
              SizedBox(
                width: 64,
                child: TextField(
                  key: Key('series-interval-$id'),
                  controller: _interval,
                  enabled: !widget.busy,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(errorText: err('interval')),
                ),
              ),
              const SizedBox(width: 8),
              DropdownButton<String>(
                key: Key('series-every-$id'),
                value: _every,
                items: const [
                  DropdownMenuItem(value: 'day', child: Text('day(s)')),
                  DropdownMenuItem(value: 'week', child: Text('week(s)')),
                  DropdownMenuItem(value: 'month', child: Text('month(s)')),
                ],
                onChanged: widget.busy
                    ? null
                    : (v) => setState(() => _every = v ?? _every),
              ),
            ],
          ),
          field(
            'series-from',
            _from,
            'First date',
            hint: 'YYYY-MM-DD',
            wire: 'from_date',
            maxLength: 10,
          ),
          field(
            'series-until',
            _until,
            'Last date',
            hint: 'YYYY-MM-DD',
            wire: 'until_date',
            maxLength: 10,
          ),
          field(
            'series-start',
            _start,
            'Start time',
            hint: 'HH:MM',
            wire: 'start_time',
            maxLength: 5,
          ),
          field(
            'series-end',
            _end,
            'End time (optional)',
            hint: 'HH:MM',
            wire: 'end_time',
            maxLength: 5,
          ),
          field(
            'series-reporting',
            _reporting,
            'Reporting time (optional)',
            hint: 'HH:MM',
            wire: 'reporting_time',
            maxLength: 5,
          ),
          field(
            'series-positions',
            _positions,
            'Positions, separated by commas (e.g. Preacher, Reader, Usher)',
            wire: 'positions',
            maxLength: 600,
          ),
          field(
            'series-location',
            _location,
            'Location (optional)',
            wire: 'location',
            maxLength: 120,
          ),
          field(
            'series-instructions',
            _instructions,
            'Instructions (optional)',
            wire: 'instructions',
            maxLength: 1000,
            maxLines: 3,
          ),
          field(
            'series-topic',
            _topic,
            'Topic (optional)',
            wire: 'topic',
            maxLength: 120,
          ),
          field(
            'series-scripture',
            _scripture,
            'Scripture (optional)',
            wire: 'scripture',
            maxLength: 120,
          ),
          // Story 4.8: the member reminders of every date.
          _ReminderChoice(
            keyPrefix: 'series-$id',
            custom: _customReminders,
            selected: _reminders,
            enabled: !widget.busy,
            error: errors['reminders'],
            onCustom: (v) => setState(() => _customReminders = v),
            onToggle: (c, on) =>
                setState(() => on ? _reminders.add(c) : _reminders.remove(c)),
          ),
          ListenableBuilder(
            listenable: Listenable.merge(_all),
            builder: (context, _) {
              final draft = _draft;
              return Wrap(
                spacing: 8,
                children: [
                  FocusRing(
                    child: FilledButton(
                      key: Key('series-create-$id'),
                      onPressed: widget.busy || draft == null
                          ? null
                          : () => ref
                                .read(dutyRotaProvider.notifier)
                                .createSeries(
                                  draft.withReminders(
                                    _chosenReminders(
                                      _customReminders,
                                      _reminders,
                                    ),
                                  ),
                                ),
                      child: const Text('Make the draft dates'),
                    ),
                  ),
                  FocusRing(
                    child: TextButton(
                      key: Key('series-close-$id'),
                      onPressed: widget.onClose,
                      child: const Text('Close'),
                    ),
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

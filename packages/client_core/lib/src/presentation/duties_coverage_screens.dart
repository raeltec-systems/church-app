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

/// What needs a leader's action, zeros printed as zeros (the summary's
/// footer and a phone row's second line).
String _covActionCounts(CoverageCounts c) => [
  '${c.unfilled} unfilled',
  '${c.overdue} overdue',
  '${c.declined} declined or changed',
  '${c.needsContact} need contact',
].join(' · ');

/// A church date (`YYYY-MM-DD`) in words ("Thu, Jan 1").
String _covDay(BuildContext context, String ymd) =>
    MaterialLocalizations.of(context).formatMediumDate(
      DateTime.utc(
        int.parse(ymd.substring(0, 4)),
        int.parse(ymd.substring(5, 7)),
        int.parse(ymd.substring(8, 10)),
      ),
    );

/// Controls in the toolbar and on a row: 40 px on staff web, the 44 px
/// target on the phone.
double _covControlHeight(BuildContext context) =>
    isStaffLayout(context) ? 40 : ChurchGeometry.minTarget;

/// Staff web buttons take no extra invisible height (a mouse needs none);
/// the phone keeps the padded 48 px target.
MaterialTapTargetSize _covTarget(BuildContext context) => isStaffLayout(context)
    ? MaterialTapTargetSize.shrinkWrap
    : MaterialTapTargetSize.padded;

const _covButtonText = TextStyle(
  fontFamily: ChurchFonts.body,
  fontSize: 14,
  fontWeight: FontWeight.w600,
);

ButtonStyle _covOutlined(BuildContext context) => OutlinedButton.styleFrom(
  minimumSize: Size(64, _covControlHeight(context)),
  padding: const EdgeInsets.symmetric(horizontal: 14),
  tapTargetSize: _covTarget(context),
  textStyle: _covButtonText,
);

ButtonStyle _covFilled(BuildContext context) => FilledButton.styleFrom(
  minimumSize: Size(64, _covControlHeight(context)),
  padding: const EdgeInsets.symmetric(horizontal: 16),
  tapTargetSize: _covTarget(context),
  textStyle: _covButtonText,
);

ButtonStyle _covText(BuildContext context, {Color? color}) =>
    TextButton.styleFrom(
      minimumSize: Size(48, _covControlHeight(context)),
      padding: const EdgeInsets.symmetric(horizontal: 10),
      tapTargetSize: _covTarget(context),
      textStyle: _covButtonText,
      foregroundColor: color,
    );

/// A text action inside a line of text (Call, Message, the follow-up
/// task): 32 px on staff web, the 44 px target on the phone.
ButtonStyle _covLink(BuildContext context) {
  final staff = isStaffLayout(context);
  return TextButton.styleFrom(
    minimumSize: Size(40, staff ? 32 : ChurchGeometry.minTarget),
    padding: const EdgeInsets.symmetric(horizontal: 8),
    tapTargetSize: _covTarget(context),
    textStyle: _covButtonText,
  );
}

/// A form's parts with 12 px between them.
List<Widget> _covSpaced(List<Widget> parts) => [
  for (var i = 0; i < parts.length; i++) ...[
    if (i > 0) const SizedBox(height: 12),
    parts[i],
  ],
];

/// An outlined toolbar field with its label kept on the border.
InputDecoration _covField(String label, {String? error}) => InputDecoration(
  labelText: label,
  errorText: error,
  counterText: '',
  isDense: true,
  floatingLabelBehavior: FloatingLabelBehavior.always,
  contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
);

/// Story 4.9: `/duties/coverage`.
class DutyCoverageScreen extends StatelessWidget {
  const DutyCoverageScreen({super.key});

  @override
  Widget build(BuildContext context) => _DutiesPage<DutyCoverage>(
    title: 'Coverage',
    subtitle: 'Positions still to fill, answer or confirm',
    provider: dutyCoverageProvider,
    needs: _coverageNeeds,
    loading: 'Loading coverage…',
    body: (context, value, state) => _CoverageBody(value: value, state: state),
  );
}

/// The queue, in reading order: the days and duties asked for (one
/// toolbar row), the navy summary answering how many positions are
/// confirmed, Pastor's and the Admin's church-wide table of gaps, the
/// filter pills with their counts, then each department's positions.
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

  /// The query as one row: the first day, how many days, a duty name and
  /// (with more than one) the department; Show asks the server again.
  Widget _toolbar(BuildContext context, DutyCoverage v, bool busy) => Wrap(
    spacing: 12,
    runSpacing: 12,
    crossAxisAlignment: WrapCrossAlignment.center,
    children: [
      SizedBox(
        width: 168,
        child: TextField(
          key: const Key('coverage-from'),
          controller: _from,
          decoration: _covField('From (YYYY-MM-DD)', error: _fromError),
        ),
      ),
      SizedBox(
        width: 120,
        child: DropdownButtonFormField<int>(
          key: const Key('coverage-days'),
          initialValue: _days,
          isDense: true,
          isExpanded: true,
          decoration: _covField('Days'),
          items: [
            for (final d in const [7, 14, 31])
              DropdownMenuItem(
                value: d,
                child: Text('$d days', overflow: TextOverflow.ellipsis),
              ),
          ],
          onChanged: (d) => setState(() => _days = d ?? 7),
        ),
      ),
      SizedBox(
        width: 220,
        child: TextField(
          key: const Key('coverage-duty'),
          controller: _duty,
          maxLength: 80,
          decoration: _covField('Duty name contains'),
        ),
      ),
      if (v.departments.length > 1 || _department != null)
        SizedBox(
          width: 220,
          child: DropdownButtonFormField<String?>(
            key: const Key('coverage-department'),
            initialValue: _department,
            isDense: true,
            isExpanded: true,
            decoration: _covField('Department'),
            items: [
              const DropdownMenuItem<String?>(
                value: null,
                child: Text('All departments'),
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
          key: const Key('coverage-apply'),
          style: _covOutlined(context),
          onPressed: busy ? null : _apply,
          child: const Text('Show'),
        ),
      ),
    ],
  );

  /// The navy summary: the days asked for, how many positions are
  /// confirmed (with the bar at its true ratio) and what needs action.
  Widget _summary(BuildContext context, DutyCoverage v) {
    final t = v.totals;
    final range =
        '${_covDay(context, v.from)} to ${_covDay(context, v.to)}, church time';
    final scope = v.duty == null
        ? range
        : '$range, duties matching "${v.duty}"';
    final none = t.required == 0;
    return StaffSummaryBand(
      key: const Key('coverage-band'),
      title: scope,
      meta: v.departments.length == 1
          ? v.departments.single.name
          : '${v.departments.length} departments',
      headline: none
          ? 'No positions to cover'
          : '${t.confirmed} of ${t.required} confirmed',
      value: none ? null : t.confirmed,
      max: none ? null : t.required,
      footer: none
          ? 'No published duty in these days has a position.'
          : _covActionCounts(t),
      semanticLabel: none
          ? '$scope. No positions to cover.'
          : '$scope. ${t.confirmed} of ${t.required} positions confirmed. '
                '${_covActionCounts(t).replaceAll(' · ', ', ')}.',
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = ChurchColors.of(context);
    final v = widget.value;
    final busy = widget.state.busy;
    final operational = v.departments.where((d) => !d.full).toList();
    final all = [for (final d in v.departments) ...d.positions];
    final children = <Widget>[
      _toolbar(context, v, busy),
      const SizedBox(height: 16),
      if (v.truncated) ...[
        const RequestStateBanner(
          key: Key('coverage-truncated'),
          tone: StatusTone.warning,
          title: 'Showing the first 1000 positions',
          message:
              'The counts cover every position; choose fewer days or one '
              'department to list the rest.',
        ),
        const SizedBox(height: 16),
      ],
    ];
    if (v.departments.isEmpty) {
      // An empty queue keeps its frame and says so in one sentence.
      children.add(
        ChurchCard(
          radius: churchCardRadiusOf(context),
          child: Text(
            'No departments to show.',
            style: ChurchType.secondary.copyWith(color: c.muted),
          ),
        ),
      );
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      );
    }
    children.addAll([_summary(context, v), const SizedBox(height: 16)]);
    // Pastor's (and the Admin's) church-wide view of gaps.
    if (operational.isNotEmpty) {
      children.addAll([
        _CovChurchTable(value: v),
        const SizedBox(height: ChurchGeometry.sectionGap),
      ]);
    }
    children.add(
      // The pills' focus rings inset them 4 px: start them on the edge.
      Transform.translate(
        offset: const Offset(-4, 0),
        child: StaffFilterPills<CoverageFilter>(
          label: 'Show positions',
          selected: _filter,
          onChanged: (f) => setState(() => _filter = f),
          options: [
            for (final f in CoverageFilter.values)
              StaffFilterOption(
                f,
                f.label,
                count: all.where(f.matches).length,
                key: Key('coverage-filter-${f.name}'),
              ),
          ],
        ),
      ),
    );
    for (final d in v.departments) {
      children.addAll([
        const SizedBox(height: 12),
        _CovDepartment(
          department: d,
          filter: _filter,
          busy: busy,
          fieldErrors: widget.state.fieldErrors,
          lastAction: widget.state.noticeAction,
        ),
      ]);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    );
  }
}

/// Pastor's and the Admin's church-wide gaps as a table: one department
/// per row, its confirmed positions against those required (with a thin
/// bar at the true ratio) and what needs action, numbers right-aligned in
/// tabular figures, then the total of the rows. Below 640 px each
/// department is a two-line row.
class _CovChurchTable extends StatelessWidget {
  const _CovChurchTable({required this.value});

  final DutyCoverage value;

  static const _columns = [
    StaffColumn('Department', flex: 3),
    StaffColumn('Confirmed', width: 120, numeric: true),
    StaffColumn('Unfilled', width: 104, numeric: true),
    StaffColumn('Overdue', width: 104, numeric: true),
    StaffColumn('Declined or changed', width: 168, numeric: true),
    StaffColumn('Need contact', width: 128, numeric: true),
  ];

  @override
  Widget build(BuildContext context) {
    final rows = value.departments;
    return StaffSection(
      key: const Key('coverage-church-wide'),
      title: 'Gaps across the church',
      subtitle:
          'Operational view: positions and their state only. Contact details '
          'and notes are for each department\'s leaders and deputies.',
      bodyPadding: EdgeInsets.zero,
      child: LayoutBuilder(
        builder: (context, box) {
          final wide = box.maxWidth >= 640;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (wide) const StaffTableHeader(columns: _columns),
              for (var i = 0; i < rows.length; i++)
                _row(
                  context,
                  key: Key('coverage-summary-${rows[i].departmentId}'),
                  name: rows[i].name,
                  counts: rows[i].counts,
                  wide: wide,
                  divider: i > 0,
                ),
              _row(
                context,
                key: const Key('coverage-church-totals'),
                name: 'All departments',
                counts: value.totals,
                wide: wide,
                divider: true,
                total: true,
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _row(
    BuildContext context, {
    required Key key,
    required String name,
    required CoverageCounts counts,
    required bool wide,
    required bool divider,
    bool total = false,
  }) {
    final c = ChurchColors.of(context);
    final nameStyle = ChurchType.staffBody.copyWith(
      color: c.ink,
      fontWeight: total ? FontWeight.w700 : FontWeight.w600,
    );
    Widget figure(int n) => Text(
      '$n',
      style: staffFigureStyle(context).copyWith(
        color: n > 0 ? c.ink : c.muted,
        fontWeight: n > 0 ? FontWeight.w600 : FontWeight.w400,
      ),
    );
    final confirmed = counts.required == 0
        // No positions: "confirmed of" does not apply.
        ? Text('—', style: staffFigureStyle(context).copyWith(color: c.muted))
        : Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '${counts.confirmed} of ${counts.required}',
                style: staffFigureStyle(context)
                    .copyWith(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 4),
              SizedBox(
                width: 64,
                child: StaffProgressBar(
                  value: counts.confirmed,
                  max: counts.required,
                  height: 4,
                ),
              ),
            ],
          );
    final body = wide
        ? StaffColumnsRow(
            columns: _columns,
            cells: [
              Text(name, style: nameStyle),
              confirmed,
              figure(counts.unfilled),
              figure(counts.overdue),
              figure(counts.declined),
              figure(counts.needsContact),
            ],
          )
        : Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(child: Text(name, style: nameStyle)),
                  const SizedBox(width: 12),
                  Text(
                    counts.required == 0
                        ? 'No positions'
                        : '${counts.confirmed} of ${counts.required} '
                              'confirmed',
                    style: staffFigureStyle(context)
                        .copyWith(fontWeight: FontWeight.w600),
                  ),
                ],
              ),
              const SizedBox(height: 2),
              Text(
                _covActionCounts(counts),
                style: ChurchType.secondary.copyWith(
                  color: c.muted,
                  fontSize: 13,
                ),
              ),
            ],
          );
    return StaffTableRow(
      key: key,
      divider: divider,
      padding: EdgeInsets.fromLTRB(wide ? 20 : 16, 10, wide ? 20 : 16, 10),
      child: Semantics(
        container: true,
        label: '$name: ${_countsText(counts)}',
        excludeSemantics: true,
        child: body,
      ),
    );
  }
}

/// One department of the queue: a white card whose head names it with its
/// counts (and, for Pastor and the Admin, what they may do), then its
/// positions as rows split by 1 px lines.
class _CovDepartment extends StatelessWidget {
  const _CovDepartment({
    required this.department,
    required this.filter,
    required this.busy,
    required this.fieldErrors,
    required this.lastAction,
  });

  final CoverageDepartment department;
  final CoverageFilter filter;
  final bool busy;
  final Map<String, String> fieldErrors;
  final DutyAction? lastAction;

  @override
  Widget build(BuildContext context) {
    final c = ChurchColors.of(context);
    final d = department;
    final shown = d.positions.where(filter.matches).toList();
    final pad = isStaffLayout(context) ? 20.0 : 16.0;
    final quiet = ChurchType.secondary.copyWith(color: c.muted, fontSize: 13);
    return ChurchCard(
      radius: churchCardRadiusOf(context),
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: EdgeInsets.fromLTRB(pad, 14, pad, 12),
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
                    key: Key('coverage-dept-${d.departmentId}'),
                    style: ChurchType.cardTitle.copyWith(
                      color: c.ink,
                      fontSize: 17,
                    ),
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  _countsText(d.counts),
                  key: Key('coverage-counts-${d.departmentId}'),
                  style: quiet,
                ),
                if (!d.full)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      d.canManage
                          ? 'Admin view: you can reassign or cancel positions; '
                                'contact details and notes are for the '
                                'department\'s leaders.'
                          : 'Pastor oversight (read only).',
                      style: quiet,
                    ),
                  ),
              ],
            ),
          ),
          if (shown.isEmpty)
            Padding(
              padding: EdgeInsets.fromLTRB(pad, 16, pad, 18),
              child: Text(
                filter == CoverageFilter.all
                    ? 'No duties in these dates.'
                    : 'Nothing here for "${filter.label}".',
                style: ChurchType.secondary.copyWith(color: c.muted),
              ),
            ),
          for (var i = 0; i < shown.length; i++)
            _CoverageCard(
              key: Key('coverage-card-${shown[i].slotId}'),
              department: d,
              position: shown[i],
              busy: busy,
              fieldErrors: fieldErrors,
              lastAction: lastAction,
              divider: i > 0,
            ),
        ],
      ),
    );
  }
}

enum _CoverageForm { none, attempt, confirm, assign, cancel }

/// One position of the queue in the handoff's shape: who has it (or No one
/// assigned) with its one status mark, the position, when and where in
/// grey, what is known about the answer, the contact routes, then the
/// actions, the one that resolves it filled. On wide screens the status
/// sits in a column of its own so a department reads down by state.
class _CoverageCard extends ConsumerStatefulWidget {
  const _CoverageCard({
    super.key,
    required this.department,
    required this.position,
    required this.busy,
    required this.fieldErrors,
    required this.lastAction,
    this.divider = false,
  });

  final CoverageDepartment department;
  final CoveragePosition position;
  final bool busy;
  final Map<String, String> fieldErrors;
  final DutyAction? lastAction;

  /// A 1 px line above (every row but the department's first).
  final bool divider;

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
    final c = ChurchColors.of(context);
    final layout = ChurchLayout.of(context);
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
    final nameStyle = layout.body.copyWith(
      color: c.ink,
      fontWeight: FontWeight.w600,
      height: 1.3,
    );
    final detail = ChurchType.secondary.copyWith(color: c.ink);
    final quiet = ChurchType.secondary.copyWith(color: c.muted);

    // The one status mark of the row.
    final status = StatusLabel(
      key: Key('coverage-status-${p.slotId}'),
      label: a?.confirmedByLeader ?? false
          ? 'Confirmed by leader'
          : (a?.priorAcceptedAt != null && a?.response == DutyResponse.declined
                ? 'Can\'t make it anymore'
                : p.status.label),
      tone: _coverageTone(p.status),
    );
    final who = a == null
        ? Text('No one assigned', style: nameStyle)
        : Text.rich(
            key: Key('coverage-who-${p.slotId}'),
            TextSpan(
              children: [
                TextSpan(text: a.name, style: nameStyle),
                if (a.account == AccountStanding.noLogin)
                  TextSpan(
                    text: ' (no login: contact them directly)',
                    style: quiet,
                  ),
              ],
            ),
          );
    final where = [
      p.positionName ?? p.dutyName,
      if (p.positionName != null) p.dutyName,
      _timesText(context, p.times),
      ?p.location,
    ].join(' · ');

    // What is known about the answer, one line each.
    final lines = <Widget>[
      if (a != null && a.response == DutyResponse.pending)
        Text(
          'Answer by ${_when(context, a.responseDeadline)}'
          '${a.deadlineSource == DutyDeadlineSource.churchDefault ? ' (church default)' : ''}',
          style: detail,
        ),
      if (a?.confirmation case final cf?)
        Text(
          'Confirmed by leader ${_channelPast(cf.channel)}'
          '${cf.by == null ? '' : ', recorded by ${cf.by}'}, '
          '${_when(context, cf.at)}'
          '${cf.reason == null ? '' : ': "${cf.reason}"'}',
          key: Key('coverage-confirmation-${p.slotId}'),
          style: detail,
        ),
      if (a?.changes case final ch? when p.status == CoverageStatus.changed)
        Text(
          'Changed: ${DutyFields.describe(ch)}. They are asked again.',
          style: detail,
        ),
      if (a?.note case final n?) Text('Their note: "$n"', style: detail),
    ];
    if (p.followUp case final f?) {
      final last = f.lastAttempt;
      lines.addAll([
        Text(
          '${f.attempts} contact ${f.attempts == 1 ? 'attempt' : 'attempts'}; '
          'latest ${_when(context, last.at)} ${_channelPast(last.channel)}'
          '${last.by == null ? '' : ' by ${last.by}'}: ${last.outcome.label}'
          '${last.note == null ? '' : ' ("${last.note}")'}.',
          key: Key('coverage-attempts-${p.slotId}'),
          style: detail,
        ),
        Wrap(
          spacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(
              'Next follow-up ${_when(context, f.nextFollowUpAt)}'
              '${f.overdue ? ' (overdue)' : ''}',
              key: Key('coverage-next-${p.slotId}'),
              style: f.overdue
                  ? detail.copyWith(color: c.redFg, fontWeight: FontWeight.w600)
                  : detail,
            ),
            if (f.taskId case final t?)
              FocusRing(
                child: TextButton(
                  key: Key('coverage-task-${p.slotId}'),
                  style: _covLink(context),
                  onPressed: () => context.go(FollowUpPaths.task(t)),
                  child: const Text('Open the follow-up task'),
                ),
              ),
          ],
        ),
      ]);
    }
    // Facts that are not the status: grey words, never a second chip.
    if (p.vacated) {
      lines.add(
        Text(
          'Needs a new person: the person given this position can no longer '
          'serve it. Give it to someone else.',
          key: Key('coverage-vacated-${p.slotId}'),
          style: quiet,
        ),
      );
      // Story 4.16: the coarse reason, for the department's leaders and
      // deputies only (the server sends nothing to anyone else).
      if (p.vacancyReason case final r?) {
        lines.add(
          Text(
            'Reason: ${DutyVacancyReasons.label(r)}',
            key: Key('coverage-vacancy-reason-${p.slotId}'),
            style: quiet,
          ),
        );
      }
    }
    if (p.needsContact case final nc?) {
      lines.add(
        Text(
          'Needs contact: ${nc.text}',
          key: Key('coverage-needs-contact-${p.slotId}'),
          style: quiet,
        ),
      );
    }
    final facts = [
      if (a?.shortNotice ?? false) 'Given at short notice',
      if (p.overlaps > 0)
        'Overlaps ${p.overlaps} other ${p.overlaps == 1 ? 'duty' : 'duties'}',
    ];
    if (facts.isNotEmpty) lines.add(Text(facts.join(' · '), style: quiet));
    if (routes.isNotEmpty && a?.response != DutyResponse.accepted) {
      for (final r in routes) {
        lines.add(
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text('${r.label}: ', style: quiet),
              Text(r.phone, style: staffFigureStyle(context)),
              const SizedBox(width: 8),
              FocusRing(
                child: TextButton(
                  key: Key('coverage-call-${p.slotId}-${r.phone}'),
                  style: _covLink(context),
                  onPressed: () => _contact(r, true),
                  child: const Text('Call'),
                ),
              ),
              FocusRing(
                child: TextButton(
                  key: Key('coverage-message-${p.slotId}-${r.phone}'),
                  style: _covLink(context),
                  onPressed: () => _contact(r, false),
                  child: const Text('Message'),
                ),
              ),
            ],
          ),
        );
      }
    }
    if (_launch case final l?) {
      lines.add(
        Text(l, key: Key('coverage-launch-${p.slotId}'), style: detail),
      );
    }
    if (own && p.contactable) {
      lines.add(
        Text('This is your own duty: answer it in My duties.', style: quiet),
      );
    }

    // The action that resolves the row is filled: a person for an empty,
    // declined, changed or overdue position; the rest are outlined, and
    // cancelling is a red text action (its form is the confirmation).
    final needsPerson =
        p.vacated ||
        const {
          CoverageStatus.unfilled,
          CoverageStatus.declined,
          CoverageStatus.changed,
          CoverageStatus.overdue,
        }.contains(p.status);
    final actions = <Widget>[
      if (d.canManage && !started)
        FocusRing(
          child: needsPerson
              ? FilledButton(
                  key: Key('coverage-assign-${p.slotId}'),
                  style: _covFilled(context),
                  onPressed: busy ? null : () => _open(_CoverageForm.assign),
                  child: Text(a == null ? 'Assign' : 'Reassign'),
                )
              : OutlinedButton(
                  key: Key('coverage-assign-${p.slotId}'),
                  style: _covOutlined(context),
                  onPressed: busy ? null : () => _open(_CoverageForm.assign),
                  child: Text(a == null ? 'Assign' : 'Reassign'),
                ),
        ),
      if (d.canContact && p.confirmable && !started && !own)
        FocusRing(
          child: OutlinedButton(
            key: Key('coverage-confirm-${p.slotId}'),
            style: _covOutlined(context),
            onPressed: busy ? null : () => _open(_CoverageForm.confirm),
            child: const Text('Confirmed by leader'),
          ),
        ),
      if (d.canContact && p.contactable && !started && !own)
        FocusRing(
          child: OutlinedButton(
            key: Key('coverage-attempt-${p.slotId}'),
            style: _covOutlined(context),
            onPressed: busy ? null : () => _open(_CoverageForm.attempt),
            child: const Text('Record contact attempt'),
          ),
        ),
      if (d.canManage && !started)
        FocusRing(
          child: TextButton(
            key: Key('coverage-cancel-${p.slotId}'),
            style: _covText(context, color: c.redFg),
            onPressed: busy ? null : () => _open(_CoverageForm.cancel),
            child: const Text('Cancel position'),
          ),
        ),
    ];
    final form = switch (_form) {
      _CoverageForm.none => null,
      _CoverageForm.attempt => _attemptForm(context, errors),
      _CoverageForm.confirm => _confirmForm(context, errors),
      _CoverageForm.assign => _assignForm(context, errors),
      _CoverageForm.cancel => _cancelForm(context),
    };

    List<Widget> body({required bool statusBeside}) => [
      if (statusBeside)
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: who),
            const SizedBox(width: 8),
            status,
          ],
        )
      else
        who,
      const SizedBox(height: 2),
      Text(where, style: quiet),
      if (lines.isNotEmpty) ...[
        const SizedBox(height: 6),
        for (var i = 0; i < lines.length; i++) ...[
          if (i > 0) const SizedBox(height: 2),
          lines[i],
        ],
      ],
      if (actions.isNotEmpty) ...[
        const SizedBox(height: 6),
        Wrap(
          spacing: 0,
          runSpacing: 0,
          crossAxisAlignment: WrapCrossAlignment.center,
          // The focus rings' own 4 px inset aligns the first button with
          // the text above.
          children: [
            for (final b in actions)
              Transform.translate(offset: const Offset(-4, 0), child: b),
          ],
        ),
      ],
      if (form != null) ...[
        const SizedBox(height: 8),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: Container(
            constraints: const BoxConstraints(maxWidth: 600),
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: c.bg,
              border: Border.all(color: c.line),
              borderRadius: BorderRadius.circular(10),
            ),
            child: form,
          ),
        ),
      ],
    ];

    final staff = isStaffLayout(context);
    return Container(
      padding: EdgeInsets.fromLTRB(staff ? 20 : 16, 14, staff ? 20 : 16, 14),
      decoration: BoxDecoration(
        border: widget.divider ? Border(top: BorderSide(color: c.line)) : null,
      ),
      child: LayoutBuilder(
        builder: (context, box) {
          if (box.maxWidth < 640) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: body(statusBeside: true),
            );
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 188,
                child: Padding(
                  padding: const EdgeInsets.only(top: 1),
                  child: Align(
                    alignment: AlignmentDirectional.topStart,
                    child: status,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: body(statusBeside: false),
                ),
              ),
            ],
          );
        },
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
      children: _covSpaced([
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
              width: 200,
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
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: FilledButton(
            key: Key('coverage-attempt-save-${p.slotId}'),
            style: _covFilled(context),
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
      ]),
    );
  }

  Widget _confirmForm(BuildContext context, Map<String, String> errors) {
    final busy = widget.busy;
    final a = p.assignment!;
    final reasonOk = _reason.text.trim().isNotEmpty;
    return Column(
      key: Key('coverage-confirm-form-${p.slotId}'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: _covSpaced([
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
            style: _covFilled(context),
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
      ]),
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
      children: _covSpaced([
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
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: FilledButton(
            key: Key('coverage-assign-save-${p.slotId}'),
            style: _covFilled(context),
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
      ]),
    );
  }

  Widget _cancelForm(BuildContext context) {
    final busy = widget.busy;
    final a = p.assignment;
    final notify = a != null && a.response != DutyResponse.declined;
    return Column(
      key: Key('coverage-cancel-form-${p.slotId}'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: _covSpaced([
        Text(
          [
            p.positionsLeft <= 1
                ? 'This is the duty\'s last position: the whole duty on '
                      '${_when(context, p.times.startsAt)} is cancelled.'
                : 'Only this position is cancelled; the other positions stay.',
            if (notify) '${a.name} gets a cancellation notice.',
          ].join(' '),
        ),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton(
              key: Key('coverage-cancel-confirm-${p.slotId}'),
              style: _covFilled(context).copyWith(
                backgroundColor: WidgetStateProperty.resolveWith(
                  (states) => states.contains(WidgetState.disabled)
                      ? null
                      : ChurchColors.of(context).redFg,
                ),
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
              style: _covOutlined(context),
              onPressed: () => setState(() => _form = _CoverageForm.none),
              child: const Text('Keep it'),
            ),
          ],
        ),
      ]),
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

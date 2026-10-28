part of 'duties_screens.dart';

// Story 4.8: the creator's choice of member reminders (a duty, a rota, one
// date or this and later dates), the Short notice and Needs contact labels,
// and the leader's Needs contact list. The server keeps the deadline, plans
// the reminders and decides who is reached; these widgets only show and send
// what the leader chose.

/// The answer-by time a leader leaves empty: what the church default means.
const _defaultDeadlineHelp =
    'Leave the answer-by time empty for the church default: 2 weeks before '
    'for a duty a month or more away, 2 days before for one 3 days to a '
    'month away, otherwise 1 day before. When that has already passed the '
    'duty is Short notice: the member is asked to answer now and you are '
    'told to contact them directly.';

/// The choice of member reminders: the church defaults, or the ones picked
/// (none picked = no reminders). Leaders and deputies are always alerted
/// when an answer is overdue; that is not a choice.
class _ReminderChoice extends StatelessWidget {
  const _ReminderChoice({
    required this.keyPrefix,
    required this.custom,
    required this.selected,
    required this.enabled,
    required this.onCustom,
    required this.onToggle,
    this.error,
    this.extra = const [],
    this.reporting = false,
  });

  /// Review: stored reminders that are not among [dutyReminderChoices] (set
  /// by another client or an earlier version): shown as "custom" and kept
  /// unless the leader unticks them.
  final List<DutyReminderSpec> extra;

  /// The duty has a reporting time ("before the reporting time").
  final bool reporting;

  final String keyPrefix;
  final bool custom;
  final Set<DutyReminderSpec> selected;
  final bool enabled;
  final ValueChanged<bool> onCustom;
  final void Function(DutyReminderSpec spec, bool on) onToggle;

  /// A refusal code for `reminders` (invalid, out_of_range).
  final String? error;

  @override
  Widget build(BuildContext context) => Column(
    key: Key('$keyPrefix-reminders'),
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      CheckboxListTile(
        key: Key('$keyPrefix-reminders-custom'),
        contentPadding: EdgeInsets.zero,
        controlAffinity: ListTileControlAffinity.leading,
        value: custom,
        onChanged: enabled ? (v) => onCustom(v ?? false) : null,
        title: const Text('Choose the member\'s reminders'),
        subtitle: Text(
          custom
              ? 'Pick the reminders the member gets. None picked means no '
                    'reminders. Reminders before the answer-by time stop once '
                    'they answer; reminders before the start continue after '
                    'they accept.'
              : const DutyReminders().textFor(reporting: reporting),
        ),
      ),
      if (custom)
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final (i, c) in dutyReminderChoices.indexed)
              FilterChip(
                key: Key('$keyPrefix-reminder-$i'),
                label: Text(c.labelFor(reporting: reporting)),
                selected: selected.contains(c),
                onSelected: enabled ? (on) => onToggle(c, on) : null,
              ),
            for (final (i, c) in extra.indexed)
              FilterChip(
                key: Key('$keyPrefix-reminder-custom-$i'),
                label: Text('${c.labelFor(reporting: reporting)} (custom)'),
                selected: selected.contains(c),
                onSelected: enabled ? (on) => onToggle(c, on) : null,
              ),
          ],
        ),
      _muted(
        context,
        'Leaders and deputies are told when an answer is overdue, and at once '
        'for a Short-notice duty. Reminders are sent at any hour (there are '
        'no quiet hours); the member can snooze one.',
      ),
      if (error != null)
        Text(
          'Those reminders cannot be used.',
          key: Key('$keyPrefix-reminders-error'),
          style: TextStyle(color: ChurchColors.of(context).redFg),
        ),
    ],
  );
}

/// The specs a [_ReminderChoice] stands for (null = the defaults), in the
/// order of [dutyReminderChoices], then any kept [extra] (custom) specs.
List<DutyReminderSpec>? _chosenReminders(
  bool custom,
  Set<DutyReminderSpec> selected, [
  List<DutyReminderSpec> extra = const [],
]) => custom
    ? [
        for (final c in [...dutyReminderChoices, ...extra])
          if (selected.contains(c)) c,
      ]
    : null;

/// Story 4.8: a duty's reminders with a "Change reminders" editor for its
/// managers (a duty, or one rota date; [onSave] sends the command).
class _RemindersEditor extends StatefulWidget {
  const _RemindersEditor({
    super.key,
    required this.keyPrefix,
    required this.reminders,
    required this.canChange,
    required this.busy,
    required this.onSave,
    this.saveLabel = 'Save the reminders',
    this.error,
    this.reporting = false,
  });

  final String keyPrefix;
  final DutyReminders reminders;

  /// The duty has a reporting time ("before the reporting time").
  final bool reporting;
  final bool canChange;
  final bool busy;
  final String saveLabel;
  final String? error;
  final void Function(List<DutyReminderSpec>? reminders) onSave;

  @override
  State<_RemindersEditor> createState() => _RemindersEditorState();
}

class _RemindersEditorState extends State<_RemindersEditor> {
  bool _open = false;
  late bool _custom = !widget.reminders.isDefault;
  late final Set<DutyReminderSpec> _selected = {...?widget.reminders.specs};

  /// Review: stored specs outside [dutyReminderChoices] ("custom"), kept
  /// unless the leader unticks them.
  late final List<DutyReminderSpec> _extra = [
    for (final s in widget.reminders.specs ?? const <DutyReminderSpec>[])
      if (!dutyReminderChoices.contains(s)) s,
  ];

  /// Review: Cancel puts the stored reminders back.
  void _reset() => setState(() {
    _open = false;
    _custom = !widget.reminders.isDefault;
    _selected
      ..clear()
      ..addAll(widget.reminders.specs ?? const []);
  });

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        widget.reminders.textFor(reporting: widget.reporting),
        key: Key('${widget.keyPrefix}-reminders-text'),
      ),
      if (widget.canChange && !_open)
        FocusRing(
          child: TextButton(
            key: Key('${widget.keyPrefix}-reminders-change'),
            onPressed: widget.busy ? null : () => setState(() => _open = true),
            child: const Text('Change reminders'),
          ),
        ),
      if (widget.canChange && _open) ...[
        _ReminderChoice(
          keyPrefix: '${widget.keyPrefix}-edit',
          custom: _custom,
          selected: _selected,
          enabled: !widget.busy,
          error: widget.error,
          extra: _extra,
          reporting: widget.reporting,
          onCustom: (v) => setState(() => _custom = v),
          onToggle: (c, on) =>
              setState(() => on ? _selected.add(c) : _selected.remove(c)),
        ),
        Wrap(
          spacing: 8,
          children: [
            FocusRing(
              child: FilledButton(
                key: Key('${widget.keyPrefix}-reminders-save'),
                onPressed: widget.busy
                    ? null
                    // Review: the editor stays open (with any field error)
                    // until the server accepts; the new revision replaces
                    // this widget with a closed one.
                    : () => widget.onSave(
                        _chosenReminders(_custom, _selected, _extra),
                      ),
                child: Text(widget.saveLabel),
              ),
            ),
            FocusRing(
              child: TextButton(
                key: Key('${widget.keyPrefix}-reminders-cancel'),
                onPressed: _reset,
                child: const Text('Cancel'),
              ),
            ),
          ],
        ),
      ],
    ],
  );
}

/// Story 4.8: the leader's flags on an assignment: Short notice and Needs
/// contact (never why a member could not be reached).
List<Widget> _contactFlags(
  BuildContext context, {
  required String assignmentId,
  required bool shortNotice,
  required DutyResponse response,
  required DutyContactNeed? needsContact,
}) => [
  if (shortNotice && response == DutyResponse.pending)
    StatusLabel(
      key: Key('short-notice-$assignmentId'),
      label: 'Short notice',
      tone: StatusTone.warning,
    ),
  if (needsContact != null)
    StatusLabel(
      key: Key('needs-contact-$assignmentId'),
      label: 'Needs contact',
      tone: StatusTone.danger,
    ),
  if (needsContact case final n?)
    _muted(context, '${n.text} (since ${_when(context, n.since)}).'),
];

/// Story 4.8: the department's Needs contact list (assignments whose member
/// should be contacted directly: given at short notice, or not reachable in
/// the app). Contact attempts and confirmation arrive with entry 9.
class _NeedsContactList extends StatelessWidget {
  const _NeedsContactList({required this.department});
  final LeaderDepartment department;

  @override
  Widget build(BuildContext context) {
    final rows = [
      for (final duty in department.duties)
        for (final p in duty.positions)
          if (p.assignment case final a? when a.needsContact != null)
            (duty, p, a),
    ];
    final notices = department.contactNotices;
    return Column(
      key: Key('needs-contact-list-${department.departmentId}'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _heading(context, 'Needs contact (${rows.length + notices.length})'),
        if (rows.isEmpty && notices.isEmpty)
          _muted(context, 'Nobody needs direct contact right now.'),
        // Review: members the app cannot reach whose duty was taken away
        // (released, or the date cancelled), until it would have started.
        for (final n in notices)
          Text(
            'Tell ${n.displayName ?? 'the removed member'}: ${n.title}, '
            '${_when(context, n.startsAt)} '
            '${n.cancelled ? 'is cancelled' : 'is no longer theirs'}.',
            key: Key('contact-notice-${n.assignmentId}'),
          ),
        if (rows.isEmpty)
          const SizedBox.shrink()
        else ...[
          _muted(
            context,
            'Contact these members directly (in person or by phone) and ask '
            'for their answer. Reminders keep running in the app for those who '
            'have it.',
          ),
          for (final (duty, p, a) in rows)
            Text(
              '${a.displayName ?? 'Removed member'}: ${duty.dutyName}'
              '${p.positionName == null ? '' : ' (${p.positionName})'}, '
              '${_timesText(context, duty.times)}. ${a.needsContact!.text}.',
              key: Key('needs-contact-row-${a.assignmentId}'),
            ),
        ],
      ],
    );
  }
}

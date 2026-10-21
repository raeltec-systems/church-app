part of 'duties.dart';

// ---------------------------------------------------------------------------
// Special assignments (owner decision 2026-10-21): a duty that belongs to no
// department and no cell (a one-off church project, leading a service, a task
// from church leadership). Only a Pastor gives them, at a fixed date and time
// or with a due date ("done by", no start time). The member answers them in My
// duties; a Pastor records the outcome. Who may give, change, read or record
// what is decided by the server; these classes are presentation only.
// ---------------------------------------------------------------------------

/// Special assignment command names (through `api.duties_command`) and words.
abstract final class DutySpecial {
  static const give = 'duties.give_special';
  static const revise = 'duties.revise_special';
  static const cancel = 'duties.cancel_special';

  /// Who a special assignment belongs to, as every reader sees it.
  static const ownerLabel = 'Special assignment';

  /// A due date ends at this church hour (the server's due moment).
  static const dueHour = 18;

  static const _months = [
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

  /// "Due 30 Nov" for a due date (a calendar date, no zone applied).
  static String dueText(DateTime dueOn) =>
      'Due ${dueOn.day} ${_months[dueOn.month - 1]}';

  /// A typed `YYYY-MM-DD` as a calendar date (UTC midnight), or null when it
  /// is malformed or names a day that does not exist.
  static DateTime? parseDate(String text) {
    final at = ChurchTime.parse(text, '00:00');
    if (at == null) return null;
    final w = ChurchTime.wall(at);
    return DateTime.utc(w.year, w.month, w.day);
  }

  /// The due moment of [dueOn] (18:00 church time on that date).
  static DateTime dueMoment(DateTime dueOn) =>
      ChurchTime.instant(dueOn.year, dueOn.month, dueOn.day, dueHour, 0);
}

/// A fixed date and time, or a due date.
enum SpecialTiming {
  time('time'),
  due('due');

  const SpecialTiming(this.wire);
  final String wire;

  static SpecialTiming fromWire(Object? v) => switch (v) {
    'time' => time,
    'due' => due,
    _ => throw const FormatException('unexpected timing'),
  };
}

/// Who holds a special assignment now, as the Pastors read it.
class SpecialHolder {
  const SpecialHolder({
    required this.assignmentId,
    required this.revision,
    required this.memberId,
    required this.response,
    required this.responseDeadline,
    this.displayName,
    this.account,
    this.own = false,
    this.confirmedByLeader = false,
    this.confirmedChannel,
    this.respondedAt,
    this.priorAcceptedAt,
    this.note,
    this.deadlineSource = DutyDeadlineSource.creator,
    this.shortNotice = false,
    this.needsContact,
    this.override,
    this.outcome,
    this.allowed = const [],
  });

  factory SpecialHolder.fromJson(Object? json) {
    final m = _map(json, 'special assignment holder');
    final response = DutyResponse.fromWire(m['response']);
    return SpecialHolder(
      assignmentId: _req<String>(m, 'assignment_id'),
      revision: _revision(m),
      memberId: _req<String>(m, 'member_id'),
      displayName: _opt<String>(m, 'display_name'),
      account: m['account'] == null ? null : _account(m['account']),
      own: _opt<bool>(m, 'own') ?? false,
      response: response,
      confirmedByLeader: m['response_provenance'] == 'leader',
      confirmedChannel: m['confirmed_channel'] == null
          ? null
          : ContactChannel.fromWire(m['confirmed_channel']),
      respondedAt: _optInstant(m, 'responded_at'),
      priorAcceptedAt: _priorAccepted(m, response),
      note: _opt<String>(m, 'note'),
      responseDeadline: _instant(m, 'response_deadline'),
      deadlineSource: DutyDeadlineSource.fromWire(m['deadline_source']),
      shortNotice: _shortNotice(m),
      needsContact: DutyContactNeed.fromJsonOrNull(m['needs_contact']),
      override: DutyOverride.fromJsonOrNull(m['override']),
      outcome: DutyOutcomeRecord.fromJsonOrNull(m['outcome']),
      allowed: _allowed(m),
    );
  }

  final String assignmentId;

  /// The assignment (answer) revision: an outcome or a confirmation is sent
  /// against it.
  final int revision;
  final String memberId;
  final String? displayName;

  /// `app_account` or `no_login` (null for an erased member).
  final AccountStanding? account;

  /// The reader's own (another Pastor records its outcome).
  final bool own;
  final DutyResponse response;
  final bool confirmedByLeader;
  final ContactChannel? confirmedChannel;
  final DateTime? respondedAt;
  final DateTime? priorAcceptedAt;

  /// The member's note with their answer.
  final String? note;
  final DateTime responseDeadline;
  final DutyDeadlineSource deadlineSource;
  final bool shortNotice;
  final DutyContactNeed? needsContact;
  final DutyOverride? override;
  final DutyOutcomeRecord? outcome;

  /// What a Pastor may record now (empty before the start or due moment).
  final List<DutyOutcome> allowed;

  String get name => displayName ?? 'A member';

  /// The member's record was erased (the server's nil id).
  bool get erased => memberId == '00000000-0000-0000-0000-000000000000';

  bool get noLogin => account == AccountStanding.noLogin;

  /// The member's answer as the Pastor reads it.
  String get answerLabel => confirmedByLeader
      ? 'Confirmed by the Pastor'
      : switch (response) {
          DutyResponse.accepted => 'Accepted',
          DutyResponse.declined =>
            priorAcceptedAt == null
                ? 'Can\'t make it'
                : 'Can\'t make it anymore',
          DutyResponse.pending => 'Awaiting answer',
        };
}

/// Why nobody holds a special assignment now (the member left the church or
/// was deleted).
class SpecialVacancy {
  const SpecialVacancy({required this.since, this.reason});

  factory SpecialVacancy.fromJson(Object? json) {
    final m = _map(json, 'vacancy');
    return SpecialVacancy(
      reason: DutyVacancyReasons.parse(m['reason']),
      since: _instant(m, 'since'),
    );
  }

  final String? reason;
  final DateTime since;
}

/// One special assignment in `api.duties_special_assignments`.
class SpecialAssignment {
  const SpecialAssignment({
    required this.occurrenceId,
    required this.revision,
    required this.slotId,
    required this.dutyName,
    required this.timing,
    required this.times,
    required this.started,
    this.location,
    this.instructions,
    this.givenBy,
    this.givenAt,
    this.holder,
    this.vacancy,
  });

  factory SpecialAssignment.fromJson(Object? json) {
    final m = _map(json, 'special assignment');
    final timing = SpecialTiming.fromWire(m['timing']);
    final times = DutyTimes.fromJson(m);
    if ((timing == SpecialTiming.due) != times.isDue) {
      throw const FormatException('unexpected due_on');
    }
    return SpecialAssignment(
      occurrenceId: _req<String>(m, 'occurrence_id'),
      revision: _revision(m),
      slotId: _req<String>(m, 'slot_id'),
      dutyName: _req<String>(m, 'duty_name'),
      timing: timing,
      times: times,
      location: _opt<String>(m, 'location'),
      instructions: _opt<String>(m, 'instructions'),
      givenBy: _opt<String>(m, 'given_by'),
      givenAt: _optInstant(m, 'given_at'),
      started: _req<bool>(m, 'started'),
      holder: m['assignment'] == null
          ? null
          : SpecialHolder.fromJson(m['assignment']),
      vacancy: m['vacancy'] == null
          ? null
          : SpecialVacancy.fromJson(m['vacancy']),
    );
  }

  final String occurrenceId;

  /// The occurrence revision (expected_revision of a change or cancel).
  final int revision;
  final String slotId;
  final String dutyName;
  final SpecialTiming timing;
  final DutyTimes times;
  final String? location;
  final String? instructions;
  final String? givenBy;
  final DateTime? givenAt;

  /// Its start (or due moment) has passed: no change or cancellation, the
  /// outcome may be recorded.
  final bool started;

  /// The current assignment; null when nobody holds it ([vacancy] says why).
  final SpecialHolder? holder;
  final SpecialVacancy? vacancy;

  bool get isDue => timing == SpecialTiming.due;

  /// The outcome is still to be recorded (past, held, nothing recorded).
  bool get outcomeDue {
    final h = holder;
    return started && h != null && h.outcome == null && h.allowed.isNotEmpty;
  }

  /// Something a Pastor should act on before it starts: nobody holds it, or
  /// the member cannot make it.
  bool get needsSomeone {
    final h = holder;
    return !started && (h == null || h.response == DutyResponse.declined);
  }
}

/// `api.duties_special_assignments()`: the church's special assignments of
/// the last 90 days and ahead, and the members they may be given to.
class SpecialAssignments {
  const SpecialAssignments({
    required this.assignments,
    required this.members,
    this.truncated = false,
    this.membersTruncated = false,
  });

  factory SpecialAssignments.fromJson(Object? json) {
    final m = _map(json, 'special assignments');
    return SpecialAssignments(
      assignments: List.unmodifiable(
        _req<List>(m, 'assignments').map(SpecialAssignment.fromJson),
      ),
      members: List.unmodifiable(
        _req<List>(m, 'members').map(DepartmentMember.fromJson),
      ),
      truncated: _opt<bool>(m, 'truncated') ?? false,
      membersTruncated: _opt<bool>(m, 'members_truncated') ?? false,
    );
  }

  /// Upcoming first (soonest first), then past (newest first).
  final List<SpecialAssignment> assignments;

  /// Every active member but the reader, by name.
  final List<DepartmentMember> members;
  final bool truncated;
  final bool membersTruncated;

  SpecialAssignment? find(String occurrenceId) {
    for (final a in assignments) {
      if (a.occurrenceId == occurrenceId) return a;
    }
    return null;
  }
}

/// What a Pastor enters to give a special assignment.
class SpecialDraft {
  const SpecialDraft({
    required this.memberId,
    required this.dutyName,
    required this.timing,
    this.startsAt,
    this.endsAt,
    this.dueOn,
    this.location,
    this.instructions,
    this.responseDeadline,
    this.overrideReason,
  });

  final String memberId;
  final String dutyName;
  final SpecialTiming timing;

  /// A fixed time: the start and an optional end.
  final DateTime? startsAt;
  final DateTime? endsAt;

  /// A due date (a calendar date).
  final DateTime? dueOn;
  final String? location;
  final String? instructions;

  /// Null = the church's lead-time default.
  final DateTime? responseDeadline;
  final String? overrideReason;

  Map<String, Object?> toPayload() {
    String utc(DateTime t) => t.toUtc().toIso8601String();
    return {
      'member_id': memberId,
      'duty_name': _clean(dutyName),
      if (timing == SpecialTiming.time) ...{
        'starts_at': utc(startsAt!),
        if (endsAt case final e?) 'ends_at': utc(e),
      } else
        'due_on': ChurchTime.ymd(dueOn!),
      'location': ?_clean(location),
      'instructions': ?_clean(instructions, multiline: true),
      if (responseDeadline case final d?) 'response_deadline': utc(d),
      'override_reason': ?DutyOverride.clean(overrideReason),
    };
  }
}

/// A Pastor's change of a special assignment. Only what differs from [item]
/// is sent (a patch); the timing is sent whole when any part of it changed.
/// A material change (anything but the instructions) asks the member again.
class SpecialEdit {
  const SpecialEdit({
    required this.item,
    required this.dutyName,
    required this.timing,
    this.startsAt,
    this.endsAt,
    this.dueOn,
    this.location,
    this.instructions,
    this.memberId,
    this.responseDeadline,
    this.overrideReason,
  });

  final SpecialAssignment item;
  final String dutyName;
  final SpecialTiming timing;
  final DateTime? startsAt;
  final DateTime? endsAt;
  final DateTime? dueOn;
  final String? location;
  final String? instructions;

  /// The member to give it to (null: whoever holds it now).
  final String? memberId;
  final DateTime? responseDeadline;
  final String? overrideReason;

  static bool _same(DateTime? a, DateTime? b) =>
      a == null ? b == null : (b != null && a.isAtSameMomentAs(b));

  bool get timingChanged => timing != item.timing
      ? true
      : timing == SpecialTiming.due
      ? !_same(dueOn, item.times.dueOn)
      : !_same(startsAt, item.times.startsAt) ||
            !_same(endsAt, item.times.endsAt);

  bool get memberChanged =>
      memberId != null && memberId != item.holder?.memberId;

  /// The changed fields, in display order.
  List<String> get changed => [
    if (_clean(dutyName) != item.dutyName) DutyFields.dutyName,
    if (timingChanged) DutyFields.startsAt,
    if (_clean(location) != item.location) DutyFields.location,
    if (memberChanged) DutyFields.memberId,
    if (_clean(instructions, multiline: true) != item.instructions)
      DutyFields.instructions,
  ];

  /// A change the member must answer again (anything but instructions).
  bool get material => changed.any((f) => f != DutyFields.instructions);

  Map<String, Object?> toPayload() {
    String utc(DateTime t) => t.toUtc().toIso8601String();
    final c = changed;
    return {
      'occurrence_id': item.occurrenceId,
      if (c.contains(DutyFields.dutyName)) 'duty_name': _clean(dutyName),
      if (timingChanged)
        if (timing == SpecialTiming.time) ...{
          'starts_at': utc(startsAt!),
          'ends_at': endsAt == null ? null : utc(endsAt!),
        } else
          'due_on': ChurchTime.ymd(dueOn!),
      if (c.contains(DutyFields.location)) 'location': _clean(location),
      if (memberChanged) 'member_id': memberId,
      if (c.contains(DutyFields.instructions))
        'instructions': _clean(instructions, multiline: true),
      if (material && responseDeadline != null)
        'response_deadline': utc(responseDeadline!),
      if (material) 'override_reason': ?DutyOverride.clean(overrideReason),
    };
  }
}

/// Application port for the Pastors' read. Never throws.
abstract interface class DutySpecialRepository {
  Future<AccessRead<SpecialAssignments>> fetchSpecialAssignments();
}

class UnconfiguredDutySpecialRepository implements DutySpecialRepository {
  const UnconfiguredDutySpecialRepository();

  @override
  Future<AccessRead<SpecialAssignments>> fetchSpecialAssignments() async =>
      const AccessReadDenied(AccessDenial.unavailable);
}

/// Special assignments: does [grants] give them (the Pastor role)?
/// Navigation only; the server checks every read and command.
bool givesSpecialAssignments(MemberGrants? grants) =>
    grants?.hasRole(ChurchRoles.pastor) ?? false;

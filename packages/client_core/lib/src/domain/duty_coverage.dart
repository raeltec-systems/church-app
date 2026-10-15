part of 'duties.dart';

// ---------------------------------------------------------------------------
// Story 4.9: the coverage queue (`api.duties_coverage`), contact attempts,
// Confirmed by leader and position cancellation. Presentation only: what a
// reader may see (contact routes, notes, reasons) is decided by the server.
// ---------------------------------------------------------------------------

/// Story 4.9 command names (through `api.duties_command`).
abstract final class DutyCoverageCommands {
  static const recordContactAttempt = 'duties.record_contact_attempt';
  static const confirmByLeader = 'duties.confirm_by_leader';
  static const cancelPosition = 'duties.cancel_position';
}

/// A position's state in the queue (wire codes).
enum CoverageStatus {
  unfilled('unfilled', 'Unfilled'),
  awaiting('awaiting', 'Awaiting response'),
  overdue('overdue', 'Overdue response'),
  declined('declined', 'Declined'),
  changed('changed', 'Changed: needs a new answer'),
  confirmed('confirmed', 'Confirmed');

  const CoverageStatus(this.wire, this.label);
  final String wire;
  final String label;

  static CoverageStatus fromWire(Object? v) {
    for (final s in values) {
      if (s.wire == v) return s;
    }
    throw FormatException('unexpected status $v');
  }
}

/// The queue's filters (design contract: All, Unfilled, Overdue, Declined,
/// Awaiting, Needs contact, Confirmed).
enum CoverageFilter {
  all('All'),
  unfilled('Unfilled'),
  overdue('Overdue'),
  declined('Declined'),
  awaiting('Awaiting'),
  needsContact('Needs contact'),
  confirmed('Confirmed');

  const CoverageFilter(this.label);
  final String label;

  /// "Declined" covers declines and changed duties that need a new answer.
  bool matches(CoveragePosition p) => switch (this) {
    all => true,
    unfilled => p.status == CoverageStatus.unfilled,
    overdue => p.status == CoverageStatus.overdue,
    declined =>
      p.status == CoverageStatus.declined || p.status == CoverageStatus.changed,
    awaiting => p.status == CoverageStatus.awaiting,
    needsContact => p.needsContact != null,
    confirmed => p.status == CoverageStatus.confirmed,
  };
}

/// How a leader reached (or tried to reach) a member (wire codes).
enum ContactChannel {
  phone('phone', 'Phone call'),
  message('message', 'Message'),
  inPerson('in_person', 'In person'),
  other('other', 'Other');

  const ContactChannel(this.wire, this.label);
  final String wire;
  final String label;

  static ContactChannel fromWire(Object? v) {
    for (final c in values) {
      if (c.wire == v) return c;
    }
    throw FormatException('unexpected channel $v');
  }
}

/// What came of a contact attempt (wire codes).
enum ContactOutcome {
  noAnswer('no_answer', 'No answer'),
  leftMessage('left_message', 'Left a message'),
  willAnswer('will_answer', 'Will answer in the app'),
  cannotServe('cannot_serve', 'Cannot serve'),
  other('other', 'Other');

  const ContactOutcome(this.wire, this.label);
  final String wire;
  final String label;

  static ContactOutcome fromWire(Object? v) {
    for (final o in values) {
      if (o.wire == v) return o;
    }
    throw FormatException('unexpected outcome $v');
  }
}

/// A labelled 2.5 contact route (never a phone username).
class DutyContactRoute {
  const DutyContactRoute({
    required this.phone,
    required this.belongsTo,
    this.holderLabel,
  });

  factory DutyContactRoute.fromJson(Object? json) {
    final m = _map(json, 'contact route');
    final belongs = _req<String>(m, 'belongs_to');
    if (!const ['member', 'relative', 'household', 'other'].contains(belongs)) {
      throw const FormatException('unexpected belongs_to');
    }
    final phone = _req<String>(m, 'phone');
    if (!RegExp(r'^\+[1-9][0-9]{7,14}$').hasMatch(phone)) {
      throw const FormatException('unexpected phone');
    }
    return DutyContactRoute(
      phone: phone,
      belongsTo: belongs,
      holderLabel: _opt<String>(m, 'holder_label'),
    );
  }

  final String phone;

  /// `member`, `relative`, `household` or `other`.
  final String belongsTo;
  final String? holderLabel;

  /// "Own number", "Household (SYNTHETIC sister)".
  String get label => switch (belongsTo) {
    'member' => 'Own number',
    'relative' => 'Relative${_holder()}',
    'household' => 'Household${_holder()}',
    _ => 'Other${_holder()}',
  };

  String _holder() => holderLabel == null ? '' : ' ($holderLabel)';
}

/// Confirmed by leader: who recorded it, when, how, and (department leaders
/// and deputies only) the reason.
class CoverageConfirmation {
  const CoverageConfirmation({
    required this.at,
    required this.channel,
    this.by,
    this.reason,
  });

  static CoverageConfirmation? fromJsonOrNull(Object? json) {
    if (json == null) return null;
    final m = _map(json, 'confirmation');
    return CoverageConfirmation(
      by: _opt<String>(m, 'by'),
      at: _instant(m, 'at'),
      channel: ContactChannel.fromWire(m['channel']),
      reason: _opt<String>(m, 'reason'),
    );
  }

  final String? by;
  final DateTime at;
  final ContactChannel channel;
  final String? reason;
}

/// One contact attempt as the queue shows it.
class CoverageAttempt {
  const CoverageAttempt({
    required this.at,
    required this.channel,
    required this.outcome,
    this.by,
    this.note,
  });

  factory CoverageAttempt.fromJson(Object? json) {
    final m = _map(json, 'attempt');
    return CoverageAttempt(
      at: _instant(m, 'at'),
      by: _opt<String>(m, 'by'),
      channel: ContactChannel.fromWire(m['channel']),
      outcome: ContactOutcome.fromWire(m['outcome']),
      note: _opt<String>(m, 'note'),
    );
  }

  final DateTime at;
  final String? by;
  final ContactChannel channel;
  final ContactOutcome outcome;

  /// The practical note (department leaders and deputies only).
  final String? note;
}

/// The open coverage case of an assignment and its Follow-ups task.
class CoverageFollowUp {
  const CoverageFollowUp({
    required this.caseId,
    required this.openedAt,
    required this.attempts,
    required this.nextFollowUpAt,
    required this.overdue,
    required this.lastAttempt,
    this.taskId,
  });

  static CoverageFollowUp? fromJsonOrNull(Object? json) {
    if (json == null) return null;
    final m = _map(json, 'follow_up');
    final attempts = _req<int>(m, 'attempts');
    if (attempts < 1) throw const FormatException('unexpected attempts');
    return CoverageFollowUp(
      caseId: _req<String>(m, 'case_id'),
      taskId: _opt<String>(m, 'task_id'),
      openedAt: _instant(m, 'opened_at'),
      attempts: attempts,
      nextFollowUpAt: _instant(m, 'next_follow_up_at'),
      overdue: _req<bool>(m, 'overdue'),
      lastAttempt: CoverageAttempt.fromJson(m['last_attempt']),
    );
  }

  final String caseId;

  /// The Follow-ups task (null for Admin and Pastor, or when Follow-ups
  /// could not be reached when the case was opened).
  final String? taskId;
  final DateTime openedAt;
  final int attempts;
  final DateTime nextFollowUpAt;
  final bool overdue;
  final CoverageAttempt lastAttempt;
}

/// The current assignment of a queue position.
class CoverageAssignment {
  const CoverageAssignment({
    required this.assignmentId,
    required this.revision,
    required this.memberId,
    required this.account,
    required this.response,
    required this.responseDeadline,
    this.displayName,
    this.confirmedByLeader = false,
    this.deadlineSource = DutyDeadlineSource.creator,
    this.shortNotice = false,
    this.respondedAt,
    this.priorAcceptedAt,
    this.note,
    this.confirmation,
    this.changes,
  });

  factory CoverageAssignment.fromJson(Object? json) {
    final m = _map(json, 'assignment');
    final response = DutyResponse.fromWire(m['response']);
    final provenance = _opt<String>(m, 'response_provenance');
    if (provenance != null &&
        provenance != 'member' &&
        provenance != 'leader') {
      throw const FormatException('unexpected response_provenance');
    }
    return CoverageAssignment(
      assignmentId: _req<String>(m, 'assignment_id'),
      revision: _revision(m),
      memberId: _req<String>(m, 'member_id'),
      displayName: _opt<String>(m, 'display_name'),
      account: _account(m['account']),
      response: response,
      confirmedByLeader: provenance == 'leader',
      responseDeadline: _instant(m, 'response_deadline'),
      deadlineSource: DutyDeadlineSource.fromWire(m['deadline_source']),
      shortNotice: _shortNotice(m),
      respondedAt: _optInstant(m, 'responded_at'),
      priorAcceptedAt: _priorAccepted(m, response),
      note: _opt<String>(m, 'note'),
      confirmation: CoverageConfirmation.fromJsonOrNull(m['confirmation']),
      changes: _optFields(m, 'changes'),
    );
  }

  final String assignmentId;
  final int revision;
  final String memberId;

  /// Null once the member's record was erased.
  final String? displayName;
  final AccountStanding account;
  final DutyResponse response;

  /// Accepted through Confirmed by leader (never the member's own answer).
  final bool confirmedByLeader;
  final DateTime responseDeadline;
  final DutyDeadlineSource deadlineSource;
  final bool shortNotice;
  final DateTime? respondedAt;
  final DateTime? priorAcceptedAt;

  /// The member's note (department leaders and deputies only).
  final String? note;
  final CoverageConfirmation? confirmation;
  final List<String>? changes;

  String get name => displayName ?? 'Removed member';
}

/// One position of a published duty in the window.
class CoveragePosition {
  const CoveragePosition({
    required this.slotId,
    required this.positionNo,
    required this.occurrenceId,
    required this.occurrenceRevision,
    required this.dutyName,
    required this.times,
    required this.status,
    required this.positionsLeft,
    this.positionName,
    this.seriesId,
    this.location,
    this.needsContact,
    this.overlaps = 0,
    this.assignment,
    this.followUp,
    this.vacatedSince,
  });

  factory CoveragePosition.fromJson(Object? json) {
    final m = _map(json, 'position');
    final status = CoverageStatus.fromWire(m['status']);
    final assignment = m['assignment'] == null
        ? null
        : CoverageAssignment.fromJson(m['assignment']);
    if ((status == CoverageStatus.unfilled) != (assignment == null)) {
      throw const FormatException('unexpected assignment');
    }
    final left = _req<int>(m, 'positions_left');
    if (left < 1) throw const FormatException('unexpected positions_left');
    // Story 4.12: only an unfilled position can be vacated.
    final vacated = m['vacated'] == null ? null : _map(m['vacated'], 'vacated');
    if (vacated != null && status != CoverageStatus.unfilled) {
      throw const FormatException('unexpected vacated');
    }
    return CoveragePosition(
      slotId: _req<String>(m, 'slot_id'),
      positionNo: _req<int>(m, 'position_no'),
      positionName: _opt<String>(m, 'position_name'),
      occurrenceId: _req<String>(m, 'occurrence_id'),
      occurrenceRevision: _revision(m, 'occurrence_revision'),
      seriesId: _opt<String>(m, 'series_id'),
      dutyName: _req<String>(m, 'duty_name'),
      times: DutyTimes.fromJson(m),
      location: _opt<String>(m, 'location'),
      positionsLeft: left,
      status: status,
      needsContact: DutyContactNeed.fromJsonOrNull(m['needs_contact']),
      overlaps: _overlaps(m),
      assignment: assignment,
      followUp: CoverageFollowUp.fromJsonOrNull(m['follow_up']),
      vacatedSince: vacated == null ? null : _instant(vacated, 'since'),
    );
  }

  final String slotId;
  final int positionNo;
  final String? positionName;
  final String occurrenceId;
  final int occurrenceRevision;
  final String? seriesId;
  final String dutyName;
  final DutyTimes times;
  final String? location;

  /// How many positions of the duty are not cancelled (1: cancelling this one
  /// cancels the duty).
  final int positionsLeft;
  final CoverageStatus status;
  final DutyContactNeed? needsContact;
  final int overlaps;
  final CoverageAssignment? assignment;
  final CoverageFollowUp? followUp;

  /// Story 4.12: when the person given this unfilled position stopped being
  /// able to serve (null otherwise). Never why.
  final DateTime? vacatedSince;

  bool get vacated => vacatedSince != null;

  String get title =>
      positionName == null ? dutyName : '$dutyName: $positionName';

  /// A contact attempt is for an answer still missing (or a decline).
  bool get contactable =>
      assignment != null && assignment!.response != DutyResponse.accepted;

  /// Confirmed by leader is for a member who has not answered yet.
  bool get confirmable => assignment?.response == DutyResponse.pending;
}

/// A department's counts over the window.
class CoverageCounts {
  const CoverageCounts({
    this.required = 0,
    this.confirmed = 0,
    this.unfilled = 0,
    this.awaiting = 0,
    this.overdue = 0,
    this.declined = 0,
    this.needsContact = 0,
    this.conflicts = 0,
    this.overdueFollowUps = 0,
    this.vacated = 0,
  });

  factory CoverageCounts.fromJson(Object? json) {
    final m = _map(json, 'counts');
    int n(String k) {
      final v = _req<int>(m, k);
      if (v < 0) throw FormatException('unexpected $k');
      return v;
    }

    return CoverageCounts(
      required: n('required'),
      confirmed: n('confirmed'),
      unfilled: n('unfilled'),
      awaiting: n('awaiting'),
      overdue: n('overdue'),
      declined: n('declined'),
      needsContact: n('needs_contact'),
      conflicts: n('conflicts'),
      overdueFollowUps: n('overdue_follow_ups'),
      // Story 4.12 (absent from older servers).
      vacated: m['vacated'] == null ? 0 : n('vacated'),
    );
  }

  final int required;
  final int confirmed;
  final int unfilled;
  final int awaiting;
  final int overdue;
  final int declined;
  final int needsContact;
  final int conflicts;
  final int overdueFollowUps;

  /// Story 4.12: unfilled positions whose person can no longer serve.
  final int vacated;

  CoverageCounts operator +(CoverageCounts o) => CoverageCounts(
    required: required + o.required,
    confirmed: confirmed + o.confirmed,
    unfilled: unfilled + o.unfilled,
    awaiting: awaiting + o.awaiting,
    overdue: overdue + o.overdue,
    declined: declined + o.declined,
    needsContact: needsContact + o.needsContact,
    conflicts: conflicts + o.conflicts,
    overdueFollowUps: overdueFollowUps + o.overdueFollowUps,
    vacated: vacated + o.vacated,
  );

  /// Anything for a leader to act on.
  bool get needsAttention =>
      unfilled + overdue + declined + needsContact + overdueFollowUps > 0;
}

/// One department of the queue.
class CoverageDepartment {
  const CoverageDepartment({
    required this.departmentId,
    required this.name,
    required this.full,
    required this.canManage,
    required this.canContact,
    required this.counts,
    this.members = const [],
    this.contactRoutes = const {},
    this.positions = const [],
  });

  factory CoverageDepartment.fromJson(Object? json) {
    final m = _map(json, 'coverage department');
    final view = _req<String>(m, 'view');
    if (view != 'full' && view != 'operational') {
      throw const FormatException('unexpected view');
    }
    final routes = _map(m['contact_routes'] ?? const {}, 'contact_routes');
    return CoverageDepartment(
      departmentId: _req<String>(m, 'department_id'),
      name: _req<String>(m, 'name'),
      full: view == 'full',
      canManage: _req<bool>(m, 'can_manage'),
      canContact: _req<bool>(m, 'can_contact'),
      members: List.unmodifiable(
        (_opt<List>(m, 'members') ?? const []).map(DepartmentMember.fromJson),
      ),
      counts: CoverageCounts.fromJson(m['counts']),
      contactRoutes: Map.unmodifiable({
        for (final e in routes.entries)
          e.key as String: List<DutyContactRoute>.unmodifiable(
            (e.value as List).map(DutyContactRoute.fromJson),
          ),
      }),
      positions: List.unmodifiable(
        _req<List>(m, 'positions').map(CoveragePosition.fromJson),
      ),
    );
  }

  final String departmentId;
  final String name;

  /// The department's leaders and deputies get the full view (contact
  /// routes, notes, reasons); Admin and Pastor the operational one.
  final bool full;

  /// Reassign and cancel a position (leaders, deputies, Admin).
  final bool canManage;

  /// Contact attempts and Confirmed by leader (leaders and deputies only).
  final bool canContact;
  final CoverageCounts counts;
  final List<DepartmentMember> members;
  final Map<String, List<DutyContactRoute>> contactRoutes;
  final List<CoveragePosition> positions;

  List<DutyContactRoute> routesOf(String memberId) =>
      contactRoutes[memberId] ?? const [];
}

/// `api.duties_coverage`: the window (church dates), the departments the
/// reader may see, and whether the list was cut at 1000 positions.
class DutyCoverage {
  const DutyCoverage({
    required this.from,
    required this.to,
    required this.departments,
    this.duty,
    this.truncated = false,
  });

  factory DutyCoverage.fromJson(Object? json) {
    final m = _map(json, 'coverage');
    final w = _map(m['window'], 'window');
    final from = _req<String>(w, 'from');
    final to = _req<String>(w, 'to');
    if (!_ymd(from) || !_ymd(to)) {
      throw const FormatException('unexpected window');
    }
    return DutyCoverage(
      from: from,
      to: to,
      duty: _opt<String>(m, 'duty'),
      truncated: _opt<bool>(m, 'truncated') ?? false,
      departments: List.unmodifiable(
        _req<List>(m, 'departments').map(CoverageDepartment.fromJson),
      ),
    );
  }

  /// Church-local dates `YYYY-MM-DD`.
  final String from;
  final String to;
  final String? duty;
  final bool truncated;
  final List<CoverageDepartment> departments;

  /// The leader Home card's totals: departments the reader leads or
  /// deputises only (not Pastor oversight or the Admin role alone).
  CoverageCounts get managedTotals => departments
      .where((d) => d.full)
      .fold(const CoverageCounts(), (a, d) => a + d.counts);

  /// Church-wide totals (Pastor's gap view).
  CoverageCounts get totals =>
      departments.fold(const CoverageCounts(), (a, d) => a + d.counts);

  bool get leadsAny => departments.any((d) => d.full);
}

bool _ymd(String s) => RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(s);

/// The queue's server-side filters (null = the server's default: today and
/// the next six days, every visible department, every duty).
class CoverageQuery {
  const CoverageQuery({this.from, this.days = 7, this.departmentId, this.duty});

  /// Church-local start date `YYYY-MM-DD`.
  final String? from;

  /// 1-31 days.
  final int days;
  final String? departmentId;
  final String? duty;

  static const maxDays = 31;

  Map<String, Object?> toParams() {
    final d = duty?.trim();
    final start = from;
    String? end;
    if (start != null) {
      final day = DateTime.utc(
        int.parse(start.substring(0, 4)),
        int.parse(start.substring(5, 7)),
        int.parse(start.substring(8, 10)),
      ).add(Duration(days: days.clamp(1, maxDays) - 1));
      String two(int v) => v.toString().padLeft(2, '0');
      end =
          '${day.year.toString().padLeft(4, '0')}-${two(day.month)}-${two(day.day)}';
    }
    return {
      'from_date': ?start,
      'to_date': ?end,
      if (departmentId != null) 'department_id': departmentId,
      if (d != null && d.isNotEmpty) 'duty': d,
    };
  }

  CoverageQuery copyWith({
    String? from,
    int? days,
    String? departmentId,
    bool clearDepartment = false,
    String? duty,
  }) => CoverageQuery(
    from: from ?? this.from,
    days: days ?? this.days,
    departmentId: clearDepartment ? null : (departmentId ?? this.departmentId),
    duty: duty ?? this.duty,
  );

  @override
  bool operator ==(Object other) =>
      other is CoverageQuery &&
      other.from == from &&
      other.days == days &&
      other.departmentId == departmentId &&
      other.duty == duty;

  @override
  int get hashCode => Object.hash(from, days, departmentId, duty);
}

/// A contact attempt to send (`duties.record_contact_attempt`).
class ContactAttemptDraft {
  const ContactAttemptDraft({
    required this.channel,
    required this.outcome,
    required this.nextFollowUpAt,
    this.note,
  });

  final ContactChannel channel;
  final ContactOutcome outcome;
  final DateTime nextFollowUpAt;
  final String? note;

  static const noteMax = 280;

  /// Field errors before sending (the server checks again).
  Map<String, String> errors({DateTime? now, DateTime? startsAt}) {
    final t = now ?? DateTime.now().toUtc();
    final n = _clean(note, multiline: true);
    return {
      if (!nextFollowUpAt.isAfter(t)) 'next_follow_up_at': 'past',
      if (startsAt != null && !nextFollowUpAt.isBefore(startsAt))
        'next_follow_up_at': 'after_start',
      if (n != null && n.length > noteMax) 'note': 'invalid',
    };
  }

  Map<String, Object?> toPayload(String assignmentId) {
    final n = _clean(note, multiline: true);
    return {
      'assignment_id': assignmentId,
      'channel': channel.wire,
      'outcome': outcome.wire,
      'note': ?n,
      'next_follow_up_at': _utc(nextFollowUpAt),
    };
  }
}

/// Confirmed by leader to send (`duties.confirm_by_leader`).
class LeaderConfirmationDraft {
  const LeaderConfirmationDraft({required this.channel, required this.reason});

  final ContactChannel channel;
  final String reason;

  static const reasonMax = 200;

  Map<String, String> errors() {
    final r = _clean(reason);
    return {
      if (r == null) 'reason': 'required',
      if (r != null && r.length > reasonMax) 'reason': 'invalid',
    };
  }

  Map<String, Object?> toPayload(String assignmentId) => {
    'assignment_id': assignmentId,
    'channel': channel.wire,
    'reason': _clean(reason),
  };
}

String _utc(DateTime t) {
  final u = t.toUtc();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${u.year.toString().padLeft(4, '0')}-${two(u.month)}-${two(u.day)}'
      'T${two(u.hour)}:${two(u.minute)}:00Z';
}

/// Application port for the coverage read. Never throws.
abstract interface class DutyCoverageRepository {
  Future<AccessRead<DutyCoverage>> fetchCoverage(CoverageQuery query);
}

class UnconfiguredDutyCoverageRepository implements DutyCoverageRepository {
  const UnconfiguredDutyCoverageRepository();

  @override
  Future<AccessRead<DutyCoverage>> fetchCoverage(CoverageQuery query) async =>
      const AccessReadDenied(AccessDenial.unavailable);
}

/// Does [grants] lead or deputise a department (the leader Home card)?
bool leadsADepartment(MemberGrants? grants) =>
    grants != null &&
    grants.scopes.any((s) => DutyScopeKinds.isDepartmentScope(s.scopeKind));

/// What happened when the app asked the phone to call or message.
enum ContactLaunch {
  /// The phone or messaging app was opened (nothing was sent by the app).
  opened,

  /// The device could not open it.
  failed,

  /// This build cannot open the phone app (staff web on a computer, tests).
  unavailable,
}

/// Port: opens the phone or messaging app for a number. The app never sends
/// a call or message itself (no SMS or WhatsApp automation in v1).
abstract interface class ContactLauncher {
  Future<ContactLaunch> call(String phone);
  Future<ContactLaunch> message(String phone);
}

class UnavailableContactLauncher implements ContactLauncher {
  const UnavailableContactLauncher();

  @override
  Future<ContactLaunch> call(String phone) async => ContactLaunch.unavailable;

  @override
  Future<ContactLaunch> message(String phone) async =>
      ContactLaunch.unavailable;
}

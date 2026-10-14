part of 'duties.dart';

// ---------------------------------------------------------------------------
// Story 4.10: completion outcomes (`duties.record_outcome`,
// `duties.correct_outcome`), the leader's outcomes read (`api.duties_outcomes`)
// and a member's assignment history (`api.duties_member_history`). Response,
// coverage and completion stay separate: an outcome is only what a leader
// recorded after the duty; nothing is ever inferred from time passing. Who may
// read what (notes, reasons, history) is decided by the server.
// ---------------------------------------------------------------------------

/// Story 4.10 command names (through `api.duties_command`).
abstract final class DutyOutcomeCommands {
  static const recordOutcome = 'duties.record_outcome';
  static const correctOutcome = 'duties.correct_outcome';
}

/// What the leader recorded after the duty (wire codes).
enum DutyOutcome {
  completed('completed', 'Completed'),
  excused('excused', 'Excused'),
  noShow('no_show', 'No-show');

  const DutyOutcome(this.wire, this.label);
  final String wire;
  final String label;

  static DutyOutcome fromWire(Object? v) {
    for (final o in values) {
      if (o.wire == v) return o;
    }
    throw FormatException('unexpected outcome $v');
  }
}

/// Where a duty stands on completion (never derived from the clock).
enum OutcomeState {
  /// The duty has started and no leader has recorded an outcome.
  unrecorded('unrecorded', 'Not recorded'),
  completed('completed', 'Completed'),
  excused('excused', 'Excused'),
  noShow('no_show', 'No-show'),

  /// History only: the duty has not started yet.
  upcoming('upcoming', 'Upcoming'),

  /// History only: reassigned or cancelled, so it has no outcome.
  none('none', 'No outcome');

  const OutcomeState(this.wire, this.label);
  final String wire;
  final String label;

  static OutcomeState fromWire(Object? v) {
    for (final s in values) {
      if (s.wire == v) return s;
    }
    throw FormatException('unexpected outcome_state $v');
  }
}

/// One recorded value in an outcome's trail (newest first): the value, its
/// note, the correction reason (null for the first record), who and when.
class OutcomeRevision {
  const OutcomeRevision({
    required this.revision,
    required this.outcome,
    required this.at,
    this.note,
    this.reason,
    this.by,
  });

  factory OutcomeRevision.fromJson(Object? json) {
    final m = _map(json, 'outcome revision');
    return OutcomeRevision(
      revision: _revision(m),
      outcome: DutyOutcome.fromWire(m['outcome']),
      note: _opt<String>(m, 'note'),
      reason: _opt<String>(m, 'reason'),
      by: _opt<String>(m, 'by'),
      at: _instant(m, 'at'),
    );
  }

  final int revision;
  final DutyOutcome outcome;
  final String? note;
  final String? reason;
  final String? by;
  final DateTime at;
}

/// The current outcome of an assignment with its correction trail.
class DutyOutcomeRecord {
  const DutyOutcomeRecord({
    required this.outcome,
    required this.revision,
    required this.recordedAt,
    this.note,
    this.recordedBy,
    this.corrected = false,
    this.trail = const [],
  });

  static DutyOutcomeRecord? fromJsonOrNull(Object? json) {
    if (json == null) return null;
    final m = _map(json, 'outcome');
    final trail = m['trail'];
    if (trail != null && trail is! List) {
      throw const FormatException('unexpected trail');
    }
    final revision = _revision(m);
    return DutyOutcomeRecord(
      outcome: DutyOutcome.fromWire(m['outcome']),
      revision: revision,
      note: _opt<String>(m, 'note'),
      recordedAt: _instant(m, 'recorded_at'),
      recordedBy: _opt<String>(m, 'recorded_by'),
      corrected: _opt<bool>(m, 'corrected') ?? revision > 1,
      trail: List.unmodifiable([
        for (final t in (trail as List?) ?? const [])
          OutcomeRevision.fromJson(t),
      ]),
    );
  }

  final DutyOutcome outcome;
  final int revision;
  final String? note;
  final DateTime recordedAt;
  final String? recordedBy;
  final bool corrected;

  /// Every recorded value, newest first (the server sends at most 20).
  final List<OutcomeRevision> trail;

  /// The earlier values (corrections keep them).
  List<OutcomeRevision> get earlier =>
      trail.where((t) => t.revision < revision).toList();
}

List<DutyOutcome> _allowed(Map m) {
  final v = m['allowed'];
  if (v == null) return const [];
  if (v is! List) throw const FormatException('unexpected allowed');
  return List.unmodifiable(v.map(DutyOutcome.fromWire));
}

/// A started position's current assignment as the outcomes read shows it.
class OutcomeAssignment {
  const OutcomeAssignment({
    required this.assignmentId,
    required this.revision,
    required this.memberId,
    required this.response,
    required this.state,
    this.displayName,
    this.own = false,
    this.confirmedByLeader = false,
    this.respondedAt,
    this.outcome,
    this.allowed = const [],
  });

  factory OutcomeAssignment.fromJson(Object? json) {
    final m = _map(json, 'assignment');
    final state = OutcomeState.fromWire(m['outcome_state']);
    final outcome = DutyOutcomeRecord.fromJsonOrNull(m['outcome']);
    if ((state == OutcomeState.unrecorded) != (outcome == null)) {
      throw const FormatException('unexpected outcome');
    }
    return OutcomeAssignment(
      assignmentId: _req<String>(m, 'assignment_id'),
      revision: _revision(m),
      memberId: _req<String>(m, 'member_id'),
      displayName: _opt<String>(m, 'display_name'),
      own: _opt<bool>(m, 'own') ?? false,
      response: DutyResponse.fromWire(m['response']),
      confirmedByLeader: m['response_provenance'] == 'leader',
      respondedAt: _optInstant(m, 'responded_at'),
      state: state,
      outcome: outcome,
      allowed: _allowed(m),
    );
  }

  final String assignmentId;

  /// The assignment (answer) revision: a first record is sent against it.
  final int revision;
  final String memberId;
  final String? displayName;

  /// The reader's own duty (another leader or deputy records it).
  final bool own;
  final DutyResponse response;
  final bool confirmedByLeader;
  final DateTime? respondedAt;
  final OutcomeState state;
  final DutyOutcomeRecord? outcome;

  /// What may be recorded (No-show only after an acceptance).
  final List<DutyOutcome> allowed;

  String get name => displayName ?? 'A member';

  String get responseLabel => confirmedByLeader
      ? 'Confirmed by leader'
      : switch (response) {
          DutyResponse.accepted => 'Accepted',
          DutyResponse.declined => 'Declined',
          DutyResponse.pending => 'Never answered',
        };
}

/// One started position in the outcomes read.
class OutcomePosition {
  const OutcomePosition({
    required this.slotId,
    required this.positionNo,
    required this.occurrenceId,
    required this.dutyName,
    required this.times,
    this.positionName,
    this.location,
    this.assignment,
  });

  factory OutcomePosition.fromJson(Object? json) {
    final m = _map(json, 'position');
    return OutcomePosition(
      slotId: _req<String>(m, 'slot_id'),
      positionNo: _req<int>(m, 'position_no'),
      positionName: _opt<String>(m, 'position_name'),
      occurrenceId: _req<String>(m, 'occurrence_id'),
      dutyName: _req<String>(m, 'duty_name'),
      times: DutyTimes.fromJson(m),
      location: _opt<String>(m, 'location'),
      assignment: m['assignment'] == null
          ? null
          : OutcomeAssignment.fromJson(m['assignment']),
    );
  }

  final String slotId;
  final int positionNo;
  final String? positionName;
  final String occurrenceId;
  final String dutyName;
  final DutyTimes times;
  final String? location;
  final OutcomeAssignment? assignment;

  String get title =>
      positionName == null ? dutyName : '$dutyName: $positionName';
}

/// A department's totals (never per member: there is no ranking).
class OutcomeCounts {
  const OutcomeCounts({
    this.positions = 0,
    this.unfilled = 0,
    this.unrecorded = 0,
    this.completed = 0,
    this.excused = 0,
    this.noShow = 0,
  });

  factory OutcomeCounts.fromJson(Object? json) {
    final m = _map(json, 'counts');
    int n(String k) {
      final v = _req<int>(m, k);
      if (v < 0) throw FormatException('unexpected $k');
      return v;
    }

    return OutcomeCounts(
      positions: n('positions'),
      unfilled: n('unfilled'),
      unrecorded: n('unrecorded'),
      completed: n('completed'),
      excused: n('excused'),
      noShow: n('no_show'),
    );
  }

  final int positions;
  final int unfilled;
  final int unrecorded;
  final int completed;
  final int excused;
  final int noShow;
}

class OutcomeDepartment {
  const OutcomeDepartment({
    required this.departmentId,
    required this.name,
    required this.counts,
    this.positions = const [],
  });

  factory OutcomeDepartment.fromJson(Object? json) {
    final m = _map(json, 'department');
    final positions = m['positions'];
    if (positions is! List) throw const FormatException('unexpected positions');
    return OutcomeDepartment(
      departmentId: _req<String>(m, 'department_id'),
      name: _req<String>(m, 'name'),
      counts: OutcomeCounts.fromJson(m['counts']),
      positions: List.unmodifiable(positions.map(OutcomePosition.fromJson)),
    );
  }

  final String departmentId;
  final String name;
  final OutcomeCounts counts;
  final List<OutcomePosition> positions;
}

/// `api.duties_outcomes`: the started duties of the departments the reader
/// leads or deputises.
class DutyOutcomes {
  const DutyOutcomes({
    required this.from,
    required this.to,
    this.duty,
    this.truncated = false,
    this.departments = const [],
  });

  factory DutyOutcomes.fromJson(Object? json) {
    final m = _map(json, 'outcomes');
    final w = _map(m['window'], 'window');
    final from = _req<String>(w, 'from');
    final to = _req<String>(w, 'to');
    if (!_ymd(from) || !_ymd(to)) {
      throw const FormatException('unexpected window');
    }
    final deps = m['departments'];
    if (deps is! List) throw const FormatException('unexpected departments');
    return DutyOutcomes(
      from: from,
      to: to,
      duty: _opt<String>(m, 'duty'),
      truncated: _opt<bool>(m, 'truncated') ?? false,
      departments: List.unmodifiable(deps.map(OutcomeDepartment.fromJson)),
    );
  }

  final String from;
  final String to;
  final String? duty;
  final bool truncated;
  final List<OutcomeDepartment> departments;
}

/// The outcomes read's filters (null: the server's default, the last 14
/// church days, every department the reader leads, every duty).
class OutcomesQuery {
  const OutcomesQuery({
    this.from,
    this.days = 14,
    this.departmentId,
    this.duty,
  });

  /// Church-local first date `YYYY-MM-DD`.
  final String? from;

  /// 1-31 days.
  final int days;
  final String? departmentId;
  final String? duty;

  Map<String, Object?> toParams() {
    final d = duty?.trim();
    final start = from;
    String? end;
    if (start != null) {
      final day = DateTime.utc(
        int.parse(start.substring(0, 4)),
        int.parse(start.substring(5, 7)),
        int.parse(start.substring(8, 10)),
      ).add(Duration(days: days.clamp(1, CoverageQuery.maxDays) - 1));
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

  @override
  bool operator ==(Object other) =>
      other is OutcomesQuery &&
      other.from == from &&
      other.days == days &&
      other.departmentId == departmentId &&
      other.duty == duty;

  @override
  int get hashCode => Object.hash(from, days, departmentId, duty);
}

/// A first outcome (`duties.record_outcome`) or a correction
/// (`duties.correct_outcome`, which needs a reason).
class OutcomeDraft {
  const OutcomeDraft({required this.outcome, this.note, this.reason});

  final DutyOutcome outcome;
  final String? note;

  /// Required for a correction.
  final String? reason;

  static const noteMax = 200;
  static const reasonMax = 200;

  /// Field errors before sending (the server checks again).
  Map<String, String> errors({
    required bool correction,
    List<DutyOutcome> allowed = DutyOutcome.values,
  }) {
    final n = _clean(note);
    final r = _clean(reason);
    return {
      if (!allowed.contains(outcome)) 'outcome': 'not_accepted',
      if (n != null && n.length > noteMax) 'note': 'invalid',
      if (correction && r == null) 'reason': 'required',
      if (r != null && r.length > reasonMax) 'reason': 'invalid',
    };
  }

  Map<String, Object?> toPayload(
    String assignmentId, {
    required bool correction,
  }) {
    final n = _clean(note);
    return {
      'assignment_id': assignmentId,
      'outcome': outcome.wire,
      'note': ?n,
      if (correction) 'reason': _clean(reason),
    };
  }
}

/// One position a member held (the latest revision of that person on it).
class HistoryEntry {
  const HistoryEntry({
    required this.assignmentId,
    required this.occurrenceId,
    required this.departmentId,
    required this.departmentName,
    required this.dutyName,
    required this.times,
    required this.started,
    required this.state,
    required this.response,
    required this.outcomeState,
    this.positionName,
    this.confirmedByLeader = false,
    this.respondedAt,
    this.outcome,
  });

  factory HistoryEntry.fromJson(Object? json) {
    final m = _map(json, 'history entry');
    final state = _req<String>(m, 'state');
    if (!const ['current', 'reassigned', 'cancelled'].contains(state)) {
      throw const FormatException('unexpected state');
    }
    return HistoryEntry(
      assignmentId: _req<String>(m, 'assignment_id'),
      occurrenceId: _req<String>(m, 'occurrence_id'),
      departmentId: _req<String>(m, 'department_id'),
      departmentName: _req<String>(m, 'department_name'),
      dutyName: _req<String>(m, 'duty_name'),
      positionName: _opt<String>(m, 'position_name'),
      times: DutyTimes.fromJson(m),
      started: _req<bool>(m, 'started'),
      state: state,
      response: DutyResponse.fromWire(m['response']),
      confirmedByLeader: m['response_provenance'] == 'leader',
      respondedAt: _optInstant(m, 'responded_at'),
      outcomeState: OutcomeState.fromWire(m['outcome_state']),
      outcome: DutyOutcomeRecord.fromJsonOrNull(m['outcome']),
    );
  }

  final String assignmentId;
  final String occurrenceId;
  final String departmentId;
  final String departmentName;
  final String dutyName;
  final String? positionName;
  final DutyTimes times;
  final bool started;

  /// `current`, `reassigned` or `cancelled`.
  final String state;
  final DutyResponse response;
  final bool confirmedByLeader;
  final DateTime? respondedAt;
  final OutcomeState outcomeState;
  final DutyOutcomeRecord? outcome;

  String get title =>
      positionName == null ? dutyName : '$dutyName: $positionName';

  String get stateLabel => switch (state) {
    'reassigned' => 'Given to someone else',
    'cancelled' => 'Cancelled',
    _ => switch (response) {
      _ when confirmedByLeader => 'Confirmed by leader',
      DutyResponse.accepted => 'Accepted',
      DutyResponse.declined => 'Declined',
      DutyResponse.pending => started ? 'Never answered' : 'Awaiting response',
    },
  };
}

/// The member's own figures for the last 12 months (never compared with
/// anyone else).
class HistorySummary {
  const HistorySummary({
    this.held = 0,
    this.accepted = 0,
    this.confirmedByLeader = 0,
    this.declined = 0,
    this.unanswered = 0,
    this.completed = 0,
    this.excused = 0,
    this.noShow = 0,
    this.unrecorded = 0,
    this.ended = 0,
  });

  factory HistorySummary.fromJson(Object? json) {
    final m = _map(json, 'summary');
    int n(String k) {
      final v = _req<int>(m, k);
      if (v < 0) throw FormatException('unexpected $k');
      return v;
    }

    return HistorySummary(
      held: n('held'),
      accepted: n('accepted'),
      confirmedByLeader: n('confirmed_by_leader'),
      declined: n('declined'),
      unanswered: n('unanswered'),
      completed: n('completed'),
      excused: n('excused'),
      noShow: n('no_show'),
      unrecorded: n('unrecorded'),
      ended: n('ended'),
    );
  }

  final int held;
  final int accepted;
  final int confirmedByLeader;
  final int declined;
  final int unanswered;
  final int completed;
  final int excused;
  final int noShow;
  final int unrecorded;
  final int ended;
}

/// `api.duties_member_history`: one page of a member's assignment history.
class MemberHistory {
  const MemberHistory({
    required this.memberId,
    required this.self,
    required this.summary,
    this.displayName,
    this.upcoming = 0,
    this.entries = const [],
    this.hasMore = false,
    this.departmentNames = const [],
  });

  factory MemberHistory.fromJson(Object? json) {
    final m = _map(json, 'history');
    final member = _map(m['member'], 'member');
    final entries = m['entries'];
    if (entries is! List) throw const FormatException('unexpected entries');
    final deps = m['departments'];
    if (deps is! List) throw const FormatException('unexpected departments');
    return MemberHistory(
      memberId: _req<String>(member, 'member_id'),
      displayName: _opt<String>(member, 'display_name'),
      self: _req<bool>(m, 'self'),
      summary: HistorySummary.fromJson(m['summary']),
      upcoming: _req<int>(m, 'upcoming'),
      entries: List.unmodifiable(entries.map(HistoryEntry.fromJson)),
      hasMore: _opt<bool>(m, 'has_more') ?? false,
      departmentNames: List.unmodifiable([
        for (final d in deps) _req<String>(_map(d, 'department'), 'name'),
      ]),
    );
  }

  final String memberId;
  final String? displayName;
  final bool self;
  final HistorySummary summary;
  final int upcoming;
  final List<HistoryEntry> entries;
  final bool hasMore;
  final List<String> departmentNames;

  /// The cursor of the next (older) page, when there is one.
  HistoryCursor? get next => hasMore && entries.isNotEmpty
      ? HistoryCursor(entries.last.times.startsAt, entries.last.assignmentId)
      : null;
}

/// Where an older page starts (the last row's start and assignment id).
class HistoryCursor {
  const HistoryCursor(this.beforeAt, this.beforeId);
  final DateTime beforeAt;
  final String beforeId;

  @override
  bool operator ==(Object other) =>
      other is HistoryCursor &&
      other.beforeAt == beforeAt &&
      other.beforeId == beforeId;

  @override
  int get hashCode => Object.hash(beforeAt, beforeId);
}

/// Whose history and which page (null member: the reader's own).
class HistoryQuery {
  const HistoryQuery({this.memberId, this.pages = const []});

  final String? memberId;

  /// The cursors of the pages opened so far (empty: the newest page).
  final List<HistoryCursor> pages;

  HistoryCursor? get cursor => pages.isEmpty ? null : pages.last;

  HistoryQuery older(HistoryCursor c) =>
      HistoryQuery(memberId: memberId, pages: [...pages, c]);

  HistoryQuery newer() => HistoryQuery(
    memberId: memberId,
    pages: pages.isEmpty ? const [] : pages.sublist(0, pages.length - 1),
  );

  Map<String, Object?> toParams() => {
    if (memberId != null) 'member_id': memberId,
    if (cursor case final c?) 'before_at': c.beforeAt.toUtc().toIso8601String(),
    if (cursor case final c?) 'before_id': c.beforeId,
  };

  @override
  bool operator ==(Object other) =>
      other is HistoryQuery &&
      other.memberId == memberId &&
      other.pages.length == pages.length &&
      Iterable.generate(pages.length).every((i) => other.pages[i] == pages[i]);

  @override
  int get hashCode => Object.hash(memberId, Object.hashAll(pages));
}

/// Application port for the outcomes and history reads. Never throws.
abstract interface class DutyOutcomesRepository {
  Future<AccessRead<DutyOutcomes>> fetchOutcomes(OutcomesQuery query);
  Future<AccessRead<MemberHistory>> fetchHistory(HistoryQuery query);
}

class UnconfiguredDutyOutcomesRepository implements DutyOutcomesRepository {
  const UnconfiguredDutyOutcomesRepository();

  @override
  Future<AccessRead<DutyOutcomes>> fetchOutcomes(OutcomesQuery query) async =>
      const AccessReadDenied(AccessDenial.unavailable);

  @override
  Future<AccessRead<MemberHistory>> fetchHistory(HistoryQuery query) async =>
      const AccessReadDenied(AccessDenial.unavailable);
}

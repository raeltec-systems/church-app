/// Stories 4.1-4.3: departments and assigned duties as the server reports
/// them, with revisions (a material change replaces an assignment with a new
/// pending one; the earlier answer is kept in history) and rota series
/// (drafts, Publish N draft slots, this-occurrence and this-and-future edits).
/// Department setup (Admin), publishing (the department's leader or deputy,
/// or an Admin) and the assignee's explicit answer are all decided by the
/// server; these reads are presentation only. Free of widgets and SDKs.
library;

import 'access_grants.dart';
import 'church_time.dart';

/// Duties-registered scope kinds in the Identity grant model (story 2.3).
abstract final class DutyScopeKinds {
  static const leader = 'department_leader';
  static const deputy = 'department_deputy';

  static bool isDepartmentScope(String kind) =>
      kind == leader || kind == deputy;
}

/// The duties command function and command names (1.4 envelope).
abstract final class DutyCommands {
  static const function = 'duties_command';
  static const createDepartment = 'duties.create_department';
  static const addMember = 'duties.add_member';
  static const publish = 'duties.publish_duty';
  static const respond = 'duties.respond';
  static const revise = 'duties.revise_duty';

  /// Story 4.3: rota series, drafts and series edits.
  static const createSeries = 'duties.create_series';
  static const assignSlot = 'duties.assign_slot';
  static const publishDrafts = 'duties.publish_drafts';
  static const reviseSeries = 'duties.revise_series';
  static const cancelOccurrence = 'duties.cancel_occurrence';
  static const cancelSeries = 'duties.cancel_series';
}

/// Story 4.2: the revisable fields (wire names) in display order, and the
/// words a member or leader reads for them. Which ones are material is the
/// server's decision (`app.duties_slot_field_class`); this only names them.
abstract final class DutyFields {
  static const dutyName = 'duty_name';
  static const startsAt = 'starts_at';
  static const endsAt = 'ends_at';
  static const reportingAt = 'reporting_at';
  static const location = 'location';
  static const memberId = 'member_id';
  static const instructions = 'instructions';

  /// Story 4.3 notes fields (an update notice; answers stand).
  static const topic = 'topic';
  static const scripture = 'scripture';

  /// Story 4.3: a linked-event reference (recorded, no notice).
  static const eventRef = 'event_ref';

  static const order = [
    dutyName,
    startsAt,
    endsAt,
    reportingAt,
    location,
    memberId,
    instructions,
    topic,
    scripture,
    eventRef,
  ];

  static String label(String field) => switch (field) {
    dutyName => 'duty',
    startsAt => 'date or start time',
    endsAt => 'end time',
    reportingAt => 'reporting time',
    location => 'place',
    memberId => 'who is assigned',
    instructions => 'instructions',
    topic => 'topic',
    scripture => 'scripture',
    eventRef => 'linked event',
    _ => 'details',
  };

  /// "date or start time, place" for the known fields in display order.
  static String describe(Iterable<String> fields) {
    final known = order.where(fields.contains).map(label).toList();
    return known.isEmpty ? 'details' : known.join(', ');
  }

  /// The changed fields of a stale-response refusal
  /// (`{"assignment_id": "superseded", "<field>": "changed"}`).
  static List<String> changedIn(Map<String, String> fieldErrors) => [
    for (final f in order)
      if (fieldErrors[f] == 'changed') f,
  ];
}

/// The member's explicit answer (wire codes).
enum DutyResponse {
  pending('pending'),
  accepted('accepted'),
  declined('declined');

  const DutyResponse(this.wire);
  final String wire;

  static DutyResponse fromWire(Object? v) {
    for (final r in values) {
      if (r.wire == v) return r;
    }
    throw FormatException('unexpected response $v');
  }

  String get label => switch (this) {
    pending => 'Awaiting response',
    accepted => 'Accepted',
    declined => 'Can\'t make it',
  };
}

T _req<T>(Map json, String key) {
  final v = json[key];
  if (v is! T) throw FormatException('unexpected $key');
  return v;
}

T? _opt<T>(Map json, String key) {
  final v = json[key];
  if (v == null) return null;
  if (v is! T) throw FormatException('unexpected $key');
  return v;
}

Map _map(Object? json, String what) {
  if (json is! Map) throw FormatException('$what is not an object');
  return json;
}

DateTime _instant(Map json, String key) {
  final v = _req<String>(json, key);
  final t = DateTime.tryParse(v);
  if (t == null || !t.isUtc) throw FormatException('unexpected $key');
  return t;
}

DateTime? _optInstant(Map json, String key) =>
    json[key] == null ? null : _instant(json, key);

/// Story 4.2: an optional list of changed field names (null when absent).
List<String>? _optFields(Map json, String key) {
  final v = json[key];
  if (v == null) return null;
  if (v is! List || v.any((f) => f is! String)) {
    throw FormatException('unexpected $key');
  }
  return List.unmodifiable(v.cast<String>());
}

List<String> _ids(Map json, String key) {
  final v = json[key];
  if (v == null) return const [];
  if (v is! List || v.any((f) => f is! String)) {
    throw FormatException('unexpected $key');
  }
  return List.unmodifiable(v.cast<String>());
}

int _slotRevision(Map json) {
  final r = _opt<int>(json, 'slot_revision') ?? 1;
  if (r < 1) throw const FormatException('unexpected slot_revision');
  return r;
}

int _revision(Map json, [String key = 'revision']) {
  final r = _req<int>(json, key);
  if (r < 1) throw FormatException('unexpected $key');
  return r;
}

AccountStanding _account(Object? v) => switch (v) {
  'app_account' => AccountStanding.appAccount,
  'no_login' => AccountStanding.noLogin,
  'access_review' => AccountStanding.accessReview,
  _ => throw const FormatException('unexpected account'),
};

/// The time fields every duty carries.
class DutyTimes {
  const DutyTimes({required this.startsAt, this.endsAt, this.reportingAt});

  factory DutyTimes.fromJson(Map m) => DutyTimes(
    startsAt: _instant(m, 'starts_at'),
    endsAt: _optInstant(m, 'ends_at'),
    reportingAt: _optInstant(m, 'reporting_at'),
  );

  final DateTime startsAt;
  final DateTime? endsAt;
  final DateTime? reportingAt;

  /// The moment the member must be there (reporting time when earlier).
  DateTime get arriveBy => reportingAt ?? startsAt;
}

/// One of the signed-in member's assignments (`api.duties_my_duties`).
class MyDuty {
  const MyDuty({
    required this.assignmentId,
    required this.revision,
    required this.occurrenceId,
    required this.departmentId,
    required this.departmentName,
    required this.dutyName,
    required this.times,
    required this.response,
    required this.responseDeadline,
    this.location,
    this.instructions,
    this.respondedAt,
    this.note,
    this.slotRevision = 1,
    this.changes,
    this.previousResponse,
    this.previousAssignmentIds = const [],
    this.notesUpdatedAt,
    this.positionName,
    this.topic,
    this.scripture,
  });

  factory MyDuty.fromJson(Object? json) {
    final m = _map(json, 'duty');
    final response = DutyResponse.fromWire(m['response']);
    final respondedAt = _optInstant(m, 'responded_at');
    if ((response == DutyResponse.pending) != (respondedAt == null)) {
      throw const FormatException('unexpected responded_at');
    }
    return MyDuty(
      assignmentId: _req<String>(m, 'assignment_id'),
      revision: _revision(m),
      occurrenceId: _req<String>(m, 'occurrence_id'),
      departmentId: _req<String>(m, 'department_id'),
      departmentName: _req<String>(m, 'department_name'),
      dutyName: _req<String>(m, 'duty_name'),
      times: DutyTimes.fromJson(m),
      location: _opt<String>(m, 'location'),
      instructions: _opt<String>(m, 'instructions'),
      response: response,
      responseDeadline: _instant(m, 'response_deadline'),
      respondedAt: respondedAt,
      note: _opt<String>(m, 'note'),
      slotRevision: _slotRevision(m),
      changes: _optFields(m, 'changes'),
      previousResponse: m['previous_response'] == null
          ? null
          : DutyResponse.fromWire(m['previous_response']),
      previousAssignmentIds: _ids(m, 'previous_assignment_ids'),
      notesUpdatedAt: _optInstant(m, 'notes_updated_at'),
      positionName: _opt<String>(m, 'position_name'),
      topic: _opt<String>(m, 'topic'),
      scripture: _opt<String>(m, 'scripture'),
    );
  }

  /// Story 4.3: the named position of a rota (null for a one-position duty).
  final String? positionName;

  /// Story 4.3: optional topic and scripture of the occurrence.
  final String? topic;
  final String? scripture;

  final String assignmentId;

  /// The assignment's revision (expected_revision of duties.respond).
  final int revision;
  final String occurrenceId;
  final String departmentId;
  final String departmentName;
  final String dutyName;
  final DutyTimes times;
  final String? location;
  final String? instructions;
  final DutyResponse response;
  final DateTime responseDeadline;
  final DateTime? respondedAt;
  final String? note;

  /// Story 4.2: the slot revision this assignment asks the member to answer.
  final int slotRevision;

  /// What the change that created this assignment changed (field names),
  /// when it replaced the member's own earlier assignment; null otherwise.
  final List<String>? changes;

  /// The member's answer to the assignment this one replaced.
  final DutyResponse? previousResponse;

  /// The member's earlier assignments for this position (an old reminder
  /// link still finds this, the current version).
  final List<String> previousAssignmentIds;

  /// The latest notes-only update since this assignment was made.
  final DateTime? notesUpdatedAt;

  /// A revision asking again after a material change.
  bool get isChanged => changes != null;

  bool startedAt(DateTime now) => !times.arriveBy.isAfter(now);

  /// Still asks for an answer: pending and not yet started.
  bool needsResponse(DateTime now) =>
      response == DutyResponse.pending && !startedAt(now);
}

/// `api.duties_my_duties`.
class MyDuties {
  const MyDuties({
    required this.memberId,
    required this.assignments,
    this.truncated = false,
  });

  factory MyDuties.fromJson(Object? json) {
    final m = _map(json, 'my duties');
    return MyDuties(
      memberId: _req<String>(m, 'member_id'),
      assignments: List.unmodifiable(
        _req<List>(m, 'assignments').map(MyDuty.fromJson),
      ),
      truncated: _opt<bool>(m, 'truncated') ?? false,
    );
  }

  final String memberId;
  final List<MyDuty> assignments;

  /// More duties exist than the server listed (future ones come first).
  final bool truncated;

  MyDuty? find(String? assignmentId) {
    for (final a in assignments) {
      if (a.assignmentId == assignmentId) return a;
    }
    return null;
  }

  /// Story 4.2: the current version of [assignmentId], also when it is an
  /// earlier (superseded) assignment of the member for the same position.
  MyDuty? findCurrent(String? assignmentId) {
    final own = find(assignmentId);
    if (own != null) return own;
    for (final a in assignments) {
      if (a.previousAssignmentIds.contains(assignmentId)) return a;
    }
    return null;
  }
}

/// A position's current assignment as a leader sees it.
class PositionAssignment {
  const PositionAssignment({
    required this.assignmentId,
    required this.memberId,
    required this.response,
    required this.responseDeadline,
    required this.revision,
    this.displayName,
    this.respondedAt,
    this.note,
    this.slotRevision = 1,
    this.changes,
    this.notesUpdatedAt,
  });

  factory PositionAssignment.fromJson(Object? json) {
    final m = _map(json, 'assignment');
    return PositionAssignment(
      assignmentId: _req<String>(m, 'assignment_id'),
      memberId: _req<String>(m, 'member_id'),
      displayName: _opt<String>(m, 'display_name'),
      response: DutyResponse.fromWire(m['response']),
      responseDeadline: _instant(m, 'response_deadline'),
      respondedAt: _optInstant(m, 'responded_at'),
      note: _opt<String>(m, 'note'),
      revision: _revision(m),
      slotRevision: _slotRevision(m),
      changes: _optFields(m, 'changes'),
      notesUpdatedAt: _optInstant(m, 'notes_updated_at'),
    );
  }

  final String assignmentId;
  final String memberId;

  /// Null once the member's record was erased (the fact stays anonymous).
  final String? displayName;
  final DutyResponse response;
  final DateTime responseDeadline;
  final DateTime? respondedAt;

  /// The member's practical note (never shown to Pastor oversight).
  final String? note;
  final int revision;

  /// Story 4.2: the slot revision this assignment answers.
  final int slotRevision;

  /// What the change that created this assignment changed; null for the
  /// first assignment of the position.
  final List<String>? changes;

  /// The latest notes-only update since this assignment was made.
  final DateTime? notesUpdatedAt;
}

/// Story 4.2: an ended assignment of a position (superseded by a material
/// change, or cancelled), with the answer it had, kept as history.
class AssignmentHistoryEntry {
  const AssignmentHistoryEntry({
    required this.assignmentId,
    required this.memberId,
    required this.state,
    required this.endedAt,
    required this.response,
    required this.slotRevision,
    this.displayName,
    this.endReason,
    this.respondedAt,
    this.provenance,
    this.note,
  });

  factory AssignmentHistoryEntry.fromJson(Object? json) {
    final m = _map(json, 'history entry');
    final state = _req<String>(m, 'state');
    if (state != 'superseded' && state != 'cancelled') {
      throw const FormatException('unexpected state');
    }
    final provenance = _opt<String>(m, 'response_provenance');
    if (provenance != null && provenance != 'member') {
      throw const FormatException('unexpected response_provenance');
    }
    return AssignmentHistoryEntry(
      assignmentId: _req<String>(m, 'assignment_id'),
      memberId: _req<String>(m, 'member_id'),
      displayName: _opt<String>(m, 'display_name'),
      state: state,
      endReason: _opt<String>(m, 'end_reason'),
      endedAt: _instant(m, 'ended_at'),
      response: DutyResponse.fromWire(m['response']),
      respondedAt: _optInstant(m, 'responded_at'),
      provenance: provenance,
      note: _opt<String>(m, 'note'),
      slotRevision: _slotRevision(m),
    );
  }

  final String assignmentId;
  final String memberId;

  /// Null once the member's record was erased.
  final String? displayName;

  /// `superseded` or `cancelled`.
  final String state;
  final String? endReason;
  final DateTime endedAt;

  /// The answer the assignment had when it ended (kept, never reset).
  final DutyResponse response;
  final DateTime? respondedAt;

  /// Who recorded the answer (`member` until entry 9 adds leader
  /// confirmation).
  final String? provenance;
  final String? note;
  final int slotRevision;
}

class DutyPosition {
  const DutyPosition({
    required this.slotId,
    required this.positionNo,
    this.assignment,
    this.slotRevision = 1,
    this.history = const [],
    this.positionName,
  });

  factory DutyPosition.fromJson(Object? json) {
    final m = _map(json, 'position');
    final no = _req<int>(m, 'position_no');
    if (no < 1) throw const FormatException('unexpected position_no');
    return DutyPosition(
      slotId: _req<String>(m, 'slot_id'),
      positionNo: no,
      assignment: m['assignment'] == null
          ? null
          : PositionAssignment.fromJson(m['assignment']),
      slotRevision: _slotRevision(m),
      positionName: _opt<String>(m, 'position_name'),
      history: m['history'] == null
          ? const []
          : List.unmodifiable(
              _req<List>(m, 'history').map(AssignmentHistoryEntry.fromJson),
            ),
    );
  }

  final String slotId;
  final int positionNo;
  final PositionAssignment? assignment;

  /// Story 4.3: the named position of a rota (null for a one-position duty).
  final String? positionName;

  /// Story 4.2: the slot's current revision.
  final int slotRevision;

  /// Ended assignments, newest first (at most 20).
  final List<AssignmentHistoryEntry> history;
}

/// One published occurrence on the leader board.
class LeaderDuty {
  const LeaderDuty({
    required this.occurrenceId,
    required this.departmentId,
    required this.dutyName,
    required this.times,
    required this.revision,
    required this.positions,
    this.location,
    this.instructions,
    this.topic,
    this.scripture,
  });

  factory LeaderDuty.fromJson(Object? json) {
    final m = _map(json, 'leader duty');
    if (m['state'] != 'published') {
      throw const FormatException('unexpected state');
    }
    return LeaderDuty(
      occurrenceId: _req<String>(m, 'occurrence_id'),
      departmentId: _req<String>(m, 'department_id'),
      dutyName: _req<String>(m, 'duty_name'),
      times: DutyTimes.fromJson(m),
      location: _opt<String>(m, 'location'),
      instructions: _opt<String>(m, 'instructions'),
      topic: _opt<String>(m, 'topic'),
      scripture: _opt<String>(m, 'scripture'),
      revision: _revision(m),
      positions: List.unmodifiable(
        _req<List>(m, 'positions').map(DutyPosition.fromJson),
      ),
    );
  }

  final String occurrenceId;
  final String departmentId;
  final String dutyName;
  final DutyTimes times;
  final String? location;
  final String? instructions;

  /// Story 4.3: optional topic and scripture.
  final String? topic;
  final String? scripture;
  final int revision;
  final List<DutyPosition> positions;

  /// "1 of 1 confirmed": accepted current positions over all positions.
  int get accepted => positions
      .where((p) => p.assignment?.response == DutyResponse.accepted)
      .length;

  /// The assignee of a one-position duty (null with several positions: a
  /// rota position is given with duties.assign_slot).
  String? get memberId =>
      positions.length != 1 ? null : positions.first.assignment?.memberId;
}

/// One member of a department's roster.
class DepartmentMember {
  const DepartmentMember({
    required this.memberId,
    required this.displayName,
    required this.account,
  });

  factory DepartmentMember.fromJson(Object? json) {
    final m = _map(json, 'department member');
    return DepartmentMember(
      memberId: _req<String>(m, 'member_id'),
      displayName: _req<String>(m, 'display_name'),
      account: _account(m['account']),
    );
  }

  final String memberId;
  final String displayName;
  final AccountStanding account;
}

/// One department on the leader board.
class LeaderDepartment {
  const LeaderDepartment({
    required this.departmentId,
    required this.name,
    required this.capacity,
    required this.canPublish,
    required this.members,
    required this.duties,
    this.dutiesTruncated = false,
  });

  factory LeaderDepartment.fromJson(Object? json) {
    final m = _map(json, 'leader department');
    const capacities = {
      'department_leader',
      'department_deputy',
      'admin',
      'pastor',
    };
    final capacity = _req<String>(m, 'capacity');
    if (!capacities.contains(capacity)) {
      throw const FormatException('unexpected capacity');
    }
    return LeaderDepartment(
      departmentId: _req<String>(m, 'department_id'),
      name: _req<String>(m, 'name'),
      capacity: capacity,
      canPublish: _req<bool>(m, 'can_publish'),
      members: List.unmodifiable(
        _req<List>(m, 'members').map(DepartmentMember.fromJson),
      ),
      duties: List.unmodifiable(
        _req<List>(m, 'duties').map(LeaderDuty.fromJson),
      ),
      dutiesTruncated: _opt<bool>(m, 'duties_truncated') ?? false,
    );
  }

  /// More duties exist than the server listed.
  final bool dutiesTruncated;

  final String departmentId;
  final String name;

  /// `department_leader`, `department_deputy`, `admin` or `pastor`.
  final String capacity;
  final bool canPublish;
  final List<DepartmentMember> members;
  final List<LeaderDuty> duties;

  String get capacityLabel => switch (capacity) {
    'department_leader' => 'You lead this department',
    'department_deputy' => 'You are the deputy',
    'admin' => 'Admin',
    _ => 'Pastor oversight (read only)',
  };
}

/// `api.duties_leader_board`.
class DutyLeaderBoard {
  const DutyLeaderBoard({required this.departments});

  factory DutyLeaderBoard.fromJson(Object? json) {
    final m = _map(json, 'leader board');
    return DutyLeaderBoard(
      departments: List.unmodifiable(
        _req<List>(m, 'departments').map(LeaderDepartment.fromJson),
      ),
    );
  }

  final List<LeaderDepartment> departments;
}

class DepartmentStaff {
  const DepartmentStaff({
    required this.memberId,
    required this.displayName,
    required this.grantsRevision,
  });

  factory DepartmentStaff.fromJson(Object? json) {
    final m = _map(json, 'department staff');
    return DepartmentStaff(
      memberId: _req<String>(m, 'member_id'),
      displayName: _req<String>(m, 'display_name'),
      grantsRevision: _revision(m, 'grants_revision'),
    );
  }

  final String memberId;
  final String displayName;

  /// The member's grant-set revision (expected_revision of a scope command).
  final int grantsRevision;
}

/// One department as the Admin sets it up.
class AdminDepartment {
  const AdminDepartment({
    required this.departmentId,
    required this.name,
    required this.isSynthetic,
    required this.revision,
    required this.leaders,
    required this.deputies,
    required this.members,
  });

  factory AdminDepartment.fromJson(Object? json) {
    final m = _map(json, 'department');
    if (m['department_state'] != 'active') {
      throw const FormatException('unexpected department_state');
    }
    List<DepartmentStaff> staff(String key) =>
        List.unmodifiable(_req<List>(m, key).map(DepartmentStaff.fromJson));
    return AdminDepartment(
      departmentId: _req<String>(m, 'department_id'),
      name: _req<String>(m, 'name'),
      isSynthetic: _req<bool>(m, 'is_synthetic'),
      revision: _revision(m),
      leaders: staff('leaders'),
      deputies: staff('deputies'),
      members: List.unmodifiable(
        _req<List>(m, 'members').map(DepartmentMember.fromJson),
      ),
    );
  }

  final String departmentId;
  final String name;
  final bool isSynthetic;

  /// The department's revision (expected_revision of duties.add_member).
  final int revision;
  final List<DepartmentStaff> leaders;
  final List<DepartmentStaff> deputies;
  final List<DepartmentMember> members;

  bool hasMember(String memberId) => members.any((m) => m.memberId == memberId);
}

/// One approved member the Admin may add or give a role (no contact data).
class DutyCandidate {
  const DutyCandidate({
    required this.memberId,
    required this.displayName,
    required this.account,
    required this.grantsRevision,
  });

  factory DutyCandidate.fromJson(Object? json) {
    final m = _map(json, 'candidate');
    return DutyCandidate(
      memberId: _req<String>(m, 'member_id'),
      displayName: _req<String>(m, 'display_name'),
      account: _account(m['account']),
      grantsRevision: _revision(m, 'grants_revision'),
    );
  }

  final String memberId;
  final String displayName;
  final AccountStanding account;
  final int grantsRevision;
}

/// `api.duties_admin_overview`.
class DutyAdminOverview {
  const DutyAdminOverview({
    required this.departments,
    required this.members,
    this.membersTruncated = false,
  });

  factory DutyAdminOverview.fromJson(Object? json) {
    final m = _map(json, 'duties overview');
    return DutyAdminOverview(
      departments: List.unmodifiable(
        _req<List>(m, 'departments').map(AdminDepartment.fromJson),
      ),
      members: List.unmodifiable(
        _req<List>(m, 'members').map(DutyCandidate.fromJson),
      ),
      membersTruncated: _opt<bool>(m, 'members_truncated') ?? false,
    );
  }

  final List<AdminDepartment> departments;
  final List<DutyCandidate> members;

  /// More approved members exist than the server listed (at most 500).
  final bool membersTruncated;
}

/// What a leader enters to publish one duty. Instants are sent as UTC.
class DutyDraft {
  const DutyDraft({
    required this.departmentId,
    required this.dutyName,
    required this.startsAt,
    required this.memberId,
    required this.responseDeadline,
    this.endsAt,
    this.reportingAt,
    this.location,
    this.instructions,
  });

  final String departmentId;
  final String dutyName;
  final DateTime startsAt;
  final DateTime? endsAt;
  final DateTime? reportingAt;
  final String? location;
  final String? instructions;
  final String memberId;
  final DateTime responseDeadline;

  Map<String, Object?> toPayload() {
    String utc(DateTime t) => t.toUtc().toIso8601String();
    String? text(String? s) {
      final t = s?.trim();
      return t == null || t.isEmpty ? null : t;
    }

    return {
      'department_id': departmentId,
      'duty_name': dutyName.trim(),
      'starts_at': utc(startsAt),
      if (endsAt case final e?) 'ends_at': utc(e),
      if (reportingAt case final r?) 'reporting_at': utc(r),
      'location': ?text(location),
      'instructions': ?text(instructions),
      'member_id': memberId,
      'response_deadline': utc(responseDeadline),
    };
  }
}

/// Story 4.2: a leader's edit of a published duty. Only the fields that
/// differ from [duty] are sent (a patch; `null` clears an optional field);
/// the server decides what is material and refuses a material change without
/// a new [responseDeadline].
class DutyEdit {
  const DutyEdit({
    required this.duty,
    required this.dutyName,
    required this.startsAt,
    required this.memberId,
    this.endsAt,
    this.reportingAt,
    this.location,
    this.instructions,
    this.responseDeadline,
  });

  final LeaderDuty duty;
  final String dutyName;
  final DateTime startsAt;
  final DateTime? endsAt;
  final DateTime? reportingAt;
  final String? location;
  final String? instructions;
  final String? memberId;
  final DateTime? responseDeadline;

  static String? _line(String? s) {
    final t = s?.replaceAll(RegExp(r'\s+'), ' ').trim();
    return t == null || t.isEmpty ? null : t;
  }

  static String? _text(String? s) {
    final t = s?.trim();
    return t == null || t.isEmpty ? null : t;
  }

  static bool _same(DateTime? a, DateTime? b) =>
      a == null ? b == null : (b != null && a.isAtSameMomentAs(b));

  /// The changed fields, in display order.
  List<String> get changed => [
    if (_line(dutyName) != duty.dutyName) DutyFields.dutyName,
    if (!_same(startsAt, duty.times.startsAt)) DutyFields.startsAt,
    if (!_same(endsAt, duty.times.endsAt)) DutyFields.endsAt,
    if (!_same(reportingAt, duty.times.reportingAt)) DutyFields.reportingAt,
    if (_line(location) != duty.location) DutyFields.location,
    if (memberId != null && memberId != duty.memberId) DutyFields.memberId,
    if (_text(instructions) != duty.instructions) DutyFields.instructions,
  ];

  /// A change the assignee must answer again (anything but instructions).
  bool get material => changed.any((f) => f != DutyFields.instructions);

  Map<String, Object?> toPayload() {
    String? utc(DateTime? t) => t?.toUtc().toIso8601String();
    final c = changed;
    return {
      'occurrence_id': duty.occurrenceId,
      if (c.contains(DutyFields.dutyName)) 'duty_name': _line(dutyName),
      if (c.contains(DutyFields.startsAt)) 'starts_at': utc(startsAt),
      if (c.contains(DutyFields.endsAt)) 'ends_at': utc(endsAt),
      if (c.contains(DutyFields.reportingAt)) 'reporting_at': utc(reportingAt),
      if (c.contains(DutyFields.location)) 'location': _line(location),
      if (c.contains(DutyFields.memberId)) 'member_id': memberId,
      if (c.contains(DutyFields.instructions))
        'instructions': _text(instructions),
      if (material && responseDeadline != null)
        'response_deadline': utc(responseDeadline),
    };
  }
}

// ---------------------------------------------------------------------------
// Story 4.3: rota series (`api.duties_rota`)
// ---------------------------------------------------------------------------

/// A planned (draft) assignee of a rota position. [displayName] is null for
/// an erased member; [available] is false when the person can no longer serve
/// in the department (no reason is disclosed).
class RotaPerson {
  const RotaPerson({
    required this.memberId,
    required this.available,
    this.displayName,
  });

  factory RotaPerson.fromJson(Object? json) {
    final m = _map(json, 'rota person');
    return RotaPerson(
      memberId: _req<String>(m, 'member_id'),
      displayName: _opt<String>(m, 'display_name'),
      available: _req<bool>(m, 'available'),
    );
  }

  final String memberId;
  final String? displayName;
  final bool available;
}

/// The current assignment of a published rota position.
class RotaAssignment {
  const RotaAssignment({
    required this.assignmentId,
    required this.memberId,
    required this.response,
    required this.responseDeadline,
    required this.revision,
    required this.available,
    this.displayName,
  });

  factory RotaAssignment.fromJson(Object? json) {
    final m = _map(json, 'rota assignment');
    return RotaAssignment(
      assignmentId: _req<String>(m, 'assignment_id'),
      memberId: _req<String>(m, 'member_id'),
      displayName: _opt<String>(m, 'display_name'),
      response: DutyResponse.fromWire(m['response']),
      responseDeadline: _instant(m, 'response_deadline'),
      revision: _revision(m),
      available: _req<bool>(m, 'available'),
    );
  }

  final String assignmentId;
  final String memberId;
  final String? displayName;
  final DutyResponse response;
  final DateTime responseDeadline;
  final int revision;
  final bool available;
}

class RotaPosition {
  const RotaPosition({
    required this.slotId,
    required this.positionNo,
    this.positionName,
    this.draft,
    this.assignment,
  });

  factory RotaPosition.fromJson(Object? json) {
    final m = _map(json, 'rota position');
    final no = _req<int>(m, 'position_no');
    if (no < 1) throw const FormatException('unexpected position_no');
    return RotaPosition(
      slotId: _req<String>(m, 'slot_id'),
      positionNo: no,
      positionName: _opt<String>(m, 'position_name'),
      draft: m['draft'] == null ? null : RotaPerson.fromJson(m['draft']),
      assignment: m['assignment'] == null
          ? null
          : RotaAssignment.fromJson(m['assignment']),
    );
  }

  final String slotId;
  final int positionNo;
  final String? positionName;
  final RotaPerson? draft;
  final RotaAssignment? assignment;

  String get label => positionName ?? 'Position $positionNo';
}

enum RotaState {
  draft('draft'),
  published('published'),
  cancelled('cancelled');

  const RotaState(this.wire);
  final String wire;

  static RotaState fromWire(Object? v) {
    for (final s in values) {
      if (s.wire == v) return s;
    }
    throw FormatException('unexpected state $v');
  }
}

/// One occurrence of a series as the rota grid shows it.
class RotaOccurrence {
  const RotaOccurrence({
    required this.occurrenceId,
    required this.seriesDate,
    required this.state,
    required this.revision,
    required this.dutyName,
    required this.times,
    required this.started,
    required this.required,
    required this.confirmed,
    required this.positions,
    this.location,
    this.instructions,
    this.topic,
    this.scripture,
  });

  factory RotaOccurrence.fromJson(Object? json) {
    final m = _map(json, 'rota occurrence');
    final positions = List<RotaPosition>.unmodifiable(
      _req<List>(m, 'positions').map(RotaPosition.fromJson),
    );
    final required = _req<int>(m, 'required');
    final confirmed = _req<int>(m, 'confirmed');
    if (required != positions.length || confirmed < 0 || confirmed > required) {
      throw const FormatException('unexpected coverage');
    }
    return RotaOccurrence(
      occurrenceId: _req<String>(m, 'occurrence_id'),
      seriesDate: _req<String>(m, 'series_date'),
      state: RotaState.fromWire(m['state']),
      revision: _revision(m),
      dutyName: _req<String>(m, 'duty_name'),
      times: DutyTimes.fromJson(m),
      location: _opt<String>(m, 'location'),
      instructions: _opt<String>(m, 'instructions'),
      topic: _opt<String>(m, 'topic'),
      scripture: _opt<String>(m, 'scripture'),
      started: _req<bool>(m, 'started'),
      required: required,
      confirmed: confirmed,
      positions: positions,
    );
  }

  final String occurrenceId;

  /// The church-local date the series made it for (YYYY-MM-DD).
  final String seriesDate;
  final RotaState state;
  final int revision;
  final String dutyName;
  final DutyTimes times;
  final String? location;
  final String? instructions;
  final String? topic;
  final String? scripture;
  final bool started;

  /// Positions in total, and current positions the member accepted.
  final int required;
  final int confirmed;
  final List<RotaPosition> positions;

  /// Changeable: not started and not cancelled.
  bool get open => !started && state != RotaState.cancelled;
}

class RotaSeries {
  const RotaSeries({
    required this.seriesId,
    required this.departmentId,
    required this.dutyName,
    required this.every,
    required this.interval,
    required this.fromDate,
    required this.untilDate,
    required this.startTime,
    required this.positions,
    required this.revision,
    required this.draftSlots,
    required this.occurrences,
    this.endTime,
    this.reportingTime,
    this.location,
    this.instructions,
    this.topic,
    this.scripture,
  });

  factory RotaSeries.fromJson(Object? json) {
    final m = _map(json, 'rota series');
    const everies = {'day', 'week', 'month'};
    final every = _req<String>(m, 'every');
    if (!everies.contains(every)) {
      throw const FormatException('unexpected every');
    }
    final draftSlots = _req<int>(m, 'draft_slots');
    if (draftSlots < 0) throw const FormatException('unexpected draft_slots');
    return RotaSeries(
      seriesId: _req<String>(m, 'series_id'),
      departmentId: _req<String>(m, 'department_id'),
      dutyName: _req<String>(m, 'duty_name'),
      every: every,
      interval: _req<int>(m, 'interval'),
      fromDate: _req<String>(m, 'from_date'),
      untilDate: _req<String>(m, 'until_date'),
      startTime: _req<String>(m, 'start_time'),
      endTime: _opt<String>(m, 'end_time'),
      reportingTime: _opt<String>(m, 'reporting_time'),
      location: _opt<String>(m, 'location'),
      instructions: _opt<String>(m, 'instructions'),
      topic: _opt<String>(m, 'topic'),
      scripture: _opt<String>(m, 'scripture'),
      positions: _ids(m, 'positions'),
      revision: _revision(m),
      draftSlots: draftSlots,
      occurrences: List.unmodifiable(
        _req<List>(m, 'occurrences').map(RotaOccurrence.fromJson),
      ),
    );
  }

  final String seriesId;
  final String departmentId;
  final String dutyName;

  /// `day`, `week` or `month`, every [interval] of them.
  final String every;
  final int interval;
  final String fromDate;
  final String untilDate;
  final String startTime;
  final String? endTime;
  final String? reportingTime;
  final String? location;
  final String? instructions;
  final String? topic;
  final String? scripture;
  final List<String> positions;

  /// The series revision (expected_revision of the series commands).
  final int revision;

  /// Positions of draft occurrences that have not started: the N of
  /// "Publish N draft slots".
  final int draftSlots;
  final List<RotaOccurrence> occurrences;

  String get repeatLabel {
    final unit = switch (every) {
      'day' => interval == 1 ? 'day' : 'days',
      'month' => interval == 1 ? 'month' : 'months',
      _ => interval == 1 ? 'week' : 'weeks',
    };
    return interval == 1 ? 'Every $unit' : 'Every $interval $unit';
  }
}

class RotaDepartment {
  const RotaDepartment({
    required this.departmentId,
    required this.name,
    required this.capacity,
    required this.canManage,
    required this.members,
    required this.series,
    this.seriesTruncated = false,
  });

  factory RotaDepartment.fromJson(Object? json) {
    final m = _map(json, 'rota department');
    return RotaDepartment(
      departmentId: _req<String>(m, 'department_id'),
      name: _req<String>(m, 'name'),
      capacity: _req<String>(m, 'capacity'),
      canManage: _req<bool>(m, 'can_manage'),
      members: List.unmodifiable(
        _req<List>(m, 'members').map(DepartmentMember.fromJson),
      ),
      series: List.unmodifiable(
        _req<List>(m, 'series').map(RotaSeries.fromJson),
      ),
      seriesTruncated: _opt<bool>(m, 'series_truncated') ?? false,
    );
  }

  final String departmentId;
  final String name;
  final String capacity;
  final bool canManage;
  final List<DepartmentMember> members;
  final List<RotaSeries> series;
  final bool seriesTruncated;
}

/// `api.duties_rota`.
class DutyRota {
  const DutyRota({required this.departments});

  factory DutyRota.fromJson(Object? json) {
    final m = _map(json, 'rota');
    return DutyRota(
      departments: List.unmodifiable(
        _req<List>(m, 'departments').map(RotaDepartment.fromJson),
      ),
    );
  }

  final List<RotaDepartment> departments;
}

/// The answer-by lead times a leader picks (before the reporting or start
/// time, in church time). Wire values of `deadline_before`.
abstract final class DutyLeads {
  static const choices = <(String, String)>[
    ('2 hours', '2 hours before'),
    ('12 hours', '12 hours before'),
    ('1 day', '1 day before'),
    ('2 days', '2 days before'),
    ('3 days', '3 days before'),
    ('7 days', '1 week before'),
    ('14 days', '2 weeks before'),
    ('30 days', '30 days before'),
  ];

  /// [at] moved earlier by [lead] (`<n> hours` or `<n> days`). Church time has no
  /// daylight saving, so whole days are 24 hours.
  static DateTime before(DateTime at, String lead) {
    final parts = lead.split(' ');
    final n = int.parse(parts[0]);
    return parts[1].startsWith('day')
        ? at.subtract(Duration(days: n))
        : at.subtract(Duration(hours: n));
  }
}

String? _clean(String? s, {bool multiline = false}) {
  final t = multiline ? s?.trim() : s?.replaceAll(RegExp(r'\s+'), ' ').trim();
  return t == null || t.isEmpty ? null : t;
}

bool _hhmm(String s) => RegExp(r'^([01][0-9]|2[0-3]):[0-5][0-9]$').hasMatch(s);

/// What a leader enters to generate a rota series (church-local dates and
/// times; the server expands it in church time).
class SeriesDraft {
  const SeriesDraft({
    required this.departmentId,
    required this.dutyName,
    required this.every,
    required this.fromDate,
    required this.untilDate,
    required this.startTime,
    required this.positions,
    this.interval = 1,
    this.endTime,
    this.reportingTime,
    this.location,
    this.instructions,
    this.topic,
    this.scripture,
  });

  final String departmentId;
  final String dutyName;
  final String every;
  final int interval;
  final String fromDate;
  final String untilDate;
  final String startTime;
  final String? endTime;
  final String? reportingTime;
  final String? location;
  final String? instructions;
  final String? topic;
  final String? scripture;
  final List<String> positions;

  /// Null while a field cannot be read (the server checks everything again).
  /// [positions] is a comma-separated list of position names.
  static SeriesDraft? parse({
    required String departmentId,
    required String dutyName,
    required String every,
    required String interval,
    required String fromDate,
    required String untilDate,
    required String startTime,
    required String endTime,
    required String reportingTime,
    required String location,
    required String instructions,
    required String topic,
    required String scripture,
    required String positions,
  }) {
    final names = [for (final p in positions.split(',')) ?_clean(p)];
    final n = int.tryParse(interval.trim().isEmpty ? '1' : interval.trim());
    bool date(String d) => ChurchTime.parse(d, '00:00') != null;
    final end = endTime.trim(), rep = reportingTime.trim();
    if (_clean(dutyName) == null ||
        names.isEmpty ||
        n == null ||
        n < 1 ||
        n > 52 ||
        !date(fromDate) ||
        !date(untilDate) ||
        !_hhmm(startTime.trim()) ||
        (end.isNotEmpty && !_hhmm(end)) ||
        (rep.isNotEmpty && !_hhmm(rep))) {
      return null;
    }
    return SeriesDraft(
      departmentId: departmentId,
      dutyName: dutyName,
      every: every,
      interval: n,
      fromDate: fromDate.trim(),
      untilDate: untilDate.trim(),
      startTime: startTime.trim(),
      endTime: end.isEmpty ? null : end,
      reportingTime: rep.isEmpty ? null : rep,
      location: location,
      instructions: instructions,
      topic: topic,
      scripture: scripture,
      positions: names,
    );
  }

  Map<String, Object?> toPayload() => {
    'department_id': departmentId,
    'duty_name': _clean(dutyName),
    'every': every,
    if (interval != 1) 'interval': interval,
    'from_date': fromDate,
    'until_date': untilDate,
    'start_time': startTime,
    'end_time': ?endTime,
    'reporting_time': ?reportingTime,
    'location': ?_clean(location),
    'instructions': ?_clean(instructions, multiline: true),
    'topic': ?_clean(topic),
    'scripture': ?_clean(scripture),
    'positions': positions,
  };
}

/// Story 4.3: a leader's change of a rota occurrence, applied to "this
/// occurrence" (`duties.revise_duty`, instants on the occurrence's own
/// church date) or "this and future" (`duties.revise_series`, church-local
/// times). Only fields that differ from [occurrence] are sent.
class RotaEdit {
  const RotaEdit({
    required this.occurrence,
    required this.dutyName,
    required this.startTime,
    this.endTime,
    this.reportingTime,
    this.location,
    this.instructions,
    this.topic,
    this.scripture,
    this.lead,
  });

  final RotaOccurrence occurrence;
  final String dutyName;
  final String startTime;
  final String? endTime;
  final String? reportingTime;
  final String? location;
  final String? instructions;
  final String? topic;
  final String? scripture;

  /// `deadline_before` for published occurrences whose material fields change.
  final String? lead;

  /// Church-local "HH:MM" of an instant.
  static String hm(DateTime at) {
    final w = ChurchTime.wall(at);
    return '${w.hour.toString().padLeft(2, '0')}:'
        '${w.minute.toString().padLeft(2, '0')}';
  }

  static String? _time(String? s) {
    final t = s?.trim();
    return t == null || t.isEmpty ? null : t;
  }

  /// Every entered time can be read.
  bool get readable =>
      _clean(dutyName) != null &&
      _hhmm(startTime.trim()) &&
      (_time(endTime) == null || _hhmm(_time(endTime)!)) &&
      (_time(reportingTime) == null || _hhmm(_time(reportingTime)!));

  String? get _oldEnd => switch (occurrence.times.endsAt) {
    final e? => hm(e),
    null => null,
  };
  String? get _oldReporting => switch (occurrence.times.reportingAt) {
    final r? => hm(r),
    null => null,
  };

  List<String> get changed => [
    if (_clean(dutyName) != occurrence.dutyName) DutyFields.dutyName,
    if (startTime.trim() != hm(occurrence.times.startsAt)) DutyFields.startsAt,
    if (_time(endTime) != _oldEnd) DutyFields.endsAt,
    if (_time(reportingTime) != _oldReporting) DutyFields.reportingAt,
    if (_clean(location) != occurrence.location) DutyFields.location,
    if (_clean(instructions, multiline: true) != occurrence.instructions)
      DutyFields.instructions,
    if (_clean(topic) != occurrence.topic) DutyFields.topic,
    if (_clean(scripture) != occurrence.scripture) DutyFields.scripture,
  ];

  /// Asks assignees again (published occurrences only).
  bool get material => changed.any(
    (f) =>
        f != DutyFields.instructions &&
        f != DutyFields.topic &&
        f != DutyFields.scripture,
  );

  /// A published occurrence with an assignee needs [lead] for a material
  /// change.
  bool get needsLead =>
      material &&
      occurrence.state == RotaState.published &&
      occurrence.positions.any((p) => p.assignment != null);

  DateTime _at(String hhmm, {DateTime? after}) {
    final w = ChurchTime.wall(occurrence.times.startsAt);
    final parts = hhmm.split(':');
    var t = ChurchTime.instant(
      w.year,
      w.month,
      w.day,
      int.parse(parts[0]),
      int.parse(parts[1]),
    );
    if (after != null && !t.isAfter(after)) {
      t = t.add(const Duration(days: 1));
    }
    return t;
  }

  /// `duties.revise_duty` (this occurrence).
  Map<String, Object?> thisPayload() {
    String utc(DateTime t) => t.toUtc().toIso8601String();
    final c = changed;
    final starts = _at(startTime.trim());
    final rep = _time(reportingTime);
    final end = _time(endTime);
    final reporting = rep == null ? null : _at(rep);
    return {
      'occurrence_id': occurrence.occurrenceId,
      if (c.contains(DutyFields.dutyName)) 'duty_name': _clean(dutyName),
      if (c.contains(DutyFields.startsAt)) 'starts_at': utc(starts),
      if (c.contains(DutyFields.endsAt) ||
          (c.contains(DutyFields.startsAt) && end != null))
        'ends_at': end == null ? null : utc(_at(end, after: starts)),
      if (c.contains(DutyFields.reportingAt))
        'reporting_at': reporting == null ? null : utc(reporting),
      if (c.contains(DutyFields.location)) 'location': _clean(location),
      if (c.contains(DutyFields.instructions))
        'instructions': _clean(instructions, multiline: true),
      if (c.contains(DutyFields.topic)) 'topic': _clean(topic),
      if (c.contains(DutyFields.scripture)) 'scripture': _clean(scripture),
      if (needsLead && lead != null)
        'response_deadline': utc(DutyLeads.before(reporting ?? starts, lead!)),
    };
  }

  /// `duties.revise_series` (this and future).
  Map<String, Object?> futurePayload(String seriesId) {
    final c = changed;
    return {
      'series_id': seriesId,
      'from_occurrence_id': occurrence.occurrenceId,
      if (c.contains(DutyFields.dutyName)) 'duty_name': _clean(dutyName),
      if (c.contains(DutyFields.startsAt)) 'start_time': startTime.trim(),
      if (c.contains(DutyFields.endsAt) ||
          (c.contains(DutyFields.startsAt) && _time(endTime) != null))
        'end_time': _time(endTime),
      if (c.contains(DutyFields.reportingAt))
        'reporting_time': _time(reportingTime),
      if (c.contains(DutyFields.location)) 'location': _clean(location),
      if (c.contains(DutyFields.instructions))
        'instructions': _clean(instructions, multiline: true),
      if (c.contains(DutyFields.topic)) 'topic': _clean(topic),
      if (c.contains(DutyFields.scripture)) 'scripture': _clean(scripture),
      if (material && lead != null) 'deadline_before': lead,
    };
  }
}

/// Application port for the duties reads. Never throws; a fresh request
/// every call.
abstract interface class DutiesRepository {
  Future<AccessRead<MyDuties>> fetchMyDuties();
  Future<AccessRead<DutyLeaderBoard>> fetchLeaderBoard();
  Future<AccessRead<DutyAdminOverview>> fetchAdminOverview();

  /// Story 4.3: `api.duties_rota`.
  Future<AccessRead<DutyRota>> fetchRota();
}

class UnconfiguredDutiesRepository implements DutiesRepository {
  const UnconfiguredDutiesRepository();

  @override
  Future<AccessRead<MyDuties>> fetchMyDuties() async =>
      const AccessReadDenied(AccessDenial.unavailable);

  @override
  Future<AccessRead<DutyLeaderBoard>> fetchLeaderBoard() async =>
      const AccessReadDenied(AccessDenial.unavailable);

  @override
  Future<AccessRead<DutyAdminOverview>> fetchAdminOverview() async =>
      const AccessReadDenied(AccessDenial.unavailable);

  @override
  Future<AccessRead<DutyRota>> fetchRota() async =>
      const AccessReadDenied(AccessDenial.unavailable);
}

/// Does [grants] lead or deputise a department, or oversee them (Admin,
/// Pastor)? Navigation only.
bool seesDutyBoard(MemberGrants? grants) =>
    grants != null &&
    (grants.isAdmin ||
        grants.hasRole(ChurchRoles.pastor) ||
        grants.scopes.any(
          (s) => DutyScopeKinds.isDepartmentScope(s.scopeKind),
        ));

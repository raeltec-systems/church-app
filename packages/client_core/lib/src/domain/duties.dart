/// Story 4.1: departments and assigned duties as the server reports them.
/// Department setup (Admin), publishing (the department's leader or deputy,
/// or an Admin) and the assignee's explicit answer are all decided by the
/// server; these reads are presentation only. Free of widgets and SDKs.
library;

import 'access_grants.dart';

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
    );
  }

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

  bool startedAt(DateTime now) => !times.arriveBy.isAfter(now);

  /// Still asks for an answer: pending and not yet started.
  bool needsResponse(DateTime now) =>
      response == DutyResponse.pending && !startedAt(now);
}

/// `api.duties_my_duties`.
class MyDuties {
  const MyDuties({required this.memberId, required this.assignments});

  factory MyDuties.fromJson(Object? json) {
    final m = _map(json, 'my duties');
    return MyDuties(
      memberId: _req<String>(m, 'member_id'),
      assignments: List.unmodifiable(
        _req<List>(m, 'assignments').map(MyDuty.fromJson),
      ),
    );
  }

  final String memberId;
  final List<MyDuty> assignments;

  MyDuty? find(String? assignmentId) {
    for (final a in assignments) {
      if (a.assignmentId == assignmentId) return a;
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
}

class DutyPosition {
  const DutyPosition({
    required this.slotId,
    required this.positionNo,
    this.assignment,
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
    );
  }

  final String slotId;
  final int positionNo;
  final PositionAssignment? assignment;
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
  final int revision;
  final List<DutyPosition> positions;

  /// "1 of 1 confirmed": accepted current positions over all positions.
  int get accepted => positions
      .where((p) => p.assignment?.response == DutyResponse.accepted)
      .length;
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
    );
  }

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
  const DutyAdminOverview({required this.departments, required this.members});

  factory DutyAdminOverview.fromJson(Object? json) {
    final m = _map(json, 'duties overview');
    return DutyAdminOverview(
      departments: List.unmodifiable(
        _req<List>(m, 'departments').map(AdminDepartment.fromJson),
      ),
      members: List.unmodifiable(
        _req<List>(m, 'members').map(DutyCandidate.fromJson),
      ),
    );
  }

  final List<AdminDepartment> departments;
  final List<DutyCandidate> members;
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

/// Application port for the duties reads. Never throws; a fresh request
/// every call.
abstract interface class DutiesRepository {
  Future<AccessRead<MyDuties>> fetchMyDuties();
  Future<AccessRead<DutyLeaderBoard>> fetchLeaderBoard();
  Future<AccessRead<DutyAdminOverview>> fetchAdminOverview();
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

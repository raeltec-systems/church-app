/// Stories 4.1-4.3: departments and assigned duties as the server reports
/// them, with revisions (a material change replaces an assignment with a new
/// pending one; the earlier answer is kept in history) and rota series
/// (drafts, Publish N draft slots, this-occurrence and this-and-future edits).
/// Story 4.4 adds overlap warnings: each candidate's upcoming load, the
/// overlapping duties the viewer may see and the leader's recorded reason for
/// assigning anyway (the assignee still answers).
/// Department setup (Admin), publishing (the department's leader or deputy,
/// or an Admin) and the assignee's explicit answer are all decided by the
/// server; these reads are presentation only. Free of widgets and SDKs.
library;

import 'dart:developer' as developer;

import 'access_grants.dart';
import 'church_time.dart';

part 'duty_coverage.dart';
part 'duty_outcomes.dart';

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

  /// Story 4.5: "Can't make it anymore" after accepting.
  static const withdrawAcceptance = 'duties.withdraw_acceptance';

  /// Story 4.5: accept several listed dates together (all or nothing).
  static const acceptMany = 'duties.accept_many';

  /// The most dates one bulk acceptance may carry (the server's limit).
  static const maxBulk = 50;

  /// Story 4.8: the member reminders of one date, or of a series from a date
  /// onwards.
  static const setReminders = 'duties.set_reminders';

  /// Story 4.11: the department marks an owner-review mismatch reviewed
  /// (expected revision = the review's revision).
  static const clearReview = 'duties.clear_review';

  /// Story 4.12 (Admin): take a member out of a department (expected
  /// revision = the department's). Their future duties there end, each
  /// position is flagged for cover and the leaders are told.
  static const removeMember = 'duties.remove_member';

  /// Story 4.12 (Admin): mark a department's leader handover done once it
  /// has a leader or deputy again (expected revision = the department's).
  static const resolveHandover = 'duties.resolve_handover';
}

/// Story 4.12: the one end reason a leader reads when the person given a
/// position can no longer serve (left the department or the church, or was
/// deleted). Never why.
abstract final class DutyEndReasons {
  static const vacated = 'vacated';
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

/// Story 4.4: an optional non-negative overlap count (0 when absent).
int _overlaps(Map json) {
  final v = _opt<int>(json, 'overlaps') ?? 0;
  if (v < 0) throw const FormatException('unexpected overlaps');
  return v;
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
    this.cellId,
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
    this.priorAcceptedAt,
    this.leaders = const [],
    this.slotId,
    this.ownerKind = DutyOwnerKind.department,
    this.deadlineSource = DutyDeadlineSource.creator,
    this.shortNotice = false,
    this.reminders,
    this.confirmedByLeader = false,
    this.confirmedChannel,
    this.outcome,
  });

  factory MyDuty.fromJson(Object? json) {
    final m = _map(json, 'duty');
    final response = DutyResponse.fromWire(m['response']);
    final respondedAt = _optInstant(m, 'responded_at');
    if ((response == DutyResponse.pending) != (respondedAt == null)) {
      throw const FormatException('unexpected responded_at');
    }
    // Story 4.11: a department duty names its department; a cell programme
    // part names its cell and no department.
    final ownerKind = DutyOwnerKind.fromWire(m['owner_kind']);
    final cell = ownerKind == DutyOwnerKind.cell;
    return MyDuty(
      assignmentId: _req<String>(m, 'assignment_id'),
      revision: _revision(m),
      occurrenceId: _req<String>(m, 'occurrence_id'),
      departmentId: cell ? null : _req<String>(m, 'department_id'),
      departmentName: cell ? null : _req<String>(m, 'department_name'),
      cellId: cell ? _req<String>(m, 'cell_id') : null,
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
      priorAcceptedAt: _priorAccepted(m, response),
      leaders: _leaders(m),
      slotId: _opt<String>(m, 'slot_id'),
      ownerKind: ownerKind,
      deadlineSource: DutyDeadlineSource.fromWire(m['deadline_source']),
      shortNotice: _shortNotice(m),
      reminders: DutyReminders.fromJsonIn(m),
      confirmedByLeader: m['response_provenance'] == 'leader',
      confirmedChannel: m['confirmed_channel'] == null
          ? null
          : ContactChannel.fromWire(m['confirmed_channel']),
      outcome: DutyOutcomeRecord.fromJsonOrNull(m['outcome']),
    );
  }

  /// Story 4.9: the acceptance was recorded by a leader (Confirmed by
  /// leader, after a call or in person), not by the member in the app.
  final bool confirmedByLeader;

  /// Story 4.9: how the leader reached the member (never the reason).
  final ContactChannel? confirmedChannel;

  /// Story 4.10: what a leader recorded after the duty (with its note and
  /// corrections), or null while nothing is recorded. Never inferred from
  /// the time.
  final DutyOutcomeRecord? outcome;

  /// Story 4.8: whose answer-by time this is (the leader's, or the church's
  /// lead-time default).
  final DutyDeadlineSource deadlineSource;

  /// Story 4.8: given at short notice (the default answer-by time had
  /// already passed): the member is asked to answer now.
  final bool shortNotice;

  /// Story 4.8: the reminders this duty sends (null from a server before
  /// 4.8).
  final DutyReminders? reminders;

  /// Story 4.5: the position's slot (stable across revisions; the calendar
  /// entry's id). Null from a server before 4.5.
  final String? slotId;

  /// Story 4.5: who owns the duty. Story 4.11: a department duty or a cell
  /// programme part can be answered here; anything else fails closed.
  final DutyOwnerKind ownerKind;

  /// Story 4.5: the member may answer this duty from My duties.
  bool get answerable =>
      ownerKind == DutyOwnerKind.department || ownerKind == DutyOwnerKind.cell;

  /// Story 4.11: the cell of a cell programme part (null for a department
  /// duty).
  final String? cellId;

  /// Story 4.11: who the duty belongs to, as the member reads it.
  String get ownerLabel => departmentName ?? 'Cell programme';

  /// Story 4.5: when the member had accepted before saying they can't make
  /// it anymore (null otherwise).
  final DateTime? priorAcceptedAt;

  /// Story 4.5: the department's current leader and deputy names (no
  /// contact details; those wait on the Q4 contact routes).
  final List<DutyLeaderName> leaders;

  /// Story 4.3: the named position of a rota (null for a one-position duty).
  final String? positionName;

  /// Story 4.3: optional topic and scripture of the occurrence.
  final String? topic;
  final String? scripture;

  final String assignmentId;

  /// The assignment's revision (expected_revision of duties.respond).
  final int revision;
  final String occurrenceId;

  /// The owning department (null for a cell programme part, story 4.11).
  final String? departmentId;
  final String? departmentName;
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

  /// Story 4.8: Short notice and still waiting for an answer.
  bool answerNow(DateTime now) => shortNotice && needsResponse(now);

  /// Still asks for an answer: pending and not yet started.
  bool needsResponse(DateTime now) =>
      answerable && response == DutyResponse.pending && !startedAt(now);

  /// Story 4.5: an accepted duty that has not started can be withdrawn
  /// ("Can't make it anymore"). Story 4.9: not an acceptance a leader
  /// recorded (the server refuses it; the member tells their leader).
  bool canWithdraw(DateTime now) =>
      answerable &&
      response == DutyResponse.accepted &&
      !confirmedByLeader &&
      !startedAt(now);

  /// Story 4.5: declined after an earlier acceptance.
  bool get declinedLater =>
      response == DutyResponse.declined && priorAcceptedAt != null;

  /// "Sunday preaching: Reader" (or the duty name alone).
  String get title =>
      positionName == null ? dutyName : '$dutyName: $positionName';
}

/// Story 4.5: who owns a duty the member sees. A server before 4.5 sends no
/// owner kind and lists department-owned duties only, so a missing value is
/// a department. Story 4.11: a cell programme part. Any other value (one
/// this app does not know) is shown but cannot be answered here (fail
/// closed).
enum DutyOwnerKind {
  department,
  cell,
  other;

  static DutyOwnerKind fromWire(Object? v) => switch (v) {
    null || 'department' => department,
    'cell' => cell,
    String() => other,
    _ => throw const FormatException('unexpected owner_kind'),
  };
}

/// Story 4.5: a leader or deputy of the duty's department, by name only.
/// Story 4.11: or a leader or assistant of a cell programme part's cell.
class DutyLeaderName {
  const DutyLeaderName({
    required this.displayName,
    required this.isDeputy,
    this.isAssistant = false,
  });

  factory DutyLeaderName.fromJson(Object? json) {
    final m = _map(json, 'leader');
    final role = _req<String>(m, 'role');
    if (role != 'leader' && role != 'deputy' && role != 'assistant') {
      throw const FormatException('unexpected role');
    }
    return DutyLeaderName(
      displayName: _req<String>(m, 'display_name'),
      isDeputy: role == 'deputy',
      isAssistant: role == 'assistant',
    );
  }

  final String displayName;
  final bool isDeputy;
  final bool isAssistant;

  /// "Leader", "Deputy" or (a cell's) "Assistant".
  String get roleLabel => isAssistant
      ? 'Assistant'
      : isDeputy
      ? 'Deputy'
      : 'Leader';
}

List<DutyLeaderName> _leaders(Map m) {
  final v = m['leaders'];
  if (v == null) return const [];
  if (v is! List) throw const FormatException('unexpected leaders');
  return List.unmodifiable(v.map(DutyLeaderName.fromJson));
}

/// Story 4.5: an earlier acceptance is only ever kept on a declined answer.
DateTime? _priorAccepted(Map m, DutyResponse response) {
  final t = _optInstant(m, 'prior_accepted_at');
  if (t != null && response != DutyResponse.declined) {
    throw const FormatException('unexpected prior_accepted_at');
  }
  return t;
}

/// Story 4.5: the three My duties segments.
class MyDutySegments {
  const MyDutySegments._(this.needsResponse, this.upcoming, this.past);

  /// Needs a response: pending and not started (soonest first). Upcoming:
  /// every other duty that has not started, accepted or not (soonest
  /// first; a declined one stays visible as "Can't make it"). Past: started
  /// (most recent first).
  factory MyDutySegments.of(List<MyDuty> duties, DateTime now) {
    int soonest(MyDuty a, MyDuty b) =>
        a.times.arriveBy.compareTo(b.times.arriveBy);
    return MyDutySegments._(
      List.unmodifiable(
        duties.where((a) => a.needsResponse(now)).toList()..sort(soonest),
      ),
      List.unmodifiable(
        duties.where((a) => !a.needsResponse(now) && !a.startedAt(now)).toList()
          ..sort(soonest),
      ),
      List.unmodifiable(
        duties.where((a) => a.startedAt(now)).toList()
          ..sort((a, b) => b.times.startsAt.compareTo(a.times.startsAt)),
      ),
    );
  }

  final List<MyDuty> needsResponse;
  final List<MyDuty> upcoming;
  final List<MyDuty> past;

  /// The duty the Home card shows: the soonest that needs an answer, else
  /// the soonest upcoming one the member accepted.
  MyDuty? get next =>
      needsResponse.firstOrNull ??
      upcoming.where((a) => a.response == DutyResponse.accepted).firstOrNull;
}

/// `api.duties_my_duties`.
class MyDuties {
  const MyDuties({
    required this.memberId,
    required this.assignments,
    this.truncated = false,
    this.skipped = 0,
  });

  factory MyDuties.fromJson(Object? json) {
    final m = _map(json, 'my duties');
    // Story 4.11 (review S2): each row is read on its own. A row this app
    // cannot read (a kind of duty a later server adds) is left out and
    // logged, never fatal to the whole list.
    final rows = <MyDuty>[];
    var skipped = 0;
    for (final row in _req<List>(m, 'assignments')) {
      try {
        rows.add(MyDuty.fromJson(row));
      } on FormatException catch (e) {
        skipped++;
        developer.log(
          'My duties: a row this app cannot read was left out (${e.message})',
          name: 'church.duties',
        );
      }
    }
    return MyDuties(
      memberId: _req<String>(m, 'member_id'),
      assignments: List.unmodifiable(rows),
      truncated: _opt<bool>(m, 'truncated') ?? false,
      skipped: skipped,
    );
  }

  final String memberId;
  final List<MyDuty> assignments;

  /// Story 4.11 (review S2): rows of the answer this app could not read and
  /// left out (a newer app shows them).
  final int skipped;

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
    this.overlaps = 0,
    this.override,
    this.priorAcceptedAt,
    this.deadlineSource = DutyDeadlineSource.creator,
    this.shortNotice = false,
    this.needsContact,
    this.confirmation,
  });

  factory PositionAssignment.fromJson(Object? json) {
    final m = _map(json, 'assignment');
    final response = DutyResponse.fromWire(m['response']);
    return PositionAssignment(
      priorAcceptedAt: _priorAccepted(m, response),
      assignmentId: _req<String>(m, 'assignment_id'),
      memberId: _req<String>(m, 'member_id'),
      displayName: _opt<String>(m, 'display_name'),
      response: response,
      responseDeadline: _instant(m, 'response_deadline'),
      respondedAt: _optInstant(m, 'responded_at'),
      note: _opt<String>(m, 'note'),
      revision: _revision(m),
      slotRevision: _slotRevision(m),
      changes: _optFields(m, 'changes'),
      notesUpdatedAt: _optInstant(m, 'notes_updated_at'),
      overlaps: _overlaps(m),
      override: DutyOverride.fromJsonOrNull(m['override']),
      deadlineSource: DutyDeadlineSource.fromWire(m['deadline_source']),
      shortNotice: _shortNotice(m),
      needsContact: DutyContactNeed.fromJsonOrNull(m['needs_contact']),
      confirmation: m['response_provenance'] == 'leader'
          ? CoverageConfirmation.fromJsonOrNull(m['confirmation'])
          : null,
    );
  }

  /// Story 4.8: whose answer-by time, Short notice, and whether the leader
  /// should contact the member directly.
  final DutyDeadlineSource deadlineSource;
  final bool shortNotice;
  final DutyContactNeed? needsContact;

  /// Story 4.9: Confirmed by leader (null for the member's own answer).
  final CoverageConfirmation? confirmation;

  final String assignmentId;
  final String memberId;

  /// Story 4.5: the member accepted at this time, then said they can't make
  /// it anymore.
  final DateTime? priorAcceptedAt;

  /// Story 4.4: how many other duties of the member overlap this one now.
  final int overlaps;

  /// Story 4.4: the leader's recorded reason for assigning despite an
  /// overlap (null when none was needed).
  final DutyOverride? override;

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
    this.priorAcceptedAt,
  });

  factory AssignmentHistoryEntry.fromJson(Object? json) {
    final m = _map(json, 'history entry');
    final state = _req<String>(m, 'state');
    if (state != 'superseded' && state != 'cancelled') {
      throw const FormatException('unexpected state');
    }
    final provenance = _opt<String>(m, 'response_provenance');
    // Story 4.12: a Confirmed by leader assignment can end too (the member
    // left), so its history keeps the `leader` provenance.
    if (provenance != null &&
        provenance != 'member' &&
        provenance != 'leader') {
      throw const FormatException('unexpected response_provenance');
    }
    final response = DutyResponse.fromWire(m['response']);
    return AssignmentHistoryEntry(
      assignmentId: _req<String>(m, 'assignment_id'),
      memberId: _req<String>(m, 'member_id'),
      displayName: _opt<String>(m, 'display_name'),
      state: state,
      endReason: _opt<String>(m, 'end_reason'),
      endedAt: _instant(m, 'ended_at'),
      priorAcceptedAt: _priorAccepted(m, response),
      response: response,
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

  /// Who recorded the answer (`member`, or `leader` for Confirmed by
  /// leader).
  final String? provenance;
  final String? note;
  final int slotRevision;

  /// Story 4.5: an acceptance the member later withdrew.
  final DateTime? priorAcceptedAt;
}

class DutyPosition {
  const DutyPosition({
    required this.slotId,
    required this.positionNo,
    this.assignment,
    this.slotRevision = 1,
    this.history = const [],
    this.positionName,
    this.cancelled = false,
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
      cancelled: _opt<bool>(m, 'cancelled') ?? false,
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

  /// Story 4.9: the position was cancelled (no longer required).
  final bool cancelled;

  /// Ended assignments, newest first (at most 20).
  final List<AssignmentHistoryEntry> history;

  /// Story 4.12: nobody holds the position because the person given it can
  /// no longer serve (the newest ended assignment ended `vacated`). Never
  /// why.
  bool get vacated =>
      assignment == null &&
      !cancelled &&
      history.isNotEmpty &&
      history.first.endReason == DutyEndReasons.vacated;
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
    this.reminders,
    this.reviews = const [],
    this.linkedParts = 0,
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
      reminders: DutyReminders.fromJsonIn(m),
      reviews: DutyReview.listIn(m),
      linkedParts: _linkedParts(m),
    );
  }

  /// Story 4.8: the member reminders of this duty (null from a server
  /// before 4.8).
  final DutyReminders? reminders;

  /// Story 4.11: open owner-review mismatches (a linked meeting or event
  /// changed); the duty itself did not change.
  final List<DutyReview> reviews;

  /// Story 4.11: how many cell programme parts show this duty (display
  /// links; the department keeps sole authority).
  final int linkedParts;

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

  /// Story 4.9: the positions still required (cancelled ones are not).
  int get required => positions.where((p) => !p.cancelled).length;

  /// The assignee of a one-position duty (null with several positions: a
  /// rota position is given with duties.assign_slot).
  String? get memberId =>
      positions.length != 1 ? null : positions.first.assignment?.memberId;
}

/// Story 4.11: an owner-review mismatch on a department duty. A linked cell
/// meeting or event changed; the duty, its answers and its reminders did not.
/// Only codes travel (never the meeting's or event's details).
class DutyReview {
  const DutyReview({
    required this.flagId,
    required this.revision,
    required this.source,
    required this.changed,
    required this.flaggedAt,
  });

  factory DutyReview.fromJson(Object? json) {
    final m = _map(json, 'review');
    final source = _req<String>(m, 'source');
    if (source != 'cell_part' && source != 'event') {
      throw const FormatException('unexpected review source');
    }
    final changed = _req<List>(m, 'changed');
    if (changed.isEmpty || changed.any((c) => !reviewFields.contains(c))) {
      throw const FormatException('unexpected review fields');
    }
    return DutyReview(
      flagId: _req<String>(m, 'flag_id'),
      revision: _revision(m),
      source: source,
      changed: List.unmodifiable(changed.cast<String>()),
      flaggedAt: _instant(m, 'flagged_at'),
    );
  }

  /// The open reviews in a duty answer (none from a server before 4.11).
  static List<DutyReview> listIn(Map m) {
    final v = m['reviews'];
    if (v == null) return const [];
    if (v is! List) throw const FormatException('unexpected reviews');
    return List.unmodifiable(v.map(DutyReview.fromJson));
  }

  /// The change codes the server sends, in the order they are read.
  static const reviewFields = [
    'time',
    'place',
    'label',
    'assignee',
    'cancelled',
  ];

  final String flagId;

  /// The review's revision (expected_revision of duties.clear_review).
  final int revision;

  /// `cell_part` (a linked cell meeting) or `event` (a linked event).
  final String source;
  final List<String> changed;
  final DateTime flaggedAt;

  /// "The linked cell meeting changed (time, place)".
  String get summary {
    const words = {
      'time': 'time',
      'place': 'place',
      'label': 'name',
      'assignee': 'person',
      'cancelled': 'cancelled',
    };
    final what = [
      for (final f in reviewFields)
        if (changed.contains(f)) words[f]!,
    ].join(', ');
    return '${source == 'event' ? 'The linked event' : 'A linked cell meeting'} '
        'changed ($what)';
  }
}

int _linkedParts(Map m) {
  final v = m['linked_parts'];
  if (v == null) return 0;
  if (v is! int || v < 0) {
    throw const FormatException('unexpected linked_parts');
  }
  return v;
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
    this.contactNotices = const [],
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
      contactNotices: m['contact_notices'] == null
          ? const []
          : List.unmodifiable(
              _req<List>(m, 'contact_notices').map(DutyContactNotice.fromJson),
            ),
    );
  }

  /// Story 4.8 (review): notices the leader must still pass on in person to
  /// members the app cannot reach (released from a position, a cancelled
  /// date). Empty from a server before 4.8 and for Pastor oversight.
  final List<DutyContactNotice> contactNotices;

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
    this.handovers = const [],
    this.needsLeader = false,
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
      // Story 4.12 (absent from older servers: none pending).
      handovers: m['handovers'] == null
          ? const []
          : List.unmodifiable(
              _req<List>(m, 'handovers').map(DepartmentHandover.fromJson),
            ),
      needsLeader: _opt<bool>(m, 'needs_leader') ?? false,
    );
  }

  final String departmentId;
  final String name;
  final bool isSynthetic;

  /// Story 4.12: pending leader handovers (the last leader or deputy left
  /// while being deleted); resolved with duties.resolve_handover.
  final List<DepartmentHandover> handovers;

  /// Story 4.12: no approved leader or deputy the app can reach.
  final bool needsLeader;

  /// The department's revision (expected_revision of duties.add_member).
  final int revision;
  final List<DepartmentStaff> leaders;
  final List<DepartmentStaff> deputies;
  final List<DepartmentMember> members;

  bool hasMember(String memberId) => members.any((m) => m.memberId == memberId);
}

/// Story 4.12: one pending department handover (ids and time only).
class DepartmentHandover {
  const DepartmentHandover({
    required this.obligationId,
    required this.recordedAt,
  });

  factory DepartmentHandover.fromJson(Object? json) {
    final m = _map(json, 'handover');
    return DepartmentHandover(
      obligationId: _req<String>(m, 'obligation_id'),
      recordedAt: _instant(m, 'recorded_at'),
    );
  }

  final String obligationId;
  final DateTime recordedAt;
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
    this.responseDeadline,
    this.endsAt,
    this.reportingAt,
    this.location,
    this.instructions,
    this.overrideReason,
    this.reminders,
  });

  final String departmentId;
  final String dutyName;
  final DateTime startsAt;
  final DateTime? endsAt;
  final DateTime? reportingAt;
  final String? location;
  final String? instructions;
  final String memberId;

  /// Story 4.8: null = the church's lead-time default.
  final DateTime? responseDeadline;

  /// Story 4.8: the creator's member reminders (null = the defaults; empty =
  /// none).
  final List<DutyReminderSpec>? reminders;

  /// Story 4.4: why the member is assigned although another duty overlaps.
  final String? overrideReason;

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
      if (responseDeadline case final d?) 'response_deadline': utc(d),
      'override_reason': ?DutyOverride.clean(overrideReason),
      if (reminders case final r?) 'reminders': [for (final x in r) x.toJson()],
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
    this.overrideReason,
  });

  final LeaderDuty duty;

  /// Story 4.4: why, when the change puts someone into an overlap.
  final String? overrideReason;
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
      if (material) 'override_reason': ?DutyOverride.clean(overrideReason),
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
    this.overlaps = 0,
    this.overrideReason,
  });

  factory RotaPerson.fromJson(Object? json) {
    final m = _map(json, 'rota person');
    return RotaPerson(
      memberId: _req<String>(m, 'member_id'),
      displayName: _opt<String>(m, 'display_name'),
      available: _req<bool>(m, 'available'),
      overlaps: _overlaps(m),
      overrideReason: _opt<String>(m, 'override_reason'),
    );
  }

  final String memberId;
  final String? displayName;
  final bool available;

  /// Story 4.4: other duties (and plans of this department) that overlap.
  final int overlaps;

  /// Story 4.4: the planned reason to assign despite an overlap.
  final String? overrideReason;
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
    this.overlaps = 0,
    this.override,
    this.priorAcceptedAt,
    this.deadlineSource = DutyDeadlineSource.creator,
    this.shortNotice = false,
    this.needsContact,
    this.confirmedByLeader = false,
  });

  factory RotaAssignment.fromJson(Object? json) {
    final m = _map(json, 'rota assignment');
    final response = DutyResponse.fromWire(m['response']);
    return RotaAssignment(
      assignmentId: _req<String>(m, 'assignment_id'),
      memberId: _req<String>(m, 'member_id'),
      displayName: _opt<String>(m, 'display_name'),
      priorAcceptedAt: _priorAccepted(m, response),
      response: response,
      responseDeadline: _instant(m, 'response_deadline'),
      revision: _revision(m),
      available: _req<bool>(m, 'available'),
      overlaps: _overlaps(m),
      override: DutyOverride.fromJsonOrNull(m['override']),
      deadlineSource: DutyDeadlineSource.fromWire(m['deadline_source']),
      shortNotice: _shortNotice(m),
      needsContact: DutyContactNeed.fromJsonOrNull(m['needs_contact']),
      confirmedByLeader: m['response_provenance'] == 'leader',
    );
  }

  /// Story 4.9: accepted through Confirmed by leader.
  final bool confirmedByLeader;

  /// Story 4.8.
  final DutyDeadlineSource deadlineSource;
  final bool shortNotice;
  final DutyContactNeed? needsContact;

  /// Story 4.4: overlapping duties now, and the recorded override.
  final int overlaps;
  final DutyOverride? override;

  /// Story 4.5: accepted at this time, then "can't make it anymore".
  final DateTime? priorAcceptedAt;

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
    this.cancelled = false,
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
      cancelled: _opt<bool>(m, 'cancelled') ?? false,
    );
  }

  /// Story 4.9: the position was cancelled.
  final bool cancelled;

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
    this.reminders,
    this.reviews = const [],
    this.linkedParts = 0,
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
      reminders: DutyReminders.fromJsonIn(m),
      reviews: DutyReview.listIn(m),
      linkedParts: _linkedParts(m),
    );
  }

  /// Story 4.8: this date's member reminders (null from a server before
  /// 4.8).
  final DutyReminders? reminders;

  /// Story 4.11: open owner-review mismatches of this date.
  final List<DutyReview> reviews;

  /// Story 4.11: how many cell programme parts show this date.
  final int linkedParts;

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
  /// Story 4.8: the pickers' "church default" entry (no lead time is sent;
  /// each date takes the 3.3 lead-time default).
  static const churchDefault = '';

  /// [lead], or null for [churchDefault].
  static String? wire(String lead) => lead == churchDefault ? null : lead;

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
    this.reminders,
  });

  /// Story 4.8: the member reminders of every date (null = the defaults).
  final List<DutyReminderSpec>? reminders;

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
    if (reminders case final r?) 'reminders': [for (final x in r) x.toJson()],
  };

  /// Story 4.8: the same draft with the creator's reminders.
  SeriesDraft withReminders(List<DutyReminderSpec>? r) => SeriesDraft(
    departmentId: departmentId,
    dutyName: dutyName,
    every: every,
    interval: interval,
    fromDate: fromDate,
    untilDate: untilDate,
    startTime: startTime,
    endTime: endTime,
    reportingTime: reportingTime,
    location: location,
    instructions: instructions,
    topic: topic,
    scripture: scripture,
    positions: positions,
    reminders: r,
  );
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
    this.overrideReason,
  });

  final RotaOccurrence occurrence;

  /// Story 4.4: why, when new times put an assignee into an overlap.
  final String? overrideReason;
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
      if (needsLead) 'override_reason': ?DutyOverride.clean(overrideReason),
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
      if (material) 'override_reason': ?DutyOverride.clean(overrideReason),
    };
  }
}

// ---------------------------------------------------------------------------
// Story 4.4: overlaps, load and reasoned overrides (`api.duties_candidates`)
// ---------------------------------------------------------------------------

/// A leader's recorded reason for assigning someone despite an overlap. The
/// member does not see it; [reason] is null once the assignee was erased.
class DutyOverride {
  const DutyOverride({required this.at, this.reason, this.overlaps, this.by});

  static DutyOverride? fromJsonOrNull(Object? json) {
    if (json == null) return null;
    final m = _map(json, 'override');
    final n = _opt<int>(m, 'overlaps');
    if (n != null && n < 1) throw const FormatException('unexpected overlaps');
    return DutyOverride(
      reason: _opt<String>(m, 'reason'),
      overlaps: n,
      at: _instant(m, 'at'),
      by: _opt<String>(m, 'by'),
    );
  }

  /// At most this many characters (the server refuses longer).
  static const maxLength = 280;

  /// A reason as sent: trimmed, null when blank.
  static String? clean(String? reason) {
    final t = reason?.trim();
    return t == null || t.isEmpty ? null : t;
  }

  /// Did the server refuse for an overlap without a reason?
  static bool required(Map<String, String> fieldErrors) =>
      fieldErrors['override_reason'] == 'required';

  final String? reason;
  final int? overlaps;
  final DateTime at;

  /// Who recorded it (null once erased).
  final String? by;
}

/// One overlapping duty of a candidate, as the viewer may see it. A
/// limited conflict (another department's duty, or a cell programme part
/// the viewer does not lead) carries only its owner kind and busy time.
class DutyConflict {
  const DutyConflict({
    required this.full,
    required this.ownerKind,
    required this.from,
    required this.to,
    this.occurrenceId,
    this.ownerName,
    this.dutyName,
    this.positionName,
    this.state,
    this.response,
    this.times,
    this.location,
  });

  factory DutyConflict.fromJson(Object? json) {
    final m = _map(json, 'conflict');
    final visibility = _req<String>(m, 'visibility');
    final kind = _req<String>(m, 'owner_kind');
    if (visibility != 'full' && visibility != 'limited') {
      throw const FormatException('unexpected visibility');
    }
    if (kind != 'department' && kind != 'cell') {
      throw const FormatException('unexpected owner_kind');
    }
    final full = visibility == 'full';
    final state = full ? _req<String>(m, 'state') : null;
    if (state != null && state != 'published' && state != 'draft') {
      throw const FormatException('unexpected state');
    }
    return DutyConflict(
      full: full,
      ownerKind: kind,
      from: _instant(m, 'from'),
      to: _instant(m, 'to'),
      occurrenceId: full ? _req<String>(m, 'occurrence_id') : null,
      ownerName: full ? _opt<String>(m, 'owner_name') : null,
      dutyName: full ? _req<String>(m, 'duty_name') : null,
      positionName: full ? _opt<String>(m, 'position_name') : null,
      state: state,
      response: full && m['response'] != null
          ? DutyResponse.fromWire(m['response'])
          : null,
      times: full ? DutyTimes.fromJson(m) : null,
      location: full ? _opt<String>(m, 'location') : null,
    );
  }

  final bool full;

  /// `department` or `cell`.
  final String ownerKind;

  /// The busy time: reporting time (or start) to end time (or two hours).
  final DateTime from;
  final DateTime to;

  final String? occurrenceId;
  final String? ownerName;
  final String? dutyName;
  final String? positionName;

  /// `published`, or `draft` (a plan of this department).
  final String? state;
  final DutyResponse? response;
  final DutyTimes? times;
  final String? location;

  bool get isCell => ownerKind == 'cell';
  bool get isDraft => state == 'draft';

  /// Who owns it, in words.
  String get ownerLabel => switch ((full, isCell)) {
    (false, false) => 'Another department\'s duty',
    (false, true) => 'A cell programme part',
    (true, true) => 'Your cell\'s programme',
    (true, false) => ownerName ?? 'A department',
  };
}

/// One roster member as the assignment picker shows them.
class CandidateCheck {
  const CandidateCheck({
    required this.memberId,
    required this.displayName,
    required this.account,
    required this.current,
    required this.upcomingTotal,
    required this.upcomingHere,
    required this.conflictCount,
    required this.conflicts,
  });

  factory CandidateCheck.fromJson(Object? json) {
    final m = _map(json, 'candidate');
    final upcoming = _map(m['upcoming'], 'upcoming');
    final c = _map(m['conflicts'], 'conflicts');
    final total = _req<int>(upcoming, 'total');
    final here = _req<int>(upcoming, 'here');
    final count = _req<int>(c, 'count');
    final items = List<DutyConflict>.unmodifiable(
      _req<List>(c, 'items').map(DutyConflict.fromJson),
    );
    if (total < 0 || here < 0 || here > total || count < items.length) {
      throw const FormatException('unexpected counts');
    }
    return CandidateCheck(
      memberId: _req<String>(m, 'member_id'),
      displayName: _req<String>(m, 'display_name'),
      account: _account(m['account']),
      current: _req<bool>(m, 'current'),
      upcomingTotal: total,
      upcomingHere: here,
      conflictCount: count,
      conflicts: items,
    );
  }

  final String memberId;
  final String displayName;
  final AccountStanding account;

  /// Holds (or is planned for) the position asked about.
  final bool current;

  /// Duties awaiting an answer or accepted in the next 90 days: all owners,
  /// and in this department.
  final int upcomingTotal;
  final int upcomingHere;

  /// Overlapping duties in all, and the first ones (at most 10).
  final int conflictCount;
  final List<DutyConflict> conflicts;

  bool get overlaps => conflictCount > 0;

  /// "3 upcoming (1 here)".
  String get loadLabel =>
      '$upcomingTotal upcoming'
      '${upcomingTotal == upcomingHere ? '' : ' ($upcomingHere here)'}';
}

/// `api.duties_candidates`.
class DutyCandidates {
  const DutyCandidates({
    required this.departmentId,
    required this.from,
    required this.to,
    required this.candidates,
    this.slotId,
  });

  factory DutyCandidates.fromJson(Object? json) {
    final m = _map(json, 'candidates read');
    final w = _map(m['window'], 'window');
    return DutyCandidates(
      departmentId: _req<String>(m, 'department_id'),
      slotId: _opt<String>(m, 'slot_id'),
      from: _instant(w, 'from'),
      to: _instant(w, 'to'),
      candidates: List.unmodifiable(
        _req<List>(m, 'candidates').map(CandidateCheck.fromJson),
      ),
    );
  }

  final String departmentId;
  final String? slotId;

  /// The busy time asked about.
  final DateTime from;
  final DateTime to;
  final List<CandidateCheck> candidates;

  CandidateCheck? of(String? memberId) {
    for (final c in candidates) {
      if (c.memberId == memberId) return c;
    }
    return null;
  }
}

/// What the candidates read is asked about: a position (at its own times,
/// or at the new times of an edit), or the busy time of a one-off duty not
/// published yet. Equal queries share one read.
class CandidateQuery {
  const CandidateQuery.slot(
    String this.slotId, {
    this.startsAt,
    this.endsAt,
    this.reportingAt,
  }) : departmentId = null;

  const CandidateQuery.window({
    required String this.departmentId,
    required DateTime this.startsAt,
    this.endsAt,
    this.reportingAt,
  }) : slotId = null;

  final String? slotId;
  final String? departmentId;
  final DateTime? startsAt;
  final DateTime? endsAt;
  final DateTime? reportingAt;

  /// The named parameters of `api.duties_candidates`.
  Map<String, Object?> toParams() {
    String utc(DateTime t) => t.toUtc().toIso8601String();
    return {
      'slot_id': ?slotId,
      'department_id': ?departmentId,
      if (startsAt case final s?) 'starts_at': utc(s),
      if (endsAt case final e?) 'ends_at': utc(e),
      if (reportingAt case final r?) 'reporting_at': utc(r),
    };
  }

  @override
  bool operator ==(Object other) =>
      other is CandidateQuery &&
      other.slotId == slotId &&
      other.departmentId == departmentId &&
      other.startsAt == startsAt &&
      other.endsAt == endsAt &&
      other.reportingAt == reportingAt;

  @override
  int get hashCode =>
      Object.hash(slotId, departmentId, startsAt, endsAt, reportingAt);
}

/// Application port for the duties reads. Never throws; a fresh request
/// every call.
abstract interface class DutiesRepository {
  Future<AccessRead<MyDuties>> fetchMyDuties();
  Future<AccessRead<DutyLeaderBoard>> fetchLeaderBoard();
  Future<AccessRead<DutyAdminOverview>> fetchAdminOverview();

  /// Story 4.3: `api.duties_rota`.
  Future<AccessRead<DutyRota>> fetchRota();

  /// Story 4.4: `api.duties_candidates` for a position or a prospective
  /// one-off duty.
  Future<AccessRead<DutyCandidates>> fetchCandidates(CandidateQuery query);
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

  @override
  Future<AccessRead<DutyCandidates>> fetchCandidates(
    CandidateQuery query,
  ) async => const AccessReadDenied(AccessDenial.unavailable);
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

// ---------------------------------------------------------------------------
// Story 4.8: answer-by defaults, Short notice, reminders and Needs contact
// ---------------------------------------------------------------------------

bool _shortNotice(Map m) => _opt<bool>(m, 'short_notice') ?? false;

/// Whose answer-by time an assignment has. A server before 4.8 sends none:
/// every deadline then was the leader's.
enum DutyDeadlineSource {
  creator('creator'),
  churchDefault('default');

  const DutyDeadlineSource(this.wire);
  final String wire;

  static DutyDeadlineSource fromWire(Object? v) {
    if (v == null) return creator;
    for (final s in values) {
      if (s.wire == v) return s;
    }
    throw FormatException('unexpected deadline_source $v');
  }
}

/// What a reminder is relative to.
enum DutyReminderAnchor {
  /// The answer-by time (stops once the member answered).
  deadline('response_deadline'),

  /// The reporting time, or the start (kept after an acceptance).
  start('starts_at');

  const DutyReminderAnchor(this.wire);
  final String wire;

  static DutyReminderAnchor fromWire(Object? v) {
    for (final a in values) {
      if (a.wire == v) return a;
    }
    throw FormatException('unexpected anchor $v');
  }
}

/// One member reminder the creator chose: [offset] (`<n> minutes|hours|days`)
/// before (or [after]) its [anchor].
class DutyReminderSpec {
  const DutyReminderSpec.before(this.anchor, this.offset) : after = false;
  const DutyReminderSpec.after(this.anchor, this.offset) : after = true;

  factory DutyReminderSpec.fromJson(Object? json) {
    final m = _map(json, 'reminder');
    final anchor = DutyReminderAnchor.fromWire(m['anchor']);
    final before = _opt<String>(m, 'before');
    final after = _opt<String>(m, 'after');
    if ((before == null) == (after == null)) {
      throw const FormatException('unexpected reminder');
    }
    return before != null
        ? DutyReminderSpec.before(anchor, before)
        : DutyReminderSpec.after(anchor, after!);
  }

  final DutyReminderAnchor anchor;
  final String offset;
  final bool after;

  Map<String, Object?> toJson() => {
    'anchor': anchor.wire,
    if (after) 'after': offset else 'before': offset,
  };

  /// "24 hours before the answer-by time", "at the answer-by time",
  /// "2 hours before the start".
  String get label => labelFor();

  /// Review: with a reporting time the start anchor is the reporting time.
  String labelFor({bool reporting = false}) {
    final what = anchor == DutyReminderAnchor.deadline
        ? 'the answer-by time'
        : (reporting ? 'the reporting time' : 'the start');
    final parts = offset.split(' ');
    if (parts.length != 2) return '$offset ${after ? 'after' : 'before'} $what';
    if (parts[0] == '0') return 'at $what';
    final unit = parts[0] == '1' && parts[1].endsWith('s')
        ? parts[1].substring(0, parts[1].length - 1)
        : parts[1];
    return '${parts[0]} $unit ${after ? 'after' : 'before'} $what';
  }

  @override
  bool operator ==(Object other) =>
      other is DutyReminderSpec &&
      other.anchor == anchor &&
      other.offset == offset &&
      other.after == after;

  @override
  int get hashCode => Object.hash(anchor, offset, after);
}

/// The member reminders a creator may pick (staff web).
const dutyReminderChoices = [
  DutyReminderSpec.before(DutyReminderAnchor.deadline, '2 days'),
  DutyReminderSpec.before(DutyReminderAnchor.deadline, '24 hours'),
  DutyReminderSpec.before(DutyReminderAnchor.deadline, '0 minutes'),
  DutyReminderSpec.before(DutyReminderAnchor.start, '24 hours'),
  DutyReminderSpec.before(DutyReminderAnchor.start, '2 hours'),
];

/// The member reminders of a duty: [specs] null = the church defaults.
class DutyReminders {
  const DutyReminders([this.specs]);

  /// Reads `reminders` from [m] (null when the server sent no such key: a
  /// server before 4.8).
  static DutyReminders? fromJsonIn(Map m) {
    if (!m.containsKey('reminders')) return null;
    final v = m['reminders'];
    if (v == null) return const DutyReminders();
    if (v is! List) throw const FormatException('unexpected reminders');
    return DutyReminders(List.unmodifiable(v.map(DutyReminderSpec.fromJson)));
  }

  final List<DutyReminderSpec>? specs;

  bool get isDefault => specs == null;

  /// The wire value (`null` = the defaults).
  List<Map<String, Object?>>? toWire() =>
      specs == null ? null : [for (final s in specs!) s.toJson()];

  /// What leaders and members read.
  String get text => textFor();

  /// Review: "before the reporting time" when the duty has one.
  String textFor({bool reporting = false}) => switch (specs) {
    null =>
      'Reminders: the defaults (24 hours before and at the answer-by time, '
          'and 24 hours before ${reporting ? 'the reporting time' : 'the start'}).',
    final s when s.isEmpty => 'Reminders: none.',
    final s =>
      'Reminders: ${s.map((x) => x.labelFor(reporting: reporting)).join(', ')}.',
  };
}

/// Story 4.8: why the leader should contact a member directly.
/// [shortNotice]: given at short notice and not answered yet; [notReached]:
/// a notice or reminder could not reach the member in the app (no reason is
/// ever given).
class DutyContactNeed {
  const DutyContactNeed({
    required this.shortNotice,
    required this.notReached,
    required this.since,
  });

  static DutyContactNeed? fromJsonOrNull(Object? json) {
    if (json == null) return null;
    final m = _map(json, 'needs_contact');
    final reasons = _ids(m, 'reasons');
    if (reasons.isEmpty ||
        reasons.any((r) => r != 'short_notice' && r != 'not_reached')) {
      throw const FormatException('unexpected reasons');
    }
    return DutyContactNeed(
      shortNotice: reasons.contains('short_notice'),
      notReached: reasons.contains('not_reached'),
      since: _instant(m, 'since'),
    );
  }

  final bool shortNotice;
  final bool notReached;
  final DateTime since;

  /// What the leader reads.
  String get text => [
    if (shortNotice) 'Given at short notice: ask for an answer now',
    if (notReached) 'Reminders cannot reach them in the app',
  ].join('; ');
}

/// Story 4.8 (review): a notice to pass on in person to a member the app
/// cannot reach (never why): released from a position, or the date was
/// cancelled. Listed until the duty would have started.
class DutyContactNotice {
  const DutyContactNotice({
    required this.assignmentId,
    required this.memberId,
    required this.occurrenceId,
    required this.dutyName,
    required this.startsAt,
    required this.cancelled,
    required this.since,
    this.displayName,
    this.positionName,
  });

  factory DutyContactNotice.fromJson(Object? json) {
    final m = _map(json, 'contact notice');
    final notice = _req<String>(m, 'notice');
    if (notice != 'released' && notice != 'cancelled') {
      throw const FormatException('unexpected notice');
    }
    return DutyContactNotice(
      assignmentId: _req<String>(m, 'assignment_id'),
      memberId: _req<String>(m, 'member_id'),
      displayName: _opt<String>(m, 'display_name'),
      occurrenceId: _req<String>(m, 'occurrence_id'),
      dutyName: _req<String>(m, 'duty_name'),
      positionName: _opt<String>(m, 'position_name'),
      startsAt: _instant(m, 'starts_at'),
      cancelled: notice == 'cancelled',
      since: _instant(m, 'since'),
    );
  }

  final String assignmentId;
  final String memberId;
  final String? displayName;
  final String occurrenceId;
  final String dutyName;
  final String? positionName;
  final DateTime startsAt;

  /// The date was cancelled (otherwise the position went to someone else).
  final bool cancelled;
  final DateTime since;

  String get title =>
      positionName == null ? dutyName : '$dutyName: $positionName';
}

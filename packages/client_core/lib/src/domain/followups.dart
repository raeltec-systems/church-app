/// Story 4.6: follow-up tasks as the server reports them. One task per
/// source and purpose with one accountable owner, a supervising scope, a
/// next action, the original due date and an Open / In progress / Waiting /
/// Done / Closed state. The owner, the holders of the task's scope and an
/// Admin (routing metadata only) are decided by the server; these reads are
/// presentation only. Free of widgets and SDKs.
library;

import 'access_grants.dart';

/// The follow-ups command function and command names (1.4 envelope).
abstract final class FollowUpCommands {
  static const function = 'followups_command';
  static const createTask = 'followups.create_task';
  static const updateTask = 'followups.update_task';
  static const reassign = 'followups.reassign';
}

/// A task's state (wire codes).
enum FollowUpState {
  open('open'),
  inProgress('in_progress'),
  waiting('waiting'),
  done('done'),
  closed('closed');

  const FollowUpState(this.wire);
  final String wire;

  static FollowUpState fromWire(Object? v) {
    for (final s in values) {
      if (s.wire == v) return s;
    }
    throw FormatException('unexpected state $v');
  }

  bool get active => this == open || this == inProgress || this == waiting;

  String get label => switch (this) {
    open => 'Open',
    inProgress => 'In progress',
    waiting => 'Waiting',
    done => 'Done',
    closed => 'Closed',
  };
}

/// Who may act, as the server answered for the reader.
enum FollowUpCapacity {
  owner('owner'),
  supervisor('supervisor'),
  admin('admin'),
  source('source');

  const FollowUpCapacity(this.wire);
  final String wire;

  static FollowUpCapacity fromWire(Object? v) {
    for (final c in values) {
      if (c.wire == v) return c;
    }
    throw FormatException('unexpected capacity $v');
  }
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

List<String> _tokens(Map json, String key) => List.unmodifiable(
  _req<List>(json, key).map((v) {
    if (v is! String) throw FormatException('unexpected $key');
    return v;
  }),
);

/// An outcome or purpose code as words ("no_longer_needed" -> "No longer
/// needed").
String followUpCodeLabel(String code) {
  final words = code.replaceAll('_', ' ');
  return words.isEmpty ? words : words[0].toUpperCase() + words.substring(1);
}

/// A member on a task: null [displayName] once the member was erased.
class FollowUpPerson {
  const FollowUpPerson({
    required this.memberId,
    required this.account,
    this.displayName,
  });

  factory FollowUpPerson.fromJson(Object? json) {
    final m = _map(json, 'person');
    return FollowUpPerson(
      memberId: _req<String>(m, 'member_id'),
      displayName: _opt<String>(m, 'display_name'),
      account: _account(m['account']),
    );
  }

  final String memberId;
  final String? displayName;
  final AccountStanding account;

  String get name => displayName ?? 'Former member';
}

/// The task's supervising scope (an Identity scope grant).
class FollowUpScope {
  const FollowUpScope({required this.scopeKind, required this.scopeId});

  factory FollowUpScope.fromJson(Object? json) {
    final m = _map(json, 'scope');
    return FollowUpScope(
      scopeKind: _req<String>(m, 'scope_kind'),
      scopeId: _req<String>(m, 'scope_id'),
    );
  }

  final String scopeKind;
  final String scopeId;

  /// "Department leader ab12cd34" (SYNTHETIC scopes have no shared name
  /// read yet; the id prefix tells two scopes apart).
  String get label =>
      '${followUpCodeLabel(scopeKind)} ${scopeId.length >= 8 ? scopeId.substring(0, 8) : scopeId}';

  bool same(FollowUpScope other) =>
      other.scopeKind == scopeKind && other.scopeId == scopeId;
}

/// The routing metadata every reader of a task gets (Admin gets only this).
class FollowUpRouting {
  const FollowUpRouting({
    required this.taskId,
    required this.revision,
    required this.sourceType,
    required this.purpose,
    required this.purposeLabel,
    required this.owner,
    required this.supervisor,
    required this.scope,
    required this.state,
    required this.dueAt,
    required this.overdue,
    required this.duePassed,
    required this.createdAt,
    required this.updatedAt,
    this.reviewAt,
    this.finishedAt,
  });

  factory FollowUpRouting.fromJson(Object? json) {
    final m = _map(json, 'routing task');
    final state = FollowUpState.fromWire(m['state']);
    final review = _optInstant(m, 'review_at');
    if ((state == FollowUpState.waiting) != (review != null)) {
      throw const FormatException('unexpected review_at');
    }
    final finished = _optInstant(m, 'finished_at');
    if (state.active == (finished != null)) {
      throw const FormatException('unexpected finished_at');
    }
    return FollowUpRouting(
      taskId: _req<String>(m, 'task_id'),
      revision: _revision(m),
      sourceType: _req<String>(m, 'source_type'),
      purpose: _req<String>(m, 'purpose'),
      purposeLabel: _req<String>(m, 'purpose_label'),
      owner: FollowUpPerson.fromJson(m['owner']),
      supervisor: FollowUpPerson.fromJson(m['supervisor']),
      scope: FollowUpScope.fromJson(m['scope']),
      state: state,
      dueAt: _instant(m, 'due_at'),
      reviewAt: review,
      overdue: _req<bool>(m, 'overdue'),
      duePassed: _req<bool>(m, 'due_passed'),
      finishedAt: finished,
      createdAt: _instant(m, 'created_at'),
      updatedAt: _instant(m, 'updated_at'),
    );
  }

  final String taskId;

  /// The task's revision (expected_revision of update and reassign).
  final int revision;
  final String sourceType;
  final String purpose;
  final String purposeLabel;
  final FollowUpPerson owner;
  final FollowUpPerson supervisor;
  final FollowUpScope scope;
  final FollowUpState state;

  /// The original due date; it never moves, also while Waiting.
  final DateTime dueAt;

  /// The next review date (Waiting only).
  final DateTime? reviewAt;

  /// Past the due date (Open / In progress) or the review date (Waiting).
  final bool overdue;

  /// The original due date has passed (kept while Waiting).
  final bool duePassed;
  final DateTime? finishedAt;
  final DateTime createdAt;
  final DateTime updatedAt;

  /// The date that asks for action now: the review date while Waiting.
  DateTime get actionableAt => reviewAt ?? dueAt;
}

/// A task as its owner or a holder of its scope sees it.
class FollowUpTask {
  const FollowUpTask({
    required this.routing,
    required this.sourceId,
    required this.nextAction,
    required this.outcomes,
    required this.capacity,
    required this.canUpdate,
    required this.canReassign,
    this.contextLabel,
    this.latestOutcome,
    this.closeCode,
    this.closeReason,
  });

  factory FollowUpTask.fromJson(Object? json) {
    final m = _map(json, 'task');
    final context = m['context'];
    return FollowUpTask(
      routing: FollowUpRouting.fromJson(m),
      sourceId: _req<String>(m, 'source_id'),
      contextLabel: context == null
          ? null
          : _req<String>(_map(context, 'context'), 'label'),
      nextAction: _req<String>(m, 'next_action'),
      latestOutcome: _opt<String>(m, 'latest_outcome'),
      outcomes: _tokens(m, 'outcomes'),
      closeCode: _opt<String>(m, 'close_code'),
      closeReason: _opt<String>(m, 'close_reason'),
      capacity: FollowUpCapacity.fromWire(m['capacity']),
      canUpdate: _req<bool>(m, 'can_update'),
      canReassign: _req<bool>(m, 'can_reassign'),
    );
  }

  final FollowUpRouting routing;
  final String sourceId;

  /// The source's minimal context for this reader (null when none).
  final String? contextLabel;
  final String nextAction;
  final String? latestOutcome;

  /// The outcome codes the source registered for this purpose.
  final List<String> outcomes;

  /// `manual`, `source_resolved` or `source_cancelled` once Closed.
  final String? closeCode;
  final String? closeReason;
  final FollowUpCapacity capacity;
  final bool canUpdate;
  final bool canReassign;

  String get taskId => routing.taskId;
  int get revision => routing.revision;
  FollowUpState get state => routing.state;
}

/// `api.followups_my_tasks`.
class MyFollowUps {
  const MyFollowUps({
    required this.memberId,
    required this.tasks,
    required this.truncated,
  });

  factory MyFollowUps.fromJson(Object? json) {
    final m = _map(json, 'my follow-ups');
    return MyFollowUps(
      memberId: _req<String>(m, 'member_id'),
      tasks: List.unmodifiable(
        _req<List>(m, 'tasks').map(FollowUpTask.fromJson),
      ),
      truncated: _req<bool>(m, 'truncated'),
    );
  }

  final String memberId;
  final List<FollowUpTask> tasks;
  final bool truncated;

  List<FollowUpTask> get active =>
      tasks.where((t) => t.state.active).toList(growable: false);

  int get overdue => active.where((t) => t.routing.overdue).length;
}

/// One entry of a task's activity (content-free).
class FollowUpActivity {
  const FollowUpActivity({
    required this.at,
    required this.action,
    required this.capacity,
    this.actor,
    this.onBehalfOf,
    this.fromState,
    this.toState,
    this.outcome,
    this.reviewAt,
    this.fromMember,
    this.toMember,
    this.code,
  });

  factory FollowUpActivity.fromJson(Object? json) {
    final m = _map(json, 'activity');
    FollowUpState? state(String key) =>
        m[key] == null ? null : FollowUpState.fromWire(m[key]);
    return FollowUpActivity(
      at: _instant(m, 'at'),
      action: _req<String>(m, 'action'),
      capacity: FollowUpCapacity.fromWire(m['capacity']),
      actor: _opt<String>(m, 'actor'),
      onBehalfOf: _opt<String>(m, 'on_behalf_of'),
      fromState: state('from_state'),
      toState: state('to_state'),
      outcome: _opt<String>(m, 'outcome'),
      reviewAt: _optInstant(m, 'review_at'),
      fromMember: _opt<String>(m, 'from_member'),
      toMember: _opt<String>(m, 'to_member'),
      code: _opt<String>(m, 'code'),
    );
  }

  final DateTime at;
  final String action;
  final FollowUpCapacity capacity;
  final String? actor;
  final String? onBehalfOf;
  final FollowUpState? fromState;
  final FollowUpState? toState;
  final String? outcome;
  final DateTime? reviewAt;
  final String? fromMember;
  final String? toMember;
  final String? code;

  /// "Status: Open to In progress", "Reassigned to X", ...
  String get summary => switch (action) {
    'created' => 'Task opened',
    'status_changed' =>
      'Status: ${fromState?.label ?? '?'} to ${toState?.label ?? '?'}',
    'review_date_set' => 'Review date changed',
    'outcome_recorded' =>
      'Outcome: ${followUpCodeLabel(outcome ?? 'recorded')}',
    'next_action_changed' => 'Next action changed',
    'note_added' => 'Private note added',
    'reassigned' => 'Reassigned to ${toMember ?? 'a former member'}',
    'supervisor_changed' =>
      'Supervisor changed to ${toMember ?? 'a former member'}',
    'closed_by_source' => 'Closed by its source (${code ?? 'event'})',
    _ => followUpCodeLabel(action),
  };

  /// "by X for Y", "by X", or "by its source".
  String get attribution {
    if (capacity == FollowUpCapacity.source && actor == null) {
      return 'by its source';
    }
    final who = actor ?? 'a former member';
    return onBehalfOf == null ? 'by $who' : 'recorded by $who for $onBehalfOf';
  }
}

/// One private note (owner and scope holders only).
class FollowUpNote {
  const FollowUpNote({
    required this.noteId,
    required this.at,
    required this.erased,
    this.author,
    this.onBehalfOf,
    this.body,
  });

  factory FollowUpNote.fromJson(Object? json) {
    final m = _map(json, 'note');
    final erased = _req<bool>(m, 'erased');
    final body = _opt<String>(m, 'body');
    if (erased != (body == null)) {
      throw const FormatException('unexpected body');
    }
    return FollowUpNote(
      noteId: _req<String>(m, 'note_id'),
      at: _instant(m, 'at'),
      author: _opt<String>(m, 'author'),
      onBehalfOf: _opt<String>(m, 'on_behalf_of'),
      body: body,
      erased: erased,
    );
  }

  final String noteId;
  final DateTime at;
  final String? author;
  final String? onBehalfOf;
  final String? body;
  final bool erased;
}

/// `api.followups_task`: the full task (owner, scope holders) or routing
/// metadata only (Admin).
class FollowUpDetail {
  const FollowUpDetail.full({
    required FollowUpTask this.task,
    required this.activity,
    required this.notes,
  }) : routing = null;

  const FollowUpDetail.routing(FollowUpRouting this.routing)
    : task = null,
      activity = const [],
      notes = const [];

  factory FollowUpDetail.fromJson(Object? json) {
    final m = _map(json, 'follow-up');
    return switch (m['view']) {
      'full' => FollowUpDetail.full(
        task: FollowUpTask.fromJson(m['task']),
        activity: List.unmodifiable(
          _req<List>(m, 'activity').map(FollowUpActivity.fromJson),
        ),
        notes: List.unmodifiable(
          _req<List>(m, 'notes').map(FollowUpNote.fromJson),
        ),
      ),
      'routing' => FollowUpDetail.routing(FollowUpRouting.fromJson(m['task'])),
      _ => throw const FormatException('unexpected view'),
    };
  }

  final FollowUpTask? task;
  final FollowUpRouting? routing;
  final List<FollowUpActivity> activity;
  final List<FollowUpNote> notes;

  FollowUpRouting get meta => task?.routing ?? routing!;
}

/// A purpose a scope holder may create tasks for by hand.
class FollowUpPurpose {
  const FollowUpPurpose({
    required this.sourceType,
    required this.purpose,
    required this.label,
    required this.scopeKinds,
    required this.outcomes,
  });

  factory FollowUpPurpose.fromJson(Object? json) {
    final m = _map(json, 'purpose');
    return FollowUpPurpose(
      sourceType: _req<String>(m, 'source_type'),
      purpose: _req<String>(m, 'purpose'),
      label: _req<String>(m, 'label'),
      scopeKinds: _tokens(m, 'scope_kinds'),
      outcomes: _tokens(m, 'outcomes'),
    );
  }

  final String sourceType;
  final String purpose;
  final String label;
  final List<String> scopeKinds;
  final List<String> outcomes;

  /// SYNTHETIC sources accept any id at revision 1.
  bool get synthetic => sourceType.startsWith('fixture_');
}

/// `api.followups_supervision`.
class FollowUpSupervision {
  const FollowUpSupervision({
    required this.scopes,
    required this.purposes,
    required this.tasks,
    required this.candidates,
    required this.truncated,
  });

  factory FollowUpSupervision.fromJson(Object? json) {
    final m = _map(json, 'supervision');
    return FollowUpSupervision(
      scopes: List.unmodifiable(
        _req<List>(m, 'scopes').map(FollowUpScope.fromJson),
      ),
      purposes: List.unmodifiable(
        _req<List>(m, 'purposes').map(FollowUpPurpose.fromJson),
      ),
      tasks: List.unmodifiable(
        _req<List>(m, 'tasks').map(FollowUpTask.fromJson),
      ),
      candidates: List.unmodifiable(
        _req<List>(m, 'candidates').map(FollowUpPerson.fromJson),
      ),
      truncated: _req<bool>(m, 'truncated'),
    );
  }

  final List<FollowUpScope> scopes;
  final List<FollowUpPurpose> purposes;
  final List<FollowUpTask> tasks;
  final List<FollowUpPerson> candidates;
  final bool truncated;
}

/// `api.followups_admin_routing`.
class FollowUpAdminRouting {
  const FollowUpAdminRouting({
    required this.tasks,
    required this.candidates,
    required this.truncated,
  });

  factory FollowUpAdminRouting.fromJson(Object? json) {
    final m = _map(json, 'routing');
    return FollowUpAdminRouting(
      tasks: List.unmodifiable(
        _req<List>(m, 'tasks').map(FollowUpRouting.fromJson),
      ),
      candidates: List.unmodifiable(
        _req<List>(m, 'candidates').map(FollowUpPerson.fromJson),
      ),
      truncated: _req<bool>(m, 'truncated'),
    );
  }

  final List<FollowUpRouting> tasks;
  final List<FollowUpPerson> candidates;
  final bool truncated;
}

/// What a scope holder enters to create a SYNTHETIC task by hand. The
/// source id is generated by the client (any id is a SYNTHETIC source).
class FollowUpDraft {
  const FollowUpDraft({
    required this.purpose,
    required this.sourceId,
    required this.ownerMemberId,
    required this.scope,
    required this.nextAction,
    required this.dueAt,
    this.note,
  });

  final FollowUpPurpose purpose;
  final String sourceId;
  final String ownerMemberId;
  final FollowUpScope scope;
  final String nextAction;
  final DateTime dueAt;
  final String? note;

  Map<String, Object?> toPayload() {
    final n = note?.trim();
    return {
      'source_type': purpose.sourceType,
      'source_id': sourceId,
      'source_revision': 1,
      'purpose': purpose.purpose,
      'owner_member_id': ownerMemberId,
      'scope_kind': scope.scopeKind,
      'scope_id': scope.scopeId,
      'next_action': nextAction.trim(),
      'due_at': dueAt.toUtc().toIso8601String(),
      if (n != null && n.isNotEmpty) 'note': n,
    };
  }
}

/// An update the owner (or a scope holder for them) records.
class FollowUpUpdate {
  const FollowUpUpdate({
    this.status,
    this.reviewAt,
    this.closeReason,
    this.outcome,
    this.nextAction,
    this.note,
  });

  final FollowUpState? status;
  final DateTime? reviewAt;
  final String? closeReason;
  final String? outcome;
  final String? nextAction;
  final String? note;

  bool get isEmpty =>
      status == null &&
      reviewAt == null &&
      _blank(closeReason) &&
      outcome == null &&
      _blank(nextAction) &&
      _blank(note);

  static bool _blank(String? s) => s == null || s.trim().isEmpty;

  Map<String, Object?> toPayload(String taskId) => {
    'task_id': taskId,
    if (status case final s?) 'status': s.wire,
    if (reviewAt case final r?) 'review_at': r.toUtc().toIso8601String(),
    if (!_blank(closeReason)) 'close_reason': closeReason!.trim(),
    'outcome': ?outcome,
    if (!_blank(nextAction)) 'next_action': nextAction!.trim(),
    if (!_blank(note)) 'note': note!.trim(),
  };
}

/// Application port for the follow-up reads. Never throws; a fresh request
/// every call.
abstract interface class FollowUpsRepository {
  Future<AccessRead<MyFollowUps>> fetchMyTasks();
  Future<AccessRead<FollowUpDetail>> fetchTask(String taskId);
  Future<AccessRead<FollowUpSupervision>> fetchSupervision();
  Future<AccessRead<FollowUpAdminRouting>> fetchAdminRouting();
}

class UnconfiguredFollowUpsRepository implements FollowUpsRepository {
  const UnconfiguredFollowUpsRepository();

  @override
  Future<AccessRead<MyFollowUps>> fetchMyTasks() async =>
      const AccessReadDenied(AccessDenial.unavailable);

  @override
  Future<AccessRead<FollowUpDetail>> fetchTask(String taskId) async =>
      const AccessReadDenied(AccessDenial.unavailable);

  @override
  Future<AccessRead<FollowUpSupervision>> fetchSupervision() async =>
      const AccessReadDenied(AccessDenial.unavailable);

  @override
  Future<AccessRead<FollowUpAdminRouting>> fetchAdminRouting() async =>
      const AccessReadDenied(AccessDenial.unavailable);
}

/// Scope kinds whose holders may supervise follow-ups today (department and
/// cell leaders and their deputies or assistants). Navigation only.
const followUpSupervisingScopeKinds = {
  'department_leader',
  'department_deputy',
  'cell_leader',
  'cell_assistant',
};

/// Does [grants] hold a scope that supervises follow-ups? Navigation only:
/// the supervision read is checked by the server.
bool supervisesFollowUps(MemberGrants? grants) =>
    grants != null &&
    grants.scopes.any(
      (s) => followUpSupervisingScopeKinds.contains(s.scopeKind),
    );

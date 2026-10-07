/// Story 2.6: primary cell membership as the server reports it. Cell setup,
/// leader/Admin confirmation (separate from church approval), the Admin
/// follow-up queue and the atomic transfer are all decided by the server;
/// these reads are presentation only. Free of widgets and SDKs.
library;

import 'access_grants.dart';

/// Cells-registered scope kinds in the Identity grant model (story 2.3).
abstract final class CellScopeKinds {
  static const leader = 'cell_leader';
  static const assistant = 'cell_assistant';

  static bool isCellScope(String kind) => kind == leader || kind == assistant;
}

/// The cells command function and command names (1.4 envelope).
abstract final class CellCommands {
  static const function = 'cells_command';
  static const createCell = 'cells.create_cell';
  static const updateCell = 'cells.update_cell';
  static const requestChange = 'cells.request_change';
  static const confirm = 'cells.confirm_request';
  static const decline = 'cells.decline_request';
  static const cancel = 'cells.cancel_request';
}

/// Why a request was not confirmed (wire codes).
enum CellDeclineReason {
  notInThisCell('not_in_this_cell'),
  notKnownToLeader('not_known_to_leader'),
  memberWithdrew('member_withdrew'),
  noCellForNow('no_cell_for_now'),

  /// Recorded when an Admin (not the member) cancels a request.
  cancelledByAdmin('cancelled_by_admin');

  const CellDeclineReason(this.wire);
  final String wire;

  static CellDeclineReason? fromWire(Object? v) {
    for (final r in values) {
      if (r.wire == v) return r;
    }
    return null;
  }

  String get label => switch (this) {
    notInThisCell => 'Not in this cell',
    notKnownToLeader => 'Not known to the leader',
    memberWithdrew => 'Withdrawn',
    noCellForNow => 'No cell for now',
    cancelledByAdmin => 'Cancelled by the church office',
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

const _kinds = {'join', 'change'};
const _origins = {'application', 'member', 'admin'};
const _choices = {'cell', 'not_sure', 'not_in_cell'};

String _oneOf(Map json, String key, Set<String> allowed) {
  final v = _req<String>(json, key);
  if (!allowed.contains(v)) throw FormatException('unexpected $key $v');
  return v;
}

/// The member's current primary cell (safe label and area).
class CellPlacement {
  const CellPlacement({
    required this.membershipId,
    required this.cellId,
    required this.label,
    required this.broadArea,
    required this.since,
  });

  factory CellPlacement.fromJson(Object? json) {
    final m = _map(json, 'primary cell');
    return CellPlacement(
      membershipId: _req<String>(m, 'membership_id'),
      cellId: _req<String>(m, 'cell_id'),
      label: _req<String>(m, 'label'),
      broadArea: _req<String>(m, 'broad_area'),
      since: _req<String>(m, 'since'),
    );
  }

  final String membershipId;
  final String cellId;
  final String label;
  final String broadArea;
  final String since;
}

/// The member's own open request.
class OwnCellRequest {
  const OwnCellRequest({
    required this.requestId,
    required this.kind,
    required this.origin,
    required this.choice,
    required this.referred,
    this.cellId,
    this.label,
  });

  factory OwnCellRequest.fromJson(Object? json) {
    final m = _map(json, 'open request');
    final state = _oneOf(m, 'state', const {'pending', 'referred'});
    return OwnCellRequest(
      requestId: _req<String>(m, 'request_id'),
      kind: _oneOf(m, 'kind', _kinds),
      origin: _oneOf(m, 'origin', _origins),
      choice: _oneOf(m, 'choice', _choices),
      referred: state == 'referred',
      cellId: _opt<String>(m, 'cell_id'),
      label: _opt<String>(m, 'label'),
    );
  }

  final String requestId;

  /// `join` or `change`.
  final String kind;
  final String origin;

  /// `cell`, `not_sure` or `not_in_cell`.
  final String choice;

  /// Passed to the church office (Admin follow-up) by the leader.
  final bool referred;
  final String? cellId;
  final String? label;
}

class CellDecision {
  const CellDecision({required this.state, this.reason});

  factory CellDecision.fromJson(Object? json) {
    final m = _map(json, 'decision');
    return CellDecision(
      state: _oneOf(m, 'state', const {'confirmed', 'declined', 'cancelled'}),
      reason: CellDeclineReason.fromWire(m['reason']),
    );
  }

  /// `confirmed`, `declined` or `cancelled`.
  final String state;
  final CellDeclineReason? reason;
}

/// `api.cells_my_cell` (and the data of a member cell command).
class MyCell {
  const MyCell({
    required this.memberId,
    required this.revision,
    this.primary,
    this.openRequest,
    this.lastDecision,
  });

  factory MyCell.fromJson(Object? json) {
    final m = _map(json, 'my cell');
    final revision = _req<int>(m, 'revision');
    if (revision < 1) throw const FormatException('unexpected revision');
    return MyCell(
      memberId: _req<String>(m, 'member_id'),
      revision: revision,
      primary: m['primary'] == null
          ? null
          : CellPlacement.fromJson(m['primary']),
      openRequest: m['open_request'] == null
          ? null
          : OwnCellRequest.fromJson(m['open_request']),
      lastDecision: m['last_decision'] == null
          ? null
          : CellDecision.fromJson(m['last_decision']),
    );
  }

  final String memberId;

  /// The member's Cells revision (expected_revision of their cell commands).
  final int revision;
  final CellPlacement? primary;
  final OwnCellRequest? openRequest;
  final CellDecision? lastDecision;
}

class CellStaff {
  const CellStaff({
    required this.memberId,
    required this.displayName,
    required this.grantsRevision,
  });

  factory CellStaff.fromJson(Object? json) {
    final m = _map(json, 'cell staff');
    return CellStaff(
      memberId: _req<String>(m, 'member_id'),
      displayName: _req<String>(m, 'display_name'),
      grantsRevision: _req<int>(m, 'grants_revision'),
    );
  }

  final String memberId;
  final String displayName;

  /// The member's grant-set revision (expected_revision of a scope command).
  final int grantsRevision;
}

/// One cell as the Admin sets it up.
class AdminCell {
  const AdminCell({
    required this.cellId,
    required this.name,
    required this.broadArea,
    required this.listed,
    required this.active,
    required this.isSynthetic,
    required this.revision,
    required this.leaders,
    required this.assistants,
    required this.memberCount,
    this.signupLabel,
    this.signupRevision,
  });

  factory AdminCell.fromJson(Object? json) {
    final m = _map(json, 'cell');
    List<CellStaff> staff(String key) =>
        List.unmodifiable(_req<List>(m, key).map(CellStaff.fromJson));
    return AdminCell(
      cellId: _req<String>(m, 'cell_id'),
      name: _req<String>(m, 'name'),
      broadArea: _req<String>(m, 'broad_area'),
      signupLabel: _opt<String>(m, 'signup_label'),
      signupRevision: _opt<int>(m, 'signup_revision'),
      listed: _req<bool>(m, 'listed'),
      active: _oneOf(m, 'cell_state', const {'active', 'retired'}) == 'active',
      isSynthetic: _req<bool>(m, 'is_synthetic'),
      revision: _req<int>(m, 'revision'),
      leaders: staff('leaders'),
      assistants: staff('assistants'),
      memberCount: _req<int>(m, 'member_count'),
    );
  }

  final String cellId;
  final String name;
  final String broadArea;
  final String? signupLabel;

  /// Set while the cell is offered in the sign-up chooser.
  final int? signupRevision;
  final bool listed;
  final bool active;
  final bool isSynthetic;

  /// The cell's revision (expected_revision of cells.update_cell).
  final int revision;
  final List<CellStaff> leaders;
  final List<CellStaff> assistants;
  final int memberCount;
}

/// One open request in the Admin overview.
class AdminCellRequest {
  const AdminCellRequest({
    required this.requestId,
    required this.memberId,
    required this.displayName,
    required this.kind,
    required this.origin,
    required this.choice,
    required this.referred,
    required this.followUp,
    required this.memberRevision,
    required this.ownRecord,
    this.requestedCellId,
    this.requestedCellName,
    this.currentCellName,
    this.reason,
  });

  factory AdminCellRequest.fromJson(Object? json) {
    final m = _map(json, 'request');
    return AdminCellRequest(
      requestId: _req<String>(m, 'request_id'),
      memberId: _req<String>(m, 'member_id'),
      displayName: _req<String>(m, 'display_name'),
      kind: _oneOf(m, 'kind', _kinds),
      origin: _oneOf(m, 'origin', _origins),
      choice: _oneOf(m, 'choice', _choices),
      referred: _oneOf(m, 'state', const {'pending', 'referred'}) == 'referred',
      followUp: _req<bool>(m, 'follow_up'),
      memberRevision: _req<int>(m, 'member_revision'),
      ownRecord: _req<bool>(m, 'own_record'),
      requestedCellId: _opt<String>(m, 'requested_cell_id'),
      requestedCellName: _opt<String>(m, 'requested_cell_name'),
      currentCellName: _opt<String>(m, 'current_cell_name'),
      reason: CellDeclineReason.fromWire(m['reason']),
    );
  }

  final String requestId;
  final String memberId;
  final String displayName;
  final String kind;
  final String origin;
  final String choice;
  final bool referred;

  /// No cell chosen, or referred by a leader: the Admin resolves it.
  final bool followUp;
  final int memberRevision;

  /// The reviewing Admin's own record: another person must decide it.
  final bool ownRecord;
  final String? requestedCellId;
  final String? requestedCellName;
  final String? currentCellName;
  final CellDeclineReason? reason;
}

/// One approved member and their cell (Admin overview).
class CellMemberRow {
  const CellMemberRow({
    required this.memberId,
    required this.displayName,
    required this.account,
    required this.grantsRevision,
    required this.cellRevision,
    this.cellId,
    this.openRequestId,
  });

  factory CellMemberRow.fromJson(Object? json) {
    final m = _map(json, 'member');
    return CellMemberRow(
      memberId: _req<String>(m, 'member_id'),
      displayName: _req<String>(m, 'display_name'),
      account: switch (m['account']) {
        'app_account' => AccountStanding.appAccount,
        'no_login' => AccountStanding.noLogin,
        'access_review' => AccountStanding.accessReview,
        _ => throw const FormatException('unexpected account'),
      },
      grantsRevision: _req<int>(m, 'grants_revision'),
      cellRevision: _req<int>(m, 'cell_revision'),
      cellId: _opt<String>(m, 'cell_id'),
      openRequestId: _opt<String>(m, 'open_request_id'),
    );
  }

  final String memberId;
  final String displayName;
  final AccountStanding account;
  final int grantsRevision;
  final int cellRevision;
  final String? cellId;
  final String? openRequestId;
}

/// `api.cells_admin_overview`.
class CellAdminOverview {
  const CellAdminOverview({
    required this.cells,
    required this.requests,
    required this.members,
  });

  factory CellAdminOverview.fromJson(Object? json) {
    final m = _map(json, 'overview');
    return CellAdminOverview(
      cells: List.unmodifiable(_req<List>(m, 'cells').map(AdminCell.fromJson)),
      requests: List.unmodifiable(
        _req<List>(m, 'requests').map(AdminCellRequest.fromJson),
      ),
      members: List.unmodifiable(
        _req<List>(m, 'members').map(CellMemberRow.fromJson),
      ),
    );
  }

  final List<AdminCell> cells;
  final List<AdminCellRequest> requests;
  final List<CellMemberRow> members;

  AdminCell? cell(String? id) {
    for (final c in cells) {
      if (c.cellId == id) return c;
    }
    return null;
  }
}

class LeaderRequest {
  const LeaderRequest({
    required this.requestId,
    required this.memberId,
    required this.displayName,
    required this.kind,
    required this.memberRevision,
    required this.ownRecord,
  });

  factory LeaderRequest.fromJson(Object? json) {
    final m = _map(json, 'leader request');
    return LeaderRequest(
      requestId: _req<String>(m, 'request_id'),
      memberId: _req<String>(m, 'member_id'),
      displayName: _req<String>(m, 'display_name'),
      kind: _oneOf(m, 'kind', _kinds),
      memberRevision: _req<int>(m, 'member_revision'),
      ownRecord: _req<bool>(m, 'own_record'),
    );
  }

  final String requestId;
  final String memberId;
  final String displayName;
  final String kind;
  final int memberRevision;
  final bool ownRecord;
}

class RosterEntry {
  const RosterEntry({required this.memberId, required this.displayName});

  factory RosterEntry.fromJson(Object? json) {
    final m = _map(json, 'roster entry');
    return RosterEntry(
      memberId: _req<String>(m, 'member_id'),
      displayName: _req<String>(m, 'display_name'),
    );
  }

  final String memberId;
  final String displayName;
}

/// One cell the caller leads or assists.
class LeaderCell {
  const LeaderCell({
    required this.cellId,
    required this.name,
    required this.broadArea,
    required this.isLeader,
    required this.members,
    required this.requests,
  });

  factory LeaderCell.fromJson(Object? json) {
    final m = _map(json, 'leader cell');
    return LeaderCell(
      cellId: _req<String>(m, 'cell_id'),
      name: _req<String>(m, 'name'),
      broadArea: _req<String>(m, 'broad_area'),
      isLeader: _oneOf(m, 'role', const {'leader', 'assistant'}) == 'leader',
      members: List.unmodifiable(
        _req<List>(m, 'members').map(RosterEntry.fromJson),
      ),
      requests: List.unmodifiable(
        _req<List>(m, 'requests').map(LeaderRequest.fromJson),
      ),
    );
  }

  final String cellId;
  final String name;
  final String broadArea;
  final bool isLeader;
  final List<RosterEntry> members;
  final List<LeaderRequest> requests;
}

/// `api.cells_leader_queue`.
class LeaderQueue {
  const LeaderQueue({required this.cells});

  factory LeaderQueue.fromJson(Object? json) {
    final m = _map(json, 'leader queue');
    return LeaderQueue(
      cells: List.unmodifiable(_req<List>(m, 'cells').map(LeaderCell.fromJson)),
    );
  }

  final List<LeaderCell> cells;
}

/// Application port for the cells reads. Never throws; a fresh request
/// every call.
abstract interface class CellsRepository {
  Future<AccessRead<MyCell>> fetchMyCell();
  Future<AccessRead<LeaderQueue>> fetchLeaderQueue();
  Future<AccessRead<CellAdminOverview>> fetchAdminOverview();
}

class UnconfiguredCellsRepository implements CellsRepository {
  const UnconfiguredCellsRepository();

  @override
  Future<AccessRead<MyCell>> fetchMyCell() async =>
      const AccessReadDenied(AccessDenial.unavailable);

  @override
  Future<AccessRead<LeaderQueue>> fetchLeaderQueue() async =>
      const AccessReadDenied(AccessDenial.unavailable);

  @override
  Future<AccessRead<CellAdminOverview>> fetchAdminOverview() async =>
      const AccessReadDenied(AccessDenial.unavailable);
}

/// Does [grants] lead or assist any cell (navigation only)?
bool servesACell(MemberGrants? grants) =>
    grants?.scopes.any((s) => CellScopeKinds.isCellScope(s.scopeKind)) ?? false;

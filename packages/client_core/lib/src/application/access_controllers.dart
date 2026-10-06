import 'package:church_contracts/church_contracts.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/access_grants.dart';
import '../domain/commands.dart';
import 'providers.dart';

/// The caller's own grants as last answered by the server for the CURRENT
/// account generation. Protected state (AD-13): memory only, dropped on any
/// account change; late answers for an older generation are discarded.
class MyAccessState {
  const MyAccessState({this.loading = false, this.result});

  final bool loading;
  final AccessRead<MemberGrants>? result;

  /// The grants in force, or null when the server has not granted access.
  MemberGrants? get grants => switch (result) {
    AccessReadOk(:final value) => value,
    _ => null,
  };
}

/// Story 2.3: navigation on both clients follows this read. The shells ask
/// again on every navigation and when the app resumes, and the grant screen
/// asks again after any refused command, so a grant or revocation made
/// elsewhere shows at the next protected request. It is never the security
/// control: the server checks the current grant rows on every call.
class MyAccessController extends Notifier<MyAccessState> {
  bool _again = false;

  @override
  MyAccessState build() {
    _again = false;
    final generation = ref.watch(accountGenerationProvider);
    final accountId = ref.watch(accountProvider.select((s) => s.accountId));
    if (accountId == null) {
      return const MyAccessState(
        result: AccessReadDenied(AccessDenial.signedOut),
      );
    }
    Future.microtask(() => _load(generation));
    return const MyAccessState(loading: true);
  }

  /// Asks the server again. A request already in flight is followed by one
  /// more, so the answer always reflects a read made after this call.
  Future<void> refresh() async {
    if (state.loading) {
      _again = true;
      return;
    }
    await _load(ref.read(accountGenerationProvider));
  }

  Future<void> _load(int generation) async {
    // Every terminal path clears the pending re-read: it belongs to this
    // account generation only.
    if (!ref.mounted || ref.read(accountGenerationProvider) != generation) {
      _again = false;
      return;
    }
    if (ref.read(accountProvider).accountId == null) {
      _again = false;
      return;
    }
    // Keep showing the last answer while asking again (navigation only).
    state = MyAccessState(loading: true, result: state.result);
    final result = await ref.read(grantsRepositoryProvider).fetchMyAccess();
    if (!ref.mounted || ref.read(accountGenerationProvider) != generation) {
      _again = false;
      return;
    }
    state = MyAccessState(result: result);
    if (result is AccessReadDenied<MemberGrants> &&
        result.denial == AccessDenial.untrustedSession) {
      _again = false;
      // Same rule as the member summary (story 2.2): end the session here.
      await ref.read(accountProvider.notifier).endUntrustedSession();
      return;
    }
    if (_again) {
      _again = false;
      await _load(generation);
    }
  }
}

/// The one hook for protected denials (story 2.3). Any `forbidden` or
/// `unauthenticated` answer from a protected read or command may mean the
/// caller's grants or session changed, so the caller's access (and with it
/// the navigation) is read again. The controller coalesces repeated calls.
void noteProtectedDenial(Ref ref) {
  if (!ref.mounted) return;
  ref.read(myAccessProvider.notifier).refresh();
}

final myAccessProvider = NotifierProvider<MyAccessController, MyAccessState>(
  MyAccessController.new,
);

/// What the grant screen tells the Admin after an action.
enum GrantNotice {
  granted,
  revoked,

  /// Changed elsewhere (stale tab): the roster was reloaded.
  changedElsewhere,
  lastAdmin,

  /// Separation of duty: an Admin cannot grant to their own record.
  selfGrant,
  noLongerAdmin,
  signInAgain,
  roleUnavailable,
  refused,

  /// The outcome is unknown: check again with the same request.
  unconfirmed,
  notSent,
}

class GrantAction {
  const GrantAction({
    required this.request,
    required this.memberName,
    required this.label,
    required this.grant,
  });

  final CommandRequest request;
  final String memberName;

  /// The role label or scope kind acted on.
  final String label;

  /// true = grant, false = remove.
  final bool grant;

  String get memberId => request.payload['member_id']! as String;
}

class GrantAdminState {
  const GrantAdminState({
    this.loading = false,
    this.result,
    this.members = const [],
    this.roles = const [],
    this.next,
    this.pending,
    this.unconfirmed,
    this.notice,
    this.noticeAction,
  });

  final bool loading;

  /// The last roster answer (denials and failures included).
  final AccessRead<GrantRoster>? result;
  final List<RosterMember> members;
  final List<RoleOption> roles;
  final RosterCursor? next;

  /// The command in flight.
  final GrantAction? pending;

  /// A command whose outcome is unknown; "Check again" resends it unchanged.
  final GrantAction? unconfirmed;
  final GrantNotice? notice;
  final GrantAction? noticeAction;

  bool get busy => pending != null;

  GrantAdminState copyWith({
    bool? loading,
    AccessRead<GrantRoster>? result,
    List<RosterMember>? members,
    List<RoleOption>? roles,
    RosterCursor? next,
    bool clearNext = false,
    GrantAction? pending,
    bool clearPending = false,
    GrantAction? unconfirmed,
    bool clearUnconfirmed = false,
    GrantNotice? notice,
    GrantAction? noticeAction,
    bool clearNotice = false,
  }) => GrantAdminState(
    loading: loading ?? this.loading,
    result: result ?? this.result,
    members: members ?? this.members,
    roles: roles ?? this.roles,
    next: clearNext ? null : (next ?? this.next),
    pending: clearPending ? null : (pending ?? this.pending),
    unconfirmed: clearUnconfirmed ? null : (unconfirmed ?? this.unconfirmed),
    notice: clearNotice ? null : (notice ?? this.notice),
    noticeAction: clearNotice ? null : (noticeAction ?? this.noticeAction),
  );
}

/// Admin grant roster and the grant/revoke commands (1.4 envelope), with
/// honest request states. Scoped to the account generation.
class GrantAdminController extends Notifier<GrantAdminState> {
  int _epoch = 0;

  @override
  GrantAdminState build() {
    ref.watch(accountGenerationProvider);
    _epoch++;
    final epoch = _epoch;
    Future.microtask(() => _reload(epoch));
    return const GrantAdminState(loading: true);
  }

  bool _current(int epoch) => ref.mounted && epoch == _epoch;

  /// Reloads the first page (the server rechecks Admin every time).
  Future<void> reload() => _reload(_epoch);

  Future<void> _reload(int epoch) async {
    if (!_current(epoch)) return;
    state = state.copyWith(loading: true);
    final r = await ref.read(grantsRepositoryProvider).fetchRoster();
    if (!_current(epoch)) return;
    state = switch (r) {
      AccessReadOk(:final value) => state.copyWith(
        loading: false,
        result: r,
        members: value.members,
        roles: value.roles,
        next: value.next,
        clearNext: value.next == null,
      ),
      // A denial drops the roster: nothing protected stays on screen.
      AccessReadDenied() => GrantAdminState(
        result: r,
        notice: state.notice,
        noticeAction: state.noticeAction,
      ),
      // No answer: the members are dropped too, so nothing is shown that the
      // server did not just confirm (the banner says why the list is empty).
      AccessReadFailed() => GrantAdminState(
        result: r,
        notice: state.notice,
        noticeAction: state.noticeAction,
      ),
    };
    if (r is AccessReadDenied<GrantRoster>) {
      // The navigation follows the server's current answer.
      noteProtectedDenial(ref);
    }
  }

  Future<void> loadMore() async {
    final after = state.next;
    if (after == null || state.loading) return;
    final epoch = _epoch;
    state = state.copyWith(loading: true);
    final r = await ref
        .read(grantsRepositoryProvider)
        .fetchRoster(after: after);
    if (!_current(epoch)) return;
    if (r is AccessReadOk<GrantRoster>) {
      state = state.copyWith(
        loading: false,
        members: [...state.members, ...r.value.members],
        next: r.value.next,
        clearNext: r.value.next == null,
      );
    } else {
      await _reload(epoch);
    }
  }

  void dismissNotice() => state = state.copyWith(clearNotice: true);

  Future<void> setRole(
    RosterMember member,
    String role, {
    required bool grant,
  }) => _send(
    member,
    grant ? GrantCommands.grantRole : GrantCommands.revokeRole,
    {'member_id': member.memberId, 'role': role},
    ChurchRoles.label(role),
    grant,
  );

  Future<void> revokeScope(RosterMember member, ScopeGrant scope) => _send(
    member,
    GrantCommands.revokeScope,
    {
      'member_id': member.memberId,
      'scope_kind': scope.scopeKind,
      'scope_id': scope.scopeId,
    },
    scope.scopeKind,
    false,
  );

  /// Resends the unconfirmed command unchanged (same request_id and body).
  Future<void> checkAgain() async {
    final u = state.unconfirmed;
    if (u == null || state.busy) return;
    await _dispatch(u);
  }

  Future<void> _send(
    RosterMember member,
    String command,
    Map<String, Object?> payload,
    String label,
    bool grant,
  ) async {
    if (state.busy) return;
    final unconfirmed = state.unconfirmed;
    final revision = Optional.of(member.grants.revision);
    // An input whose outcome was never learned is resent under its original
    // request id; anything else is a new request.
    final sameAsUnconfirmed =
        unconfirmed != null &&
        unconfirmed.request.command == command &&
        unconfirmed.request.expectedRevision.value == revision.value &&
        _samePayload(unconfirmed.request.payload, payload);
    final request = CommandRequest(
      command: command,
      requestId: sameAsUnconfirmed
          ? unconfirmed.request.requestId
          : ref.read(requestIdsProvider).next(),
      expectedRevision: revision,
      payload: payload,
    );
    await _dispatch(
      GrantAction(
        request: request,
        memberName: member.displayName,
        label: label,
        grant: grant,
      ),
    );
  }

  static bool _samePayload(Map<String, Object?> a, Map<String, Object?> b) =>
      a.length == b.length && a.entries.every((e) => b[e.key] == e.value);

  Future<void> _dispatch(GrantAction action) async {
    final epoch = _epoch;
    state = state.copyWith(pending: action, clearNotice: true);
    final outcome = await ref
        .read(commandGatewayProvider)
        .send(GrantCommands.function, action.request);
    if (!_current(epoch)) return;
    switch (outcome) {
      case CommandConfirmed(:final success):
        MemberGrants? grants;
        try {
          grants = MemberGrants.fromJson(success.data);
        } on FormatException {
          grants = null;
        }
        state = state.copyWith(
          clearPending: true,
          clearUnconfirmed: true,
          members: [
            for (final m in state.members)
              if (grants != null && m.memberId == grants.memberId)
                m.withGrants(grants)
              else
                m,
          ],
          notice: action.grant ? GrantNotice.granted : GrantNotice.revoked,
          noticeAction: action,
        );
        if (grants == null) await _reload(epoch);
        // The Admin may have changed their own grants.
        await ref.read(myAccessProvider.notifier).refresh();
      case CommandRefused(:final error):
        final notice = switch (error.code) {
          ErrorCode.conflict => GrantNotice.changedElsewhere,
          ErrorCode.forbidden
              when error.fieldErrors['member_id'] == 'unsupported' =>
            GrantNotice.selfGrant,
          ErrorCode.forbidden
              when !action.grant &&
                  error.fieldErrors['role'] == 'unsupported' =>
            GrantNotice.lastAdmin,
          ErrorCode.forbidden => GrantNotice.noLongerAdmin,
          ErrorCode.unauthenticated => GrantNotice.signInAgain,
          ErrorCode.unavailable
              when error.fieldErrors['policy'] == 'gate_closed' =>
            GrantNotice.roleUnavailable,
          _ => GrantNotice.refused,
        };
        state = state.copyWith(
          clearPending: true,
          clearUnconfirmed: true,
          notice: notice,
          noticeAction: action,
        );
        if (notice != GrantNotice.lastAdmin &&
            notice != GrantNotice.selfGrant) {
          await _reload(epoch);
        }
        if (error.code == ErrorCode.forbidden ||
            error.code == ErrorCode.unauthenticated) {
          noteProtectedDenial(ref);
        }
      case CommandUnknownOutcome():
        state = state.copyWith(
          clearPending: true,
          unconfirmed: action,
          notice: GrantNotice.unconfirmed,
          noticeAction: action,
        );
      case CommandNotSent():
        state = state.copyWith(
          clearPending: true,
          notice: GrantNotice.notSent,
          noticeAction: action,
        );
    }
  }
}

final grantAdminProvider =
    NotifierProvider<GrantAdminController, GrantAdminState>(
      GrantAdminController.new,
    );

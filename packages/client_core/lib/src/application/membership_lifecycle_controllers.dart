import 'dart:convert';

import 'package:church_contracts/church_contracts.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/access_grants.dart';
import '../domain/commands.dart';
import '../domain/credential_review.dart';
import '../domain/membership_lifecycle.dart';
import '../domain/membership_review.dart' show IdentityCheck, MemberRecord;
import 'access_controllers.dart';
import 'providers.dart';

/// Story 2.10: the signed-in account's own membership status. Asked only
/// when the server answered that the account has no member access, to tell a
/// deactivated membership apart from one not linked yet. Protected state:
/// scoped to one account generation, dropped on sign-out or account change.
class MyMembershipStatusController
    extends Notifier<AccessRead<MyMembershipStatus>?> {
  int _epoch = 0;

  @override
  AccessRead<MyMembershipStatus>? build() {
    ref.watch(accountGenerationProvider);
    final accountId = ref.watch(accountProvider.select((s) => s.accountId));
    _epoch++;
    if (accountId == null) return null;
    final epoch = _epoch;
    Future.microtask(() => _load(epoch));
    return null;
  }

  Future<void> refresh() => _load(_epoch);

  Future<void> _load(int epoch) async {
    if (!ref.mounted || epoch != _epoch) return;
    final r = await ref
        .read(membershipLifecycleRepositoryProvider)
        .fetchMyStatus();
    if (!ref.mounted || epoch != _epoch) return;
    state = r;
  }
}

final myMembershipStatusProvider =
    NotifierProvider<
      MyMembershipStatusController,
      AccessRead<MyMembershipStatus>?
    >(MyMembershipStatusController.new);

/// What the Admin lifecycle screen tells the Admin after an action.
enum LifecycleNotice {
  loginHeld,
  holdReleased,
  deactivated,
  restored,

  /// The church would be left without a usable Admin.
  lastAdmin,

  /// The member is the last responsible person for something an owning
  /// module manages: it must be handed over first.
  handoverRequired,
  alreadyHeld,

  /// The member is not an approved member (already deactivated, pending...).
  notApproved,
  notDeactivated,

  /// The hold stays until the member resets the password themselves.
  passwordResetRequired,
  changedElsewhere,
  selfAction,
  noLongerAdmin,
  signInAgain,
  notAccepting,
  invalid,
  notFound,
  refused,
  unconfirmed,
  notSent,
}

class MembershipLifecycleState {
  const MembershipLifecycleState({
    this.loading = false,
    this.result,
    this.pending,
    this.pendingFunction,
    this.unconfirmed,
    this.unconfirmedFunction,
    this.notice,
    this.subject,
    this.searching = false,
    this.search,
  });

  final bool loading;
  final AccessRead<MembershipLifecycleOverview>? result;
  final CommandRequest? pending;
  final String? pendingFunction;
  final CommandRequest? unconfirmed;
  final String? unconfirmedFunction;
  final LifecycleNotice? notice;

  /// Who the last action was about (display only).
  final String? subject;
  final bool searching;

  /// Approved members found to hold or deactivate.
  final AccessRead<List<MemberRecord>>? search;

  bool get busy => pending != null;

  MembershipLifecycleOverview? get overview => switch (result) {
    AccessReadOk(:final value) => value,
    _ => null,
  };
}

class MembershipLifecycleController extends Notifier<MembershipLifecycleState> {
  int _epoch = 0;

  @override
  MembershipLifecycleState build() {
    ref.watch(accountGenerationProvider);
    _epoch++;
    final epoch = _epoch;
    Future.microtask(() => _reload(epoch));
    return const MembershipLifecycleState(loading: true);
  }

  bool _current(int epoch) => ref.mounted && epoch == _epoch;

  Future<void> reload() => _reload(_epoch);

  Future<void> _reload(int epoch) async {
    if (!_current(epoch)) return;
    state = MembershipLifecycleState(
      loading: true,
      result: state.result,
      unconfirmed: state.unconfirmed,
      unconfirmedFunction: state.unconfirmedFunction,
      notice: state.notice,
      subject: state.subject,
      search: state.search,
    );
    final r = await ref
        .read(membershipLifecycleRepositoryProvider)
        .fetchOverview();
    if (!_current(epoch)) return;
    // A denial or failure drops everything protected from the screen.
    state = MembershipLifecycleState(
      result: r,
      unconfirmed: state.unconfirmed,
      unconfirmedFunction: state.unconfirmedFunction,
      notice: state.notice,
      subject: state.subject,
      search: r is AccessReadOk<MembershipLifecycleOverview>
          ? state.search
          : null,
    );
    if (r is AccessReadDenied<MembershipLifecycleOverview>) {
      noteProtectedDenial(ref);
    }
  }

  void dismissNotice() => state = MembershipLifecycleState(
    result: state.result,
    unconfirmed: state.unconfirmed,
    unconfirmedFunction: state.unconfirmedFunction,
    subject: state.subject,
    search: state.search,
  );

  /// Finds approved members (the 2.5 member search).
  Future<void> searchMembers(String query) async {
    final epoch = _epoch;
    state = MembershipLifecycleState(
      result: state.result,
      unconfirmed: state.unconfirmed,
      unconfirmedFunction: state.unconfirmedFunction,
      notice: state.notice,
      subject: state.subject,
      searching: true,
      search: state.search,
    );
    final r = await ref
        .read(reviewRepositoryProvider)
        .searchMembers(query.trim().isEmpty ? null : query.trim());
    if (!_current(epoch)) return;
    state = MembershipLifecycleState(
      result: state.result,
      unconfirmed: state.unconfirmed,
      unconfirmedFunction: state.unconfirmedFunction,
      notice: state.notice,
      subject: state.subject,
      search: switch (r) {
        AccessReadOk(:final value) => AccessReadOk(value.members),
        AccessReadDenied(:final denial) => AccessReadDenied(denial),
        AccessReadFailed(:final unreachable, :final cause) => AccessReadFailed(
          unreachable: unreachable,
          cause: cause,
        ),
      },
    );
    if (r is AccessReadDenied) noteProtectedDenial(ref);
  }

  /// A 2.8 hold of kind `login` (identity.place_hold `login_disabled`).
  Future<void> holdLogin(MemberRecord m) => _send(
    CredentialCommands.function,
    CredentialCommands.placeHold,
    m.revision,
    {'member_id': m.memberId, 'reason_code': HoldReason.loginDisabled.wire},
    m.displayName,
  );

  Future<void> releaseLoginHold(LoginHoldItem hold, IdentityCheck check) =>
      _send(
        CredentialCommands.function,
        CredentialCommands.releaseHold,
        hold.memberRevision,
        {
          'member_id': hold.memberId,
          'hold_id': hold.holdId,
          'identity_check': check.wire,
        },
        hold.displayName,
      );

  Future<void> deactivate(MemberRecord m, DeactivationReason reason) => _send(
    LifecycleCommands.function,
    LifecycleCommands.deactivate,
    m.revision,
    {'member_id': m.memberId, 'reason_code': reason.wire},
    m.displayName,
  );

  Future<void> restore(DeactivatedMember m, IdentityCheck check) => _send(
    LifecycleCommands.function,
    LifecycleCommands.restore,
    m.revision,
    {'member_id': m.memberId, 'identity_check': check.wire},
    m.displayName,
  );

  Future<void> checkAgain() async {
    final u = state.unconfirmed;
    final f = state.unconfirmedFunction;
    if (u == null || f == null || state.busy) return;
    await _dispatch(f, u, state.subject ?? '');
  }

  Future<void> _send(
    String function,
    String command,
    int expected,
    Map<String, Object?> payload,
    String subject,
  ) async {
    if (state.busy) return;
    final u = state.unconfirmed;
    final same =
        u != null &&
        state.unconfirmedFunction == function &&
        u.command == command &&
        u.expectedRevision.value == expected &&
        jsonEncode(u.payload) == jsonEncode(payload);
    await _dispatch(
      function,
      CommandRequest(
        command: command,
        requestId: same ? u.requestId : ref.read(requestIdsProvider).next(),
        expectedRevision: Optional.of(expected),
        payload: payload,
      ),
      subject,
    );
  }

  static LifecycleNotice refusal(CommandError error) {
    final f = error.fieldErrors;
    return switch (error.code) {
      ErrorCode.forbidden when f['member_id'] == 'last_admin' =>
        LifecycleNotice.lastAdmin,
      ErrorCode.forbidden when f.values.contains('unsupported') =>
        LifecycleNotice.selfAction,
      ErrorCode.forbidden => LifecycleNotice.noLongerAdmin,
      ErrorCode.conflict when f['member_id'] == 'handover_required' =>
        LifecycleNotice.handoverRequired,
      ErrorCode.conflict when f['reason_code'] == 'already_held' =>
        LifecycleNotice.alreadyHeld,
      ErrorCode.conflict when f['member_id'] == 'not_approved' =>
        LifecycleNotice.notApproved,
      ErrorCode.conflict when f['member_id'] == 'not_deactivated' =>
        LifecycleNotice.notDeactivated,
      ErrorCode.conflict when f['hold_id'] == 'password_reset_required' =>
        LifecycleNotice.passwordResetRequired,
      ErrorCode.conflict => LifecycleNotice.changedElsewhere,
      ErrorCode.validationFailed => LifecycleNotice.invalid,
      ErrorCode.unauthenticated => LifecycleNotice.signInAgain,
      ErrorCode.notFound => LifecycleNotice.notFound,
      ErrorCode.unavailable => LifecycleNotice.notAccepting,
      _ => LifecycleNotice.refused,
    };
  }

  static LifecycleNotice _success(String command) => switch (command) {
    CredentialCommands.placeHold => LifecycleNotice.loginHeld,
    CredentialCommands.releaseHold => LifecycleNotice.holdReleased,
    LifecycleCommands.deactivate => LifecycleNotice.deactivated,
    _ => LifecycleNotice.restored,
  };

  Future<void> _dispatch(
    String function,
    CommandRequest request,
    String subject,
  ) async {
    final epoch = _epoch;
    state = MembershipLifecycleState(
      result: state.result,
      pending: request,
      pendingFunction: function,
      subject: subject,
      search: state.search,
    );
    final outcome = await ref
        .read(commandGatewayProvider)
        .send(function, request);
    if (!_current(epoch)) return;
    LifecycleNotice notice;
    CommandRequest? unconfirmed;
    var reload = true;
    switch (outcome) {
      case CommandConfirmed():
        notice = _success(request.command);
      case CommandRefused(:final error):
        notice = refusal(error);
        if (error.code == ErrorCode.forbidden ||
            error.code == ErrorCode.unauthenticated) {
          noteProtectedDenial(ref);
        }
        reload =
            notice != LifecycleNotice.invalid &&
            notice != LifecycleNotice.selfAction;
      case CommandUnknownOutcome():
        notice = LifecycleNotice.unconfirmed;
        unconfirmed = request;
        reload = false;
      case CommandNotSent():
        notice = LifecycleNotice.notSent;
        reload = false;
    }
    final changed =
        notice == LifecycleNotice.loginHeld ||
        notice == LifecycleNotice.deactivated;
    state = MembershipLifecycleState(
      result: state.result,
      unconfirmed: unconfirmed,
      unconfirmedFunction: unconfirmed == null ? null : function,
      notice: notice,
      subject: subject,
      // The found member's revision changed: search again before acting.
      search: changed ? null : state.search,
    );
    if (reload) await _reload(epoch);
  }
}

final membershipLifecycleProvider =
    NotifierProvider<MembershipLifecycleController, MembershipLifecycleState>(
      MembershipLifecycleController.new,
    );

import 'dart:convert';

import 'package:church_contracts/church_contracts.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/access_grants.dart';
import '../domain/account_auth.dart';
import '../domain/commands.dart';
import '../domain/credential_review.dart';
import '../domain/membership_review.dart' show IdentityCheck, MemberRecord;
import '../domain/recovery_email.dart';
import 'access_controllers.dart' show noteProtectedDenial;
import 'account_controllers.dart' show memberSummaryControllerProvider;
import 'providers.dart';

// ---------------------------------------------------------------------------
// Member: own sign-in details, change requests and the help screen
// ---------------------------------------------------------------------------

enum CredentialNotice {
  /// Recorded; the church reviews it.
  requested,

  /// Recorded; the confirmation link was sent to the new address.
  checkInbox,

  /// Withdrawn: the account is back on its approved sign-in details.
  withdrawn,
  wrongPassword,

  /// The last password sign-in is too old: confirm the password again.
  reauthenticate,

  /// The number is a username of another account (never taken over).
  numberUnavailable,

  /// Only test numbers are accepted here for now.
  numberOutOfRange,
  unchanged,
  addressUnavailable,
  invalid,

  /// Another request is still waiting.
  pendingChange,
  rateLimited,

  /// Recorded, but the confirmation email could not be sent.
  confirmationNotSent,
  notNow,
  signInAgain,
  unconfirmed,
  unreachable,
  notSent,
}

class MyCredentialsState {
  const MyCredentialsState({
    this.loading = false,
    this.result,
    this.busy = false,
    this.notice,
    this.unconfirmed,
  });

  final bool loading;
  final AccessRead<MyCredentials>? result;
  final bool busy;
  final CredentialNotice? notice;

  /// The request whose outcome is unknown (same request id on retry).
  final CommandRequest? unconfirmed;

  MyCredentials? get value => switch (result) {
    AccessReadOk(:final value) => value,
    _ => null,
  };

  MyCredentialsState copyWith({
    bool? loading,
    AccessRead<MyCredentials>? result,
    bool? busy,
    CredentialNotice? notice,
    bool clearNotice = false,
    CommandRequest? unconfirmed,
    bool clearUnconfirmed = false,
  }) => MyCredentialsState(
    loading: loading ?? this.loading,
    result: result ?? this.result,
    busy: busy ?? this.busy,
    notice: clearNotice ? null : (notice ?? this.notice),
    unconfirmed: clearUnconfirmed ? null : (unconfirmed ?? this.unconfirmed),
  );
}

/// The member's own sign-in details, change requests (mobile) and the
/// generic access-review help screen (both clients). Protected state
/// (AD-13): memory only, scoped to the account generation.
class MyCredentialsController extends Notifier<MyCredentialsState> {
  int _epoch = 0;

  @override
  MyCredentialsState build() {
    ref.watch(accountGenerationProvider);
    _epoch++;
    final epoch = _epoch;
    if (ref.read(accountProvider).accountId == null) {
      return const MyCredentialsState(
        result: AccessReadDenied(AccessDenial.signedOut),
      );
    }
    Future.microtask(() => _load(epoch));
    return const MyCredentialsState(loading: true);
  }

  bool _current(int epoch) => ref.mounted && epoch == _epoch;

  Future<void> reload() => _load(_epoch);

  Future<void> _load(int epoch) async {
    if (!_current(epoch)) return;
    state = state.copyWith(loading: true);
    final r = await ref.read(credentialReviewRepositoryProvider).fetchMine();
    if (!_current(epoch)) return;
    state = state.copyWith(loading: false, result: r);
    if (r is AccessReadDenied<MyCredentials> &&
        r.denial != AccessDenial.signedOut) {
      noteProtectedDenial(ref);
    }
  }

  void dismissNotice() => state = state.copyWith(clearNotice: true);

  /// Confirms the current password (a fresh password sign-in on the same
  /// account), then records the request for church review. For a new
  /// recovery email, Auth then emails the confirmation link to it.
  Future<void> requestChange(
    CredentialChangeKind kind,
    String password, {
    String? phoneUsername,
    String? email,
  }) async {
    if (state.busy) return;
    final epoch = _epoch;
    state = state.copyWith(busy: true, clearNotice: true);
    final auth = await ref
        .read(recoveryEmailRepositoryProvider)
        .confirmPassword(password);
    if (!_current(epoch)) return;
    if (auth is AuthFailed) {
      state = state.copyWith(
        busy: false,
        notice: switch (auth.failure) {
          AuthFailure.invalidCredentials => CredentialNotice.wrongPassword,
          AuthFailure.rateLimited => CredentialNotice.rateLimited,
          AuthFailure.unreachable => CredentialNotice.unreachable,
          _ => CredentialNotice.notNow,
        },
      );
      return;
    }
    final payload = <String, Object?>{
      'change_kind': kind.wire,
      if (kind == CredentialChangeKind.phoneUsername)
        'phone_username': phoneUsername,
      if (kind == CredentialChangeKind.recoveryEmailReplace)
        'email': email?.trim().toLowerCase(),
    };
    final u = state.unconfirmed;
    final same =
        u != null &&
        u.command == CredentialCommands.request &&
        jsonEncode(u.payload) == jsonEncode(payload);
    await _send(
      epoch,
      CredentialCommands.function,
      CommandRequest(
        command: CredentialCommands.request,
        requestId: same ? u.requestId : ref.read(requestIdsProvider).next(),
        expectedRevision: const Optional.of(null),
        payload: payload,
      ),
    );
  }

  /// Withdraws the member's own pending request (also in review).
  Future<void> withdraw(CredentialChange change) async {
    if (state.busy) return;
    final epoch = _epoch;
    state = state.copyWith(busy: true, clearNotice: true);
    await _send(
      epoch,
      CredentialCommands.function,
      CommandRequest(
        command: CredentialCommands.withdraw,
        requestId: ref.read(requestIdsProvider).next(),
        expectedRevision: Optional.of(change.revision),
        payload: {'change_id': change.changeId},
      ),
    );
  }

  /// Withdraws a pending 2.7 recovery-email addition from the help screen.
  Future<void> withdrawRecoveryEmail(RecoveryEmailProposal proposal) async {
    if (state.busy) return;
    final epoch = _epoch;
    state = state.copyWith(busy: true, clearNotice: true);
    await _send(
      epoch,
      RecoveryEmailCommands.function,
      CommandRequest(
        command: RecoveryEmailCommands.withdraw,
        requestId: ref.read(requestIdsProvider).next(),
        expectedRevision: Optional.of(proposal.revision),
        payload: {'proposal_id': proposal.proposalId},
      ),
    );
  }

  /// Resends an unconfirmed request unchanged (same request id and body).
  Future<void> checkAgain() async {
    final u = state.unconfirmed;
    if (u == null || state.busy) return;
    final epoch = _epoch;
    state = state.copyWith(busy: true, clearNotice: true);
    await _send(epoch, CredentialCommands.function, u);
  }

  static CredentialNotice _refusal(CommandError error) {
    final f = error.fieldErrors;
    return switch (error.code) {
      ErrorCode.forbidden when f['session'] == 'reauthenticate' =>
        CredentialNotice.reauthenticate,
      ErrorCode.conflict when f['phone_username'] == 'unavailable' =>
        CredentialNotice.numberUnavailable,
      ErrorCode.conflict when f['email'] == 'unavailable' =>
        CredentialNotice.addressUnavailable,
      ErrorCode.conflict when f['change_id'] == 'pending' =>
        CredentialNotice.pendingChange,
      ErrorCode.validationFailed when f['phone_username'] == 'out_of_range' =>
        CredentialNotice.numberOutOfRange,
      ErrorCode.validationFailed when f.values.contains('unchanged') =>
        CredentialNotice.unchanged,
      ErrorCode.validationFailed when f['email'] == 'unsupported' =>
        CredentialNotice.addressUnavailable,
      ErrorCode.validationFailed => CredentialNotice.invalid,
      ErrorCode.rateLimited => CredentialNotice.rateLimited,
      ErrorCode.unauthenticated => CredentialNotice.signInAgain,
      _ => CredentialNotice.notNow,
    };
  }

  Future<void> _send(int epoch, String function, CommandRequest request) async {
    final outcome = await ref
        .read(commandGatewayProvider)
        .send(function, request);
    if (!_current(epoch)) return;
    switch (outcome) {
      case CommandConfirmed()
          when request.command != CredentialCommands.request:
        state = state.copyWith(
          busy: false,
          clearUnconfirmed: true,
          notice: CredentialNotice.withdrawn,
        );
        // A lifted review moved the trust epoch: the summary is asked again,
        // and an untrusted answer ends this session (sign in again).
        ref.invalidate(memberSummaryControllerProvider);
        noteProtectedDenial(ref);
        await _load(epoch);
      case CommandConfirmed():
        var notice = CredentialNotice.requested;
        if (request.payload['change_kind'] ==
            CredentialChangeKind.recoveryEmailReplace.wire) {
          final sent = await ref
              .read(recoveryEmailRepositoryProvider)
              .requestVerification(request.payload['email']! as String);
          if (!_current(epoch)) return;
          notice = switch (sent) {
            EmailVerificationRequest.sent => CredentialNotice.checkInbox,
            EmailVerificationRequest.addressUnavailable =>
              CredentialNotice.addressUnavailable,
            EmailVerificationRequest.rateLimited =>
              CredentialNotice.rateLimited,
            _ => CredentialNotice.confirmationNotSent,
          };
          // The old address left the account: access now waits in review.
          noteProtectedDenial(ref);
        }
        state = state.copyWith(
          busy: false,
          clearUnconfirmed: true,
          notice: notice,
        );
        await _load(epoch);
      case CommandRefused(:final error):
        state = state.copyWith(
          busy: false,
          clearUnconfirmed: true,
          notice: _refusal(error),
        );
        if (error.code == ErrorCode.forbidden ||
            error.code == ErrorCode.unauthenticated) {
          noteProtectedDenial(ref);
        }
        await _load(epoch);
      case CommandUnknownOutcome():
        state = state.copyWith(
          busy: false,
          unconfirmed: request,
          notice: CredentialNotice.unconfirmed,
        );
      case CommandNotSent():
        state = state.copyWith(busy: false, notice: CredentialNotice.notSent);
    }
  }
}

final myCredentialsProvider =
    NotifierProvider<MyCredentialsController, MyCredentialsState>(
      MyCredentialsController.new,
    );

// ---------------------------------------------------------------------------
// Admin: credential changes, access reviews and holds (staff web)
// ---------------------------------------------------------------------------

enum CredentialReviewNotice {
  approved,
  rejected,
  holdPlaced,
  holdReleased,
  restored,
  accepted,

  /// A new recovery email is not confirmed on the account yet.
  unverified,

  /// Something else changed on the account: reject, then review it.
  otherChanges,

  /// Another account holds the requested number.
  taken,

  /// Decide the pending request first.
  pendingChange,

  /// An extra sign-in factor exists: restore instead.
  unsupportedFactors,

  /// The account's current number or email cannot be accepted.
  notAcceptable,
  alreadyHeld,

  /// The member is on hold: release the hold first (restore stays possible).
  held,

  /// The hold stays until the member resets the password themselves.
  passwordResetRequired,

  /// The password may have been set by someone else: restore instead.
  passwordUnreviewed,

  /// The approved number or address is held by another account now.
  restoreBlocked,
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

class CredentialReviewState {
  const CredentialReviewState({
    this.loading = false,
    this.result,
    this.pending,
    this.unconfirmed,
    this.notice,
    this.subject,
    this.searching = false,
    this.search,
  });

  final bool loading;
  final AccessRead<CredentialQueue>? result;
  final CommandRequest? pending;
  final CommandRequest? unconfirmed;
  final CredentialReviewNotice? notice;

  /// Who the last action was about (display only).
  final String? subject;
  final bool searching;

  /// Members found to place a hold on.
  final AccessRead<List<MemberRecord>>? search;

  bool get busy => pending != null;

  CredentialQueue? get queue => switch (result) {
    AccessReadOk(:final value) => value,
    _ => null,
  };

  CredentialReviewState copyWith({
    bool? loading,
    AccessRead<CredentialQueue>? result,
    CommandRequest? pending,
    bool clearPending = false,
    CommandRequest? unconfirmed,
    bool clearUnconfirmed = false,
    CredentialReviewNotice? notice,
    bool clearNotice = false,
    String? subject,
    bool? searching,
    AccessRead<List<MemberRecord>>? search,
  }) => CredentialReviewState(
    loading: loading ?? this.loading,
    result: result ?? this.result,
    pending: clearPending ? null : (pending ?? this.pending),
    unconfirmed: clearUnconfirmed ? null : (unconfirmed ?? this.unconfirmed),
    notice: clearNotice ? null : (notice ?? this.notice),
    subject: subject ?? this.subject,
    searching: searching ?? this.searching,
    search: search ?? this.search,
  );
}

class CredentialReviewController extends Notifier<CredentialReviewState> {
  int _epoch = 0;

  @override
  CredentialReviewState build() {
    ref.watch(accountGenerationProvider);
    _epoch++;
    final epoch = _epoch;
    Future.microtask(() => _reload(epoch));
    return const CredentialReviewState(loading: true);
  }

  bool _current(int epoch) => ref.mounted && epoch == _epoch;

  Future<void> reload() => _reload(_epoch);

  Future<void> _reload(int epoch) async {
    if (!_current(epoch)) return;
    state = state.copyWith(loading: true);
    final r = await ref.read(credentialReviewRepositoryProvider).fetchQueue();
    if (!_current(epoch)) return;
    // A denial or failure drops everything protected from the screen.
    state = CredentialReviewState(
      result: r,
      unconfirmed: state.unconfirmed,
      notice: state.notice,
      subject: state.subject,
      search: r is AccessReadOk<CredentialQueue> ? state.search : null,
    );
    if (r is AccessReadDenied<CredentialQueue>) noteProtectedDenial(ref);
  }

  void dismissNotice() => state = state.copyWith(clearNotice: true);

  /// Finds approved members to place a hold on (the 2.5 member search).
  Future<void> searchMembers(String query) async {
    final epoch = _epoch;
    state = state.copyWith(searching: true);
    final r = await ref
        .read(reviewRepositoryProvider)
        .searchMembers(query.trim().isEmpty ? null : query.trim());
    if (!_current(epoch)) return;
    state = state.copyWith(
      searching: false,
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

  Future<void> approve(CredentialChangeItem item, IdentityCheck check) => _send(
    CredentialCommands.approve,
    item.change.revision,
    {'change_id': item.change.changeId, 'identity_check': check.wire},
    item.displayName,
  );

  Future<void> reject(
    CredentialChangeItem item, {
    RecoveryEmailRejectReason? reason,
  }) => _send(CredentialCommands.reject, item.change.revision, {
    'change_id': item.change.changeId,
    'reason': ?reason?.wire,
  }, item.displayName);

  Future<void> placeHold(
    String memberId,
    int memberRevision,
    String displayName,
    HoldReason reason,
  ) => _send(CredentialCommands.placeHold, memberRevision, {
    'member_id': memberId,
    'reason_code': reason.wire,
  }, displayName);

  Future<void> releaseHold(HoldItem hold, IdentityCheck check) =>
      _send(CredentialCommands.releaseHold, hold.memberRevision, {
        'member_id': hold.memberId,
        'hold_id': hold.holdId,
        'identity_check': check.wire,
      }, hold.displayName);

  Future<void> restore(AccessReviewItem item, IdentityCheck check) => _send(
    CredentialCommands.restore,
    item.memberRevision,
    {'member_id': item.memberId, 'identity_check': check.wire},
    item.displayName,
  );

  Future<void> accept(AccessReviewItem item, IdentityCheck check) => _send(
    CredentialCommands.accept,
    item.memberRevision,
    {'member_id': item.memberId, 'identity_check': check.wire},
    item.displayName,
  );

  Future<void> checkAgain() async {
    final u = state.unconfirmed;
    if (u == null || state.busy) return;
    await _dispatch(u, state.subject ?? '');
  }

  Future<void> _send(
    String command,
    int expected,
    Map<String, Object?> payload,
    String subject,
  ) async {
    if (state.busy) return;
    final u = state.unconfirmed;
    final same =
        u != null &&
        u.command == command &&
        u.expectedRevision.value == expected &&
        jsonEncode(u.payload) == jsonEncode(payload);
    await _dispatch(
      CommandRequest(
        command: command,
        requestId: same ? u.requestId : ref.read(requestIdsProvider).next(),
        expectedRevision: Optional.of(expected),
        payload: payload,
      ),
      subject,
    );
  }

  static CredentialReviewNotice _refusal(CommandError error) {
    final f = error.fieldErrors;
    return switch (error.code) {
      ErrorCode.conflict when f['change_id'] == 'other_changes' =>
        CredentialReviewNotice.otherChanges,
      ErrorCode.conflict when f['phone_username'] == 'taken' =>
        CredentialReviewNotice.taken,
      ErrorCode.conflict when f['member_id'] == 'pending_change' =>
        CredentialReviewNotice.pendingChange,
      ErrorCode.conflict when f['member_id'] == 'unsupported_factors' =>
        CredentialReviewNotice.unsupportedFactors,
      ErrorCode.conflict
          when f['member_id'] == 'phone_unsupported' ||
              f['member_id'] == 'email_unverified' =>
        CredentialReviewNotice.notAcceptable,
      ErrorCode.conflict
          when f['member_id'] == 'phone_taken' ||
              f['member_id'] == 'email_taken' =>
        CredentialReviewNotice.restoreBlocked,
      ErrorCode.conflict when f['reason_code'] == 'already_held' =>
        CredentialReviewNotice.alreadyHeld,
      ErrorCode.conflict when f['member_id'] == 'held' =>
        CredentialReviewNotice.held,
      ErrorCode.conflict when f['hold_id'] == 'password_reset_required' =>
        CredentialReviewNotice.passwordResetRequired,
      ErrorCode.conflict when f['member_id'] == 'password_unreviewed' =>
        CredentialReviewNotice.passwordUnreviewed,
      ErrorCode.conflict => CredentialReviewNotice.changedElsewhere,
      ErrorCode.validationFailed when f['recovery_email'] == 'unverified' =>
        CredentialReviewNotice.unverified,
      ErrorCode.validationFailed => CredentialReviewNotice.invalid,
      ErrorCode.forbidden when f.values.contains('unsupported') =>
        CredentialReviewNotice.selfAction,
      ErrorCode.forbidden => CredentialReviewNotice.noLongerAdmin,
      ErrorCode.unauthenticated => CredentialReviewNotice.signInAgain,
      ErrorCode.notFound => CredentialReviewNotice.notFound,
      ErrorCode.unavailable => CredentialReviewNotice.notAccepting,
      _ => CredentialReviewNotice.refused,
    };
  }

  static CredentialReviewNotice _success(String command) => switch (command) {
    CredentialCommands.approve => CredentialReviewNotice.approved,
    CredentialCommands.reject => CredentialReviewNotice.rejected,
    CredentialCommands.placeHold => CredentialReviewNotice.holdPlaced,
    CredentialCommands.releaseHold => CredentialReviewNotice.holdReleased,
    CredentialCommands.restore => CredentialReviewNotice.restored,
    _ => CredentialReviewNotice.accepted,
  };

  Future<void> _dispatch(CommandRequest request, String subject) async {
    final epoch = _epoch;
    state = state.copyWith(
      pending: request,
      clearNotice: true,
      subject: subject,
    );
    final outcome = await ref
        .read(commandGatewayProvider)
        .send(CredentialCommands.function, request);
    if (!_current(epoch)) return;
    CredentialReviewNotice notice;
    CommandRequest? unconfirmed;
    var reload = true;
    switch (outcome) {
      case CommandConfirmed():
        notice = _success(request.command);
      case CommandRefused(:final error):
        notice = _refusal(error);
        if (error.code == ErrorCode.forbidden ||
            error.code == ErrorCode.unauthenticated) {
          noteProtectedDenial(ref);
        }
        reload =
            notice != CredentialReviewNotice.invalid &&
            notice != CredentialReviewNotice.selfAction;
      case CommandUnknownOutcome():
        notice = CredentialReviewNotice.unconfirmed;
        unconfirmed = request;
        reload = false;
      case CommandNotSent():
        notice = CredentialReviewNotice.notSent;
        reload = false;
    }
    state = CredentialReviewState(
      result: state.result,
      unconfirmed: unconfirmed,
      notice: notice,
      subject: subject,
      search: notice == CredentialReviewNotice.holdPlaced ? null : state.search,
    );
    if (reload) await _reload(epoch);
  }
}

final credentialReviewProvider =
    NotifierProvider<CredentialReviewController, CredentialReviewState>(
      CredentialReviewController.new,
    );

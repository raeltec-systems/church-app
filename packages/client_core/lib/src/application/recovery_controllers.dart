import 'dart:convert';

import 'package:church_contracts/church_contracts.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/access_grants.dart';
import '../domain/account_auth.dart';
import '../domain/commands.dart';
import '../domain/membership_review.dart' show IdentityCheck;
import '../domain/password_recovery.dart';
import '../domain/recovery_email.dart';
import 'access_controllers.dart' show noteProtectedDenial;
import 'providers.dart';

// ---------------------------------------------------------------------------
// Forgot password (neutral)
// ---------------------------------------------------------------------------

enum ForgotPhase { idle, pending, sent, unreachable, notConfigured }

/// Forgot password. The answer is the same whether or not the address
/// belongs to an account or is its approved recovery email.
class ForgotPasswordController extends Notifier<ForgotPhase> {
  @override
  ForgotPhase build() => ForgotPhase.idle;

  Future<void> request(String email) async {
    if (state == ForgotPhase.pending) return;
    state = ForgotPhase.pending;
    final outcome = await ref
        .read(passwordRecoveryGatewayProvider)
        .requestReset(email);
    if (!ref.mounted) return;
    state = switch (outcome) {
      ResetRequestOutcome.sent => ForgotPhase.sent,
      ResetRequestOutcome.unreachable => ForgotPhase.unreachable,
      ResetRequestOutcome.notConfigured => ForgotPhase.notConfigured,
    };
  }

  void reset() => state = ForgotPhase.idle;
}

final forgotPasswordProvider =
    NotifierProvider<ForgotPasswordController, ForgotPhase>(
      ForgotPasswordController.new,
    );

// ---------------------------------------------------------------------------
// Opening a recovery link and setting the new password
// ---------------------------------------------------------------------------

enum RecoveryPhase {
  /// Opening the link with the verifier this device kept.
  opening,

  /// A new password can be set (the only thing this session can do).
  ready,
  saving,

  /// Expired, used, not for an approved recovery email, from another
  /// device, or malformed: one answer for all.
  unusable,
  unreachable,

  /// Password set; the recovery session is ended. Sign in again.
  done,
}

class RecoveryState {
  const RecoveryState(
    this.phase, {
    this.failure,
    this.serverReasons = const [],
  });
  final RecoveryPhase phase;

  /// The last refused password (weak, or the session ran out).
  final SetPasswordFailure? failure;
  final List<String> serverReasons;
}

class RecoveryLinkController extends Notifier<RecoveryState> {
  String? _openedCode;

  @override
  RecoveryState build() {
    // Leaving without setting a password ends the recovery session.
    final gateway = ref.read(passwordRecoveryGatewayProvider);
    ref.onDispose(gateway.discard);
    return const RecoveryState(RecoveryPhase.opening);
  }

  /// Opens [link] once; anything not usable is the same neutral answer.
  Future<void> open(AuthLink? link) async {
    if (link == null || link.kind != AuthLinkKind.recovery || !link.usable) {
      state = const RecoveryState(RecoveryPhase.unusable);
      return;
    }
    if (_openedCode == link.code) return;
    _openedCode = link.code;
    state = const RecoveryState(RecoveryPhase.opening);
    final outcome = await ref
        .read(passwordRecoveryGatewayProvider)
        .openLink(link.code!);
    if (!ref.mounted) return;
    state = RecoveryState(switch (outcome) {
      RecoveryLinkOutcome.ready => RecoveryPhase.ready,
      RecoveryLinkOutcome.unusable => RecoveryPhase.unusable,
      RecoveryLinkOutcome.unreachable => RecoveryPhase.unreachable,
    });
  }

  Future<void> setPassword(String password) async {
    if (state.phase != RecoveryPhase.ready) return;
    state = const RecoveryState(RecoveryPhase.saving);
    final outcome = await ref
        .read(passwordRecoveryGatewayProvider)
        .setNewPassword(password);
    if (!ref.mounted) return;
    switch (outcome) {
      case PasswordSet():
        // Every earlier session lost private access at the server; end this
        // device's own one too, so the next step is a fresh sign-in.
        if (ref.read(accountProvider).accountId != null) {
          await ref.read(accountAuthGatewayProvider).signOut();
        }
        if (!ref.mounted) return;
        state = const RecoveryState(RecoveryPhase.done);
      case PasswordNotSet(:final failure, :final serverReasons):
        state = RecoveryState(
          failure == SetPasswordFailure.linkExpired
              ? RecoveryPhase.unusable
              : RecoveryPhase.ready,
          failure: failure,
          serverReasons: serverReasons,
        );
    }
  }
}

final recoveryLinkProvider =
    NotifierProvider.autoDispose<RecoveryLinkController, RecoveryState>(
      RecoveryLinkController.new,
    );

// ---------------------------------------------------------------------------
// The member's own recovery email
// ---------------------------------------------------------------------------

enum RecoveryEmailNotice {
  /// Proposed and the confirmation link was sent to the new address.
  checkInbox,

  /// The current password was not right.
  wrongPassword,

  /// The last password sign-in is too old: confirm the password again.
  reauthenticate,

  /// This address cannot be used (for example while only test addresses are
  /// allowed, or it belongs to another account).
  addressUnavailable,
  invalidAddress,
  rateLimited,

  /// Recorded, but Auth could not send the confirmation: try again.
  confirmationNotSent,

  /// Adding a recovery email is not possible right now (access review, an
  /// approved email already exists, or the feature is closed here).
  notNow,
  signInAgain,
  unconfirmed,
  unreachable,
  notSent,
}

class MyRecoveryEmailState {
  const MyRecoveryEmailState({
    this.loading = false,
    this.result,
    this.busy = false,
    this.notice,
    this.unconfirmed,
  });

  final bool loading;
  final AccessRead<MyRecoveryEmail>? result;
  final bool busy;
  final RecoveryEmailNotice? notice;

  /// The proposal whose outcome is unknown (same request id on retry).
  final CommandRequest? unconfirmed;

  MyRecoveryEmailState copyWith({
    bool? loading,
    AccessRead<MyRecoveryEmail>? result,
    bool? busy,
    RecoveryEmailNotice? notice,
    bool clearNotice = false,
    CommandRequest? unconfirmed,
    bool clearUnconfirmed = false,
  }) => MyRecoveryEmailState(
    loading: loading ?? this.loading,
    result: result ?? this.result,
    busy: busy ?? this.busy,
    notice: clearNotice ? null : (notice ?? this.notice),
    unconfirmed: clearUnconfirmed ? null : (unconfirmed ?? this.unconfirmed),
  );
}

/// Mobile: the member adds an optional recovery email to the same account.
/// Protected state (AD-13): memory only, scoped to the account generation.
class MyRecoveryEmailController extends Notifier<MyRecoveryEmailState> {
  int _epoch = 0;

  @override
  MyRecoveryEmailState build() {
    ref.watch(accountGenerationProvider);
    _epoch++;
    final epoch = _epoch;
    if (ref.read(accountProvider).accountId == null) {
      return const MyRecoveryEmailState(
        result: AccessReadDenied(AccessDenial.signedOut),
      );
    }
    Future.microtask(() => _load(epoch));
    return const MyRecoveryEmailState(loading: true);
  }

  bool _current(int epoch) => ref.mounted && epoch == _epoch;

  Future<void> reload() => _load(_epoch);

  Future<void> _load(int epoch) async {
    if (!_current(epoch)) return;
    state = state.copyWith(loading: true);
    final r = await ref.read(recoveryEmailRepositoryProvider).fetchMine();
    if (!_current(epoch)) return;
    state = state.copyWith(loading: false, result: r);
    if (r is AccessReadDenied<MyRecoveryEmail> &&
        r.denial != AccessDenial.signedOut) {
      noteProtectedDenial(ref);
    }
  }

  void dismissNotice() => state = state.copyWith(clearNotice: true);

  /// Confirms the current password (a fresh password sign-in on the same
  /// account), records the proposal, then asks Auth to email the
  /// confirmation link to [email].
  Future<void> addEmail(String email, String password) async {
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
          AuthFailure.invalidCredentials => RecoveryEmailNotice.wrongPassword,
          AuthFailure.rateLimited => RecoveryEmailNotice.rateLimited,
          AuthFailure.unreachable => RecoveryEmailNotice.unreachable,
          _ => RecoveryEmailNotice.notNow,
        },
      );
      return;
    }
    final payload = {'email': email.trim().toLowerCase()};
    final u = state.unconfirmed;
    final same = u != null && jsonEncode(u.payload) == jsonEncode(payload);
    await _propose(
      epoch,
      CommandRequest(
        command: RecoveryEmailCommands.propose,
        requestId: same ? u.requestId : ref.read(requestIdsProvider).next(),
        expectedRevision: const Optional.of(null),
        payload: payload,
      ),
    );
  }

  /// Resends an unconfirmed proposal unchanged (same request id and body).
  Future<void> checkAgain() async {
    final u = state.unconfirmed;
    if (u == null || state.busy) return;
    final epoch = _epoch;
    state = state.copyWith(busy: true, clearNotice: true);
    await _propose(epoch, u);
  }

  Future<void> _propose(int epoch, CommandRequest request) async {
    final outcome = await ref
        .read(commandGatewayProvider)
        .send(RecoveryEmailCommands.function, request);
    if (!_current(epoch)) return;
    switch (outcome) {
      case CommandConfirmed():
        final sent = await ref
            .read(recoveryEmailRepositoryProvider)
            .requestVerification(request.payload['email']! as String);
        if (!_current(epoch)) return;
        state = state.copyWith(
          busy: false,
          clearUnconfirmed: true,
          notice: switch (sent) {
            EmailVerificationRequest.sent => RecoveryEmailNotice.checkInbox,
            EmailVerificationRequest.addressUnavailable =>
              RecoveryEmailNotice.addressUnavailable,
            EmailVerificationRequest.rateLimited =>
              RecoveryEmailNotice.rateLimited,
            _ => RecoveryEmailNotice.confirmationNotSent,
          },
        );
        await _load(epoch);
      case CommandRefused(:final error):
        final f = error.fieldErrors;
        state = state.copyWith(
          busy: false,
          clearUnconfirmed: true,
          notice: switch (error.code) {
            ErrorCode.forbidden when f['session'] == 'reauthenticate' =>
              RecoveryEmailNotice.reauthenticate,
            ErrorCode.validationFailed when f['email'] == 'unsupported' =>
              RecoveryEmailNotice.addressUnavailable,
            ErrorCode.validationFailed when f['email'] == 'invalid' =>
              RecoveryEmailNotice.invalidAddress,
            ErrorCode.rateLimited => RecoveryEmailNotice.rateLimited,
            ErrorCode.unauthenticated => RecoveryEmailNotice.signInAgain,
            _ => RecoveryEmailNotice.notNow,
          },
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
          notice: RecoveryEmailNotice.unconfirmed,
        );
      case CommandNotSent():
        state = state.copyWith(
          busy: false,
          notice: RecoveryEmailNotice.notSent,
        );
    }
  }
}

final myRecoveryEmailProvider =
    NotifierProvider<MyRecoveryEmailController, MyRecoveryEmailState>(
      MyRecoveryEmailController.new,
    );

// ---------------------------------------------------------------------------
// Admin: approve recovery emails into the credential binding
// ---------------------------------------------------------------------------

enum RecoveryReviewNotice {
  approved,
  rejected,

  /// The account no longer holds this email confirmed.
  unverified,

  /// Something else changed on the account: credential review needed.
  otherChanges,
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

class RecoveryReviewState {
  const RecoveryReviewState({
    this.loading = false,
    this.result,
    this.items = const [],
    this.pending,
    this.unconfirmed,
    this.notice,
    this.subject,
  });

  final bool loading;
  final AccessRead<RecoveryEmailQueue>? result;
  final List<RecoveryEmailReviewItem> items;
  final CommandRequest? pending;
  final CommandRequest? unconfirmed;
  final RecoveryReviewNotice? notice;

  /// Who the last action was about (display only).
  final String? subject;

  bool get busy => pending != null;
}

class RecoveryEmailReviewController extends Notifier<RecoveryReviewState> {
  int _epoch = 0;

  @override
  RecoveryReviewState build() {
    ref.watch(accountGenerationProvider);
    _epoch++;
    final epoch = _epoch;
    Future.microtask(() => _reload(epoch));
    return const RecoveryReviewState(loading: true);
  }

  bool _current(int epoch) => ref.mounted && epoch == _epoch;

  Future<void> reload() => _reload(_epoch);

  Future<void> _reload(int epoch) async {
    if (!_current(epoch)) return;
    state = RecoveryReviewState(
      loading: true,
      result: state.result,
      items: state.items,
      unconfirmed: state.unconfirmed,
      notice: state.notice,
      subject: state.subject,
    );
    final r = await ref.read(recoveryEmailRepositoryProvider).fetchQueue();
    if (!_current(epoch)) return;
    state = RecoveryReviewState(
      result: r,
      // A denial or failure drops everything protected from the screen.
      items: r is AccessReadOk<RecoveryEmailQueue> ? r.value.items : const [],
      unconfirmed: state.unconfirmed,
      notice: state.notice,
      subject: state.subject,
    );
    if (r is AccessReadDenied<RecoveryEmailQueue>) noteProtectedDenial(ref);
  }

  void dismissNotice() => state = RecoveryReviewState(
    result: state.result,
    items: state.items,
    unconfirmed: state.unconfirmed,
  );

  Future<void> approve(RecoveryEmailReviewItem item, IdentityCheck check) =>
      _send(RecoveryEmailCommands.approve, item, {
        'proposal_id': item.proposal.proposalId,
        'identity_check': check.wire,
      });

  Future<void> reject(
    RecoveryEmailReviewItem item, {
    RecoveryEmailRejectReason? reason,
  }) => _send(RecoveryEmailCommands.reject, item, {
    'proposal_id': item.proposal.proposalId,
    if (reason != null) 'reason': reason.wire,
  });

  Future<void> checkAgain() async {
    final u = state.unconfirmed;
    if (u == null || state.busy) return;
    await _dispatch(u, state.subject ?? '');
  }

  Future<void> _send(
    String command,
    RecoveryEmailReviewItem item,
    Map<String, Object?> payload,
  ) async {
    if (state.busy) return;
    final u = state.unconfirmed;
    final expected = Optional.of(item.proposal.revision);
    final same =
        u != null &&
        u.command == command &&
        u.expectedRevision.value == expected.value &&
        jsonEncode(u.payload) == jsonEncode(payload);
    await _dispatch(
      CommandRequest(
        command: command,
        requestId: same ? u.requestId : ref.read(requestIdsProvider).next(),
        expectedRevision: expected,
        payload: payload,
      ),
      item.displayName,
    );
  }

  static RecoveryReviewNotice _refusal(CommandError error) {
    final f = error.fieldErrors;
    return switch (error.code) {
      ErrorCode.conflict when f['proposal_id'] == 'other_changes' =>
        RecoveryReviewNotice.otherChanges,
      ErrorCode.conflict => RecoveryReviewNotice.changedElsewhere,
      ErrorCode.validationFailed when f['recovery_email'] == 'unverified' =>
        RecoveryReviewNotice.unverified,
      ErrorCode.validationFailed => RecoveryReviewNotice.invalid,
      ErrorCode.forbidden when f.values.contains('unsupported') =>
        RecoveryReviewNotice.selfAction,
      ErrorCode.forbidden => RecoveryReviewNotice.noLongerAdmin,
      ErrorCode.unauthenticated => RecoveryReviewNotice.signInAgain,
      ErrorCode.notFound => RecoveryReviewNotice.notFound,
      ErrorCode.unavailable => RecoveryReviewNotice.notAccepting,
      _ => RecoveryReviewNotice.refused,
    };
  }

  Future<void> _dispatch(CommandRequest request, String subject) async {
    final epoch = _epoch;
    state = RecoveryReviewState(
      result: state.result,
      items: state.items,
      pending: request,
      unconfirmed: state.unconfirmed,
      subject: subject,
    );
    final outcome = await ref
        .read(commandGatewayProvider)
        .send(RecoveryEmailCommands.function, request);
    if (!_current(epoch)) return;
    RecoveryReviewNotice notice;
    CommandRequest? unconfirmed;
    var reload = true;
    switch (outcome) {
      case CommandConfirmed():
        notice = request.command == RecoveryEmailCommands.approve
            ? RecoveryReviewNotice.approved
            : RecoveryReviewNotice.rejected;
      case CommandRefused(:final error):
        notice = _refusal(error);
        if (error.code == ErrorCode.forbidden ||
            error.code == ErrorCode.unauthenticated) {
          noteProtectedDenial(ref);
        }
        reload =
            notice != RecoveryReviewNotice.invalid &&
            notice != RecoveryReviewNotice.selfAction;
      case CommandUnknownOutcome():
        notice = RecoveryReviewNotice.unconfirmed;
        unconfirmed = request;
        reload = false;
      case CommandNotSent():
        notice = RecoveryReviewNotice.notSent;
        reload = false;
    }
    state = RecoveryReviewState(
      result: state.result,
      items: state.items,
      unconfirmed: unconfirmed,
      notice: notice,
      subject: subject,
    );
    if (reload) await _reload(epoch);
  }
}

final recoveryEmailReviewProvider =
    NotifierProvider<RecoveryEmailReviewController, RecoveryReviewState>(
      RecoveryEmailReviewController.new,
    );

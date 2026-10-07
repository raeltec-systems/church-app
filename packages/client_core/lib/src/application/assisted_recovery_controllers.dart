import 'dart:convert';

import 'package:church_contracts/church_contracts.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/access_grants.dart';
import '../domain/assisted_recovery.dart';
import '../domain/commands.dart';
import '../domain/membership_review.dart' show IdentityCheck, MemberRecord;
import 'access_controllers.dart' show noteProtectedDenial;
import 'providers.dart';

// ---------------------------------------------------------------------------
// Member device: "I need help accessing my account" (story 2.9)
// ---------------------------------------------------------------------------

enum AccountHelpPhase {
  /// Enter the phone number username.
  start,
  requesting,

  /// Show the request code to the church office.
  waiting,
  checking,

  /// The office issued the setup: choose a password.
  ready,
  setting,

  /// The password is set: sign in with it.
  succeeded,

  /// This request is over; start again if needed.
  ended,
}

enum AccountHelpNotice {
  rateLimited,
  refused,
  unavailable,
  unreachable,
  notConfigured,

  /// The office has not issued the setup yet.
  stillWaiting,

  /// Expired, used or replaced.
  closed,

  /// The setup could not be used.
  rejected,
  passwordRejected,

  /// Not confirmed: the account stays protected until the office checks.
  uncertain,

  /// No answer to the password step: the result is unknown.
  redeemUnreachable,
  invalid,
}

class AccountHelpState {
  const AccountHelpState({
    this.phase = AccountHelpPhase.start,
    this.phoneUsername,
    this.requestCode,
    this.expiresAt,
    this.notice,
  });

  final AccountHelpPhase phase;
  final String? phoneUsername;

  /// Not a secret: the office types it to find this request.
  final String? requestCode;
  final DateTime? expiresAt;
  final AccountHelpNotice? notice;

  bool get busy =>
      phase == AccountHelpPhase.requesting ||
      phase == AccountHelpPhase.checking ||
      phase == AccountHelpPhase.setting;
}

/// Holds the grant secret in memory only (never in state, storage or logs)
/// for the life of this app process; it is dropped when the request ends.
class AccountHelpController extends Notifier<AccountHelpState> {
  GrantSecret? _secret;

  @override
  AccountHelpState build() => const AccountHelpState();

  AssistedRecoveryGateway get _gateway =>
      ref.read(assistedRecoveryGatewayProvider);

  static AccountHelpNotice _failure(RecoveryFailure f) => switch (f) {
    RecoveryFailure.rateLimited => AccountHelpNotice.rateLimited,
    RecoveryFailure.refused => AccountHelpNotice.refused,
    RecoveryFailure.unavailable => AccountHelpNotice.unavailable,
    RecoveryFailure.unreachable => AccountHelpNotice.unreachable,
    RecoveryFailure.notConfigured => AccountHelpNotice.notConfigured,
  };

  /// Creates a new secret and sends its digest with [phoneUsername] (E.164).
  Future<void> start(String phoneUsername) async {
    if (state.busy) return;
    final secret = GrantSecret.generate();
    _secret = secret;
    state = AccountHelpState(
      phase: AccountHelpPhase.requesting,
      phoneUsername: phoneUsername,
    );
    final r = await _gateway.request(phoneUsername, secret.digest);
    if (!ref.mounted || !identical(_secret, secret)) return;
    switch (r) {
      case RecoveryRequestReceived(:final requestCode, :final expiresAt):
        state = AccountHelpState(
          phase: AccountHelpPhase.waiting,
          phoneUsername: phoneUsername,
          requestCode: requestCode,
          expiresAt: expiresAt,
        );
      case RecoveryRequestNotReceived(:final reason):
        _secret = null;
        state = AccountHelpState(
          phase: AccountHelpPhase.start,
          phoneUsername: phoneUsername,
          notice: _failure(reason),
        );
    }
  }

  /// Asks whether the office issued the setup.
  Future<void> checkStatus() async {
    final secret = _secret;
    if (secret == null || state.busy) return;
    final before = state;
    state = AccountHelpState(
      phase: AccountHelpPhase.checking,
      phoneUsername: before.phoneUsername,
      requestCode: before.requestCode,
      expiresAt: before.expiresAt,
    );
    final r = await _gateway.status(secret.digest);
    if (!ref.mounted || !identical(_secret, secret)) return;
    switch (r) {
      case RecoveryStatus(state: RecoveryGrantState.ready, :final expiresAt):
        state = AccountHelpState(
          phase: AccountHelpPhase.ready,
          phoneUsername: before.phoneUsername,
          requestCode: before.requestCode,
          expiresAt: expiresAt,
        );
      case RecoveryStatus(state: RecoveryGrantState.waiting):
        state = AccountHelpState(
          phase: AccountHelpPhase.waiting,
          phoneUsername: before.phoneUsername,
          requestCode: before.requestCode,
          expiresAt: before.expiresAt,
          notice: AccountHelpNotice.stillWaiting,
        );
      case RecoveryStatus(state: RecoveryGrantState.closed):
        _end(AccountHelpNotice.closed);
      case RecoveryStatusFailed(:final reason):
        state = AccountHelpState(
          phase: AccountHelpPhase.waiting,
          phoneUsername: before.phoneUsername,
          requestCode: before.requestCode,
          expiresAt: before.expiresAt,
          notice: _failure(reason),
        );
    }
  }

  /// Sends the chosen password with the secret, once.
  Future<void> setPassword(String password) async {
    final secret = _secret;
    final phone = state.phoneUsername;
    if (secret == null || phone == null || state.busy) return;
    final before = state;
    state = AccountHelpState(
      phase: AccountHelpPhase.setting,
      phoneUsername: phone,
      requestCode: before.requestCode,
      expiresAt: before.expiresAt,
    );
    final r = await _gateway.redeem(phone, secret, password);
    if (!ref.mounted || !identical(_secret, secret)) return;
    AccountHelpState retry(AccountHelpNotice n) => AccountHelpState(
      phase: AccountHelpPhase.ready,
      phoneUsername: phone,
      requestCode: before.requestCode,
      expiresAt: before.expiresAt,
      notice: n,
    );
    switch (r) {
      case RedeemOutcome.succeeded:
        _secret = null;
        state = AccountHelpState(
          phase: AccountHelpPhase.succeeded,
          phoneUsername: phone,
        );
      case RedeemOutcome.rejected:
        _end(AccountHelpNotice.rejected);
      case RedeemOutcome.passwordRejected:
        _end(AccountHelpNotice.passwordRejected);
      case RedeemOutcome.uncertain:
        _end(AccountHelpNotice.uncertain);
      case RedeemOutcome.unreachable:
        state = retry(AccountHelpNotice.redeemUnreachable);
      case RedeemOutcome.invalid:
        state = retry(AccountHelpNotice.invalid);
      case RedeemOutcome.unavailable:
        state = retry(AccountHelpNotice.unavailable);
      case RedeemOutcome.notConfigured:
        state = retry(AccountHelpNotice.notConfigured);
    }
  }

  void _end(AccountHelpNotice notice) {
    _secret = null;
    state = AccountHelpState(
      phase: AccountHelpPhase.ended,
      phoneUsername: state.phoneUsername,
      notice: notice,
    );
  }

  /// Drops the secret and starts again.
  void startOver() {
    _secret = null;
    state = AccountHelpState(phoneUsername: state.phoneUsername);
  }
}

final accountHelpProvider =
    NotifierProvider<AccountHelpController, AccountHelpState>(
      AccountHelpController.new,
    );

// ---------------------------------------------------------------------------
// Staff web (Admin): recovery cases
// ---------------------------------------------------------------------------

enum RecoveryCasesNotice {
  opened,
  issued,
  cancelled,
  reconciled,

  /// The account cannot be recovered now (review, dispute, changed phone).
  notRecoverable,
  openCase,
  unknownCode,

  /// The request came from another number: not this member's.
  codeMismatch,

  /// A reset is still unresolved: reconcile it first.
  unresolved,
  nothingToReconcile,
  closed,
  notLinked,
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

class RecoveryCasesState {
  const RecoveryCasesState({
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
  final AccessRead<RecoveryCases>? result;
  final CommandRequest? pending;
  final CommandRequest? unconfirmed;
  final RecoveryCasesNotice? notice;
  final String? subject;
  final bool searching;
  final AccessRead<List<MemberRecord>>? search;

  bool get busy => pending != null;

  RecoveryCases? get cases => switch (result) {
    AccessReadOk(:final value) => value,
    _ => null,
  };
}

class RecoveryCasesController extends Notifier<RecoveryCasesState> {
  int _epoch = 0;

  @override
  RecoveryCasesState build() {
    ref.watch(accountGenerationProvider);
    _epoch++;
    final epoch = _epoch;
    Future.microtask(() => _reload(epoch));
    return const RecoveryCasesState(loading: true);
  }

  bool _current(int epoch) => ref.mounted && epoch == _epoch;

  Future<void> reload() => _reload(_epoch);

  Future<void> _reload(int epoch) async {
    if (!_current(epoch)) return;
    state = RecoveryCasesState(
      loading: true,
      result: state.result,
      unconfirmed: state.unconfirmed,
      notice: state.notice,
      subject: state.subject,
      search: state.search,
    );
    final r = await ref.read(recoveryCasesRepositoryProvider).fetchCases();
    if (!_current(epoch)) return;
    final ok = r is AccessReadOk<RecoveryCases>;
    // A denial or failure drops everything protected, the member's name too.
    state = RecoveryCasesState(
      result: r,
      unconfirmed: ok ? state.unconfirmed : null,
      notice: state.notice,
      subject: ok ? state.subject : null,
      search: r is AccessReadOk<RecoveryCases> ? state.search : null,
    );
    if (r is AccessReadDenied<RecoveryCases>) noteProtectedDenial(ref);
  }

  void dismissNotice() => state = RecoveryCasesState(
    result: state.result,
    unconfirmed: state.unconfirmed,
    subject: state.subject,
    search: state.search,
  );

  /// Finds approved members (the 2.5 member search).
  Future<void> searchMembers(String query) async {
    final epoch = _epoch;
    state = RecoveryCasesState(
      result: state.result,
      unconfirmed: state.unconfirmed,
      notice: state.notice,
      subject: state.subject,
      searching: true,
      search: state.search,
    );
    final r = await ref
        .read(reviewRepositoryProvider)
        .searchMembers(query.trim().isEmpty ? null : query.trim());
    if (!_current(epoch)) return;
    state = RecoveryCasesState(
      result: state.result,
      unconfirmed: state.unconfirmed,
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

  Future<void> openCase(
    MemberRecord member,
    IdentityCheck check,
    Set<RecoveryEvidence> evidence,
  ) => _send(RecoveryCaseCommands.open, null, {
    'member_id': member.memberId,
    'identity_check': check.wire,
    'evidence': [
      for (final e in RecoveryEvidence.values)
        if (evidence.contains(e)) e.wire,
    ],
  }, member.displayName);

  Future<void> issueGrant(RecoveryCaseItem item, String requestCode) => _send(
    RecoveryCaseCommands.issue,
    item.revision,
    {'case_id': item.caseId, 'request_code': normalizeRequestCode(requestCode)},
    item.displayName,
  );

  Future<void> cancel(RecoveryCaseItem item, RecoveryCancelReason reason) =>
      _send(RecoveryCaseCommands.cancel, item.revision, {
        'case_id': item.caseId,
        'reason': reason.wire,
      }, item.displayName);

  Future<void> reconcile(RecoveryCaseItem item, IdentityCheck check) => _send(
    RecoveryCaseCommands.reconcile,
    item.revision,
    {'case_id': item.caseId, 'identity_check': check.wire},
    item.displayName,
  );

  Future<void> checkAgain() async {
    final u = state.unconfirmed;
    if (u == null || state.busy) return;
    await _dispatch(u, state.subject ?? '');
  }

  Future<void> _send(
    String command,
    int? expected,
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
        // A new case is created with an explicit null expected revision.
        expectedRevision: Optional<int>.of(expected),
        payload: payload,
      ),
      subject,
    );
  }

  static const _notRecoverable = {
    'access_review',
    'disputed',
    'phone_changed',
    'account_unavailable',
    'not_approved',
  };

  static RecoveryCasesNotice _refusal(CommandError error) {
    final f = error.fieldErrors;
    return switch (error.code) {
      ErrorCode.conflict
          when f['case_id'] == 'recovery_unresolved' ||
              f['member_id'] == 'recovery_unresolved' =>
        RecoveryCasesNotice.unresolved,
      ErrorCode.conflict when f['member_id'] == 'open_case' =>
        RecoveryCasesNotice.openCase,
      ErrorCode.conflict when f['request_code'] == 'unknown' =>
        RecoveryCasesNotice.unknownCode,
      ErrorCode.conflict when f['request_code'] == 'mismatch' =>
        RecoveryCasesNotice.codeMismatch,
      ErrorCode.conflict when f['case_id'] == 'nothing_to_reconcile' =>
        RecoveryCasesNotice.nothingToReconcile,
      ErrorCode.conflict when f['case_id'] == 'closed' =>
        RecoveryCasesNotice.closed,
      ErrorCode.conflict
          when f['case_id'] == 'not_linked' || f['member_id'] == 'not_linked' =>
        RecoveryCasesNotice.notLinked,
      ErrorCode.conflict
          when _notRecoverable.contains(f['case_id']) ||
              _notRecoverable.contains(f['member_id']) =>
        RecoveryCasesNotice.notRecoverable,
      ErrorCode.conflict => RecoveryCasesNotice.changedElsewhere,
      ErrorCode.validationFailed when f['request_code'] == 'invalid' =>
        RecoveryCasesNotice.unknownCode,
      ErrorCode.validationFailed => RecoveryCasesNotice.invalid,
      ErrorCode.forbidden when f.values.contains('unsupported') =>
        RecoveryCasesNotice.selfAction,
      ErrorCode.forbidden => RecoveryCasesNotice.noLongerAdmin,
      ErrorCode.unauthenticated => RecoveryCasesNotice.signInAgain,
      ErrorCode.notFound => RecoveryCasesNotice.notFound,
      ErrorCode.unavailable => RecoveryCasesNotice.notAccepting,
      _ => RecoveryCasesNotice.refused,
    };
  }

  static RecoveryCasesNotice _success(String command) => switch (command) {
    RecoveryCaseCommands.open => RecoveryCasesNotice.opened,
    RecoveryCaseCommands.issue => RecoveryCasesNotice.issued,
    RecoveryCaseCommands.cancel => RecoveryCasesNotice.cancelled,
    _ => RecoveryCasesNotice.reconciled,
  };

  Future<void> _dispatch(CommandRequest request, String subject) async {
    final epoch = _epoch;
    state = RecoveryCasesState(
      result: state.result,
      pending: request,
      subject: subject,
      search: state.search,
    );
    final outcome = await ref
        .read(commandGatewayProvider)
        .send(RecoveryCaseCommands.function, request);
    if (!_current(epoch)) return;
    RecoveryCasesNotice notice;
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
            notice != RecoveryCasesNotice.invalid &&
            notice != RecoveryCasesNotice.selfAction;
      case CommandUnknownOutcome():
        notice = RecoveryCasesNotice.unconfirmed;
        unconfirmed = request;
        reload = false;
      case CommandNotSent():
        notice = RecoveryCasesNotice.notSent;
        reload = false;
    }
    state = RecoveryCasesState(
      result: state.result,
      unconfirmed: unconfirmed,
      notice: notice,
      subject: subject,
      search: notice == RecoveryCasesNotice.opened ? null : state.search,
    );
    if (reload) await _reload(epoch);
  }
}

final recoveryCasesProvider =
    NotifierProvider<RecoveryCasesController, RecoveryCasesState>(
      RecoveryCasesController.new,
    );

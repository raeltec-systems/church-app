import 'dart:convert';

import 'package:church_contracts/church_contracts.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/access_grants.dart';
import '../domain/account_auth.dart';
import '../domain/commands.dart';
import '../domain/member_deletion.dart';
import '../domain/membership_review.dart' show IdentityCheck, MemberRecord;
import 'access_controllers.dart';
import 'providers.dart';

// ---------------------------------------------------------------------------
// Mobile: the member deletes their own account
// ---------------------------------------------------------------------------

/// What the member is told on the deletion screen.
enum MyDeletionNotice {
  wrongPassword,
  rateLimited,
  unreachable,

  /// The server wants a fresh password confirmation.
  reauthenticate,

  /// The church's last usable Admin cannot delete their account.
  lastAdmin,
  alreadyRequested,

  /// This account has no member access (deactivated, in review, applicant).
  notMember,
  signInAgain,
  notAccepting,
  invalid,
  refused,
  unconfirmed,
  notSent,
}

class MyDeletionState {
  const MyDeletionState({
    this.busy = false,
    this.requested = false,
    this.notice,
    this.unconfirmed,
  });

  final bool busy;

  /// The server recorded the deletion: access ended and the account is
  /// signed out on this device.
  final bool requested;
  final MyDeletionNotice? notice;
  final CommandRequest? unconfirmed;
}

/// Story 2.11: the in-app deletion request. Holds no member data; it lives
/// only while the screen is open.
class MyDeletionController extends Notifier<MyDeletionState> {
  @override
  MyDeletionState build() => const MyDeletionState();

  void dismissNotice() => state = MyDeletionState(
    requested: state.requested,
    unconfirmed: state.unconfirmed,
  );

  /// Confirms the password (a fresh sign-in on the same account), then asks
  /// the server to delete the account.
  Future<void> request(String password) async {
    if (state.busy || state.requested) return;
    state = MyDeletionState(busy: true, unconfirmed: state.unconfirmed);
    final auth = await ref
        .read(recoveryEmailRepositoryProvider)
        .confirmPassword(password);
    if (!ref.mounted) return;
    if (auth is AuthFailed) {
      state = MyDeletionState(
        unconfirmed: state.unconfirmed,
        notice: switch (auth.failure) {
          AuthFailure.invalidCredentials => MyDeletionNotice.wrongPassword,
          AuthFailure.rateLimited => MyDeletionNotice.rateLimited,
          AuthFailure.unreachable => MyDeletionNotice.unreachable,
          _ => MyDeletionNotice.notAccepting,
        },
      );
      return;
    }
    final u = state.unconfirmed;
    await _send(
      CommandRequest(
        command: DeletionCommands.requestMine,
        requestId: u?.requestId ?? ref.read(requestIdsProvider).next(),
        expectedRevision: const Optional.of(null),
        payload: const {'confirm': DeletionCommands.confirmation},
      ),
    );
  }

  /// Resends an unconfirmed request unchanged (same request id and body).
  Future<void> checkAgain() async {
    final u = state.unconfirmed;
    if (u == null || state.busy) return;
    state = MyDeletionState(busy: true, unconfirmed: u);
    await _send(u);
  }

  static MyDeletionNotice refusal(CommandError error) {
    final f = error.fieldErrors;
    return switch (error.code) {
      ErrorCode.forbidden when f['session'] == 'reauthenticate' =>
        MyDeletionNotice.reauthenticate,
      ErrorCode.forbidden when f['member_id'] == 'last_admin' =>
        MyDeletionNotice.lastAdmin,
      ErrorCode.forbidden => MyDeletionNotice.notMember,
      ErrorCode.conflict when f['member_id'] == 'deletion_requested' =>
        MyDeletionNotice.alreadyRequested,
      ErrorCode.validationFailed => MyDeletionNotice.invalid,
      ErrorCode.unauthenticated => MyDeletionNotice.signInAgain,
      ErrorCode.unavailable => MyDeletionNotice.notAccepting,
      _ => MyDeletionNotice.refused,
    };
  }

  Future<void> _send(CommandRequest request) async {
    final outcome = await ref
        .read(commandGatewayProvider)
        .send(DeletionCommands.function, request);
    if (!ref.mounted) return;
    switch (outcome) {
      case CommandConfirmed():
        state = const MyDeletionState(requested: true);
        // The server already revoked every session; end this one here too.
        try {
          await ref.read(accountAuthGatewayProvider).signOut();
        } catch (_) {
          // The session is gone on the server either way.
        }
      case CommandRefused(:final error):
        state = MyDeletionState(notice: refusal(error));
      case CommandUnknownOutcome():
        state = MyDeletionState(
          notice: MyDeletionNotice.unconfirmed,
          unconfirmed: request,
        );
      case CommandNotSent():
        state = const MyDeletionState(notice: MyDeletionNotice.notSent);
    }
  }
}

final myDeletionProvider =
    NotifierProvider.autoDispose<MyDeletionController, MyDeletionState>(
      MyDeletionController.new,
    );

// ---------------------------------------------------------------------------
// Staff web (Admin): deletions and the staff route
// ---------------------------------------------------------------------------

enum DeletionAdminNotice {
  requested,
  lastAdmin,
  alreadyRequested,

  /// The member can still use the app: they ask there (or hold the login
  /// first if they cannot).
  canUseApp,
  selfAction,
  changedElsewhere,
  noLongerAdmin,
  signInAgain,
  notAccepting,
  invalid,
  notFound,
  refused,
  unconfirmed,
  notSent,
}

class MemberDeletionAdminState {
  const MemberDeletionAdminState({
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
  final AccessRead<MemberDeletionOverview>? result;
  final CommandRequest? pending;
  final CommandRequest? unconfirmed;
  final DeletionAdminNotice? notice;
  final String? subject;
  final bool searching;
  final AccessRead<List<MemberRecord>>? search;

  bool get busy => pending != null;

  MemberDeletionOverview? get overview => switch (result) {
    AccessReadOk(:final value) => value,
    _ => null,
  };

  MemberDeletionAdminState copyWith({
    bool? loading,
    AccessRead<MemberDeletionOverview>? result,
    CommandRequest? pending,
    bool clearPending = false,
    CommandRequest? unconfirmed,
    bool clearUnconfirmed = false,
    DeletionAdminNotice? notice,
    bool clearNotice = false,
    String? subject,
    bool? searching,
    AccessRead<List<MemberRecord>>? search,
    bool clearSearch = false,
  }) => MemberDeletionAdminState(
    loading: loading ?? this.loading,
    result: result ?? this.result,
    pending: clearPending ? null : (pending ?? this.pending),
    unconfirmed: clearUnconfirmed ? null : (unconfirmed ?? this.unconfirmed),
    notice: clearNotice ? null : (notice ?? this.notice),
    subject: subject ?? this.subject,
    searching: searching ?? this.searching,
    search: clearSearch ? null : (search ?? this.search),
  );
}

class MemberDeletionAdminController extends Notifier<MemberDeletionAdminState> {
  int _epoch = 0;

  @override
  MemberDeletionAdminState build() {
    ref.watch(accountGenerationProvider);
    _epoch++;
    final epoch = _epoch;
    Future.microtask(() => _reload(epoch));
    return const MemberDeletionAdminState(loading: true);
  }

  bool _current(int epoch) => ref.mounted && epoch == _epoch;

  Future<void> reload() => _reload(_epoch);

  Future<void> _reload(int epoch) async {
    if (!_current(epoch)) return;
    state = state.copyWith(loading: true);
    final r = await ref.read(memberDeletionRepositoryProvider).fetchOverview();
    if (!_current(epoch)) return;
    // A denial or failure drops everything protected from the screen.
    final ok = r is AccessReadOk<MemberDeletionOverview>;
    state = state.copyWith(loading: false, result: r, clearSearch: !ok);
    if (r is AccessReadDenied<MemberDeletionOverview>) noteProtectedDenial(ref);
  }

  void dismissNotice() => state = state.copyWith(clearNotice: true);

  /// Finds approved members (the 2.5 member search).
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

  /// identity.request_member_deletion for a member who cannot use the app.
  Future<void> requestDeletion({
    required String memberId,
    required int revision,
    required String displayName,
    required IdentityCheck check,
  }) async {
    if (state.busy) return;
    final payload = {'member_id': memberId, 'identity_check': check.wire};
    final u = state.unconfirmed;
    final same =
        u != null &&
        u.expectedRevision.value == revision &&
        jsonEncode(u.payload) == jsonEncode(payload);
    await _dispatch(
      CommandRequest(
        command: DeletionCommands.requestMember,
        requestId: same ? u.requestId : ref.read(requestIdsProvider).next(),
        expectedRevision: Optional.of(revision),
        payload: payload,
      ),
      displayName,
    );
  }

  Future<void> checkAgain() async {
    final u = state.unconfirmed;
    if (u == null || state.busy) return;
    await _dispatch(u, state.subject ?? '');
  }

  static DeletionAdminNotice refusal(CommandError error) {
    final f = error.fieldErrors;
    return switch (error.code) {
      ErrorCode.forbidden when f['member_id'] == 'last_admin' =>
        DeletionAdminNotice.lastAdmin,
      ErrorCode.forbidden when f.values.contains('unsupported') =>
        DeletionAdminNotice.selfAction,
      ErrorCode.forbidden => DeletionAdminNotice.noLongerAdmin,
      ErrorCode.conflict when f['member_id'] == 'deletion_requested' =>
        DeletionAdminNotice.alreadyRequested,
      ErrorCode.conflict when f['member_id'] == 'member_can_use_app' =>
        DeletionAdminNotice.canUseApp,
      ErrorCode.conflict => DeletionAdminNotice.changedElsewhere,
      ErrorCode.validationFailed => DeletionAdminNotice.invalid,
      ErrorCode.unauthenticated => DeletionAdminNotice.signInAgain,
      ErrorCode.notFound => DeletionAdminNotice.notFound,
      ErrorCode.unavailable => DeletionAdminNotice.notAccepting,
      _ => DeletionAdminNotice.refused,
    };
  }

  Future<void> _dispatch(CommandRequest request, String subject) async {
    final epoch = _epoch;
    state = state.copyWith(
      pending: request,
      subject: subject,
      clearNotice: true,
      clearUnconfirmed: true,
    );
    final outcome = await ref
        .read(commandGatewayProvider)
        .send(DeletionCommands.function, request);
    if (!_current(epoch)) return;
    DeletionAdminNotice notice;
    CommandRequest? unconfirmed;
    var reload = true;
    switch (outcome) {
      case CommandConfirmed():
        notice = DeletionAdminNotice.requested;
      case CommandRefused(:final error):
        notice = refusal(error);
        if (error.code == ErrorCode.forbidden ||
            error.code == ErrorCode.unauthenticated) {
          noteProtectedDenial(ref);
        }
        reload =
            notice != DeletionAdminNotice.invalid &&
            notice != DeletionAdminNotice.selfAction;
      case CommandUnknownOutcome():
        notice = DeletionAdminNotice.unconfirmed;
        unconfirmed = request;
        reload = false;
      case CommandNotSent():
        notice = DeletionAdminNotice.notSent;
        reload = false;
    }
    state = state.copyWith(
      clearPending: true,
      notice: notice,
      unconfirmed: unconfirmed,
      clearUnconfirmed: unconfirmed == null,
      // The member's revision changed: search again before acting.
      clearSearch: notice == DeletionAdminNotice.requested,
    );
    if (reload) await _reload(epoch);
  }
}

final memberDeletionAdminProvider =
    NotifierProvider<MemberDeletionAdminController, MemberDeletionAdminState>(
      MemberDeletionAdminController.new,
    );

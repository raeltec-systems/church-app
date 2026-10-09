import 'dart:convert';

import 'package:church_contracts/church_contracts.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/access_grants.dart';
import '../domain/commands.dart';
import '../domain/membership_review.dart';
import 'access_controllers.dart' show noteProtectedDenial;
import 'providers.dart';

/// What the review screen tells the Admin after an action.
enum ReviewNotice {
  approved,
  linked,
  detailsRequested,
  rejected,
  memberCreated,
  unlinked,
  reclaimed,

  /// The application or member changed elsewhere (stale tab): reloaded.
  changedElsewhere,

  /// The member, account or phone username already has a live link.
  alreadyLinked,

  /// The applicant's sign-in number changed after they applied.
  phoneChanged,

  /// The applicant's account carries an unverified email.
  emailUnverified,

  /// The member is on hold and cannot be linked now.
  memberHeld,

  /// Separation of duty: not for the Admin's own record or account.
  selfAction,

  /// Unlinking would remove the church's last usable Admin.
  lastAdmin,

  /// No account holds that phone username, or the item is gone.
  notFound,
  invalid,
  noLongerAdmin,
  signInAgain,

  /// Personal-data gate closed here.
  notAccepting,
  refused,

  /// The outcome is unknown: check again with the same request.
  unconfirmed,
  notSent,
}

/// One review command in flight or just answered.
class ReviewAction {
  const ReviewAction({required this.request, required this.subject});

  final CommandRequest request;

  /// The person acted on (display only).
  final String subject;

  String get command => request.command;
}

class ReviewState {
  const ReviewState({
    this.loading = false,
    this.queueResult,
    this.applications = const [],
    this.queueNext,
    this.searching = false,
    this.searchResult,
    this.members = const [],
    this.query,
    this.membersNext,
    this.pending,
    this.unconfirmed,
    this.notice,
    this.noticeAction,
    this.fieldErrors = const {},
  });

  final bool loading;

  /// The last queue answer (denials and failures included).
  final AccessRead<ReviewQueue>? queueResult;
  final List<ReviewApplication> applications;
  final QueueCursor? queueNext;

  final bool searching;
  final AccessRead<MemberSearchPage>? searchResult;
  final List<MemberRecord> members;
  final String? query;
  final MemberCursor? membersNext;

  final ReviewAction? pending;
  final ReviewAction? unconfirmed;
  final ReviewNotice? notice;
  final ReviewAction? noticeAction;

  /// Field errors of the last refused command (wire names).
  final Map<String, String> fieldErrors;

  bool get busy => pending != null;

  ReviewState copyWith({
    bool? loading,
    AccessRead<ReviewQueue>? queueResult,
    List<ReviewApplication>? applications,
    QueueCursor? queueNext,
    bool clearQueueNext = false,
    bool? searching,
    AccessRead<MemberSearchPage>? searchResult,
    List<MemberRecord>? members,
    String? query,
    MemberCursor? membersNext,
    bool clearMembersNext = false,
    ReviewAction? pending,
    bool clearPending = false,
    ReviewAction? unconfirmed,
    bool clearUnconfirmed = false,
    ReviewNotice? notice,
    ReviewAction? noticeAction,
    bool clearNotice = false,
    Map<String, String>? fieldErrors,
  }) => ReviewState(
    loading: loading ?? this.loading,
    queueResult: queueResult ?? this.queueResult,
    applications: applications ?? this.applications,
    queueNext: clearQueueNext ? null : (queueNext ?? this.queueNext),
    searching: searching ?? this.searching,
    searchResult: searchResult ?? this.searchResult,
    members: members ?? this.members,
    query: query ?? this.query,
    membersNext: clearMembersNext ? null : (membersNext ?? this.membersNext),
    pending: clearPending ? null : (pending ?? this.pending),
    unconfirmed: clearUnconfirmed ? null : (unconfirmed ?? this.unconfirmed),
    notice: clearNotice ? null : (notice ?? this.notice),
    noticeAction: clearNotice ? null : (noticeAction ?? this.noticeAction),
    fieldErrors: fieldErrors ?? this.fieldErrors,
  );
}

/// Story 2.5, staff web: the Admin's application queue, member records and
/// the review commands (1.4 envelope) with honest request states. Protected
/// state (AD-13): memory only, scoped to the account generation. The server
/// rechecks the live Admin grant on every read and command; nothing here
/// links or decides by itself.
class MembershipReviewController extends Notifier<ReviewState> {
  int _epoch = 0;

  @override
  ReviewState build() {
    ref.watch(accountGenerationProvider);
    _epoch++;
    final epoch = _epoch;
    Future.microtask(() => _reload(epoch));
    return const ReviewState(loading: true);
  }

  bool _current(int epoch) => ref.mounted && epoch == _epoch;

  /// Reloads the queue's first page and repeats the last member search.
  Future<void> reload() => _reload(_epoch);

  Future<void> _reload(int epoch) async {
    if (!_current(epoch)) return;
    state = state.copyWith(loading: true);
    final r = await ref.read(reviewRepositoryProvider).fetchQueue();
    if (!_current(epoch)) return;
    state = switch (r) {
      AccessReadOk(:final value) => state.copyWith(
        loading: false,
        queueResult: r,
        applications: value.applications,
        queueNext: value.next,
        clearQueueNext: value.next == null,
      ),
      // A denial or failure drops everything protected from the screen.
      _ => ReviewState(
        queueResult: r,
        notice: state.notice,
        noticeAction: state.noticeAction,
        unconfirmed: state.unconfirmed,
        fieldErrors: state.fieldErrors,
      ),
    };
    if (r is AccessReadDenied<ReviewQueue>) {
      noteProtectedDenial(ref);
      return;
    }
    if (r is AccessReadOk<ReviewQueue> && state.searchResult != null) {
      await _search(epoch, state.query);
    }
  }

  Future<void> loadMoreApplications() async {
    final after = state.queueNext;
    if (after == null || state.loading) return;
    final epoch = _epoch;
    state = state.copyWith(loading: true);
    final r = await ref.read(reviewRepositoryProvider).fetchQueue(after: after);
    if (!_current(epoch)) return;
    if (r is AccessReadOk<ReviewQueue>) {
      state = state.copyWith(
        loading: false,
        applications: [...state.applications, ...r.value.applications],
        queueNext: r.value.next,
        clearQueueNext: r.value.next == null,
      );
    } else {
      await _reload(epoch);
    }
  }

  /// Searches approved members by name or contact number (empty = all).
  Future<void> search(String? query) => _search(_epoch, query);

  Future<void> _search(int epoch, String? query) async {
    if (!_current(epoch)) return;
    state = state.copyWith(searching: true, query: query ?? '');
    final r = await ref.read(reviewRepositoryProvider).searchMembers(query);
    if (!_current(epoch)) return;
    state = switch (r) {
      AccessReadOk(:final value) => state.copyWith(
        searching: false,
        searchResult: r,
        members: value.members,
        membersNext: value.next,
        clearMembersNext: value.next == null,
      ),
      _ => state.copyWith(
        searching: false,
        searchResult: r,
        members: const [],
        clearMembersNext: true,
      ),
    };
    if (r is AccessReadDenied<MemberSearchPage>) noteProtectedDenial(ref);
  }

  Future<void> loadMoreMembers() async {
    final after = state.membersNext;
    if (after == null || state.searching) return;
    final epoch = _epoch;
    state = state.copyWith(searching: true);
    final r = await ref
        .read(reviewRepositoryProvider)
        .searchMembers(state.query, after: after);
    if (!_current(epoch)) return;
    if (r is AccessReadOk<MemberSearchPage>) {
      state = state.copyWith(
        searching: false,
        members: [...state.members, ...r.value.members],
        membersNext: r.value.next,
        clearMembersNext: r.value.next == null,
      );
    } else {
      await _search(epoch, state.query);
    }
  }

  void dismissNotice() =>
      state = state.copyWith(clearNotice: true, fieldErrors: const {});

  Future<void> approve(ReviewApplication a, IdentityCheck check) => _send(
    ReviewCommands.approve,
    Optional.of(a.application.revision),
    {'application_id': a.id, 'identity_check': check.wire},
    a.application.fullName,
  );

  Future<void> link(
    ReviewApplication a,
    String memberId,
    IdentityCheck check,
  ) => _send(ReviewCommands.link, Optional.of(a.application.revision), {
    'application_id': a.id,
    'member_id': memberId,
    'identity_check': check.wire,
  }, a.application.fullName);

  Future<void> askDetails(
    ReviewApplication a,
    Set<DetailRequest> requested, {
    IdentityCheck? check,
  }) {
    if (requested.isEmpty) return Future.value();
    final codes = [for (final r in requested) r.wire]..sort();
    return _send(
      ReviewCommands.askDetails,
      Optional.of(a.application.revision),
      {
        'application_id': a.id,
        'requested': codes,
        if (check != null) 'identity_check': check.wire,
      },
      a.application.fullName,
    );
  }

  Future<void> reject(
    ReviewApplication a, {
    RejectReason? reason,
    IdentityCheck? check,
  }) => _send(ReviewCommands.reject, Optional.of(a.application.revision), {
    'application_id': a.id,
    if (reason != null) 'reason': reason.wire,
    if (check != null) 'identity_check': check.wire,
  }, a.application.fullName);

  /// Records an approved member WITHOUT a login, with their consent.
  Future<void> createMember({
    required String fullName,
    required ConsentBasis consent,
    String? contactPhone,
    ContactOwner? contactOwner,
    String? holderLabel,
  }) => _send(ReviewCommands.createMember, const Optional.of(null), {
    'full_name': fullName,
    'consent_basis': consent.wire,
    if (contactPhone != null)
      'contact_route': {
        'phone': contactPhone,
        'belongs_to': (contactOwner ?? ContactOwner.member).wire,
        if (holderLabel != null && holderLabel.trim().isNotEmpty)
          'holder_label': holderLabel.trim(),
      },
  }, fullName);

  Future<void> unlink(MemberRecord m, UnlinkReason reason) => _send(
    ReviewCommands.unlink,
    Optional.of(m.revision),
    {'member_id': m.memberId, 'reason': reason.wire},
    m.displayName,
  );

  /// Releases a phone username held by an unlinked account (after an
  /// identity check of the person it belongs to).
  Future<void> reclaim(
    String phoneE164,
    IdentityCheck check, {
    ReclaimReason? reason,
  }) => _send(ReviewCommands.reclaim, const Optional.of(null), {
    'phone_username': phoneE164,
    'identity_check': check.wire,
    if (reason != null) 'reason': reason.wire,
  }, phoneE164);

  /// Resends the unconfirmed command unchanged (same request_id and body).
  Future<void> checkAgain() async {
    final u = state.unconfirmed;
    if (u == null || state.busy) return;
    await _dispatch(u);
  }

  Future<void> _send(
    String command,
    Optional<int> expected,
    Map<String, Object?> payload,
    String subject,
  ) async {
    if (state.busy) return;
    final u = state.unconfirmed?.request;
    // An input whose outcome was never learned is resent under its original
    // request id; anything else is a new request.
    final same =
        u != null &&
        u.command == command &&
        u.expectedRevision.value == expected.value &&
        jsonEncode(u.payload) == jsonEncode(payload);
    await _dispatch(
      ReviewAction(
        request: CommandRequest(
          command: command,
          requestId: same ? u.requestId : ref.read(requestIdsProvider).next(),
          expectedRevision: expected,
          payload: payload,
        ),
        subject: subject,
      ),
    );
  }

  static ReviewNotice _success(String command) => switch (command) {
    ReviewCommands.approve => ReviewNotice.approved,
    ReviewCommands.link => ReviewNotice.linked,
    ReviewCommands.askDetails => ReviewNotice.detailsRequested,
    ReviewCommands.reject => ReviewNotice.rejected,
    ReviewCommands.createMember => ReviewNotice.memberCreated,
    ReviewCommands.unlink => ReviewNotice.unlinked,
    _ => ReviewNotice.reclaimed,
  };

  static ReviewNotice _refusal(CommandError error) {
    final f = error.fieldErrors;
    return switch (error.code) {
      ErrorCode.conflict when f.values.contains('linked') =>
        ReviewNotice.alreadyLinked,
      ErrorCode.conflict => ReviewNotice.changedElsewhere,
      ErrorCode.validationFailed when f['phone_username'] == 'changed' =>
        ReviewNotice.phoneChanged,
      ErrorCode.validationFailed when f['recovery_email'] == 'unverified' =>
        ReviewNotice.emailUnverified,
      ErrorCode.validationFailed when f['member_id'] == 'held' =>
        ReviewNotice.memberHeld,
      ErrorCode.validationFailed => ReviewNotice.invalid,
      ErrorCode.forbidden when f['member_id'] == 'last_admin' =>
        ReviewNotice.lastAdmin,
      ErrorCode.forbidden when f.values.contains('unsupported') =>
        ReviewNotice.selfAction,
      ErrorCode.forbidden => ReviewNotice.noLongerAdmin,
      ErrorCode.unauthenticated => ReviewNotice.signInAgain,
      ErrorCode.notFound => ReviewNotice.notFound,
      ErrorCode.unavailable => ReviewNotice.notAccepting,
      _ => ReviewNotice.refused,
    };
  }

  Future<void> _dispatch(ReviewAction action) async {
    final epoch = _epoch;
    state = state.copyWith(
      pending: action,
      clearNotice: true,
      fieldErrors: const {},
    );
    final outcome = await ref
        .read(commandGatewayProvider)
        .send(ReviewCommands.function, action.request);
    if (!_current(epoch)) return;
    switch (outcome) {
      case CommandConfirmed():
        state = state.copyWith(
          clearPending: true,
          clearUnconfirmed: true,
          notice: _success(action.command),
          noticeAction: action,
        );
        // The queue and the member list reflect the server's new state.
        await _reload(epoch);
        if (_current(epoch) && state.searchResult == null) {
          await _search(epoch, state.query);
        }
      case CommandRefused(:final error):
        final notice = _refusal(error);
        state = state.copyWith(
          clearPending: true,
          clearUnconfirmed: true,
          notice: notice,
          noticeAction: action,
          fieldErrors: error.fieldErrors,
        );
        // A business refusal (last Admin) says nothing about the caller's
        // own access, so it does not re-read it.
        if ((error.code == ErrorCode.forbidden ||
                error.code == ErrorCode.unauthenticated) &&
            notice != ReviewNotice.lastAdmin) {
          noteProtectedDenial(ref);
        }
        if (notice != ReviewNotice.invalid &&
            notice != ReviewNotice.selfAction &&
            notice != ReviewNotice.lastAdmin) {
          await _reload(epoch);
        }
      case CommandUnknownOutcome():
        state = state.copyWith(
          clearPending: true,
          unconfirmed: action,
          notice: ReviewNotice.unconfirmed,
          noticeAction: action,
        );
      case CommandNotSent():
        state = state.copyWith(
          clearPending: true,
          notice: ReviewNotice.notSent,
          noticeAction: action,
        );
    }
  }
}

final membershipReviewProvider =
    NotifierProvider<MembershipReviewController, ReviewState>(
      MembershipReviewController.new,
    );

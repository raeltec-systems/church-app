/// Test doubles for the client ports, shared by the package and app tests.
/// Not for production composition roots.
library;

import 'dart:async';

import 'package:church_contracts/church_contracts.dart';
import 'package:flutter_riverpod/misc.dart' show Override;

import 'src/application/providers.dart';
import 'src/domain/platform_status.dart';

import 'src/domain/access_grants.dart';
import 'src/domain/account_auth.dart';
import 'src/domain/assisted_recovery.dart';
import 'src/domain/cell_membership.dart';
import 'src/domain/commands.dart';
import 'src/domain/credential_review.dart';
import 'src/domain/member_access.dart';
import 'src/domain/membership_application.dart';
import 'src/domain/member_deletion.dart';
import 'src/domain/membership_lifecycle.dart';
import 'src/domain/membership_review.dart';
import 'src/domain/password_recovery.dart';
import 'src/domain/recovery_email.dart';
import 'src/domain/fixture_counter.dart';
import 'src/domain/inbox.dart';
import 'src/domain/session.dart';

/// One command the fake gateway received; complete it to answer.
class SentCommand {
  SentCommand(this.function, this.request);
  final String function;
  final CommandRequest request;
  final Completer<CommandOutcome> _answer = Completer<CommandOutcome>();
  Future<CommandOutcome> get _future => _answer.future;

  /// The exact wire body that was sent.
  Map<String, Object?> get wire => request.toJson();

  void confirm(Object? data, int revision) => _answer.complete(
    CommandConfirmed(
      CommandSuccess(
        requestId: request.requestId,
        data: data,
        revision: revision,
      ),
    ),
  );

  void refuse(
    ErrorCode code, {
    Map<String, String> fieldErrors = const {},
    Optional<int> currentRevision = const Optional.absent(),
  }) => _answer.complete(
    CommandRefused(
      CommandError(
        requestId: request.requestId,
        code: code,
        message: code.wireName,
        fieldErrors: fieldErrors,
        currentRevision: currentRevision,
      ),
    ),
  );

  void unknown() => _answer.complete(const CommandUnknownOutcome('test'));
}

/// [CommandGateway] whose every call waits for the test to answer it.
class FakeCommandGateway implements CommandGateway {
  final List<SentCommand> sent = [];

  @override
  Future<CommandOutcome> send(String function, CommandRequest request) {
    final c = SentCommand(function, request);
    sent.add(c);
    return c._future;
  }
}

/// [SessionRepository] the test switches between accounts.
class FakeSession implements SessionRepository {
  FakeSession([this._current]);
  String? _current;
  final _changes = StreamController<String?>.broadcast();

  void switchTo(String? accountId) {
    _current = accountId;
    _changes.add(accountId);
  }

  @override
  String? get currentAccountId => _current;

  @override
  Stream<String?> get accountChanges => _changes.stream;
}

/// [FixtureCounterReader] answered by the test; null = unavailable.
class FakeFixtureReader implements FixtureCounterReader {
  FixtureCounter? next;
  int calls = 0;

  @override
  Future<FixtureCounter> read(String counterId) async {
    calls++;
    final n = next;
    if (n == null) throw const FixtureReadUnavailable('test: no read endpoint');
    return n;
  }
}

/// Deterministic request ids: `00000000-0000-4000-8000-00000000000N`.
class SequentialRequestIds implements RequestIds {
  int _n = 0;
  @override
  String next() {
    _n++;
    return '00000000-0000-4000-8000-${_n.toString().padLeft(12, '0')}';
  }
}

/// `data` of a synthetic fixture counter success envelope.
Map<String, Object?> fixtureCounterData({
  String id = '11111111-1111-4111-8111-111111111111',
  String intentKey = 'synthetic-demo',
  int value = 0,
}) => {
  'id': id,
  'intent_key': intentKey,
  'value': value,
  'is_synthetic': true,
  'updated_at': '2026-10-03T12:00:00Z',
};

/// A configured platform status that answers immediately.
class FakePlatformStatus implements PlatformStatusRepository {
  @override
  Future<PlatformStatus?> fetch() async => PlatformStatus(
    status: 'operational',
    message: 'SYNTHETIC tracer status',
    isSynthetic: true,
    updatedAt: DateTime.utc(2026, 10, 3, 9, 5),
  );
}

/// One sign-up or sign-in the fake gateway received; complete it to answer.
class SentAuth {
  SentAuth(this.createAccount, this.phoneE164);
  final bool createAccount;
  final String phoneE164;
  final Completer<AuthOutcome> _answer = Completer<AuthOutcome>();
}

/// [AccountAuthGateway] whose calls wait for the test. A success switches
/// [session] to the given account, as Supabase Auth would.
class FakeAccountAuth implements AccountAuthGateway {
  FakeAccountAuth(this.session);
  final FakeSession session;
  final List<SentAuth> sent = [];
  int signOuts = 0;

  SentAuth get last => sent.last;

  void succeed(String accountId) {
    last._answer.complete(AuthSucceeded(accountId));
    session.switchTo(accountId);
  }

  void fail(AuthFailure failure, {List<String> reasons = const []}) =>
      last._answer.complete(AuthFailed(failure, serverReasons: reasons));

  Future<AuthOutcome> _record(bool create, String phone) {
    final a = SentAuth(create, phone);
    sent.add(a);
    return a._answer.future;
  }

  @override
  Future<AuthOutcome> signUp({
    required String phoneE164,
    required String password,
  }) => _record(true, phoneE164);

  @override
  Future<AuthOutcome> signIn({
    required String phoneE164,
    required String password,
  }) => _record(false, phoneE164);

  @override
  Future<void> signOut() async {
    signOuts++;
    session.switchTo(null);
  }
}

/// [MemberAccessRepository] answered by the test; each call waits for
/// [answer] unless [next] is set.
class FakeMemberAccess implements MemberAccessRepository {
  MemberAccessResult? next;
  final List<Completer<MemberAccessResult>> pending = [];
  int calls = 0;

  void answer(MemberAccessResult result) =>
      pending.removeAt(0).complete(result);

  @override
  Future<MemberAccessResult> fetchMySummary() {
    calls++;
    final n = next;
    if (n != null) return Future.value(n);
    final c = Completer<MemberAccessResult>();
    pending.add(c);
    return c.future;
  }
}

/// A synthetic member summary.
MemberSummary syntheticMemberSummary({
  String name = 'SYNTHETIC Member One',
  String phone = '+12025550101',
}) => MemberSummary(
  memberId: '22222222-2222-4222-8222-222222222222',
  displayName: name,
  membershipState: 'approved',
  phoneUsername: phone,
  hasRecoveryEmail: false,
  isSynthetic: true,
);

/// [GrantsRepository] answered by the test. [myAccess] answers every
/// my-access read at once (default: not linked, so no grant-driven
/// destinations); roster reads wait for [answerRoster] unless [roster] is set.
class FakeGrants implements GrantsRepository {
  AccessRead<MemberGrants> myAccess = const AccessReadDenied(
    AccessDenial.notLinked,
  );
  AccessRead<GrantRoster>? roster;
  final List<Completer<AccessRead<GrantRoster>>> pendingRoster = [];
  final List<RosterCursor?> rosterCalls = [];
  int myAccessCalls = 0;

  void answerRoster(AccessRead<GrantRoster> r) =>
      pendingRoster.removeAt(0).complete(r);

  /// When set, every my-access read waits for it before answering.
  Completer<void>? myAccessGate;

  @override
  Future<AccessRead<MemberGrants>> fetchMyAccess() async {
    myAccessCalls++;
    final gate = myAccessGate;
    if (gate != null) await gate.future;
    return myAccess;
  }

  @override
  Future<AccessRead<GrantRoster>> fetchRoster({RosterCursor? after}) {
    rosterCalls.add(after);
    final r = roster;
    if (r != null) return Future.value(r);
    final c = Completer<AccessRead<GrantRoster>>();
    pendingRoster.add(c);
    return c.future;
  }
}

/// Synthetic grants of one member.
MemberGrants syntheticGrants({
  String memberId = '22222222-2222-4222-8222-222222222222',
  int revision = 1,
  List<String> roles = const [],
  List<ScopeGrant> scopes = const [],
}) => MemberGrants(
  memberId: memberId,
  revision: revision,
  roles: roles,
  scopes: scopes,
);

/// The wire form of [syntheticGrants] (a grant command's success `data`).
Map<String, Object?> grantsData({
  String memberId = '33333333-3333-4333-8333-333333333333',
  int revision = 2,
  List<String> roles = const [],
}) => {
  'member_id': memberId,
  'revision': revision,
  'roles': roles,
  'scopes': const <Object?>[],
};

/// A synthetic roster page with one member (no login state variations).
GrantRoster syntheticRoster({
  String memberId = '33333333-3333-4333-8333-333333333333',
  String name = 'SYNTHETIC Member Two',
  int revision = 1,
  List<String> roles = const [],
  bool leadPastorAvailable = true,
}) => GrantRoster(
  members: [
    RosterMember(
      memberId: memberId,
      displayName: name,
      isSynthetic: true,
      account: AccountStanding.appAccount,
      grants: syntheticGrants(
        memberId: memberId,
        revision: revision,
        roles: roles,
      ),
    ),
  ],
  roles: [
    const RoleOption('admin', available: true),
    const RoleOption('pastor', available: true),
    const RoleOption('media', available: true),
    RoleOption('lead_pastor', available: leadPastorAvailable),
  ],
  next: null,
);

/// [MembershipRepository] answered by the test (story 2.4). [mine] and
/// [options] answer every read at once; [calls] counts my-application reads.
class FakeMembership implements MembershipRepository {
  AccessRead<MyApplication> mine = const AccessReadOk(
    MyApplication(
      application: null,
      privacyNotice: PrivacyNotice(version: 'draft-2026-10-07', draft: true),
      accepting: true,
    ),
  );
  AccessRead<List<CellOption>> options = AccessReadOk(syntheticCellOptions);
  int calls = 0;

  @override
  Future<AccessRead<MyApplication>> fetchMyApplication() async {
    calls++;
    return mine;
  }

  @override
  Future<AccessRead<List<CellOption>>> fetchCellOptions() async => options;
}

/// The SYNTHETIC sign-up options of the local seed.
const syntheticCellOptions = <CellOption>[
  CellOption(
    cellId: '00000000-0000-4000-c000-00000000c241',
    label: 'SYNTHETIC Riverside',
    broadArea: 'SYNTHETIC North side',
    revision: 1,
  ),
  CellOption(
    cellId: '00000000-0000-4000-c000-00000000c242',
    label: 'SYNTHETIC Hilltop',
    broadArea: 'SYNTHETIC East side',
    revision: 1,
  ),
];

/// The wire form of a synthetic application (a command's success `data`).
Map<String, Object?> applicationData({
  String id = '44444444-4444-4444-8444-444444444444',
  int revision = 1,
  String churchStatus = 'awaiting_approval',
  String name = 'SYNTHETIC Applicant',
  Map<String, Object?> cellChoice = const {
    'choice': 'cell',
    'cell_id': '00000000-0000-4000-c000-00000000c241',
    'cell_revision': 1,
  },
}) => {
  'application_id': id,
  'revision': revision,
  'application_state': churchStatus == 'details_requested'
      ? 'needs_details'
      : 'submitted',
  'church_status': churchStatus,
  'full_name': name,
  'phone_username': '+12025550181',
  'cell_choice': cellChoice,
  'cell_status': cellChoice['choice'] == 'cell' ? 'requested' : 'follow_up',
  'privacy_notice_version': 'draft-2026-10-07',
  'is_synthetic': true,
  'submitted_at': '2026-10-07T04:30:00.000000Z',
  'updated_at': '2026-10-07T04:30:00.000000Z',
};

/// A my-application answer holding [applicationData].
AccessRead<MyApplication> myApplicationWith(Map<String, Object?> data) =>
    AccessReadOk(
      MyApplication(
        application: MembershipApplication.fromJson(data),
        privacyNotice: const PrivacyNotice(
          version: 'draft-2026-10-07',
          draft: true,
        ),
        accepting: true,
      ),
    );

/// [ReviewRepository] answered by the test (story 2.5). [queue] and
/// [search] answer every read at once; the call lists record what was asked.
class FakeReview implements ReviewRepository {
  AccessRead<ReviewQueue> queue = const AccessReadDenied(
    AccessDenial.notGranted,
  );
  AccessRead<MemberSearchPage> search = const AccessReadOk(
    MemberSearchPage(members: [], next: null),
  );
  final List<QueueCursor?> queueCalls = [];
  final List<String?> searchCalls = [];

  @override
  Future<AccessRead<ReviewQueue>> fetchQueue({QueueCursor? after}) async {
    queueCalls.add(after);
    return queue;
  }

  @override
  Future<AccessRead<MemberSearchPage>> searchMembers(
    String? query, {
    MemberCursor? after,
  }) async {
    searchCalls.add(query);
    return search;
  }
}

/// The wire form of one Admin queue entry (story 2.5).
Map<String, Object?> reviewApplicationData({
  String id = '55555555-5555-4555-8555-555555555555',
  int revision = 1,
  String name = 'SYNTHETIC Ruth Mwale',
  int priorNotApproved = 0,
  bool ownAccount = false,
  List<Map<String, Object?>> candidates = const [],
}) => {
  ...applicationData(id: id, revision: revision, name: name),
  'cell_choice': const {
    'choice': 'not_sure',
    'cell_id': null,
    'cell_revision': null,
  },
  'cell_status': 'follow_up',
  'prior_not_approved': priorNotApproved,
  'own_account': ownAccount,
  'candidates': candidates,
};

/// A queue page with the given entries.
AccessRead<ReviewQueue> reviewQueueWith(List<Map<String, Object?>> entries) =>
    AccessReadOk(ReviewQueue.fromJson({'applications': entries, 'next': null}));

/// The wire form of an Admin member record (story 2.5).
Map<String, Object?> memberRecordData({
  String id = '66666666-6666-4666-8666-666666666666',
  String name = 'SYNTHETIC Ruth Mwale',
  int revision = 1,
  String account = 'no_login',
  bool linkEligible = true,
  List<Map<String, Object?>> routes = const [],
}) => {
  'member_id': id,
  'display_name': name,
  'membership_state': 'approved',
  'revision': revision,
  'is_synthetic': true,
  'account': account,
  'link_eligible': linkEligible,
  'origin': 'admin_record',
  'contact_routes': routes,
};

/// [CellsRepository] answered by the test (story 2.6). Each field answers
/// every read at once; the counters record how often each was asked.
class FakeCells implements CellsRepository {
  AccessRead<MyCell> mine = const AccessReadDenied(AccessDenial.notLinked);
  AccessRead<LeaderQueue> leader = const AccessReadDenied(
    AccessDenial.notGranted,
  );
  AccessRead<CellAdminOverview> admin = const AccessReadDenied(
    AccessDenial.notGranted,
  );
  int mineCalls = 0;
  int leaderCalls = 0;
  int adminCalls = 0;

  @override
  Future<AccessRead<MyCell>> fetchMyCell() async {
    mineCalls++;
    return mine;
  }

  @override
  Future<AccessRead<LeaderQueue>> fetchLeaderQueue() async {
    leaderCalls++;
    return leader;
  }

  @override
  Future<AccessRead<CellAdminOverview>> fetchAdminOverview() async {
    adminCalls++;
    return admin;
  }
}

/// The wire form of a synthetic cell as the Admin sees it (story 2.6).
Map<String, Object?> adminCellData({
  String id = '77777777-7777-4777-8777-777777777777',
  String name = 'SYNTHETIC Cell X',
  int revision = 1,
  bool listed = true,
  int? signupRevision = 1,
  List<Map<String, Object?>> leaders = const [],
  List<Map<String, Object?>> assistants = const [],
}) => {
  'cell_id': id,
  'name': name,
  'broad_area': 'SYNTHETIC North',
  'signup_label': '$name label',
  'listed': listed,
  'signup_revision': signupRevision,
  'cell_state': 'active',
  'is_synthetic': true,
  'revision': revision,
  'leaders': leaders,
  'assistants': assistants,
  'member_count': 0,
};

/// The wire form of an open request in the Admin overview (story 2.6).
Map<String, Object?> adminCellRequestData({
  String id = '88888888-8888-4888-8888-888888888888',
  String memberId = '66666666-6666-4666-8666-666666666666',
  String choice = 'cell',
  String? requestedCellId = '77777777-7777-4777-8777-777777777777',
  String state = 'pending',
  int memberRevision = 2,
  bool ownRecord = false,
}) => {
  'request_id': id,
  'member_id': memberId,
  'display_name': 'SYNTHETIC Ruth Mwale',
  'kind': 'join',
  'origin': 'application',
  'choice': choice,
  'state': state,
  'requested_cell_id': requestedCellId,
  'requested_cell_name': requestedCellId == null ? null : 'SYNTHETIC Cell X',
  'current_cell_id': null,
  'current_cell_name': null,
  'reason': null,
  'follow_up': requestedCellId == null || state == 'referred',
  'member_revision': memberRevision,
  'own_record': ownRecord,
  'created_at': '2026-10-07T12:00:00.000000Z',
};

/// The wire form of an approved member row in the Admin overview.
Map<String, Object?> cellMemberRowData({
  String id = '99999999-9999-4999-8999-999999999999',
  String name = 'SYNTHETIC Leader Lydia',
  int grantsRevision = 3,
  int cellRevision = 1,
  String? cellId,
}) => {
  'member_id': id,
  'display_name': name,
  'account': 'app_account',
  'grants_revision': grantsRevision,
  'cell_revision': cellRevision,
  'cell_id': cellId,
  'open_request_id': null,
};

/// The wire form of the member's own cell (story 2.6).
Map<String, Object?> myCellData({
  int revision = 1,
  Map<String, Object?>? primary,
  Map<String, Object?>? openRequest,
  Map<String, Object?>? lastDecision,
}) => {
  'member_id': '22222222-2222-4222-8222-222222222222',
  'revision': revision,
  'primary': primary,
  'open_request': openRequest,
  'last_decision': lastDecision,
};

/// [PasswordRecoveryGateway] answered by the test (story 2.7). Records every
/// call; the recovery session it pretends to hold is only "open" between a
/// ready [openLink] and [setNewPassword] or [discard].
class FakePasswordRecovery implements PasswordRecoveryGateway {
  ResetRequestOutcome resetAnswer = ResetRequestOutcome.sent;
  RecoveryLinkOutcome linkAnswer = RecoveryLinkOutcome.ready;
  SetPasswordOutcome setAnswer = const PasswordSet();
  final List<String> resetEmails = [];
  final List<String> openedCodes = [];
  final List<String> passwordsSet = [];
  int discards = 0;
  bool sessionOpen = false;

  @override
  Future<ResetRequestOutcome> requestReset(String email) async {
    resetEmails.add(email);
    return resetAnswer;
  }

  @override
  Future<RecoveryLinkOutcome> openLink(String code) async {
    openedCodes.add(code);
    sessionOpen = linkAnswer == RecoveryLinkOutcome.ready;
    return linkAnswer;
  }

  @override
  Future<SetPasswordOutcome> setNewPassword(String password) async {
    passwordsSet.add(password);
    if (setAnswer is PasswordSet) sessionOpen = false;
    return setAnswer;
  }

  @override
  Future<void> discard() async {
    discards++;
    sessionOpen = false;
  }
}

/// [RecoveryEmailRepository] answered by the test (story 2.7).
class FakeRecoveryEmail implements RecoveryEmailRepository {
  AccessRead<MyRecoveryEmail> mine = AccessReadOk(
    MyRecoveryEmail.fromJson(myRecoveryEmailData()),
  );
  AccessRead<RecoveryEmailQueue> queue = const AccessReadDenied(
    AccessDenial.notGranted,
  );
  AuthOutcome passwordAnswer = const AuthSucceeded(
    'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
  );
  EmailVerificationRequest verificationAnswer = EmailVerificationRequest.sent;
  int mineCalls = 0;
  int queueCalls = 0;
  final List<String> passwordsChecked = [];
  final List<String> verificationsRequested = [];

  @override
  Future<AccessRead<MyRecoveryEmail>> fetchMine() async {
    mineCalls++;
    return mine;
  }

  @override
  Future<AccessRead<RecoveryEmailQueue>> fetchQueue() async {
    queueCalls++;
    return queue;
  }

  @override
  Future<AuthOutcome> confirmPassword(String password) async {
    passwordsChecked.add(password);
    return passwordAnswer;
  }

  @override
  Future<EmailVerificationRequest> requestVerification(String email) async {
    verificationsRequested.add(email);
    return verificationAnswer;
  }
}

/// The wire form of the member's own recovery-email state (story 2.7).
Map<String, Object?> myRecoveryEmailData({
  String access = 'granted',
  String? approvedEmail,
  Map<String, Object?>? proposal,
  bool canPropose = true,
}) => {
  'access': access,
  'approved_email': approvedEmail,
  'proposal': proposal,
  'can_propose': canPropose,
  'recent_sign_in_minutes': 10,
};

/// The wire form of one recovery-email proposal (story 2.7).
Map<String, Object?> recoveryProposalData({
  String id = '77777777-7777-4777-8777-777777777777',
  int revision = 1,
  String email = 'synthetic-member@example.test',
  String state = 'pending',
  bool verified = false,
  String? decisionReason,
}) => {
  'proposal_id': id,
  'revision': revision,
  'email': email,
  'state': state,
  'verified': verified,
  'proposed_at': '2026-10-07T10:00:00Z',
  'decision_reason': ?decisionReason,
};

/// The wire form of one Admin queue item (story 2.7).
Map<String, Object?> recoveryReviewItemData({
  String id = '77777777-7777-4777-8777-777777777777',
  int revision = 1,
  String name = 'SYNTHETIC Ruth Mwale',
  bool verified = true,
  bool otherChanges = false,
  bool ownAccount = false,
}) => {
  ...recoveryProposalData(id: id, revision: revision, verified: verified),
  'member_id': '66666666-6666-4666-8666-666666666666',
  'display_name': name,
  'phone_username': '+447700900281',
  'access_review': verified,
  'other_changes': otherChanges,
  'own_account': ownAccount,
  'is_synthetic': true,
};

/// [CredentialReviewRepository] answered by the test (story 2.8).
class FakeCredentialReview implements CredentialReviewRepository {
  AccessRead<MyCredentials> mine = AccessReadOk(
    MyCredentials.fromJson(myCredentialsData()),
  );
  AccessRead<CredentialQueue> queue = const AccessReadDenied(
    AccessDenial.notGranted,
  );
  int mineCalls = 0;
  int queueCalls = 0;

  @override
  Future<AccessRead<MyCredentials>> fetchMine() async {
    mineCalls++;
    return mine;
  }

  @override
  Future<AccessRead<CredentialQueue>> fetchQueue() async {
    queueCalls++;
    return queue;
  }
}

/// The wire form of the member's own sign-in details (story 2.8).
Map<String, Object?> myCredentialsData({
  String access = 'granted',
  String phone = '+447700900331',
  String? email,
  Map<String, Object?>? pendingChange,
  Map<String, Object?>? lastChange,
  Map<String, Object?>? pendingRecoveryEmail,
  bool canRequest = true,
  String? churchContact,
}) => access == 'review_required'
    // In review the server sends only access, the church contact and the
    // member's own pending request id/revision/kind/state.
    ? {
        'access': access,
        'church_contact': churchContact,
        'pending_change': pendingChange == null
            ? null
            : {
                for (final k in [
                  'change_id',
                  'revision',
                  'change_kind',
                  'state',
                ])
                  k: pendingChange[k],
              },
        'pending_recovery_email': pendingRecoveryEmail == null
            ? null
            : {
                for (final k in ['proposal_id', 'revision', 'state'])
                  k: pendingRecoveryEmail[k],
              },
      }
    : {
        'access': access,
        'phone_username': phone,
        'recovery_email': email,
        'pending_change': pendingChange,
        'last_change': lastChange,
        'pending_recovery_email': pendingRecoveryEmail,
        'can_request': canRequest,
        'church_contact': churchContact,
        'recent_sign_in_minutes': 10,
      };

/// The wire form of one credential change (story 2.8).
Map<String, Object?> credentialChangeData({
  String id = '88888888-8888-4888-8888-888888888888',
  int revision = 1,
  String kind = 'phone_username',
  String state = 'pending',
  String? phone = '+447700900340',
  String? email,
  bool? verified,
  String? decisionReason,
}) => {
  'change_id': id,
  'revision': revision,
  'change_kind': kind,
  'phone_username': ?phone,
  'email': ?email,
  'state': state,
  'verified': ?verified,
  'requested_at': '2026-10-07T10:00:00Z',
  'decision_reason': ?decisionReason,
};

/// The wire form of the Admin credential queue (story 2.8).
Map<String, Object?> credentialQueueData({
  List<Map<String, Object?>> changes = const [],
  List<Map<String, Object?>> reviews = const [],
  List<Map<String, Object?>> holds = const [],
}) => {'changes': changes, 'reviews': reviews, 'holds': holds};

Map<String, Object?> credentialChangeItemData({
  Map<String, Object?>? change,
  String name = 'SYNTHETIC Grace Phiri',
  bool phoneAvailable = true,
  bool otherChanges = false,
  bool ownAccount = false,
}) {
  final c = change ?? credentialChangeData();
  return {
    ...c,
    'member_id': '99999999-9999-4999-8999-999999999999',
    'display_name': name,
    'member_revision': 3,
    'current_phone_username': '+447700900331',
    'has_recovery_email': false,
    'access_review': false,
    if (c['change_kind'] == 'phone_username') 'phone_available': phoneAvailable,
    'other_changes': otherChanges,
    'own_account': ownAccount,
    'is_synthetic': true,
  };
}

Map<String, Object?> accessReviewItemData({
  String memberId = 'abababab-abab-4bab-8bab-abababababab',
  String name = 'SYNTHETIC John Banda',
  bool extraFactors = false,
  List<String> changeKinds = const ['email'],
}) => {
  'member_id': memberId,
  'display_name': name,
  'member_revision': 4,
  'link_state': 'review_required',
  'binding_review': true,
  'phone_username': '+447700900336',
  'recovery_email': null,
  'auth_phone_username': '+447700900336',
  'auth_email': 'synthetic-thief@example.test',
  'auth_email_confirmed': true,
  'extra_factors': extraFactors,
  'change_kinds': changeKinds,
  'own_account': false,
  'is_synthetic': true,
};

Map<String, Object?> holdItemData({
  String holdId = 'cdcdcdcd-cdcd-4dcd-8dcd-cdcdcdcdcdcd',
  String name = 'SYNTHETIC Mary Tembo',
  String reason = 'ownership_dispute',
  bool ownMember = false,
}) => {
  'hold_id': holdId,
  'member_id': 'efefefef-efef-4fef-8fef-efefefefefef',
  'display_name': name,
  'member_revision': 2,
  'hold_kind': reason == 'ownership_dispute' ? 'access_review' : 'security',
  'reason_code': reason,
  'placed_at': '2026-10-07T10:00:00Z',
  'own_member': ownMember,
  'is_synthetic': true,
};

/// [AssistedRecoveryGateway] answered by the test (story 2.9). Records what
/// the device sent so a test can check that only a digest left before the
/// password step.
class FakeAssistedRecovery implements AssistedRecoveryGateway {
  RecoveryRequestOutcome requestAnswer = RecoveryRequestReceived(
    'ABCD2345',
    DateTime.utc(2026, 10, 7, 12, 30),
  );
  RecoveryStatusOutcome statusAnswer = const RecoveryStatus(
    RecoveryGrantState.ready,
    null,
  );
  RedeemOutcome redeemAnswer = RedeemOutcome.succeeded;
  final List<(String, String)> requests = [];
  final List<String> statusDigests = [];
  final List<(String, GrantSecret, String)> redeems = [];

  @override
  Future<RecoveryRequestOutcome> request(String phone, String digest) async {
    requests.add((phone, digest));
    return requestAnswer;
  }

  @override
  Future<RecoveryStatusOutcome> status(String digest) async {
    statusDigests.add(digest);
    return statusAnswer;
  }

  @override
  Future<RedeemOutcome> redeem(
    String phone,
    GrantSecret secret,
    String password,
  ) async {
    redeems.add((phone, secret, password));
    return redeemAnswer;
  }
}

/// [RecoveryCasesRepository] answered by the test (story 2.9).
class FakeRecoveryCases implements RecoveryCasesRepository {
  AccessRead<RecoveryCases> cases = const AccessReadDenied(
    AccessDenial.notGranted,
  );
  int calls = 0;

  @override
  Future<AccessRead<RecoveryCases>> fetchCases() async {
    calls++;
    return cases;
  }
}

/// The wire form of one recovery case as the Admin read sends it (2.9).
Map<String, Object?> recoveryCaseData({
  String caseId = '29292929-2929-4929-8929-292929292929',
  String name = 'SYNTHETIC Ruth Mwale',
  String state = 'open',
  String? grantState,
  String? operationState,
  String? linkProblem,
  bool held = false,
  bool ownMember = false,
}) => {
  'case_id': caseId,
  'revision': 2,
  'member_id': '39393939-3939-4939-8939-393939393939',
  'display_name': name,
  'member_revision': 4,
  'case_state': state,
  'identity_check': 'in_person',
  'evidence': ['known_in_person', 'photo_id'],
  'opened_at': '2026-10-07T10:00:00Z',
  'opened_by_me': true,
  'closed_at': null,
  'outcome': state == 'completed' ? 'reset_completed' : null,
  'cancel_reason': null,
  'account': 'app_account',
  'link_problem': linkProblem,
  'held': held,
  'grant': grantState == null
      ? null
      : {
          'grant_id': '49494949-4949-4949-8949-494949494949',
          'state': grantState,
          'issued_at': '2026-10-07T10:05:00Z',
          'expires_at': '2026-10-07T10:20:00Z',
          'end_reason': null,
        },
  'operation': operationState == null
      ? null
      : {
          'operation_id': '59595959-5959-4959-8959-595959595959',
          'state': operationState,
          'begun_at': '2026-10-07T10:06:00Z',
          'completed_at': null,
        },
  'is_synthetic': true,
  'own_member': ownMember,
};

/// [MembershipLifecycleRepository] answered by the test (story 2.10).
class FakeMembershipLifecycle implements MembershipLifecycleRepository {
  AccessRead<MyMembershipStatus> status = const AccessReadOk(
    MyMembershipStatus(deactivated: false),
  );
  AccessRead<MembershipLifecycleOverview> overview = const AccessReadDenied(
    AccessDenial.notGranted,
  );
  int statusCalls = 0;
  int overviewCalls = 0;

  @override
  Future<AccessRead<MyMembershipStatus>> fetchMyStatus() async {
    statusCalls++;
    return status;
  }

  @override
  Future<AccessRead<MembershipLifecycleOverview>> fetchOverview() async {
    overviewCalls++;
    return overview;
  }
}

/// The wire form of the Admin lifecycle overview (story 2.10).
Map<String, Object?> membershipLifecycleData({
  List<Map<String, Object?>> deactivated = const [],
  List<Map<String, Object?>> loginHolds = const [],
  List<Map<String, Object?>> handovers = const [],
}) => {
  'deactivated': deactivated,
  'login_holds': loginHolds,
  'handovers': handovers,
};

Map<String, Object?> deactivatedMemberData({
  String id = '81818181-8181-4181-8181-818181818181',
  String name = 'SYNTHETIC Esther Banda',
  int revision = 4,
  String account = 'access_review',
  int pendingObligations = 1,
  String reason = 'member_request',
  bool ownMember = false,
}) => {
  'member_id': id,
  'display_name': name,
  'membership_state': 'deactivated',
  'revision': revision,
  'account': account,
  'is_synthetic': true,
  'pending_obligations': pendingObligations,
  'deactivated_at': '2026-10-07T10:00:00Z',
  'reason_code': reason,
  'own_member': ownMember,
};

Map<String, Object?> loginHoldData({
  String holdId = '82828282-8282-4282-8282-828282828282',
  String memberId = '83838383-8383-4383-8383-838383838383',
  String name = 'SYNTHETIC Moses Phiri',
  int revision = 3,
  bool ownMember = false,
}) => {
  'hold_id': holdId,
  'member_id': memberId,
  'display_name': name,
  'member_revision': revision,
  'placed_at': '2026-10-07T09:00:00Z',
  'own_member': ownMember,
  'is_synthetic': true,
};

Map<String, Object?> handoverData({
  String id = '84848484-8484-4484-8484-848484848484',
  String memberId = '81818181-8181-4181-8181-818181818181',
  String name = 'SYNTHETIC Esther Banda',
  String state = 'deactivated',
  String kind = 'fixture_door_duty',
}) => {
  'obligation_id': id,
  'member_id': memberId,
  'display_name': name,
  'membership_state': state,
  'owner_module': 'fixture',
  'obligation_kind': kind,
  'recorded_at': '2026-10-07T10:00:00Z',
};

/// [MemberDeletionRepository] answered by the test (story 2.11).
class FakeMemberDeletion implements MemberDeletionRepository {
  AccessRead<MemberDeletionOverview> overview = const AccessReadDenied(
    AccessDenial.notGranted,
  );
  int overviewCalls = 0;

  @override
  Future<AccessRead<MemberDeletionOverview>> fetchOverview() async {
    overviewCalls++;
    return overview;
  }
}

/// The wire form of the Admin deletion read (story 2.11).
Map<String, Object?> memberDeletionOverviewData({
  List<Map<String, Object?>> deletions = const [],
  List<Map<String, Object?>> deactivated = const [],
  bool accepting = true,
}) => {
  'deletions': deletions,
  'deactivated': deactivated,
  'accepting': accepting,
};

const _deletionSteps = [
  'journal_access_revoked',
  'journal_manifest_member',
  'journal_manifest_account',
  'auth_account',
  'erase_identity',
  'erase_owners',
  'anonymise',
  'verify',
  'journal_completed_member',
  'journal_completed_account',
  'complete',
];

Map<String, Object?> memberDeletionData({
  String id = '85858585-8585-4585-8585-858585858585',
  String memberId = '86868686-8686-4686-8686-868686868686',
  String name = 'SYNTHETIC Grace Mwale',
  String origin = 'member_request',
  int done = 4,
  bool hadAccount = true,
  int pendingObligations = 0,
  Map<String, Object?>? next,
  int authAttempts = 1,
}) {
  final names = [
    for (final s in _deletionSteps)
      if (hadAccount || !s.endsWith('_account')) s,
  ];
  final steps = [
    for (final (i, s) in names.indexed)
      {
        'step': s,
        'state': i < done ? 'done' : 'pending',
        'attempts': s == 'auth_account' ? authAttempts : (i < done ? 1 : 0),
        'outcome': i < done ? 'done' : null,
      },
  ];
  final completed = steps.every((s) => s['state'] == 'done');
  return {
    'deletion_id': id,
    'member_id': memberId,
    'display_name': completed ? 'Deleted member' : name,
    'origin': origin,
    'deletion_state': completed ? 'completed' : 'requested',
    'had_account': hadAccount,
    'requested_at': '2026-10-07T11:00:00Z',
    'completed_at': completed ? '2026-10-07T11:05:00Z' : null,
    'revision': 1,
    'is_synthetic': true,
    'pending_obligations': pendingObligations,
    'steps': steps,
    'next':
        next ??
        (completed
            ? {'action': 'done'}
            : {
                'step': steps[done]['step'],
                'action': 'advance',
                'attempts': 0,
              }),
  };
}

Map<String, Object?> deletionCandidateData({
  String id = '87878787-8787-4787-8787-878787878787',
  String name = 'SYNTHETIC Daniel Zulu',
  int revision = 5,
  String account = 'access_review',
  bool ownMember = false,
}) => {
  'member_id': id,
  'display_name': name,
  'revision': revision,
  'account': account,
  'own_member': ownMember,
  'is_synthetic': true,
};

/// [InboxRepository] answered by the test (story 3.1).
class FakeInbox implements InboxRepository {
  AccessRead<Inbox> inbox = const AccessReadOk(Inbox(items: []));

  /// The answer for an older page, by its cursor's item id.
  final olderPages = <String, AccessRead<Inbox>>{};
  final afters = <InboxCursor?>[];
  int calls = 0;

  @override
  Future<AccessRead<Inbox>> fetchMyInbox({InboxCursor? after}) async {
    calls++;
    afters.add(after);
    if (after == null) return inbox;
    return olderPages[after.afterItemId] ??
        const AccessReadFailed(unreachable: false);
  }
}

/// The wire form of one inbox item (story 3.1).
Map<String, Object?> inboxItemData({
  String id = '31313131-3131-4131-8131-313131313131',
  String kind = 'fixture_due',
  String dueAt = '2026-10-08T07:00:00.000000Z',
  String deliveredAt = '2026-10-08T07:00:05.000000Z',
}) => {
  'item_id': id,
  'reminder_kind': kind,
  'due_at': dueAt,
  'delivered_at': deliveredAt,
};

/// The fakes and provider overrides an app or screen test runs against.
class ClientTestHarness {
  ClientTestHarness({String? account = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'})
    : session = FakeSession(account);

  final gateway = FakeCommandGateway();
  final FakeSession session;
  final reader = FakeFixtureReader();
  late final auth = FakeAccountAuth(session);
  final memberAccess = FakeMemberAccess();
  final grants = FakeGrants();
  final membership = FakeMembership();
  final review = FakeReview();
  final cells = FakeCells();
  final recovery = FakePasswordRecovery();
  final recoveryEmail = FakeRecoveryEmail();
  final credentials = FakeCredentialReview();
  final assisted = FakeAssistedRecovery();
  final recoveryCases = FakeRecoveryCases();
  final lifecycle = FakeMembershipLifecycle();
  final deletions = FakeMemberDeletion();
  final inbox = FakeInbox();

  /// Replaces [gateway] in [overrides] when set, so a screen test can run
  /// the real adapter (for example SupabaseCommandGateway over a mock HTTP
  /// client answering with a recorded server envelope).
  CommandGateway? commandGateway;

  /// [configured] false leaves the unconfigured defaults for the gateway and
  /// the platform status (as a build without `--dart-define`s).
  List<Override> overrides({bool configured = true}) => [
    sessionRepositoryProvider.overrideWithValue(session),
    fixtureCounterReaderProvider.overrideWithValue(reader),
    requestIdsProvider.overrideWithValue(SequentialRequestIds()),
    if (configured) ...[
      accountAuthGatewayProvider.overrideWithValue(auth),
      memberAccessRepositoryProvider.overrideWithValue(memberAccess),
      grantsRepositoryProvider.overrideWithValue(grants),
      membershipRepositoryProvider.overrideWithValue(membership),
      reviewRepositoryProvider.overrideWithValue(review),
      cellsRepositoryProvider.overrideWithValue(cells),
      passwordRecoveryGatewayProvider.overrideWithValue(recovery),
      recoveryEmailRepositoryProvider.overrideWithValue(recoveryEmail),
      credentialReviewRepositoryProvider.overrideWithValue(credentials),
      assistedRecoveryGatewayProvider.overrideWithValue(assisted),
      recoveryCasesRepositoryProvider.overrideWithValue(recoveryCases),
      membershipLifecycleRepositoryProvider.overrideWithValue(lifecycle),
      memberDeletionRepositoryProvider.overrideWithValue(deletions),
      inboxRepositoryProvider.overrideWithValue(inbox),
      commandGatewayProvider.overrideWithValue(commandGateway ?? gateway),
      platformStatusRepositoryProvider.overrideWithValue(FakePlatformStatus()),
    ],
  ];
}

final _directive = RegExp(
  r'''^\s*(?:import|export)\s+['"]([^'"]+)['"]''',
  multiLine: true,
);
final _sdkPackage = RegExp(
  r'^package:(supabase|supabase_flutter|gotrue|postgrest|realtime_client|storage_client|functions_client|http)/',
);

/// Import/export targets in [source] (the file at the package-relative
/// [path], e.g. `lib/src/presentation/x.dart`) that only a composition root
/// or an adapter may reach: the Supabase/http SDKs, the adapters (by package
/// URI or by a relative path that resolves into them), `supabase_adapters.dart`
/// and `composition.dart`. Relative paths are resolved against [path].
List<String> boundaryViolations(String path, String source) {
  const ownPackage = 'package:church_client_core/';
  bool restricted(String libPath) =>
      libPath.startsWith('lib/src/adapters/') ||
      libPath == 'lib/supabase_adapters.dart' ||
      libPath == 'lib/composition.dart';
  final found = <String>[];
  for (final m in _directive.allMatches(source)) {
    final uri = m.group(1)!;
    if (uri.startsWith('dart:')) continue;
    if (_sdkPackage.hasMatch(uri)) {
      found.add(uri);
    } else if (uri.startsWith(ownPackage)) {
      if (restricted('lib/${uri.substring(ownPackage.length)}')) found.add(uri);
    } else if (!uri.startsWith('package:')) {
      final parts = path.split('/')..removeLast();
      for (final seg in uri.split('/')) {
        if (seg == '..') {
          if (parts.isNotEmpty) parts.removeLast();
        } else if (seg != '.') {
          parts.add(seg);
        }
      }
      if (restricted(parts.join('/'))) found.add(uri);
    }
  }
  return found;
}

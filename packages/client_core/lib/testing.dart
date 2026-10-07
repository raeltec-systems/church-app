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
import 'src/domain/commands.dart';
import 'src/domain/member_access.dart';
import 'src/domain/membership_application.dart';
import 'src/domain/membership_review.dart';
import 'src/domain/fixture_counter.dart';
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
      commandGatewayProvider.overrideWithValue(gateway),
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

/// Test doubles for the client ports, shared by the package and app tests.
/// Not for production composition roots.
library;

import 'dart:async';

import 'package:church_contracts/church_contracts.dart';
import 'package:flutter_riverpod/misc.dart' show Override;

import 'src/application/providers.dart';
import 'src/domain/platform_status.dart';

import 'src/domain/account_auth.dart';
import 'src/domain/commands.dart';
import 'src/domain/member_access.dart';
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

/// The fakes and provider overrides an app or screen test runs against.
class ClientTestHarness {
  ClientTestHarness({String? account = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'})
    : session = FakeSession(account);

  final gateway = FakeCommandGateway();
  final FakeSession session;
  final reader = FakeFixtureReader();
  late final auth = FakeAccountAuth(session);
  final memberAccess = FakeMemberAccess();

  /// [configured] false leaves the unconfigured defaults for the gateway and
  /// the platform status (as a build without `--dart-define`s).
  List<Override> overrides({bool configured = true}) => [
    sessionRepositoryProvider.overrideWithValue(session),
    fixtureCounterReaderProvider.overrideWithValue(reader),
    requestIdsProvider.overrideWithValue(SequentialRequestIds()),
    if (configured) ...[
      accountAuthGatewayProvider.overrideWithValue(auth),
      memberAccessRepositoryProvider.overrideWithValue(memberAccess),
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

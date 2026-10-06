import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/account_auth.dart';
import '../domain/commands.dart';
import '../domain/fixture_counter.dart';
import '../domain/member_access.dart';
import '../domain/platform_status.dart';
import '../domain/session.dart';

/// Ports. Each app's composition root overrides these with adapters; tests
/// override them with fakes. Presentation never constructs an adapter.
final sessionRepositoryProvider = Provider<SessionRepository>(
  (ref) => const SignedOutSession(),
);

final commandGatewayProvider = Provider<CommandGateway>(
  (ref) => const UnconfiguredCommandGateway(),
);

final fixtureCounterReaderProvider = Provider<FixtureCounterReader>(
  (ref) => const NoFixtureCounterReadEndpoint(),
);

/// Null when the build has no backend configuration.
final platformStatusRepositoryProvider = Provider<PlatformStatusRepository?>(
  (ref) => null,
);

final accountAuthGatewayProvider = Provider<AccountAuthGateway>(
  (ref) => const UnconfiguredAccountAuthGateway(),
);

final memberAccessRepositoryProvider = Provider<MemberAccessRepository>(
  (ref) => const UnconfiguredMemberAccessRepository(),
);

final requestIdsProvider = Provider<RequestIds>((ref) => SecureRequestIds());

/// How the signed-in account last changed.
enum AccountChange {
  signedIn,
  signedOut,
  switched,

  /// The server stopped trusting this session (signed out or revoked
  /// elsewhere, a credential change, a hold): this device ended it.
  sessionEnded,
}

/// The account the client acts for. [generation] increases on every change;
/// protected state is scoped to one generation.
class AccountState {
  const AccountState({
    required this.accountId,
    required this.generation,
    this.lastChange,
  });

  final String? accountId;
  final int generation;

  /// Set until acknowledged, so the shell can say what was cleared.
  final AccountChange? lastChange;
}

class AccountController extends Notifier<AccountState> {
  @override
  AccountState build() {
    final session = ref.watch(sessionRepositoryProvider);
    final sub = session.accountChanges.listen(_onAccount);
    ref.onDispose(sub.cancel);
    return AccountState(accountId: session.currentAccountId, generation: 0);
  }

  bool _ending = false;

  void _onAccount(String? id) {
    if (id == state.accountId) return;
    final ending = _ending;
    _ending = false;
    final change = id == null
        ? (ending ? AccountChange.sessionEnded : AccountChange.signedOut)
        : state.accountId == null
        ? AccountChange.signedIn
        : AccountChange.switched;
    state = AccountState(
      accountId: id,
      generation: state.generation + 1,
      lastChange: change,
    );
  }

  /// Ends this device's session because the server answered that it is no
  /// longer trusted. Protected state is dropped with the account generation,
  /// and the stored session is removed so a restart cannot reuse it.
  Future<void> endUntrustedSession() async {
    if (state.accountId == null) return;
    _ending = true;
    // _onAccount clears the flag when the sign-out reaches the session.
    await ref.read(accountAuthGatewayProvider).signOut();
  }

  /// Hides the "account changed" notice; protected state stays cleared.
  void acknowledgeChange() {
    state = AccountState(
      accountId: state.accountId,
      generation: state.generation,
    );
  }
}

final accountProvider = NotifierProvider<AccountController, AccountState>(
  AccountController.new,
);

/// The protected-state generation: watch this to drop state on any account
/// change.
final accountGenerationProvider = Provider<int>(
  (ref) => ref.watch(accountProvider.select((s) => s.generation)),
);

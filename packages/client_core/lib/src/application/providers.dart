import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/access_grants.dart';
import '../domain/account_auth.dart';
import '../domain/assisted_recovery.dart';
import '../domain/cell_membership.dart';
import '../domain/commands.dart';
import '../domain/credential_review.dart';
import '../domain/fixture_counter.dart';
import '../domain/inbox.dart';
import '../domain/member_access.dart';
import '../domain/member_deletion.dart';
import '../domain/membership_application.dart';
import '../domain/membership_lifecycle.dart';
import '../domain/membership_review.dart';
import '../domain/password_recovery.dart';
import '../domain/platform_status.dart';
import '../domain/push_messaging.dart';
import '../domain/recovery_email.dart';
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

/// Story 2.3: the caller's own grants and the Admin grant roster.
final grantsRepositoryProvider = Provider<GrantsRepository>(
  (ref) => const UnconfiguredGrantsRepository(),
);

/// Story 2.4: the applicant's own membership request and the cell chooser.
final membershipRepositoryProvider = Provider<MembershipRepository>(
  (ref) => const UnconfiguredMembershipRepository(),
);

/// Story 2.5: the Admin's application queue and member search.
final reviewRepositoryProvider = Provider<ReviewRepository>(
  (ref) => const UnconfiguredReviewRepository(),
);

/// Story 2.6: the member's cell, the leader queue and the Admin overview.
final cellsRepositoryProvider = Provider<CellsRepository>(
  (ref) => const UnconfiguredCellsRepository(),
);

/// Story 2.7: the isolated forgotten-password route (its own Auth client).
final passwordRecoveryGatewayProvider = Provider<PasswordRecoveryGateway>(
  (ref) => const UnconfiguredPasswordRecoveryGateway(),
);

/// Story 2.7: the member's recovery email and the Admin approval queue.
final recoveryEmailRepositoryProvider = Provider<RecoveryEmailRepository>(
  (ref) => const UnconfiguredRecoveryEmailRepository(),
);

/// Story 2.8: the member's own sign-in details and the Admin credential
/// review queue.
final credentialReviewRepositoryProvider = Provider<CredentialReviewRepository>(
  (ref) => const UnconfiguredCredentialReviewRepository(),
);

/// Story 2.9: the member device's assisted-recovery service (no session).
final assistedRecoveryGatewayProvider = Provider<AssistedRecoveryGateway>(
  (ref) => const UnconfiguredAssistedRecoveryGateway(),
);

/// Story 2.9: the Admin's assisted-recovery cases.
final recoveryCasesRepositoryProvider = Provider<RecoveryCasesRepository>(
  (ref) => const UnconfiguredRecoveryCasesRepository(),
);

/// Story 2.10: the account's own membership status and the Admin overview of
/// deactivated members, login holds and pending handovers.
final membershipLifecycleRepositoryProvider =
    Provider<MembershipLifecycleRepository>(
      (ref) => const UnconfiguredMembershipLifecycleRepository(),
    );

/// Story 2.11: the Admin's member deletions and their steps.
final memberDeletionRepositoryProvider = Provider<MemberDeletionRepository>(
  (ref) => const UnconfiguredMemberDeletionRepository(),
);

/// Story 3.1: the member's durable inbox.
final inboxRepositoryProvider = Provider<InboxRepository>(
  (ref) => const UnconfiguredInboxRepository(),
);

/// Story 3.6: the device push SDK. Off by default ([NoPushMessaging]); the
/// mobile composition root overrides it once a Firebase app is configured.
final pushMessagingProvider = Provider<PushMessaging>(
  (ref) => const NoPushMessaging(),
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

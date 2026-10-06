import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/account_auth.dart';
import '../domain/member_access.dart';
import 'providers.dart';

enum SignInPhase { idle, pending, failed, succeeded }

class SignInState {
  const SignInState({
    this.phase = SignInPhase.idle,
    this.failure,
    this.serverReasons = const [],
    this.createdAccount = false,
  });

  final SignInPhase phase;
  final AuthFailure? failure;
  final List<String> serverReasons;

  /// The last attempt was Create account (for wording).
  final bool createdAccount;
}

/// Phone/password sign-up and sign-in. Holds no credentials: the screen owns
/// the typed password and passes it once per submission.
class SignInController extends Notifier<SignInState> {
  @override
  SignInState build() => const SignInState();

  Future<void> submit({
    required bool createAccount,
    required String phoneE164,
    required String password,
  }) async {
    if (state.phase == SignInPhase.pending) return;
    state = SignInState(
      phase: SignInPhase.pending,
      createdAccount: createAccount,
    );
    final gateway = ref.read(accountAuthGatewayProvider);
    final outcome = createAccount
        ? await gateway.signUp(phoneE164: phoneE164, password: password)
        : await gateway.signIn(phoneE164: phoneE164, password: password);
    if (!ref.mounted) return;
    if (outcome is AuthSucceeded) {
      // A new session, even for the same account, gets a fresh server
      // decision: drop any earlier answer (for example a stale denial).
      ref.invalidate(memberSummaryControllerProvider);
    }
    state = switch (outcome) {
      AuthSucceeded() => SignInState(
        phase: SignInPhase.succeeded,
        createdAccount: createAccount,
      ),
      AuthFailed(:final failure, :final serverReasons) => SignInState(
        phase: SignInPhase.failed,
        failure: failure,
        serverReasons: serverReasons,
        createdAccount: createAccount,
      ),
    };
  }

  /// Clears a shown failure once the user edits the form.
  void edited() {
    if (state.phase == SignInPhase.failed) state = const SignInState();
  }

  /// Ready for another sign-in (for example after signing out).
  void reset() => state = const SignInState();
}

final signInControllerProvider =
    NotifierProvider<SignInController, SignInState>(SignInController.new);

class MemberSummaryState {
  const MemberSummaryState({this.loading = false, this.result});

  final bool loading;

  /// The last server answer for the CURRENT account, or null before one.
  final MemberAccessResult? result;
}

/// The signed-in member's own summary. Protected state (AD-13): kept in memory
/// only, scoped to one account generation, dropped on sign-out or account
/// change, and late answers for an older generation are discarded.
class MemberSummaryController extends Notifier<MemberSummaryState> {
  @override
  MemberSummaryState build() {
    final generation = ref.watch(accountGenerationProvider);
    final accountId = ref.watch(accountProvider.select((s) => s.accountId));
    if (accountId == null) {
      return const MemberSummaryState(
        result: MemberAccessDenied(MemberAccessDenial.signedOut),
      );
    }
    Future.microtask(() => _load(generation));
    return const MemberSummaryState(loading: true);
  }

  /// Asks the server again (the server rechecks access every time).
  Future<void> refresh() => _load(ref.read(accountGenerationProvider));

  Future<void> _load(int generation) async {
    if (!ref.mounted || ref.read(accountGenerationProvider) != generation) {
      return;
    }
    if (ref.read(accountProvider).accountId == null) return;
    state = MemberSummaryState(loading: true, result: state.result);
    final result = await ref
        .read(memberAccessRepositoryProvider)
        .fetchMySummary();
    if (!ref.mounted || ref.read(accountGenerationProvider) != generation) {
      return;
    }
    state = MemberSummaryState(result: result);
  }
}

final memberSummaryControllerProvider =
    NotifierProvider<MemberSummaryController, MemberSummaryState>(
      MemberSummaryController.new,
    );

/// Phone/password account port (AD-20). Free of widgets and SDKs.
///
/// There is no SMS anywhere: no code request, no code entry, no resend.
library;

/// Why a sign-up or sign-in did not produce a session. Messages shown for
/// these never say whether a phone username has an account, except that
/// creating an account with a username already in use is refused.
enum AuthFailure {
  /// Wrong password or unknown username (one generic answer for both).
  invalidCredentials,

  /// Create account: this username cannot be used.
  usernameUnavailable,

  /// Create account: the password does not meet the server's policy.
  weakPassword,

  /// Too many attempts; try later.
  rateLimited,

  /// The server could not be reached; nothing is known to have happened.
  unreachable,

  /// The server refused for another reason (for example phone sign-in is not
  /// enabled in this environment).
  unavailable,
}

sealed class AuthOutcome {
  const AuthOutcome();
}

class AuthSucceeded extends AuthOutcome {
  const AuthSucceeded(this.accountId);
  final String accountId;
}

class AuthFailed extends AuthOutcome {
  const AuthFailed(this.failure, {this.serverReasons = const []});
  final AuthFailure failure;

  /// Server-provided password policy reasons (weak password only).
  final List<String> serverReasons;
}

/// Application port over native phone/password Auth.
abstract interface class AccountAuthGateway {
  /// Creates the account with [phoneE164] (normalized) and [password].
  Future<AuthOutcome> signUp({
    required String phoneE164,
    required String password,
  });

  /// Signs in with [phoneE164] and [password].
  Future<AuthOutcome> signIn({
    required String phoneE164,
    required String password,
  });

  /// Ends this device's session (other devices keep theirs).
  Future<void> signOut();
}

/// No Auth configured (a build without `--dart-define`s).
class UnconfiguredAccountAuthGateway implements AccountAuthGateway {
  const UnconfiguredAccountAuthGateway();

  @override
  Future<AuthOutcome> signUp({
    required String phoneE164,
    required String password,
  }) async => const AuthFailed(AuthFailure.unavailable);

  @override
  Future<AuthOutcome> signIn({
    required String phoneE164,
    required String password,
  }) async => const AuthFailed(AuthFailure.unavailable);

  @override
  Future<void> signOut() async {}
}

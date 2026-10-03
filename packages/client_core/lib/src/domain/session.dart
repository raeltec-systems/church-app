/// Session port: which account the client is acting for. Free of SDKs.
library;

/// Application port over the auth session.
///
/// Sign-in itself belongs to the identity epic; the shells only observe the
/// current account so protected state can be cleared when it changes.
abstract interface class SessionRepository {
  /// The current account's `auth_user_id`, or null when signed out.
  String? get currentAccountId;

  /// Emits the account id (or null) whenever the signed-in account changes.
  Stream<String?> get accountChanges;
}

/// A session that is always signed out (no Auth configured).
class SignedOutSession implements SessionRepository {
  const SignedOutSession();

  @override
  String? get currentAccountId => null;

  @override
  Stream<String?> get accountChanges => const Stream.empty();
}

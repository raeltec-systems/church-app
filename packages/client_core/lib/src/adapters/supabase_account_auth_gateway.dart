import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:supabase/supabase.dart';

import '../domain/account_auth.dart';

/// Supabase Auth adapter for [AccountAuthGateway]: native phone/password
/// sign-up and sign-in (AD-20). It never calls an OTP, SMS or verification
/// endpoint.
class SupabaseAccountAuthGateway implements AccountAuthGateway {
  SupabaseAccountAuthGateway(this._client);

  final SupabaseClient _client;

  @override
  Future<AuthOutcome> signUp({
    required String phoneE164,
    required String password,
  }) => _run(() => _client.auth.signUp(phone: phoneE164, password: password));

  @override
  Future<AuthOutcome> signIn({
    required String phoneE164,
    required String password,
  }) => _run(
    () => _client.auth.signInWithPassword(phone: phoneE164, password: password),
  );

  @override
  Future<void> signOut() async {
    try {
      // Local scope: this device's session ends server-side; other devices
      // keep theirs. The SDK clears the local session even if the call fails.
      await _client.auth.signOut(scope: SignOutScope.local);
    } catch (_) {
      // Signed out locally regardless; the server session expires on its own.
    }
  }

  Future<AuthOutcome> _run(Future<AuthResponse> Function() call) async {
    try {
      final res = await call();
      final user = res.session?.user ?? res.user;
      // Phone confirmation is off (AD-20): a real sign-up returns a session.
      // No session means confirmation is on, which this product never uses.
      if (res.session == null || user == null) {
        return const AuthFailed(AuthFailure.unavailable);
      }
      return AuthSucceeded(user.id);
    } on AuthWeakPasswordException catch (e) {
      return AuthFailed(AuthFailure.weakPassword, serverReasons: e.reasons);
    } on AuthRetryableFetchException {
      return const AuthFailed(AuthFailure.unreachable);
    } on AuthException catch (e) {
      return AuthFailed(authFailureFor(e.code, e.statusCode));
    } on http.ClientException {
      return const AuthFailed(AuthFailure.unreachable);
    } on TimeoutException {
      return const AuthFailed(AuthFailure.unreachable);
    } catch (_) {
      return const AuthFailed(AuthFailure.unavailable);
    }
  }
}

/// Maps a GoTrue error code / HTTP status to the product's generic failures.
AuthFailure authFailureFor(String? code, String? statusCode) {
  switch (code) {
    case 'invalid_credentials':
      return AuthFailure.invalidCredentials;
    case 'user_already_exists':
    case 'phone_exists':
    case 'email_exists':
      return AuthFailure.usernameUnavailable;
    case 'weak_password':
      return AuthFailure.weakPassword;
    case 'over_request_rate_limit':
    case 'over_sms_send_rate_limit':
    case 'over_email_send_rate_limit':
      return AuthFailure.rateLimited;
  }
  if (statusCode == '429') return AuthFailure.rateLimited;
  return AuthFailure.unavailable;
}

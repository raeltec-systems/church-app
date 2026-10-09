import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:supabase/supabase.dart';

import '../domain/access_grants.dart';
import '../domain/account_auth.dart';
import '../domain/password_recovery.dart';
import '../domain/recovery_email.dart';
import 'supabase_account_auth_gateway.dart' show authFailureFor;
import 'supabase_api_reader.dart';

/// Supabase adapter for [RecoveryEmailRepository] (story 2.7): the member's
/// own state (`api.identity_my_recovery_email`), the Admin queue
/// (`api.identity_admin_recovery_email_queue`), the password re-check and
/// the native same-account email change. The server decides everything.
class SupabaseRecoveryEmailRepository implements RecoveryEmailRepository {
  SupabaseRecoveryEmailRepository(
    this._client, {
    required this.redirects,
    Duration timeout = const Duration(seconds: 10),
  }) : _reader = SupabaseApiReader(_client, timeout: timeout);

  final SupabaseClient _client;
  final SupabaseApiReader _reader;
  final AuthRedirects redirects;

  @override
  Future<AccessRead<MyRecoveryEmail>> fetchMine() => _reader.read(
    'identity_my_recovery_email',
    const {},
    MyRecoveryEmail.fromJson,
  );

  @override
  Future<AccessRead<RecoveryEmailQueue>> fetchQueue() => _reader.read(
    'identity_admin_recovery_email_queue',
    const {},
    RecoveryEmailQueue.fromJson,
  );

  @override
  Future<AuthOutcome> confirmPassword(String password) async {
    final phone = _client.auth.currentUser?.phone;
    if (phone == null || phone.isEmpty) {
      return const AuthFailed(AuthFailure.invalidCredentials);
    }
    try {
      // The same account's own phone username: a new password session.
      final res = await _client.auth.signInWithPassword(
        phone: '+${phone.replaceFirst(RegExp(r'^\+'), '')}',
        password: password,
      );
      final user = res.session?.user;
      return user == null
          ? const AuthFailed(AuthFailure.unavailable)
          : AuthSucceeded(user.id);
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

  @override
  Future<EmailVerificationRequest> requestVerification(String email) async {
    try {
      await _client.auth.updateUser(
        UserAttributes(email: email.trim()),
        emailRedirectTo: redirects.emailConfirmed.toString(),
      );
      return EmailVerificationRequest.sent;
    } on AuthRetryableFetchException {
      return EmailVerificationRequest.unreachable;
    } on AuthException catch (e) {
      if (e.code == 'email_exists') {
        return EmailVerificationRequest.addressUnavailable;
      }
      if (e.code == 'over_email_send_rate_limit' || e.statusCode == '429') {
        return EmailVerificationRequest.rateLimited;
      }
      return EmailVerificationRequest.failed;
    } on http.ClientException {
      return EmailVerificationRequest.unreachable;
    } on TimeoutException {
      return EmailVerificationRequest.unreachable;
    } catch (_) {
      return EmailVerificationRequest.failed;
    }
  }
}

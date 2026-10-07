import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:supabase/supabase.dart';

import '../domain/password_recovery.dart';

/// Supabase Auth adapter for [PasswordRecoveryGateway] (story 2.7).
///
/// It uses its OWN Auth client, separate from the app's session: PKCE flow,
/// no token refresh, nothing persisted but the one-time code verifier (in
/// [verifierStorage]). The recovery session it opens stays in this object's
/// memory, is used for exactly one call (set the password) and is then
/// signed out, so it can never become the app's session or reach a member
/// read. The server additionally refuses private data to any recovery
/// session and refuses links for emails that are not the approved one.
class SupabasePasswordRecoveryGateway implements PasswordRecoveryGateway {
  SupabasePasswordRecoveryGateway({
    required String supabaseUrl,
    required String publishableKey,
    required this.redirects,
    required GotrueAsyncStorage verifierStorage,
    http.Client? httpClient,
  }) : _auth = GoTrueClient(
         url: '$supabaseUrl/auth/v1',
         headers: {'apikey': publishableKey},
         autoRefreshToken: false,
         httpClient: httpClient,
         asyncStorage: verifierStorage,
         flowType: AuthFlowType.pkce,
       );

  final GoTrueClient _auth;
  final AuthRedirects redirects;

  @override
  Future<ResetRequestOutcome> requestReset(String email) async {
    try {
      await _auth.resetPasswordForEmail(
        email.trim(),
        redirectTo: redirects.recovery.toString(),
      );
      return ResetRequestOutcome.sent;
    } on AuthRetryableFetchException {
      return ResetRequestOutcome.unreachable;
    } on AuthException {
      // Neutral: a refusal (including "wait before asking again", which
      // Auth gives only for addresses it knows) is shown like a success.
      return ResetRequestOutcome.sent;
    } on http.ClientException {
      return ResetRequestOutcome.unreachable;
    } on TimeoutException {
      return ResetRequestOutcome.unreachable;
    } catch (_) {
      return ResetRequestOutcome.sent;
    }
  }

  @override
  Future<RecoveryLinkOutcome> openLink(String code) async {
    try {
      final res = await _auth.exchangeCodeForSession(code);
      return res.session.user.id.isEmpty
          ? RecoveryLinkOutcome.unusable
          : RecoveryLinkOutcome.ready;
    } on AuthRetryableFetchException {
      return RecoveryLinkOutcome.unreachable;
    } on AuthException {
      return RecoveryLinkOutcome.unusable;
    } on http.ClientException {
      return RecoveryLinkOutcome.unreachable;
    } on TimeoutException {
      return RecoveryLinkOutcome.unreachable;
    } catch (_) {
      return RecoveryLinkOutcome.unusable;
    }
  }

  @override
  Future<SetPasswordOutcome> setNewPassword(String password) async {
    if (_auth.currentSession == null) {
      return const PasswordNotSet(SetPasswordFailure.linkExpired);
    }
    try {
      // The ONLY call made with the recovery session.
      await _auth.updateUser(UserAttributes(password: password));
    } on AuthWeakPasswordException catch (e) {
      return PasswordNotSet(
        SetPasswordFailure.weakPassword,
        serverReasons: e.reasons,
      );
    } on AuthRetryableFetchException {
      return const PasswordNotSet(SetPasswordFailure.unreachable);
    } on AuthException catch (e) {
      if (e.code == 'weak_password') {
        return const PasswordNotSet(SetPasswordFailure.weakPassword);
      }
      if (e.statusCode == '401' || e.statusCode == '403') {
        await discard();
        return const PasswordNotSet(SetPasswordFailure.linkExpired);
      }
      return const PasswordNotSet(SetPasswordFailure.unavailable);
    } on http.ClientException {
      return const PasswordNotSet(SetPasswordFailure.unreachable);
    } on TimeoutException {
      return const PasswordNotSet(SetPasswordFailure.unreachable);
    } catch (_) {
      return const PasswordNotSet(SetPasswordFailure.unavailable);
    }
    await discard();
    return const PasswordSet();
  }

  @override
  Future<void> discard() async {
    if (_auth.currentSession == null) return;
    try {
      await _auth.signOut(scope: SignOutScope.local);
    } catch (_) {
      // The session is dropped locally regardless and expires on its own.
    }
  }
}

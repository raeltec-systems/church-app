import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:supabase/supabase.dart';

import '../domain/access_grants.dart';
import 'supabase_member_access_repository.dart' show isJwtRejection;

/// Supabase adapter for [GrantsRepository]: `POST /rest/v1/rpc/<function>`
/// with `Content-Profile: api`. The server's live-access predicate and the
/// current grant rows decide; this adapter only maps the answer. Like the
/// member summary (story 2.2), a JWT that PostgREST itself rejects is
/// refreshed once and asked again; only the predicate's answer is a denial.
class SupabaseGrantsRepository implements GrantsRepository {
  SupabaseGrantsRepository(
    this._client, {
    this.timeout = const Duration(seconds: 10),
  });

  final SupabaseClient _client;
  final Duration timeout;

  @override
  Future<AccessRead<MemberGrants>> fetchMyAccess() =>
      _read('identity_my_access', const {}, MemberGrants.fromJson);

  @override
  Future<AccessRead<GrantRoster>> fetchRoster({RosterCursor? after}) =>
      _read('identity_admin_member_grants', {
        if (after != null) ...{
          'after_display_name': after.afterDisplayName,
          'after_member_id': after.afterMemberId,
        },
      }, GrantRoster.fromJson);

  Future<AccessRead<T>> _read<T>(
    String function,
    Map<String, Object?> params,
    T Function(Object?) parse,
  ) async {
    if (_client.auth.currentSession == null) {
      return AccessReadDenied<T>(AccessDenial.signedOut);
    }
    final (first, rejected) = await _once(function, params, parse);
    if (rejected == null) return first!;
    try {
      await _client.auth.refreshSession();
    } on AuthRetryableFetchException catch (e) {
      return AccessReadFailed<T>(unreachable: true, cause: e);
    } on AuthException catch (e) {
      return _client.auth.currentSession == null
          ? AccessReadDenied<T>(AccessDenial.signedOut)
          : AccessReadFailed<T>(unreachable: false, cause: e);
    } on http.ClientException catch (e) {
      return AccessReadFailed<T>(unreachable: true, cause: e);
    } catch (e) {
      return AccessReadFailed<T>(unreachable: false, cause: e);
    }
    final (second, stillRejected) = await _once(function, params, parse);
    if (stillRejected != null) {
      return AccessReadFailed<T>(unreachable: false, cause: stillRejected);
    }
    return second!;
  }

  Future<(AccessRead<T>?, PostgrestException?)> _once<T>(
    String function,
    Map<String, Object?> params,
    T Function(Object?) parse,
  ) async {
    final Object? body;
    try {
      body = await _client
          .schema('api')
          .rpc<dynamic>(function, params: params)
          .retry(enabled: false)
          .abortSignal(Future<void>.delayed(timeout));
    } on RequestAbortedException catch (e) {
      return (AccessReadFailed<T>(unreachable: true, cause: e), null);
    } on TimeoutException catch (e) {
      return (AccessReadFailed<T>(unreachable: true, cause: e), null);
    } on http.ClientException catch (e) {
      return (AccessReadFailed<T>(unreachable: true, cause: e), null);
    } on PostgrestException catch (e) {
      if (isJwtRejection(e.code)) return (null, e);
      final denial = accessDenialFor(e.code, e.message, e.details);
      return (
        denial == null
            ? AccessReadFailed<T>(unreachable: false, cause: e)
            : AccessReadDenied<T>(denial),
        null,
      );
    } catch (e) {
      return (AccessReadFailed<T>(unreachable: false, cause: e), null);
    }
    try {
      return (AccessReadOk<T>(parse(body)), null);
    } on FormatException catch (e) {
      return (AccessReadFailed<T>(unreachable: false, cause: e), null);
    }
  }
}

/// Maps the server's denial (`message` = error code, `details` = the caller's
/// own reason) to an [AccessDenial]; null when it is not a recognised denial.
AccessDenial? accessDenialFor(String? code, String message, Object? details) {
  if (code == '42501') return AccessDenial.signedOut;
  if (isJwtRejection(code)) return null;
  final reason = details?.toString();
  switch (message) {
    case 'unauthenticated':
      return reason == 'unauthenticated'
          ? AccessDenial.signedOut
          : AccessDenial.untrustedSession;
    case 'forbidden':
      return switch (reason) {
        'not_linked' => AccessDenial.notLinked,
        'not_granted' => AccessDenial.notGranted,
        _ => AccessDenial.reviewRequired,
      };
    case 'unavailable':
      return AccessDenial.unavailable;
  }
  return null;
}

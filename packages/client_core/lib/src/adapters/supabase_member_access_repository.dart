import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:supabase/supabase.dart';

import '../domain/member_access.dart';

/// Supabase adapter for [MemberAccessRepository]: `POST
/// /rest/v1/rpc/identity_my_member_summary` with `Content-Profile: api`. The
/// server's live-access predicate decides; this adapter only maps its answer.
class SupabaseMemberAccessRepository implements MemberAccessRepository {
  SupabaseMemberAccessRepository(
    this._client, {
    this.timeout = const Duration(seconds: 10),
  });

  final SupabaseClient _client;
  final Duration timeout;

  @override
  Future<MemberAccessResult> fetchMySummary() async {
    if (_client.auth.currentSession == null) {
      return const MemberAccessDenied(MemberAccessDenial.signedOut);
    }
    final (first, rejected) = await _once();
    if (rejected == null) return first!;
    // Story 2.2: PostgREST rejected the JWT itself (expired or invalid,
    // PGRST301/PGRST303). That is not the server's access decision: refresh
    // once and ask again. Only the predicate's own denial ends the session.
    try {
      await _client.auth.refreshSession();
    } on AuthRetryableFetchException catch (e) {
      return MemberAccessFailed(unreachable: true, cause: e);
    } on AuthException catch (e) {
      // Auth refused the refresh token: the SDK has ended the local session.
      return _client.auth.currentSession == null
          ? const MemberAccessDenied(MemberAccessDenial.signedOut)
          : MemberAccessFailed(unreachable: false, cause: e);
    } on http.ClientException catch (e) {
      return MemberAccessFailed(unreachable: true, cause: e);
    } catch (e) {
      return MemberAccessFailed(unreachable: false, cause: e);
    }
    final (second, stillRejected) = await _once();
    if (stillRejected != null) {
      return MemberAccessFailed(unreachable: false, cause: stillRejected);
    }
    return second!;
  }

  /// One request. Returns the result, or the PostgREST JWT rejection.
  Future<(MemberAccessResult?, PostgrestException?)> _once() async {
    final Object? body;
    try {
      body = await _client
          .schema('api')
          .rpc<dynamic>('identity_my_member_summary')
          .retry(enabled: false)
          .abortSignal(Future<void>.delayed(timeout));
    } on RequestAbortedException catch (e) {
      return (MemberAccessFailed(unreachable: true, cause: e), null);
    } on TimeoutException catch (e) {
      return (MemberAccessFailed(unreachable: true, cause: e), null);
    } on http.ClientException catch (e) {
      return (MemberAccessFailed(unreachable: true, cause: e), null);
    } on PostgrestException catch (e) {
      if (isJwtRejection(e.code)) return (null, e);
      final denial = memberAccessDenialFor(e.code, e.message, e.details);
      return (
        denial == null
            ? MemberAccessFailed(unreachable: false, cause: e)
            : MemberAccessDenied(denial),
        null,
      );
    } catch (e) {
      return (MemberAccessFailed(unreachable: false, cause: e), null);
    }
    try {
      return (MemberAccessGranted(MemberSummary.fromJson(body)), null);
    } on FormatException catch (e) {
      return (MemberAccessFailed(unreachable: false, cause: e), null);
    }
  }
}

/// Maps the server's denial (`message` = error code, `details` = reason) to a
/// [MemberAccessDenial]; null when the answer is not a recognised denial.
MemberAccessDenial? memberAccessDenialFor(
  String? code,
  String message,
  Object? details,
) {
  // Signed-out callers have no EXECUTE on the read.
  if (code == '42501') return MemberAccessDenial.signedOut;
  // A JWT rejected by PostgREST is not an access decision (see isJwtRejection).
  if (isJwtRejection(code)) return null;
  final reason = details?.toString();
  switch (message) {
    case 'unauthenticated':
      return reason == 'unauthenticated'
          ? MemberAccessDenial.signedOut
          : MemberAccessDenial.untrustedSession;
    case 'forbidden':
      return reason == 'not_linked'
          ? MemberAccessDenial.notLinked
          : MemberAccessDenial.reviewRequired;
    case 'unavailable':
      return MemberAccessDenial.unavailable;
  }
  return null;
}

/// PostgREST rejected the JWT itself (expired / invalid), before the
/// live-access predicate ran.
bool isJwtRejection(String? code) => code == 'PGRST301' || code == 'PGRST303';

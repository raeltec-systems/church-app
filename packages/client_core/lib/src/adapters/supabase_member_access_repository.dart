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
    final Object? body;
    try {
      body = await _client
          .schema('api')
          .rpc<dynamic>('identity_my_member_summary')
          .retry(enabled: false)
          .abortSignal(Future<void>.delayed(timeout));
    } on RequestAbortedException catch (e) {
      return MemberAccessFailed(unreachable: true, cause: e);
    } on TimeoutException catch (e) {
      return MemberAccessFailed(unreachable: true, cause: e);
    } on http.ClientException catch (e) {
      return MemberAccessFailed(unreachable: true, cause: e);
    } on PostgrestException catch (e) {
      final denial = memberAccessDenialFor(e.code, e.message, e.details);
      return denial == null
          ? MemberAccessFailed(unreachable: false, cause: e)
          : MemberAccessDenied(denial);
    } catch (e) {
      return MemberAccessFailed(unreachable: false, cause: e);
    }
    try {
      return MemberAccessGranted(MemberSummary.fromJson(body));
    } on FormatException catch (e) {
      return MemberAccessFailed(unreachable: false, cause: e);
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
  if (code == 'PGRST301' || code == 'PGRST303') {
    return MemberAccessDenial.untrustedSession;
  }
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

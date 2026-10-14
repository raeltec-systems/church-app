import 'package:supabase/supabase.dart';

import '../domain/access_grants.dart';
import '../domain/member_access.dart';
import 'supabase_api_reader.dart';

export 'supabase_api_reader.dart' show isJwtRejection;

/// Supabase adapter for [MemberAccessRepository]: `POST
/// /rest/v1/rpc/identity_my_member_summary` with `Content-Profile: api`. The
/// server's live-access predicate decides; this adapter only maps its answer.
/// The request, the story 2.2 refresh-once rule and the denial mapping are
/// [SupabaseApiReader]'s (story 2.13: one read flow, not two copies).
class SupabaseMemberAccessRepository implements MemberAccessRepository {
  SupabaseMemberAccessRepository(
    SupabaseClient client, {
    this.timeout = const Duration(seconds: 10),
  }) : _reader = SupabaseApiReader(client, timeout: timeout);

  final SupabaseApiReader _reader;
  final Duration timeout;

  @override
  Future<MemberAccessResult> fetchMySummary() async {
    // The summary read takes no parameters (none are sent).
    final read = await _reader.read(
      'identity_my_member_summary',
      null,
      MemberSummary.fromJson,
    );
    return switch (read) {
      AccessReadOk(:final value) => MemberAccessGranted(value),
      AccessReadDenied(:final denial) => MemberAccessDenied(
        memberAccessDenialOf(denial),
      ),
      AccessReadFailed(:final unreachable, :final cause) => MemberAccessFailed(
        unreachable: unreachable,
        cause: cause,
      ),
    };
  }
}

/// The member summary's view of an [AccessDenial]. The summary has no role or
/// scope to lack, so a `not_granted` answer reads as a review (as before).
MemberAccessDenial memberAccessDenialOf(AccessDenial denial) =>
    switch (denial) {
      AccessDenial.signedOut => MemberAccessDenial.signedOut,
      AccessDenial.untrustedSession => MemberAccessDenial.untrustedSession,
      AccessDenial.notLinked => MemberAccessDenial.notLinked,
      AccessDenial.reviewRequired => MemberAccessDenial.reviewRequired,
      AccessDenial.notGranted => MemberAccessDenial.reviewRequired,
      AccessDenial.unavailable => MemberAccessDenial.unavailable,
    };

/// Maps the server's denial (`message` = error code, `details` = reason) to a
/// [MemberAccessDenial]; null when the answer is not a recognised denial.
MemberAccessDenial? memberAccessDenialFor(
  String? code,
  String message,
  Object? details,
) {
  final denial = accessDenialFor(code, message, details);
  return denial == null ? null : memberAccessDenialOf(denial);
}

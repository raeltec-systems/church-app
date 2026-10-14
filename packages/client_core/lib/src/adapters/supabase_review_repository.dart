import 'package:supabase/supabase.dart';

import '../domain/access_grants.dart';
import '../domain/membership_review.dart';
import 'supabase_api_reader.dart';

/// Supabase adapter for [ReviewRepository] (story 2.5): the Admin's
/// application queue (`api.identity_admin_application_queue`) and member
/// search (`api.identity_admin_member_search`). The server checks the live
/// Admin grant on every call; this adapter only maps the answer.
class SupabaseReviewRepository implements ReviewRepository {
  SupabaseReviewRepository(
    SupabaseClient client, {
    Duration timeout = const Duration(seconds: 10),
  }) : _reader = SupabaseApiReader(client, timeout: timeout);

  final SupabaseApiReader _reader;

  @override
  Future<AccessRead<ReviewQueue>> fetchQueue({QueueCursor? after}) =>
      _reader.read('identity_admin_application_queue', {
        if (after != null) ...{
          'after_submitted_at': after.afterSubmittedAt,
          'after_application_id': after.afterApplicationId,
        },
      }, ReviewQueue.fromJson);

  @override
  Future<AccessRead<MemberSearchPage>> searchMembers(
    String? query, {
    MemberCursor? after,
  }) => _reader.read('identity_admin_member_search', {
    if (query != null && query.trim().isNotEmpty) 'query': query.trim(),
    if (after != null) ...{
      'after_display_name': after.afterDisplayName,
      'after_member_id': after.afterMemberId,
    },
  }, MemberSearchPage.fromJson);
}

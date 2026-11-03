import 'package:supabase/supabase.dart';

import '../domain/access_grants.dart';
import '../domain/membership_review.dart';
import '../domain/user_management.dart';
import 'supabase_api_reader.dart';

/// Only purpose-limited, current-Admin RPCs; no direct tables or Auth Admin API.
class SupabaseUserManagementRepository implements UserManagementRepository {
  SupabaseUserManagementRepository(
    SupabaseClient client, {
    Duration timeout = const Duration(seconds: 10),
  }) : _reader = SupabaseApiReader(client, timeout: timeout);
  final SupabaseApiReader _reader;

  @override
  Future<AccessRead<UserDirectoryPage>> directory(
    UserFilter filter, {
    MemberCursor? after,
  }) => _reader.read('identity_admin_users', {
    'query': filter.query.trim().isEmpty ? null : filter.query.trim(),
    'membership': filter.membership,
    'account': filter.account,
    'role_filter': filter.role,
    if (after != null) ...{
      'after_display_name': after.afterDisplayName,
      'after_member_id': after.afterMemberId,
    },
  }, UserDirectoryPage.fromJson);

  @override
  Future<AccessRead<UserDetail>> detail(String memberId) => _reader.read(
    'identity_admin_user_detail',
    {'member_id': memberId},
    (json) {
      final detail = UserDetail.fromJson(json);
      if (detail.member.id != memberId) {
        throw const FormatException('unexpected detail target');
      }
      return detail;
    },
  );

  @override
  Future<AccessRead<UserActivityPage>> activity(
    String memberId, {
    UserActivityCursor? after,
  }) => _reader.read('identity_admin_user_activity', {
    'member_id': memberId,
    if (after != null) ...{
      'after_at': after.at,
      'after_source': after.source,
      'after_event_id': after.eventId,
    },
  }, UserActivityPage.fromJson);
}

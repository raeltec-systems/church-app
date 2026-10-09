import 'package:supabase/supabase.dart';

import '../domain/access_grants.dart';
import 'supabase_api_reader.dart';

export 'supabase_api_reader.dart' show accessDenialFor;

/// Supabase adapter for [GrantsRepository] over [SupabaseApiReader]. The
/// server's live-access predicate and the current grant rows decide; this
/// adapter only maps the answer.
class SupabaseGrantsRepository implements GrantsRepository {
  SupabaseGrantsRepository(
    SupabaseClient client, {
    Duration timeout = const Duration(seconds: 10),
  }) : _reader = SupabaseApiReader(client, timeout: timeout);

  final SupabaseApiReader _reader;

  @override
  Future<AccessRead<MemberGrants>> fetchMyAccess() =>
      _reader.read('identity_my_access', const {}, MemberGrants.fromJson);

  @override
  Future<AccessRead<GrantRoster>> fetchRoster({RosterCursor? after}) =>
      _reader.read('identity_admin_member_grants', {
        if (after != null) ...{
          'after_display_name': after.afterDisplayName,
          'after_member_id': after.afterMemberId,
        },
      }, GrantRoster.fromJson);
}

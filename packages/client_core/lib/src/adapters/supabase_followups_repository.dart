import 'package:supabase/supabase.dart';

import '../domain/access_grants.dart';
import '../domain/followups.dart';
import 'supabase_api_reader.dart';

/// Supabase adapter for [FollowUpsRepository] (story 4.6): My follow-ups
/// (`api.followups_my_tasks`), one task (`api.followups_task`), the scope
/// holders' supervision (`api.followups_supervision`) and the Admin routing
/// view (`api.followups_admin_routing`). The server checks live access, the
/// task's scope and the personal-data gate on every call; this adapter only
/// maps the answer.
class SupabaseFollowUpsRepository implements FollowUpsRepository {
  SupabaseFollowUpsRepository(
    SupabaseClient client, {
    Duration timeout = const Duration(seconds: 10),
  }) : _reader = SupabaseApiReader(client, timeout: timeout);

  final SupabaseApiReader _reader;

  @override
  Future<AccessRead<MyFollowUps>> fetchMyTasks() =>
      _reader.read('followups_my_tasks', const {}, MyFollowUps.fromJson);

  @override
  Future<AccessRead<FollowUpDetail>> fetchTask(String taskId) => _reader.read(
    'followups_task',
    {'p_task_id': taskId},
    FollowUpDetail.fromJson,
  );

  @override
  Future<AccessRead<FollowUpSupervision>> fetchSupervision() => _reader.read(
    'followups_supervision',
    const {},
    FollowUpSupervision.fromJson,
  );

  @override
  Future<AccessRead<FollowUpAdminRouting>> fetchAdminRouting() => _reader.read(
    'followups_admin_routing',
    const {},
    FollowUpAdminRouting.fromJson,
  );
}

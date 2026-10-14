import 'package:supabase/supabase.dart';

import '../domain/access_grants.dart';
import '../domain/duties.dart';
import 'supabase_api_reader.dart';

/// Supabase adapter for [DutiesRepository] (story 4.1): the member's own
/// duties (`api.duties_my_duties`), the leader board
/// (`api.duties_leader_board`) and the Admin overview
/// (`api.duties_admin_overview`). The server checks live access and the
/// current grants on every call; this adapter only maps the answer.
class SupabaseDutiesRepository implements DutiesRepository {
  SupabaseDutiesRepository(
    SupabaseClient client, {
    Duration timeout = const Duration(seconds: 10),
  }) : _reader = SupabaseApiReader(client, timeout: timeout);

  final SupabaseApiReader _reader;

  @override
  Future<AccessRead<MyDuties>> fetchMyDuties() =>
      _reader.read('duties_my_duties', const {}, MyDuties.fromJson);

  @override
  Future<AccessRead<DutyLeaderBoard>> fetchLeaderBoard() =>
      _reader.read('duties_leader_board', const {}, DutyLeaderBoard.fromJson);

  @override
  Future<AccessRead<DutyAdminOverview>> fetchAdminOverview() => _reader.read(
    'duties_admin_overview',
    const {},
    DutyAdminOverview.fromJson,
  );
}

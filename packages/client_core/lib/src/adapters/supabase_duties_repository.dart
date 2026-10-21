import 'package:supabase/supabase.dart';

import '../domain/access_grants.dart';
import '../domain/duties.dart';
import 'supabase_api_reader.dart';

/// Supabase adapter for [DutiesRepository] (story 4.1): the member's own
/// duties (`api.duties_my_duties`), the leader board
/// (`api.duties_leader_board`) and the Admin overview
/// (`api.duties_admin_overview`); story 4.3 adds the rota (`api.duties_rota`)
/// and story 4.4 the candidates read (`api.duties_candidates`). The server checks live access and the
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

  @override
  Future<AccessRead<DutyRota>> fetchRota() =>
      _reader.read('duties_rota', const {}, DutyRota.fromJson);

  /// Story 4.4: `api.duties_candidates` (named parameters).
  @override
  Future<AccessRead<DutyCandidates>> fetchCandidates(CandidateQuery query) =>
      _reader.read(
        'duties_candidates',
        query.toParams(),
        DutyCandidates.fromJson,
      );
}

/// Story 4.9: `api.duties_coverage` (named parameters). The server decides
/// which departments, contact routes and notes the caller may see.
class SupabaseDutyCoverageRepository implements DutyCoverageRepository {
  SupabaseDutyCoverageRepository(
    SupabaseClient client, {
    Duration timeout = const Duration(seconds: 10),
  }) : _reader = SupabaseApiReader(client, timeout: timeout);

  final SupabaseApiReader _reader;

  @override
  Future<AccessRead<DutyCoverage>> fetchCoverage(CoverageQuery query) =>
      _reader.read('duties_coverage', query.toParams(), DutyCoverage.fromJson);
}

/// Story 4.10: `api.duties_outcomes` and `api.duties_member_history` (named
/// parameters). The server decides which departments, notes, reasons and
/// histories the caller may see.
class SupabaseDutyOutcomesRepository implements DutyOutcomesRepository {
  SupabaseDutyOutcomesRepository(
    SupabaseClient client, {
    Duration timeout = const Duration(seconds: 10),
  }) : _reader = SupabaseApiReader(client, timeout: timeout);

  final SupabaseApiReader _reader;

  @override
  Future<AccessRead<DutyOutcomes>> fetchOutcomes(OutcomesQuery query) =>
      _reader.read('duties_outcomes', query.toParams(), DutyOutcomes.fromJson);

  @override
  Future<AccessRead<MemberHistory>> fetchHistory(HistoryQuery query) => _reader
      .read('duties_member_history', query.toParams(), MemberHistory.fromJson);
}

/// Special assignments: `api.duties_special_assignments` (the current
/// Pastors only; the server decides).
class SupabaseDutySpecialRepository implements DutySpecialRepository {
  SupabaseDutySpecialRepository(
    SupabaseClient client, {
    Duration timeout = const Duration(seconds: 10),
  }) : _reader = SupabaseApiReader(client, timeout: timeout);

  final SupabaseApiReader _reader;

  @override
  Future<AccessRead<SpecialAssignments>> fetchSpecialAssignments() =>
      _reader.read(
        'duties_special_assignments',
        const {},
        SpecialAssignments.fromJson,
      );
}

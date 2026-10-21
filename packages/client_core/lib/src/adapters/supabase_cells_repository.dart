import 'package:supabase/supabase.dart';

import '../domain/access_grants.dart';
import '../domain/cell_meetings.dart';
import '../domain/cell_membership.dart';
import '../domain/cell_programmes.dart';
import 'supabase_api_reader.dart';

/// Supabase adapter for [CellsRepository] (story 2.6): the member's own cell
/// (`api.cells_my_cell`), the leader queue (`api.cells_leader_queue`) and
/// the Admin overview (`api.cells_admin_overview`). The server checks live
/// access and the current grants on every call; this adapter only maps the
/// answer.
class SupabaseCellsRepository implements CellsRepository {
  SupabaseCellsRepository(
    SupabaseClient client, {
    Duration timeout = const Duration(seconds: 10),
  }) : _reader = SupabaseApiReader(client, timeout: timeout);

  final SupabaseApiReader _reader;

  @override
  Future<AccessRead<MyCell>> fetchMyCell() =>
      _reader.read('cells_my_cell', const {}, MyCell.fromJson);

  @override
  Future<AccessRead<LeaderQueue>> fetchLeaderQueue() =>
      _reader.read('cells_leader_queue', const {}, LeaderQueue.fromJson);

  @override
  Future<AccessRead<CellAdminOverview>> fetchAdminOverview() => _reader.read(
    'cells_admin_overview',
    const {},
    CellAdminOverview.fromJson,
  );

  /// Story 5.1: `api.cells_meetings` (leaders, assistants and Admin).
  @override
  Future<AccessRead<CellMeetingsBoard>> fetchMeetings() =>
      _reader.read('cells_meetings', const {}, CellMeetingsBoard.fromJson);

  /// Story 5.3: `api.cells_programme` (the cell's leader and assistant,
  /// Pastor oversight; counts only for an Admin-only reader).
  @override
  Future<AccessRead<ProgrammeRead>> fetchProgramme(String meetingId) =>
      _reader.read('cells_programme', {
        'meeting_id': meetingId,
      }, ProgrammeRead.fromJson);

  /// Story 5.4: `api.cells_meeting_programme` (current confirmed members of
  /// the meeting's cell).
  @override
  Future<AccessRead<MeetingProgrammeRead>> fetchMeetingProgramme(
    String meetingId,
  ) => _reader.read('cells_meeting_programme', {
    'meeting_id': meetingId,
  }, MeetingProgrammeRead.fromJson);
}

import 'package:supabase/supabase.dart';

import '../domain/access_grants.dart';
import '../domain/calendar_overlays.dart';
import 'supabase_api_reader.dart';

/// Supabase adapter for [CellCalendarRepository] (epic 6 entry 19): the
/// member's own cell meetings for the Calendar overlay
/// (`api.cells_my_meetings`). The server checks live access and the
/// member's confirmed cell on every call; this adapter only maps the answer.
class SupabaseCellCalendarRepository implements CellCalendarRepository {
  SupabaseCellCalendarRepository(
    SupabaseClient client, {
    Duration timeout = const Duration(seconds: 10),
  }) : _reader = SupabaseApiReader(client, timeout: timeout);

  final SupabaseApiReader _reader;

  @override
  Future<AccessRead<MyCellMeetingsWindow>> fetchMyMeetings() => _reader.read(
    'cells_my_meetings',
    const {},
    MyCellMeetingsWindow.fromJson,
  );
}

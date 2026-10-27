import 'package:supabase/supabase.dart';

import '../domain/access_grants.dart';
import '../domain/content_events.dart';
import 'supabase_api_reader.dart';

/// Supabase adapter for [ContentRepository] (story 6.1): the public event
/// reads (`api.content_public_events`, `api.content_public_event`), which
/// answer signed-out callers too, and the editors' read
/// (`api.content_staff_events`), which the server checks against the
/// caller's live access and roles on every call; story 6.11 adds the
/// member's own RSVP and the organisers' names read. This adapter only maps
/// the answer.
class SupabaseContentRepository implements ContentRepository {
  SupabaseContentRepository(
    SupabaseClient client, {
    Duration timeout = const Duration(seconds: 10),
  }) : _reader = SupabaseApiReader(client, timeout: timeout);

  final SupabaseApiReader _reader;

  @override
  Future<AccessRead<PublicEvents>> fetchPublicEvents() => _reader.read(
    'content_public_events',
    const {},
    PublicEvents.fromJson,
    public: true,
  );

  @override
  Future<AccessRead<PublicEventRead>> fetchPublicEvent(String eventId) =>
      _reader.read(
        'content_public_event',
        {'event_id': eventId},
        PublicEventRead.fromJson,
        public: true,
      );

  @override
  Future<AccessRead<StaffEvents>> fetchStaffEvents() =>
      _reader.read('content_staff_events', const {}, StaffEvents.fromJson);

  /// Story 6.11: the caller's own RSVP (live member access; signed out is
  /// answered locally as a denial).
  @override
  Future<AccessRead<MyEventRsvp>> fetchMyEventRsvp(String eventId) =>
      _reader.read('content_my_event_rsvp', {
        'event_id': eventId,
      }, MyEventRsvp.fromJson);

  /// Story 6.11: who is going (an Admin or one of the event's organisers).
  @override
  Future<AccessRead<StaffEventRsvpsRead>> fetchStaffEventRsvps(
    String eventId,
  ) => _reader.read('content_staff_event_rsvps', {
    'event_id': eventId,
  }, StaffEventRsvpsRead.fromJson);
}

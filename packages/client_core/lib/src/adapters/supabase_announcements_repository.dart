import 'package:supabase/supabase.dart';

import '../domain/access_grants.dart';
import '../domain/content_announcements.dart';
import 'supabase_api_reader.dart';

/// Supabase adapter for [AnnouncementsRepository] (story 6.13): the public
/// announcement reads (`api.content_public_announcements`,
/// `api.content_public_announcement`), which answer signed-out callers too,
/// and the editors' read (`api.content_staff_announcements`), which the
/// server checks against the caller's live access and roles on every call.
/// This adapter only maps the answer.
class SupabaseAnnouncementsRepository implements AnnouncementsRepository {
  SupabaseAnnouncementsRepository(
    SupabaseClient client, {
    Duration timeout = const Duration(seconds: 10),
  }) : _reader = SupabaseApiReader(client, timeout: timeout);

  final SupabaseApiReader _reader;

  @override
  Future<AccessRead<PublicAnnouncements>> fetchPublicAnnouncements() =>
      _reader.read(
        'content_public_announcements',
        const {},
        PublicAnnouncements.fromJson,
        public: true,
      );

  @override
  Future<AccessRead<PublicAnnouncementRead>> fetchPublicAnnouncement(
    String announcementId,
  ) => _reader.read(
    'content_public_announcement',
    {'announcement_id': announcementId},
    PublicAnnouncementRead.fromJson,
    public: true,
  );

  @override
  Future<AccessRead<StaffAnnouncements>> fetchStaffAnnouncements() =>
      _reader.read(
        'content_staff_announcements',
        const {},
        StaffAnnouncements.fromJson,
      );
}

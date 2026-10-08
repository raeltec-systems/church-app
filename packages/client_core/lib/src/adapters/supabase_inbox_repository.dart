import 'package:supabase/supabase.dart';

import '../domain/access_grants.dart';
import '../domain/inbox.dart';
import 'supabase_api_reader.dart';

/// Supabase adapter for [InboxRepository] (story 3.1):
/// `api.notifications_my_inbox`. The server decides; this only maps the
/// answer.
class SupabaseInboxRepository implements InboxRepository {
  SupabaseInboxRepository(
    SupabaseClient client, {
    Duration timeout = const Duration(seconds: 10),
  }) : _reader = SupabaseApiReader(client, timeout: timeout);

  final SupabaseApiReader _reader;

  @override
  Future<AccessRead<Inbox>> fetchMyInbox() =>
      _reader.read('notifications_my_inbox', const {}, Inbox.fromJson);
}

import 'package:supabase/supabase.dart';

import '../domain/access_grants.dart';
import '../domain/inbox.dart';
import 'supabase_api_reader.dart';

/// Supabase adapter for [InboxRepository]: `api.notifications_my_inbox`
/// (story 3.1) and `api.notifications_open_item` (story 3.2). The server
/// decides; this only maps the answer.
class SupabaseInboxRepository implements InboxRepository {
  SupabaseInboxRepository(
    SupabaseClient client, {
    Duration timeout = const Duration(seconds: 10),
  }) : _reader = SupabaseApiReader(client, timeout: timeout);

  final SupabaseApiReader _reader;

  @override
  Future<AccessRead<Inbox>> fetchMyInbox({InboxCursor? after}) => _reader.read(
    'notifications_my_inbox',
    after?.toParams() ?? const {},
    Inbox.fromJson,
  );

  @override
  Future<AccessRead<OpenedInboxItem>> openItem(String itemId) => _reader.read(
    'notifications_open_item',
    {'item_id': itemId},
    OpenedInboxItem.fromJson,
  );
}

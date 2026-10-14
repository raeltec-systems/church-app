import 'package:supabase/supabase.dart';

import '../domain/access_grants.dart';
import '../domain/notification_health.dart';
import 'supabase_api_reader.dart';

class SupabaseNotificationHealthRepository implements NotificationHealthRepository {
  SupabaseNotificationHealthRepository(SupabaseClient client,
      {Duration timeout = const Duration(seconds: 10)})
      : _reader = SupabaseApiReader(client, timeout: timeout);

  final SupabaseApiReader _reader;

  @override
  Future<AccessRead<ReminderHealth>> fetchHealth() =>
      _reader.read('notifications_health', const {}, ReminderHealth.fromJson);
}

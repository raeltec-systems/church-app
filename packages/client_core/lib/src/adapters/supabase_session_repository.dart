import 'package:supabase/supabase.dart';

import '../domain/session.dart';

/// Supabase Auth adapter for [SessionRepository]. Observes only; sign-in
/// goes through SupabaseAccountAuthGateway (story 2.1).
class SupabaseSessionRepository implements SessionRepository {
  SupabaseSessionRepository(this._client);

  final SupabaseClient _client;

  @override
  String? get currentAccountId => _client.auth.currentUser?.id;

  @override
  Stream<String?> get accountChanges =>
      _client.auth.onAuthStateChange.map((s) => s.session?.user.id).distinct();
}

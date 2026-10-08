import 'dart:async';

import 'package:supabase/supabase.dart';

import '../domain/access_grants.dart';
import '../domain/notification_settings.dart';
import 'supabase_api_reader.dart';

/// Supabase adapter for [NotificationSettingsRepository]:
/// `api.notifications_my_push_settings` (story 3.5). Only maps the answer.
class SupabaseNotificationSettingsRepository
    implements NotificationSettingsRepository {
  SupabaseNotificationSettingsRepository(
    SupabaseClient client, {
    Duration timeout = const Duration(seconds: 10),
  }) : _reader = SupabaseApiReader(client, timeout: timeout);

  final SupabaseApiReader _reader;

  @override
  Future<AccessRead<NotificationSettings>> fetchMySettings() => _reader.read(
    'notifications_my_push_settings',
    const {},
    NotificationSettings.fromJson,
  );
}

/// Supabase adapter for [InboxSignals]: a PRIVATE Realtime Broadcast channel
/// `account:<auth user id>`, event `inbox_changed` (story 3.7). The server's
/// RLS policy admits only the account's own session to its topic, and the
/// payload is always `{}`: nothing from it is read. Each (re)join emits too,
/// so a signal missed while disconnected still causes a fresh read. When
/// Realtime is unavailable nothing is emitted and the inbox relies on its
/// other re-reads (open, resume, pull to refresh, polling).
class SupabaseInboxSignals implements InboxSignals {
  SupabaseInboxSignals(this._client);

  final SupabaseClient _client;

  @override
  Stream<void> changes(String accountId) {
    late final StreamController<void> out;
    RealtimeChannel? channel;
    void emit() {
      if (!out.isClosed) out.add(null);
    }

    out = StreamController<void>(
      onListen: () {
        channel = _client
            .channel(
              'account:$accountId',
              opts: const RealtimeChannelConfig(private: true),
            )
            .onBroadcast(event: 'inbox_changed', callback: (_) => emit())
            .subscribe((status, _) {
              if (status == RealtimeSubscribeStatus.subscribed) emit();
            });
      },
      onCancel: () async {
        final c = channel;
        channel = null;
        if (c == null) return;
        try {
          await _client.removeChannel(c);
        } catch (_) {
          // Leaving a channel that never joined: nothing to undo.
        }
      },
    );
    return out.stream;
  }
}

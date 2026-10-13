import 'package:church_client_core/church_client_core.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('parses the content-free health projection and optional times', () {
    final health = ReminderHealth.fromJson({
      'captured_at': '2026-10-13T12:00:00Z',
      'scheduler': {
        'jobs': 1,
        'cron_runs_24h': {'succeeded': 4},
        'stale': false,
        'last_tick_at': '2026-10-13T11:59:00Z',
        'last_tick_outcome': 'sent',
        'last_success_at': '2026-10-13T11:59:00Z',
      },
      'jobs': {
        'due_pending': 2,
        'oldest_due_at': '2026-10-13T11:30:00Z',
        'leased': 1,
        'failed_attempts_24h': 3,
        'lapsed_leases_24h': 1,
      },
      'push': {
        'enabled': true,
        'outbound_open': false,
        'pending': 5,
        'leased': 0,
        'failed_attempts_24h': 2,
      },
      'tokens': {
        'retired': 4,
        'retired_24h': 1,
        'last_retired_at': '2026-10-13T10:00:00Z',
      },
      'direct_contact': {'backlog': 6, 'oldest_due_at': null},
    });

    expect(health.capturedAt, DateTime.utc(2026, 10, 13, 12));
    expect(health.scheduler.lastSuccessAt, DateTime.utc(2026, 10, 13, 11, 59));
    expect(health.jobs.duePending, 2);
    expect(health.push.outboundOpen, isFalse);
    expect(health.tokens.retired, 4);
    expect(health.directContact.backlog, 6);
    expect(health.directContact.oldestDueAt, isNull);
  });

  test('rejects malformed or negative aggregate data', () {
    expect(() => ReminderHealth.fromJson(null), throwsFormatException);
    expect(
      () => ReminderHealth.fromJson({
        'captured_at': '2026-10-13T12:00:00Z',
        'scheduler': {'jobs': -1},
        'jobs': {},
        'push': {},
        'tokens': {},
        'direct_contact': {},
      }),
      throwsFormatException,
    );
  });
}

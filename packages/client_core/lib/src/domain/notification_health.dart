/// Content-free worker and reminder health shared by staff web clients.
library;

import 'access_grants.dart';

class ReminderHealth {
  const ReminderHealth({
    required this.capturedAt,
    required this.scheduler,
    required this.jobs,
    required this.push,
    required this.tokens,
    required this.directContact,
  });

  factory ReminderHealth.fromJson(Object? value) {
    if (value is! Map<String, dynamic>) {
      throw const FormatException('unexpected reminder health');
    }
    return ReminderHealth(
      capturedAt: _date(value['captured_at']),
      scheduler: SchedulerHealth.fromJson(value['scheduler']),
      jobs: JobHealth.fromJson(value['jobs']),
      push: PushHealth.fromJson(value['push']),
      tokens: TokenHealth.fromJson(value['tokens']),
      directContact: DirectContactHealth.fromJson(value['direct_contact']),
    );
  }

  final DateTime capturedAt;
  final SchedulerHealth scheduler;
  final JobHealth jobs;
  final PushHealth push;
  final TokenHealth tokens;
  final DirectContactHealth directContact;
  bool get stale => scheduler.stale;
  bool get empty => scheduler.jobs == 0 && scheduler.lastSuccessAt == null &&
      jobs.duePending == 0 && jobs.leased == 0 && jobs.failedAttempts24h == 0 &&
      jobs.lapsedLeases24h == 0 && push.pending == 0 && push.leased == 0 &&
      push.failedAttempts24h == 0 && tokens.retired == 0 && directContact.backlog == 0;
}

class SchedulerHealth {
  const SchedulerHealth({required this.jobs, required this.cronRuns24h,
    required this.stale, this.lastTickAt, this.lastTickOutcome, this.lastSuccessAt});
  factory SchedulerHealth.fromJson(Object? value) {
    final m = _map(value);
    return SchedulerHealth(
      jobs: _int(m['jobs']),
      cronRuns24h: _counts(m['cron_runs_24h']),
      stale: m['stale'] == true,
      lastTickAt: _optionalDate(m['last_tick_at']),
      lastTickOutcome: m['last_tick_outcome'] as String?,
      lastSuccessAt: _optionalDate(m['last_success_at']),
    );
  }
  final int jobs;
  final Map<String, int> cronRuns24h;
  final bool stale;
  final DateTime? lastTickAt;
  final String? lastTickOutcome;
  final DateTime? lastSuccessAt;
}

class JobHealth {
  const JobHealth({required this.duePending, required this.leased,
    required this.failedAttempts24h, required this.lapsedLeases24h, this.oldestDueAt});
  factory JobHealth.fromJson(Object? value) {
    final m = _map(value);
    return JobHealth(duePending: _int(m['due_pending']), leased: _int(m['leased']),
      failedAttempts24h: _int(m['failed_attempts_24h']),
      lapsedLeases24h: _int(m['lapsed_leases_24h']), oldestDueAt: _optionalDate(m['oldest_due_at']));
  }
  final int duePending, leased, failedAttempts24h, lapsedLeases24h;
  final DateTime? oldestDueAt;
}

class PushHealth {
  const PushHealth({required this.enabled, required this.pending, required this.leased,
    required this.failedAttempts24h, required this.outboundOpen});
  factory PushHealth.fromJson(Object? value) {
    final m = _map(value);
    return PushHealth(enabled: m['enabled'] == true, pending: _int(m['pending']),
      leased: _int(m['leased']), failedAttempts24h: _int(m['failed_attempts_24h']),
      outboundOpen: m['outbound_open'] == true);
  }
  final bool enabled, outboundOpen;
  final int pending, leased, failedAttempts24h;
}

class TokenHealth {
  const TokenHealth({required this.retired, required this.retired24h, this.lastRetiredAt});
  factory TokenHealth.fromJson(Object? value) {
    final m = _map(value);
    return TokenHealth(retired: _int(m['retired']), retired24h: _int(m['retired_24h']),
      lastRetiredAt: _optionalDate(m['last_retired_at']));
  }
  final int retired, retired24h;
  final DateTime? lastRetiredAt;
}

class DirectContactHealth {
  const DirectContactHealth({required this.backlog, this.oldestDueAt});
  factory DirectContactHealth.fromJson(Object? value) {
    final m = _map(value);
    return DirectContactHealth(backlog: _int(m['backlog']), oldestDueAt: _optionalDate(m['oldest_due_at']));
  }
  final int backlog;
  final DateTime? oldestDueAt;
}

abstract interface class NotificationHealthRepository {
  Future<AccessRead<ReminderHealth>> fetchHealth();
}

class UnconfiguredNotificationHealthRepository implements NotificationHealthRepository {
  const UnconfiguredNotificationHealthRepository();
  @override
  Future<AccessRead<ReminderHealth>> fetchHealth() async =>
      const AccessReadDenied(AccessDenial.unavailable);
}

Map<String, dynamic> _map(Object? value) => value is Map<String, dynamic>
    ? value : throw const FormatException('unexpected reminder health section');
int _int(Object? value) => value is int && value >= 0
    ? value : throw const FormatException('unexpected reminder health count');
Map<String, int> _counts(Object? value) {
  final m = _map(value);
  return Map.unmodifiable(m.map((key, value) => MapEntry(key, _int(value))));
}
DateTime _date(Object? value) => _optionalDate(value)
    ?? (throw const FormatException('missing reminder health timestamp'));
DateTime? _optionalDate(Object? value) => value == null
    ? null : value is String ? DateTime.tryParse(value) : null;

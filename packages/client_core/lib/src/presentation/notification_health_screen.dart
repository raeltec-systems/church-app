import 'package:church_design_system/church_design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../application/notification_health_controllers.dart';
import '../domain/access_grants.dart';

class NotificationHealthScreen extends ConsumerWidget {
  const NotificationHealthScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(notificationHealthProvider);
    final health = state.health;
    final layout = ChurchLayout.of(context);
    final children = <Widget>[
      const Text('Reminder delivery health. Counts and times only; no reminder content or recipient details.'),
      const SizedBox(height: 16),
    ];
    if (state.result == null) {
      children.add(const RequestStateBanner(
        key: Key('notification-health-loading'), tone: StatusTone.info, busy: true,
        title: 'Loading reminder health…', message: 'The server checks staff access every time.'));
    } else if (health == null) {
      final denied = state.result is AccessReadDenied;
      children.add(RequestStateBanner(
        key: const Key('notification-health-unavailable'),
        tone: denied ? StatusTone.warning : StatusTone.danger,
        title: denied ? 'Reminder health unavailable' : 'Couldn’t check reminder health',
        message: denied
            ? 'This account is not authorized to view reminder health.'
            : 'The health read failed. Try again.',
      ));
    } else {
      if (health.empty) {
        children.add(const RequestStateBanner(
          key: Key('notification-health-empty'),
          tone: StatusTone.neutral,
          title: 'No reminder activity recorded',
          message: 'Worker and reminder counts are currently zero.',
        ));
      }
      if (health.stale) {
        children.add(const RequestStateBanner(
          key: Key('notification-health-stale'),
          tone: StatusTone.warning,
          title: 'Scheduler status may be stale',
          message: 'No scheduler tick was recorded in the last five minutes.',
        ));
      }
      children.addAll([
      _section('Scheduler', [
        _row('Last tick', _time(health.scheduler.lastTickAt)),
        _row('Last tick outcome', health.scheduler.lastTickOutcome ?? 'Not recorded'),
        _row('Last successful scheduler handoff', _time(health.scheduler.lastSuccessAt)),
        _row('Scheduled jobs', '${health.scheduler.jobs}'),
        _row('Cron runs in 24 hours', _counts(health.scheduler.cronRuns24h)),
      ]),
      _section('Reminder jobs', [
        _row('Due and pending', '${health.jobs.duePending}'),
        _row('Oldest due time', _time(health.jobs.oldestDueAt)),
        _row('Active leases', '${health.jobs.leased}'),
        _row('Failed attempts in 24 hours', '${health.jobs.failedAttempts24h}'),
        _row('Lapsed leases in 24 hours', '${health.jobs.lapsedLeases24h}'),
      ]),
      _section('Push', [
        _row('Sending enabled', health.push.enabled ? 'Yes' : 'No'),
        _row('Outbound gate', health.push.outboundOpen ? 'Open' : 'Closed'),
        _row('Pending push jobs', '${health.push.pending}'),
        _row('Active push leases', '${health.push.leased}'),
        _row('Transient failures in 24 hours', '${health.push.failedAttempts24h}'),
        _row('Retired device tokens', '${health.tokens.retired}'),
        _row('Retired tokens in 24 hours', '${health.tokens.retired24h}'),
        _row('Most recent token retirement', _time(health.tokens.lastRetiredAt)),
      ]),
      _section('Direct contact', [
        _row('Backlog', '${health.directContact.backlog}'),
        _row('Oldest due time', _time(health.directContact.oldestDueAt)),
      ]),
      Text('Snapshot: ${_time(health.capturedAt)}', key: const Key('notification-health-captured')),
      ]);
    }
    children.add(const SizedBox(height: 16));
    children.add(FocusRing(child: OutlinedButton.icon(
      key: const Key('refresh-notification-health'),
      onPressed: state.loading ? null : () => ref.read(notificationHealthProvider.notifier).refresh(),
      icon: const Icon(Icons.refresh), label: const Text('Check again'))));
    return Scaffold(
      appBar: AppBar(title: const Text('Reminder health')),
      body: SafeArea(child: SingleChildScrollView(
        padding: layout.pagePadding,
        child: Center(child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: layout.contentMaxWidth),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
        )),
      )),
    );
  }

  static Widget _section(String title, List<Widget> rows) => Padding(
    padding: const EdgeInsets.only(bottom: 20),
    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Semantics(header: true, child: Text(title, style: ChurchType.cardTitle)),
      const SizedBox(height: 8), ...rows,
    ]),
  );

  static Widget _row(String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Expanded(child: Text(label)), const SizedBox(width: 12),
      Flexible(child: Text(value, textAlign: TextAlign.end)),
    ]),
  );

  static String _time(DateTime? value) => value?.toUtc().toIso8601String() ?? 'Not recorded';
  static String _counts(Map<String, int> values) => values.isEmpty
      ? 'None recorded' : (values.entries.toList()..sort((a, b) => a.key.compareTo(b.key)))
          .map((entry) => '${entry.key}: ${entry.value}').join(', ');
}

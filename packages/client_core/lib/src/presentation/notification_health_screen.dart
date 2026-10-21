import 'package:church_design_system/church_design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../application/notification_health_controllers.dart';
import '../domain/access_grants.dart';
import '../domain/notification_health.dart';

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
      children.add(_refusal(state.result!));
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
          message: 'No successful scheduler hand-off was recorded in the last five minutes.',
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
        _row('Failed push attempts in 24 hours', '${health.push.failedAttempts24h}'),
        _row('Retired device tokens', '${health.tokens.retired}'),
        _row('Retired tokens in 24 hours', '${health.tokens.retired24h}'),
        _row('Most recent token retirement', _time(health.tokens.lastRetiredAt)),
      ]),
      _section('Direct contact', [
        _row('Without a route in 24 hours', '${health.directContact.backlog}'),
        _row('Oldest due time', _time(health.directContact.oldestDueAt)),
        _row('Routed in 24 hours', '${health.directContact.routed24h}'),
        _row('Without a route, all time', '${health.directContact.totalUnrouted}'),
        _row('All direct-contact needs', '${health.directContact.total}'),
      ]),
      Text('Snapshot: ${_time(health.capturedAt)}', key: const Key('notification-health-captured')),
      ]);
    }
    children.add(const SizedBox(height: 16));
    children.add(FocusRing(child: OutlinedButton.icon(
      key: const Key('refresh-notification-health'),
      onPressed: state.loading ? null : () => ref.read(notificationHealthProvider.notifier).refresh(),
      icon: const Icon(Icons.refresh), label: const Text('Check again'))));
    return ChurchPageScaffold(
      title: 'Reminder health',
      body: SafeArea(child: SingleChildScrollView(
        padding: layout.pagePadding,
        child: Center(child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: layout.contentMaxWidth),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
        )),
      )),
    );
  }

  /// One banner per refusal reason (review 3.8-3.10, finding 12).
  static Widget _refusal(AccessRead<ReminderHealth> result) => switch (result) {
    AccessReadDenied(:final denial) => RequestStateBanner(
      key: Key('notification-health-denied-${denial.name}'),
      tone: switch (denial) {
        AccessDenial.untrustedSession || AccessDenial.reviewRequired => StatusTone.warning,
        AccessDenial.signedOut => StatusTone.info,
        _ => StatusTone.neutral,
      },
      title: switch (denial) {
        AccessDenial.signedOut => 'Not signed in',
        AccessDenial.untrustedSession => 'Please sign in again',
        AccessDenial.reviewRequired => 'Access review required',
        AccessDenial.unavailable => 'Reminder health not available here',
        AccessDenial.notLinked || AccessDenial.notGranted => 'Reminder health unavailable',
      },
      message: switch (denial) {
        AccessDenial.signedOut => 'Sign in to view reminder health.',
        AccessDenial.untrustedSession => 'This sign-in is no longer valid.',
        AccessDenial.reviewRequired =>
          'Your access needs a check by the church before it can continue.',
        AccessDenial.unavailable => 'The server does not offer reminder health here yet.',
        AccessDenial.notLinked || AccessDenial.notGranted =>
          'This account is not authorized to view reminder health.',
      },
    ),
    AccessReadFailed(:final unreachable) => RequestStateBanner(
      key: const Key('notification-health-failed'),
      tone: StatusTone.danger,
      title: unreachable ? 'No connection' : 'Couldn’t check reminder health',
      message: unreachable
          ? 'The server could not be reached. Try again.'
          : 'The health read failed. Try again.',
    ),
    AccessReadOk() => const SizedBox.shrink(),
  };

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

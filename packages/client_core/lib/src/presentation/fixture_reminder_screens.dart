import 'package:church_design_system/church_design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../application/fixture_reminder_controller.dart';
import 'shell_routing.dart';

/// Story 3.7, SYNTHETIC (local and staging only; production refuses every
/// fixture command): test reminders for the signed-in member, so the inbox,
/// snooze and notification settings can be tried on a real phone.
/// `/fixture/reminders` creates them; `/fixture/reminders/<id>` is where a
/// test reminder's **Open** leads (the fixture contract's registered link),
/// with **Answer** and **Cancel**. Nothing here is real church data.
class FixtureRemindersScreen extends ConsumerWidget {
  const FixtureRemindersScreen({super.key, this.sourceId});

  /// The test source a reminder's link opened, if any.
  final String? sourceId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = ChurchColors.of(context);
    final layout = ChurchLayout.of(context);
    final s = ref.watch(fixtureReminderProvider(sourceId));
    final controller = ref.read(fixtureReminderProvider(sourceId).notifier);
    final busy = s.busy != null;
    final source = s.source;
    final children = <Widget>[
      const RequestStateBanner(
        key: Key('fixture-reminders-synthetic'),
        tone: StatusTone.warning,
        icon: Icons.science_outlined,
        title: 'SYNTHETIC test reminders',
        message:
            'For testing only, on test servers. They are sent to you, and '
            'reach your Inbox within about a minute.',
      ),
      const SizedBox(height: ChurchGeometry.sectionGap),
    ];
    if (sourceId == null) {
      children.addAll([
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            FocusRing(
              child: FilledButton.icon(
                key: const Key('fixture-reminder-create-due'),
                onPressed: busy ? null : controller.createDueNow,
                icon: const Icon(Icons.notification_add_outlined),
                label: const Text('Send me a test reminder'),
              ),
            ),
            FocusRing(
              child: OutlinedButton.icon(
                key: const Key('fixture-reminder-create-request'),
                onPressed: busy ? null : controller.createRequest,
                icon: const Icon(Icons.event_outlined),
                label: const Text('Send me a test request (starts in 20 h)'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          'A test request asks for an answer before it starts in 20 hours: '
          'snoozing its reminder for 2 days brings it back at the start '
          'instead. Answering or cancelling it ends any snooze.',
          style: ChurchType.secondary.copyWith(color: c.muted),
        ),
      ]);
    } else {
      children.add(
        Semantics(
          header: true,
          child: Text(
            'SYNTHETIC test source',
            key: const Key('fixture-reminder-source'),
            style: ChurchType.cardTitle.copyWith(color: c.ink),
          ),
        ),
      );
    }
    if (source != null) {
      children.addAll([
        const SizedBox(height: ChurchGeometry.sectionGap),
        Text(switch (source.kind) {
          'fixture_reply' => 'Last test request',
          'fixture_due' => 'Last test reminder',
          _ => 'This test source',
        }, style: ChurchType.cardTitle.copyWith(color: c.ink)),
        if (source.state == 'cancelled') const Text('Cancelled.'),
        const SizedBox(height: 8),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            if (source.kind != 'fixture_due')
              FocusRing(
                child: OutlinedButton.icon(
                  key: const Key('fixture-reminder-respond'),
                  onPressed: busy ? null : controller.respond,
                  icon: const Icon(Icons.reply),
                  label: const Text('Answer it'),
                ),
              ),
            FocusRing(
              child: OutlinedButton.icon(
                key: const Key('fixture-reminder-cancel'),
                onPressed: busy ? null : controller.cancel,
                icon: const Icon(Icons.cancel_outlined),
                label: const Text('Cancel it'),
              ),
            ),
          ],
        ),
      ]);
    }
    if (busy) {
      children.addAll([
        const SizedBox(height: 12),
        const RequestStateBanner(
          key: Key('fixture-reminder-busy'),
          tone: StatusTone.info,
          busy: true,
          title: 'Sending…',
          message: 'Waiting for the server.',
        ),
      ]);
    } else if (s.outcome != null) {
      children.addAll([
        const SizedBox(height: 12),
        _outcomeBanner(s, controller.retry),
      ]);
    }
    children.addAll([
      const SizedBox(height: ChurchGeometry.sectionGap),
      Align(
        alignment: AlignmentDirectional.centerStart,
        child: FocusRing(
          child: OutlinedButton.icon(
            key: const Key('fixture-reminders-to-inbox'),
            onPressed: () => context.go(ClientPaths.inbox),
            icon: const Icon(Icons.inbox_outlined),
            label: const Text('Go to inbox'),
          ),
        ),
      ),
    ]);
    return Scaffold(
      appBar: AppBar(title: const Text('Test reminders')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: layout.pagePadding,
          child: Center(
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: layout.contentMaxWidth),
              child: DefaultTextStyle.merge(
                style: layout.body.copyWith(color: c.ink),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: children,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

Widget _outcomeBanner(FixtureReminderState s, VoidCallback retry) {
  final what = switch (s.lastAction) {
    FixtureReminderAction.createDue => 'Test reminder created',
    FixtureReminderAction.createRequest => 'Test request created',
    FixtureReminderAction.respond => 'Answered',
    FixtureReminderAction.cancel => 'Cancelled',
    null => 'Done',
  };
  return switch (s.outcome!) {
    FixtureReminderOutcome.done => RequestStateBanner(
      key: const Key('fixture-reminder-done'),
      tone: StatusTone.success,
      icon: Icons.check_circle_outline,
      title: what,
      message: switch (s.lastAction) {
        FixtureReminderAction.createDue ||
        FixtureReminderAction.createRequest =>
          'It reaches your Inbox within about a minute.',
        _ =>
          'Any snooze of its reminder has ended; the reminder now opens '
              'as out of date.',
      },
    ),
    FixtureReminderOutcome.changed => const RequestStateBanner(
      key: Key('fixture-reminder-changed'),
      tone: StatusTone.warning,
      icon: Icons.sync_problem,
      title: 'It changed first',
      message: 'Nothing was done. Try again to act on its latest version.',
    ),
    FixtureReminderOutcome.closed => const RequestStateBanner(
      key: Key('fixture-reminder-closed'),
      tone: StatusTone.neutral,
      icon: Icons.info_outline,
      title: 'Already answered or cancelled',
      message: 'Nothing more to do.',
    ),
    FixtureReminderOutcome.noAnswerNeeded => const RequestStateBanner(
      key: Key('fixture-reminder-no-answer'),
      tone: StatusTone.neutral,
      icon: Icons.info_outline,
      title: 'Nothing to answer',
      message: 'A plain test reminder needs no answer. You can cancel it.',
    ),
    FixtureReminderOutcome.refused => RequestStateBanner(
      key: const Key('fixture-reminder-refused'),
      tone: StatusTone.danger,
      icon: Icons.error_outline,
      title: 'Refused (${s.refusal ?? 'error'})',
      message:
          'Nothing was done. Test reminders work for a signed-in member on '
          'a test server only.',
    ),
    FixtureReminderOutcome.unknown => RequestStateBanner(
      key: const Key('fixture-reminder-unknown'),
      tone: StatusTone.danger,
      icon: Icons.help_outline,
      title: 'No answer from the server',
      message: 'Try again: it sends the same request.',
      actions: [
        BannerAction(
          'Try again',
          retry,
          key: const Key('fixture-reminder-retry'),
          primary: true,
        ),
      ],
    ),
    FixtureReminderOutcome.notSent => const RequestStateBanner(
      key: Key('fixture-reminder-not-sent'),
      tone: StatusTone.neutral,
      icon: Icons.cloud_off_outlined,
      title: 'Not sent',
      message: 'This build has no server configured.',
    ),
  };
}

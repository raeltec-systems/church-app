import 'dart:math';

import 'package:church_design_system/church_design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show ProviderListenable;
import 'package:go_router/go_router.dart';

import '../application/followups_controllers.dart';
import '../domain/access_grants.dart';
import '../domain/church_time.dart';
import '../domain/commands.dart' show SecureRequestIds;
import '../domain/followups.dart';

// Story 4.6: follow-up tasks. My follow-ups for every owner (the mobile Home
// card and list, a staff web sidebar entry), one task with its activity and
// private notes, the scope holders' supervision screen (create SYNTHETIC
// tasks, reassign, record updates for owners without a login) and the Admin
// routing view (metadata only). Every list comes from a server-checked read
// and every action is a server-checked command; hiding a button is never the
// control. A change shows as done only after the server confirmed it.

/// The follow-up routes (shared by both shells' router).
abstract final class FollowUpPaths {
  /// My follow-ups: the signed-in member's own tasks.
  static const mine = '/followups';

  /// One task.
  static String task(String taskId) => '/followups/tasks/$taskId';

  /// Staff web: the tasks in the scopes the caller holds.
  static const supervision = '/followups/supervision';

  /// Staff web, Admin only: routing metadata of every task.
  static const adminRouting = '/admin/followups';
}

(StatusTone, String, String) _noticeText(
  FollowUpNotice n,
  FollowUpAction? a,
  Map<String, String> fieldErrors,
) {
  final what = a?.subject ?? 'this task';
  return switch (n) {
    FollowUpNotice.created => (
      StatusTone.success,
      'Task created',
      '$what now has an owner, a next action and a due date. The owner sees '
          'it in My follow-ups.',
    ),
    FollowUpNotice.updated => (
      StatusTone.success,
      'Saved',
      'The update to $what was recorded.',
    ),
    FollowUpNotice.reassigned => (
      StatusTone.success,
      'Reassigned',
      '$what was moved. The new owner sees it in My follow-ups.',
    ),
    FollowUpNotice.handoverContinued => (
      StatusTone.success,
      'Handed over',
      'Open tasks of $what went to someone in each task\'s group. Anything '
          'still waiting stays listed.',
    ),
    FollowUpNotice.handoverNoneMoved => (
      StatusTone.warning,
      'Nobody could take them',
      'No one the app can reach may take what $what had. It stays listed: '
          'give the group a leader or reassign the tasks one by one.',
    ),
    FollowUpNotice.changedElsewhere => (
      StatusTone.warning,
      'Changed elsewhere',
      'This task was changed in another tab or by someone else. It was '
          'reloaded; check it and try again.',
    ),
    FollowUpNotice.finished => (
      StatusTone.neutral,
      'Already finished',
      'This task is Done or Closed, so it can no longer change.',
    ),
    FollowUpNotice.taskExists => (
      StatusTone.warning,
      'Already has a task',
      'There is already a task for that source and purpose.',
    ),
    FollowUpNotice.invalid => (
      StatusTone.danger,
      'Check the form',
      _invalidText(fieldErrors),
    ),
    FollowUpNotice.notAllowed => (
      StatusTone.warning,
      'Not allowed',
      'Your account cannot do this now. Nothing was changed.',
    ),
    FollowUpNotice.signInAgain => (
      StatusTone.warning,
      'Please sign in again',
      'This sign-in is no longer valid. Nothing was changed.',
    ),
    FollowUpNotice.notFound => (
      StatusTone.neutral,
      'Not found',
      'That task or person is not available to you. The list was reloaded.',
    ),
    FollowUpNotice.notAvailable => (
      StatusTone.neutral,
      'Not available yet',
      'Follow-ups cannot be changed here right now. Nothing was changed.',
    ),
    FollowUpNotice.refused => (
      StatusTone.warning,
      'Not changed',
      'The server refused the change. The list was reloaded.',
    ),
    FollowUpNotice.unconfirmed => (
      StatusTone.warning,
      'Not sent yet',
      'We don\'t know whether the change to $what reached the church server, '
          'so nothing is shown as done. Check again: the same request is '
          'sent, so it can\'t apply twice.',
    ),
    FollowUpNotice.notSent => (
      StatusTone.neutral,
      'Not sent',
      'This build has no server configured, so nothing was sent.',
    ),
  };
}

/// Plain words for the field errors the server named.
String _invalidText(Map<String, String> f) {
  final parts = <String>[
    if (f['review_at'] == 'required') 'Waiting needs a review date.',
    if (f['review_at'] == 'past') 'The review date is in the past.',
    if (f['review_at'] == 'unchanged') 'That is already the review date.',
    if (f['close_reason'] == 'required') 'Closing needs a reason.',
    if (f['due_at'] == 'past') 'The due date is in the past.',
    if (f['status'] == 'unchanged') 'The task already has that status.',
    if (f['next_action'] == 'unchanged') 'That is already the next action.',
    if (f['owner_member_id'] == 'unchanged') 'That person already owns it.',
    if (f['owner_member_id'] == 'unknown') 'That person cannot own a task.',
    // Story 4.7, owner decision Q4: the task's own group or a Pastor.
    if (f['owner_member_id'] == 'not_in_scope')
      'The owner must belong to this task\'s group or be a Pastor.',
    if (f['reminders'] == 'fixed_by_source')
      'This source sets its own reminders.',
    if (f['reminders'] == 'invalid' || f['reminders'] == 'out_of_range')
      'Those reminders cannot be used.',
    if (f['supervisor_member_id'] == 'not_in_scope')
      'The supervisor must lead this scope.',
    if (f['outcome'] == 'unregistered') 'That outcome is not available here.',
  ];
  return parts.isEmpty
      ? 'Some answers need fixing before this can be sent.'
      : parts.join(' ');
}

Widget _readProblem<T>(AccessRead<T> r, String needs) => switch (r) {
  AccessReadOk() => const SizedBox.shrink(),
  AccessReadDenied(:final denial) => RequestStateBanner(
    key: Key('followups-denied-${denial.name}'),
    tone: StatusTone.warning,
    icon: Icons.lock_outline,
    title: switch (denial) {
      AccessDenial.signedOut => 'Not signed in',
      AccessDenial.untrustedSession => 'Please sign in again',
      AccessDenial.notGranted => 'Not available to you',
      AccessDenial.notLinked => 'No member access yet',
      AccessDenial.unavailable => 'Not available yet',
      _ => 'Access review required',
    },
    message: denial == AccessDenial.notGranted
        ? '$needs Permissions are checked by the server each time.'
        : 'Nothing is shown until the server allows it.',
  ),
  AccessReadFailed(:final unreachable) => RequestStateBanner(
    key: const Key('followups-failed'),
    tone: StatusTone.danger,
    icon: unreachable ? Icons.cloud_off_outlined : Icons.error_outline,
    title: unreachable ? 'No connection' : 'Couldn\'t load',
    message: unreachable
        ? 'We couldn\'t reach the church server. This is not an empty list: '
              'nothing is shown until it answers.'
        : 'The server answered in an unexpected way. Try again later.',
  ),
};

/// The page frame shared by the follow-up screens: notice, read problem,
/// content and a reload button.
class _FollowUpsPage<T> extends ConsumerStatefulWidget {
  const _FollowUpsPage({
    required this.title,
    required this.provider,
    required this.controller,
    required this.needs,
    required this.loading,
    required this.body,
  });

  final String title;
  final ProviderListenable<FollowUpsState<T>> provider;
  final FollowUpsController<T> Function(WidgetRef ref) controller;
  final String needs;
  final String loading;
  final Widget Function(BuildContext context, T value, FollowUpsState<T> state)
  body;

  @override
  ConsumerState<_FollowUpsPage<T>> createState() => _FollowUpsPageState<T>();
}

class _FollowUpsPageState<T> extends ConsumerState<_FollowUpsPage<T>> {
  late final AppLifecycleListener _lifecycle;
  final _noticeFocus = FocusNode(debugLabel: 'follow-ups notice');

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onResume: _reload);
    // Revisiting the screen asks the server again.
    if (ref.read(widget.provider).result != null) Future.microtask(_reload);
  }

  void _reload() {
    if (!mounted) return;
    final s = ref.read(widget.provider);
    if (!s.busy && !s.loading) widget.controller(ref).reload();
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    _noticeFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = ChurchColors.of(context);
    final layout = ChurchLayout.of(context);
    final s = ref.watch(widget.provider);
    final ctl = widget.controller(ref);
    ref.listen(widget.provider, (prev, next) {
      final n = next.notice;
      if (n == null || n == prev?.notice) return;
      final (_, title, message) = _noticeText(
        n,
        next.noticeAction,
        next.fieldErrors,
      );
      announce(context, '$title. $message');
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _noticeFocus.context != null) {
          _noticeFocus.requestFocus();
        }
      });
    });
    final children = <Widget>[];
    if (s.pending case final p?) {
      children.add(
        RequestStateBanner(
          key: const Key('followups-pending'),
          tone: StatusTone.info,
          busy: true,
          title: 'Sending…',
          message:
              'Waiting for the church server about ${p.subject}. Nothing is '
              'shown as done until it answers.',
        ),
      );
    } else if (s.notice case final n?) {
      final (tone, title, message) = _noticeText(
        n,
        s.noticeAction,
        s.fieldErrors,
      );
      children.add(
        RequestStateBanner(
          key: Key('followups-notice-${n.name}'),
          focusNode: _noticeFocus,
          tone: tone,
          title: title,
          message: message,
          actions: [
            if (n == FollowUpNotice.unconfirmed)
              BannerAction(
                'Check again',
                ctl.checkAgain,
                key: const Key('followups-check-again'),
                primary: true,
              ),
            BannerAction(
              'Dismiss',
              ctl.dismissNotice,
              key: const Key('followups-dismiss'),
            ),
          ],
        ),
      );
    }
    if (children.isNotEmpty) {
      children.add(const SizedBox(height: ChurchGeometry.sectionGap));
    }
    final result = s.result;
    if (result == null) {
      children.add(
        RequestStateBanner(
          key: const Key('followups-loading'),
          tone: StatusTone.info,
          busy: true,
          title: widget.loading,
          message: 'Asking the church server.',
        ),
      );
    } else if (result case AccessReadOk(:final value)) {
      children.add(widget.body(context, value, s));
    } else {
      children.add(_readProblem(result, widget.needs));
    }
    children.addAll([
      const SizedBox(height: ChurchGeometry.sectionGap),
      Align(
        alignment: AlignmentDirectional.centerStart,
        child: FocusRing(
          child: OutlinedButton.icon(
            key: const Key('followups-reload'),
            onPressed: s.loading || s.busy ? null : ctl.reload,
            icon: const Icon(Icons.refresh),
            label: const Text('Reload'),
          ),
        ),
      ),
    ]);
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
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

class _Card extends StatelessWidget {
  const _Card({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: ChurchCard(
      radius: identical(ChurchLayout.of(context), ChurchLayout.staff)
          ? 12
          : ChurchGeometry.mobileCardRadius,
      child: child,
    ),
  );
}

Widget _heading(BuildContext context, String text, {Key? key}) => Padding(
  padding: const EdgeInsets.only(bottom: 8),
  child: Semantics(
    header: true,
    child: Text(
      text,
      key: key,
      style: ChurchType.cardTitle.copyWith(color: ChurchColors.of(context).ink),
    ),
  ),
);

Widget _muted(BuildContext context, String text, {Key? key}) => Text(
  text,
  key: key,
  style: ChurchType.secondary.copyWith(color: ChurchColors.of(context).muted),
);

// Every follow-up date is shown in church time (Africa/Lusaka), whatever zone
// the device is set to.
String _when(BuildContext context, DateTime at) {
  final w = ChurchTime.wall(at);
  final time = MaterialLocalizations.of(context).formatTimeOfDay(
    TimeOfDay(hour: w.hour, minute: w.minute),
    alwaysUse24HourFormat: true,
  );
  return '${MaterialLocalizations.of(context).formatMediumDate(w)} $time';
}

/// "Overdue" before the state; the state otherwise.
(String, StatusTone) _statusLabel(FollowUpRouting r) {
  if (r.overdue) {
    return (
      r.state == FollowUpState.waiting ? 'Review overdue' : 'Overdue',
      StatusTone.danger,
    );
  }
  return (
    r.state.label,
    switch (r.state) {
      FollowUpState.open => StatusTone.info,
      FollowUpState.inProgress => StatusTone.info,
      FollowUpState.waiting => StatusTone.warning,
      FollowUpState.done => StatusTone.success,
      FollowUpState.closed => StatusTone.neutral,
    },
  );
}

/// "Due 4 Jan 2099 10:00 (church time)", with the review date while Waiting.
String _datesText(BuildContext context, FollowUpRouting r) => [
  'Due ${_when(context, r.dueAt)}',
  if (r.reviewAt case final v?) 'review ${_when(context, v)}',
  '(church time)',
].join(', ').replaceAll(', (church', ' (church');

String _personText(FollowUpPerson p) =>
    p.account == AccountStanding.noLogin ? '${p.name} (no login)' : p.name;

/// One task as a list row (My follow-ups, supervision).
class _TaskRow extends StatelessWidget {
  const _TaskRow({required this.task, required this.showOwner, this.trailing});

  final FollowUpTask task;
  final bool showOwner;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final r = task.routing;
    final (label, tone) = _statusLabel(r);
    return _Card(
      key: Key('followup-${task.taskId}'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            task.nextAction,
            style: ChurchType.body.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 4),
          _muted(
            context,
            [
              r.purposeLabel,
              ?task.contextLabel,
              if (showOwner) 'Owner: ${_personText(r.owner)}',
            ].join('. '),
          ),
          _muted(context, _datesText(context, r)),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              StatusLabel(
                key: Key('followup-status-${task.taskId}'),
                label: label,
                tone: tone,
              ),
              if (task.latestOutcome case final o?)
                StatusLabel(
                  label: followUpCodeLabel(o),
                  tone: StatusTone.neutral,
                ),
              FocusRing(
                child: TextButton(
                  key: Key('followup-open-${task.taskId}'),
                  onPressed: () =>
                      context.push(FollowUpPaths.task(task.taskId)),
                  child: Text(
                    'Open task',
                    semanticsLabel: 'Open task: ${task.nextAction}',
                  ),
                ),
              ),
              ?trailing,
            ],
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// My follow-ups (every owner)
// ---------------------------------------------------------------------------

/// Story 4.6: the signed-in member's own follow-up tasks (active first).
class MyFollowUpsScreen extends StatelessWidget {
  const MyFollowUpsScreen({super.key});

  @override
  Widget build(BuildContext context) => _FollowUpsPage<MyFollowUps>(
    title: 'My follow-ups',
    provider: myFollowUpsProvider,
    controller: (ref) => ref.read(myFollowUpsProvider.notifier),
    needs: 'My follow-ups needs member access.',
    loading: 'Loading your follow-ups…',
    body: (context, value, s) {
      if (value.tasks.isEmpty) {
        return _muted(
          context,
          'You have no follow-ups. When someone asks you to follow something '
          'up, it shows here.',
          key: const Key('my-followups-empty'),
        );
      }
      final active = value.active;
      final finished = value.tasks.where((t) => !t.state.active).toList();
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _heading(context, 'To do (${active.length})'),
          if (active.isEmpty) _muted(context, 'Nothing to do right now.'),
          for (final t in active) _TaskRow(task: t, showOwner: false),
          if (finished.isNotEmpty) ...[
            const SizedBox(height: ChurchGeometry.sectionGap),
            _heading(context, 'Finished in the last 30 days'),
            for (final t in finished) _TaskRow(task: t, showOwner: false),
          ],
          if (value.truncated)
            _muted(context, 'Only the first 200 tasks are shown.'),
        ],
      );
    },
  );
}

/// Story 4.6: the My follow-ups card on the member Home. It shows only while
/// the member owns open work, and a failed read never looks empty.
class MyFollowUpsHomeCard extends ConsumerStatefulWidget {
  const MyFollowUpsHomeCard({super.key});

  @override
  ConsumerState<MyFollowUpsHomeCard> createState() =>
      _MyFollowUpsHomeCardState();
}

class _MyFollowUpsHomeCardState extends ConsumerState<MyFollowUpsHomeCard> {
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onResume: _reload);
    if (ref.read(myFollowUpsProvider).result != null) {
      Future.microtask(_reload);
    }
  }

  void _reload() {
    final s = ref.read(myFollowUpsProvider);
    if (mounted && !s.busy && !s.loading) {
      ref.read(myFollowUpsProvider.notifier).reload();
    }
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(myFollowUpsProvider);
    final lines = <Widget>[];
    switch (s.result) {
      case AccessReadOk(:final value) when value.active.isNotEmpty:
        final active = value.active;
        final next = active.reduce(
          (a, b) =>
              a.routing.actionableAt.isAfter(b.routing.actionableAt) ? b : a,
        );
        final overdue = value.overdue;
        lines.addAll([
          Text(
            '${active.length} active'
            '${overdue == 0 ? '' : ', $overdue overdue'}',
            key: const Key('home-followups-count'),
          ),
          const SizedBox(height: 4),
          Text(
            'Next: ${next.nextAction}',
            key: Key('home-followup-${next.taskId}'),
            style: ChurchType.body.copyWith(fontWeight: FontWeight.w600),
          ),
          _muted(context, _datesText(context, next.routing)),
        ]);
      case AccessReadFailed(:final unreachable):
        lines.add(
          Text(
            unreachable
                ? 'No connection: we couldn\'t reach the church server. This '
                      'is not an empty list.'
                : 'Couldn\'t load your follow-ups. Try again later.',
            key: const Key('home-followups-failed'),
          ),
        );
      case AccessReadOk():
        // Review N6: nothing active, but finished work stays reachable.
        return ChurchCard(
          padding: EdgeInsets.zero,
          child: MenuRow(
            key: const Key('home-followups-link'),
            label: 'My follow-ups',
            meta: 'Nothing open',
            showDivider: false,
            onTap: () => context.push(FollowUpPaths.mine),
          ),
        );
      default:
        // Loading or denied: nothing is shown.
        return const SizedBox.shrink(key: Key('home-followups-none'));
    }
    return _Card(
      key: const Key('home-followups-card'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _heading(context, 'My follow-ups'),
          ...lines,
          const SizedBox(height: 8),
          FocusRing(
            child: TextButton(
              key: const Key('home-followups-see-all'),
              onPressed: () => context.push(FollowUpPaths.mine),
              child: const Text('See all'),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// One task
// ---------------------------------------------------------------------------

/// Story 4.6: one task. Its owner and the holders of its scope see the next
/// action, the source's minimal context, the activity and the private notes
/// and may record updates (a scope holder records for the owner); an Admin
/// sees routing metadata only.
class FollowUpTaskScreen extends StatelessWidget {
  const FollowUpTaskScreen({super.key, required this.taskId});

  final String taskId;

  @override
  Widget build(BuildContext context) => _FollowUpsPage<FollowUpDetail>(
    title: 'Follow-up',
    provider: followUpTaskProvider(taskId),
    controller: (ref) => ref.read(followUpTaskProvider(taskId).notifier),
    needs: 'Only the task\'s owner and the leaders of its scope can open it.',
    loading: 'Loading the task…',
    body: (context, value, s) {
      final task = value.task;
      if (task == null) return _RoutingOnly(routing: value.meta);
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _TaskSummary(task: task),
          if (task.canUpdate) _UpdatePanel(task: task, busy: s.busy),
          _History(detail: value),
        ],
      );
    },
  );
}

class _TaskSummary extends StatelessWidget {
  const _TaskSummary({required this.task});
  final FollowUpTask task;

  @override
  Widget build(BuildContext context) {
    final r = task.routing;
    final (label, tone) = _statusLabel(r);
    return _Card(
      key: const Key('followup-summary'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _heading(
            context,
            task.nextAction,
            key: const Key('followup-next-action-text'),
          ),
          _muted(context, [r.purposeLabel, ?task.contextLabel].join('. ')),
          const SizedBox(height: 4),
          Text(_datesText(context, r), key: const Key('followup-dates')),
          if (r.duePassed && r.state == FollowUpState.waiting)
            _muted(context, 'The original due date has passed.'),
          Text('Owner: ${_personText(r.owner)}'),
          Text('Supervisor: ${_personText(r.supervisor)}'),
          if (task.reminders case final rem? when r.state.active)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: _muted(
                context,
                '${rem.sourceText} '
                '${rem.ownerText(waiting: r.state == FollowUpState.waiting)} '
                '${rem.supervisorText(waiting: r.state == FollowUpState.waiting)}',
                key: const Key('followup-reminders-text'),
              ),
            ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              StatusLabel(
                key: const Key('followup-status'),
                label: label,
                tone: tone,
              ),
              if (task.latestOutcome case final o?)
                StatusLabel(
                  key: const Key('followup-outcome-label'),
                  label: 'Outcome: ${followUpCodeLabel(o)}',
                  tone: StatusTone.neutral,
                ),
            ],
          ),
          if (task.closeReason case final reason?)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                'Closed: $reason',
                key: const Key('followup-close-reason-text'),
              ),
            ),
          if (task.closeCode case final code? when code != 'manual')
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: _muted(
                context,
                'Closed by its source (${followUpCodeLabel(code)}).',
              ),
            ),
          if (task.capacity == FollowUpCapacity.supervisor && task.canUpdate)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: _muted(
                context,
                'You lead this task\'s scope: what you record here is shown '
                'as recorded by you for ${r.owner.name}.',
                key: const Key('followup-recording-for-owner'),
              ),
            ),
        ],
      ),
    );
  }
}

/// The owner's (or a scope holder's) actions on an active task. Each button
/// sends one change at the task's current revision.
class _UpdatePanel extends ConsumerStatefulWidget {
  const _UpdatePanel({required this.task, required this.busy});
  final FollowUpTask task;
  final bool busy;

  @override
  ConsumerState<_UpdatePanel> createState() => _UpdatePanelState();
}

class _UpdatePanelState extends ConsumerState<_UpdatePanel> {
  final _reviewDate = TextEditingController();
  final _reviewTime = TextEditingController(text: '09:00');
  final _reason = TextEditingController();
  final _next = TextEditingController();
  final _note = TextEditingController();
  String? _outcome;

  @override
  void dispose() {
    for (final c in [_reviewDate, _reviewTime, _reason, _next, _note]) {
      c.dispose();
    }
    super.dispose();
  }

  void _send(FollowUpUpdate u) => ref
      .read(followUpTaskProvider(widget.task.taskId).notifier)
      .update(widget.task.routing, u, 'this task');

  @override
  Widget build(BuildContext context) {
    // Review S4: after a confirmed save the typed text is cleared, so a
    // second tap cannot send the same note or next action again.
    ref.listen(followUpTaskProvider(widget.task.taskId), (prev, next) {
      if (next.notice == FollowUpNotice.updated && prev?.pending != null) {
        for (final c in [_note, _next, _reason]) {
          c.clear();
        }
        setState(() => _outcome = null);
      }
    });
    final t = widget.task;
    final busy = widget.busy;
    final waiting = t.state == FollowUpState.waiting;
    Widget field(
      String key,
      TextEditingController c,
      String label, {
      String? hint,
      int maxLength = 200,
      int maxLines = 1,
    }) => Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: TextField(
        key: Key(key),
        controller: c,
        enabled: !busy,
        maxLength: maxLength,
        maxLines: maxLines,
        decoration: InputDecoration(labelText: label, hintText: hint),
      ),
    );
    Widget button(
      String key,
      String label,
      VoidCallback? onPressed, {
      bool primary = false,
    }) => FocusRing(
      child: primary
          ? FilledButton(
              key: Key(key),
              onPressed: busy ? null : onPressed,
              child: Text(label),
            )
          : OutlinedButton(
              key: Key(key),
              onPressed: busy ? null : onPressed,
              child: Text(label),
            ),
    );
    return _Card(
      key: const Key('followup-actions'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _heading(context, 'Update'),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (t.state != FollowUpState.inProgress)
                button(
                  'followup-start',
                  'Mark in progress',
                  () => _send(
                    const FollowUpUpdate(status: FollowUpState.inProgress),
                  ),
                ),
              button(
                'followup-done',
                'Done',
                () => _send(const FollowUpUpdate(status: FollowUpState.done)),
                primary: true,
              ),
            ],
          ),
          const SizedBox(height: 12),
          _muted(
            context,
            waiting
                ? 'Change the review date. The original due date stays.'
                : 'Waiting for someone? Set a review date. The original due '
                      'date stays.',
          ),
          field(
            'followup-review-date',
            _reviewDate,
            'Review date',
            hint: 'YYYY-MM-DD',
            maxLength: 10,
          ),
          field(
            'followup-review-time',
            _reviewTime,
            'Review time',
            hint: 'HH:MM',
            maxLength: 5,
          ),
          ListenableBuilder(
            listenable: Listenable.merge([_reviewDate, _reviewTime]),
            builder: (context, _) {
              final at = ChurchTime.parse(_reviewDate.text, _reviewTime.text);
              return Align(
                alignment: AlignmentDirectional.centerStart,
                child: button(
                  'followup-wait',
                  waiting ? 'Change review date' : 'Waiting',
                  at == null
                      ? null
                      : () => _send(
                          FollowUpUpdate(
                            status: waiting ? null : FollowUpState.waiting,
                            reviewAt: at,
                          ),
                        ),
                ),
              );
            },
          ),
          const SizedBox(height: 12),
          if (t.outcomes.isNotEmpty) ...[
            InputDecorator(
              decoration: const InputDecoration(
                labelText: 'Outcome',
                contentPadding: EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 4,
                ),
              ),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<String?>(
                  key: const Key('followup-outcome'),
                  hint: const Text('Choose an outcome'),
                  value: _outcome,
                  isExpanded: true,
                  items: [
                    for (final o in t.outcomes)
                      DropdownMenuItem(
                        value: o,
                        child: Text(followUpCodeLabel(o)),
                      ),
                  ],
                  onChanged: busy ? null : (v) => setState(() => _outcome = v),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: button(
                'followup-record-outcome',
                'Record outcome',
                _outcome == null
                    ? null
                    : () => _send(FollowUpUpdate(outcome: _outcome)),
              ),
            ),
            const SizedBox(height: 12),
          ],
          field('followup-next', _next, 'New next action'),
          ListenableBuilder(
            listenable: _next,
            builder: (context, _) => Align(
              alignment: AlignmentDirectional.centerStart,
              child: button(
                'followup-change-next',
                'Change next action',
                _next.text.trim().isEmpty
                    ? null
                    : () => _send(FollowUpUpdate(nextAction: _next.text)),
              ),
            ),
          ),
          const SizedBox(height: 12),
          field(
            'followup-note',
            _note,
            'Private note',
            maxLength: 1000,
            maxLines: 3,
          ),
          _muted(
            context,
            'Only the owner and the leaders of this task\'s scope see private '
            'notes. Admin routing never shows them.',
          ),
          ListenableBuilder(
            listenable: _note,
            builder: (context, _) => Align(
              alignment: AlignmentDirectional.centerStart,
              child: button(
                'followup-add-note',
                'Add note',
                _note.text.trim().isEmpty
                    ? null
                    : () => _send(FollowUpUpdate(note: _note.text)),
              ),
            ),
          ),
          const SizedBox(height: 12),
          field('followup-close-reason', _reason, 'Reason for closing'),
          ListenableBuilder(
            listenable: _reason,
            builder: (context, _) => Align(
              alignment: AlignmentDirectional.centerStart,
              child: button(
                'followup-close',
                'Close',
                _reason.text.trim().isEmpty
                    ? null
                    : () => _send(
                        FollowUpUpdate(
                          status: FollowUpState.closed,
                          closeReason: _reason.text,
                        ),
                      ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _History extends StatelessWidget {
  const _History({required this.detail});
  final FollowUpDetail detail;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Card(
          key: const Key('followup-notes'),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _heading(context, 'Private notes'),
              if (detail.notes.isEmpty) _muted(context, 'No notes yet.'),
              for (final n in detail.notes)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(n.erased ? '(removed)' : n.body!),
                      _muted(
                        context,
                        '${_when(context, n.at)}, '
                        '${n.onBehalfOf == null ? 'by ${n.author ?? 'a former member'}' : 'recorded by ${n.author ?? 'a former member'} for ${n.onBehalfOf}'}',
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
        _Card(
          key: const Key('followup-activity'),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _heading(context, 'Activity'),
              for (final (i, a) in detail.activity.reversed.indexed)
                Padding(
                  key: Key('followup-activity-$i'),
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Text(
                    '${_when(context, a.at)}: ${a.summary} ${a.attribution}'
                    '${a.reviewAt == null ? '' : ' (review ${_when(context, a.reviewAt!)})'}',
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// What an Admin sees of a task: routing metadata only.
class _RoutingOnly extends StatelessWidget {
  const _RoutingOnly({required this.routing});
  final FollowUpRouting routing;

  @override
  Widget build(BuildContext context) {
    final (label, tone) = _statusLabel(routing);
    return _Card(
      key: const Key('followup-routing-only'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _heading(context, routing.purposeLabel),
          Text('Owner: ${_personText(routing.owner)}'),
          Text('Supervisor: ${_personText(routing.supervisor)}'),
          Text('Scope: ${routing.scope.label}'),
          Text(_datesText(context, routing)),
          const SizedBox(height: 6),
          StatusLabel(label: label, tone: tone),
          const SizedBox(height: 6),
          _muted(
            context,
            'Admin routing shows owner, scope, status and dates only. The '
            'next action, outcomes and private notes stay with the owner and '
            'the scope\'s leaders.',
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Staff web: supervision (scope holders)
// ---------------------------------------------------------------------------

/// A member picker over the server's candidates.
class _PersonPicker extends StatelessWidget {
  const _PersonPicker({
    required this.pickerKey,
    required this.label,
    required this.people,
    required this.value,
    required this.busy,
    required this.onChanged,
  });

  final String pickerKey;
  final String label;
  final List<FollowUpPerson> people;
  final String? value;
  final bool busy;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context) => InputDecorator(
    decoration: InputDecoration(
      labelText: label,
      contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    ),
    child: DropdownButtonHideUnderline(
      child: DropdownButton<String?>(
        key: Key(pickerKey),
        hint: const Text('Choose someone'),
        value: people.any((p) => p.memberId == value) ? value : null,
        isExpanded: true,
        items: [
          for (final p in people)
            DropdownMenuItem(value: p.memberId, child: Text(_personText(p))),
        ],
        onChanged: busy ? null : onChanged,
      ),
    ),
  );
}

/// Story 4.6, staff web: the tasks in the scopes the caller leads. Leaders
/// create SYNTHETIC tasks (local and staging only), reassign, and open a task
/// to record updates for its owner.
class FollowUpSupervisionScreen extends StatelessWidget {
  const FollowUpSupervisionScreen({super.key});

  @override
  Widget build(BuildContext context) => _FollowUpsPage<FollowUpSupervision>(
    title: 'Follow-ups',
    provider: followUpSupervisionProvider,
    controller: (ref) => ref.read(followUpSupervisionProvider.notifier),
    needs: 'Follow-ups is for the leaders of a department or cell.',
    loading: 'Loading follow-ups…',
    body: (context, value, s) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (value.purposes.isNotEmpty)
          _CreateTaskForm(supervision: value, busy: s.busy),
        _heading(context, 'Tasks in your scopes (${value.tasks.length})'),
        if (value.tasks.isEmpty)
          _muted(
            context,
            'No tasks in your scopes.',
            key: const Key('supervision-empty'),
          ),
        for (final t in value.tasks)
          _TaskRow(
            task: t,
            showOwner: true,
            trailing: t.canReassign
                ? _ReassignButton(
                    routing: t.routing,
                    candidates: followUpCandidatesFor(
                      value.scopes,
                      t.routing.scope,
                    ),
                    busy: s.busy,
                    onReassign: (ref, owner) => ref
                        .read(followUpSupervisionProvider.notifier)
                        .reassign(
                          t.routing,
                          ownerMemberId: owner,
                          subject: 'the task',
                        ),
                  )
                : null,
          ),
        if (value.truncated)
          _muted(context, 'Only the first 200 tasks are shown.'),
      ],
    ),
  );
}

class _CreateTaskForm extends ConsumerStatefulWidget {
  const _CreateTaskForm({required this.supervision, required this.busy});
  final FollowUpSupervision supervision;
  final bool busy;

  @override
  ConsumerState<_CreateTaskForm> createState() => _CreateTaskFormState();
}

class _CreateTaskFormState extends ConsumerState<_CreateTaskForm> {
  final _next = TextEditingController();
  final _dueDate = TextEditingController();
  final _dueTime = TextEditingController(text: '17:00');
  final _note = TextEditingController();
  int _purpose = 0;
  int _scope = 0;
  String? _owner;

  /// Story 4.7: the creator's owner reminders (off = the church default).
  bool _customReminders = false;
  final Set<FollowUpReminderSpec> _reminders = {followUpReminderChoices.first};

  /// Review S4: one SYNTHETIC source id per draft. It is kept while the
  /// outcome is unknown (Check again or a re-tap resends the same request)
  /// and replaced only after the server answered.
  String? _sourceId;

  @override
  void dispose() {
    for (final c in [_next, _dueDate, _dueTime, _note]) {
      c.dispose();
    }
    super.dispose();
  }

  /// Story 4.7: which reminders the owner gets. A source with its own
  /// schedule fixes them; otherwise the church default applies unless the
  /// creator chooses. The owner is told when assigned and the supervisor a
  /// day after a missed deadline either way (server rule).
  Widget _reminderChoice(
    BuildContext context,
    FollowUpPurpose purpose,
    bool busy,
  ) {
    if (purpose.fixedReminders) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: _muted(
          context,
          'Reminders: this source sets its own reminder schedule.',
          key: const Key('followup-create-reminders-fixed'),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CheckboxListTile(
            key: const Key('followup-create-reminders-custom'),
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            value: _customReminders,
            onChanged: busy
                ? null
                : (v) => setState(() => _customReminders = v ?? false),
            title: const Text('Choose the owner\'s reminders'),
          ),
          _muted(
            context,
            _customReminders
                ? 'The owner is reminded at the times you pick before the '
                      'due date (or the review date while Waiting). None '
                      'picked means no reminders.'
                : 'The church default applies. The owner is told when the '
                      'task is assigned; the supervisor a day after a missed '
                      'deadline.',
          ),
          if (_customReminders)
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final (i, c) in followUpReminderChoices.indexed)
                  FilterChip(
                    key: Key('followup-create-reminder-$i'),
                    label: Text(
                      c.label == 'at the due time'
                          ? 'At the due time'
                          : c.label,
                    ),
                    selected: _reminders.contains(c),
                    onSelected: busy
                        ? null
                        : (on) => setState(
                            () => on ? _reminders.add(c) : _reminders.remove(c),
                          ),
                  ),
              ],
            ),
        ],
      ),
    );
  }

  // Story 4.14: the same RFC 4122 version 4 generator as request ids.
  static String _newSourceId() => SecureRequestIds().next();

  @override
  Widget build(BuildContext context) {
    ref.listen(followUpSupervisionProvider, (prev, next) {
      final n = next.notice;
      if (prev?.pending == null || n == null || n == prev?.notice) return;
      if (n == FollowUpNotice.unconfirmed || n == FollowUpNotice.notSent) {
        return;
      }
      if (next.noticeAction?.command != FollowUpCommands.createTask) return;
      // The server answered this draft: the next one is a new source.
      _sourceId = null;
      if (n == FollowUpNotice.created) {
        _next.clear();
        _note.clear();
        setState(() {
          _owner = null;
          _customReminders = false;
          _reminders
            ..clear()
            ..add(followUpReminderChoices.first);
        });
      }
    });
    final sup = widget.supervision;
    final busy = widget.busy;
    final purpose = sup.purposes[min(_purpose, sup.purposes.length - 1)];
    final scopes = sup.scopes
        .where((s) => purpose.scopeKinds.contains(s.scope.scopeKind))
        .toList();
    final scope = scopes.isEmpty
        ? null
        : scopes[min(_scope, scopes.length - 1)];
    return _Card(
      key: const Key('followup-create'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _heading(context, 'Create a task'),
          _muted(
            context,
            'One owner, one next action and a due date. Real sources (duties, '
            'visitors, reports) create their own tasks; this form is for the '
            'SYNTHETIC check-in source on local and staging. Dates are church '
            'time (Lusaka).',
          ),
          const SizedBox(height: 8),
          InputDecorator(
            decoration: const InputDecoration(
              labelText: 'Purpose',
              contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            ),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<int>(
                key: const Key('followup-create-purpose'),
                value: min(_purpose, sup.purposes.length - 1),
                isExpanded: true,
                items: [
                  for (final (i, p) in sup.purposes.indexed)
                    DropdownMenuItem(value: i, child: Text(p.label)),
                ],
                onChanged: busy
                    ? null
                    : (v) => setState(() => _purpose = v ?? 0),
              ),
            ),
          ),
          const SizedBox(height: 8),
          InputDecorator(
            decoration: const InputDecoration(
              labelText: 'Scope',
              contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            ),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<int>(
                key: const Key('followup-create-scope'),
                value: scopes.isEmpty ? null : min(_scope, scopes.length - 1),
                isExpanded: true,
                items: [
                  for (final (i, sc) in scopes.indexed)
                    DropdownMenuItem(value: i, child: Text(sc.scope.label)),
                ],
                onChanged: busy
                    ? null
                    : (v) => setState(() {
                        _scope = v ?? 0;
                        _owner = null;
                      }),
              ),
            ),
          ),
          const SizedBox(height: 8),
          _PersonPicker(
            pickerKey: 'followup-create-owner',
            label: 'Owner',
            people: scope?.candidates ?? const [],
            value: _owner,
            busy: busy,
            onChanged: (v) => setState(() => _owner = v),
          ),
          const SizedBox(height: 8),
          TextField(
            key: const Key('followup-create-next'),
            controller: _next,
            enabled: !busy,
            maxLength: 200,
            decoration: const InputDecoration(labelText: 'Next action'),
          ),
          TextField(
            key: const Key('followup-create-due-date'),
            controller: _dueDate,
            enabled: !busy,
            maxLength: 10,
            decoration: const InputDecoration(
              labelText: 'Due date',
              hintText: 'YYYY-MM-DD',
            ),
          ),
          TextField(
            key: const Key('followup-create-due-time'),
            controller: _dueTime,
            enabled: !busy,
            maxLength: 5,
            decoration: const InputDecoration(
              labelText: 'Due time',
              hintText: 'HH:MM',
            ),
          ),
          _reminderChoice(context, purpose, busy),
          TextField(
            key: const Key('followup-create-note'),
            controller: _note,
            enabled: !busy,
            maxLength: 1000,
            maxLines: 3,
            decoration: const InputDecoration(
              labelText: 'Private note (optional)',
            ),
          ),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: ListenableBuilder(
              listenable: Listenable.merge([_next, _dueDate, _dueTime]),
              builder: (context, _) {
                final due = ChurchTime.parse(_dueDate.text, _dueTime.text);
                final owner = _owner;
                final ready =
                    owner != null &&
                    scope != null &&
                    due != null &&
                    _next.text.trim().isNotEmpty;
                return FocusRing(
                  child: FilledButton(
                    key: const Key('followup-create-save'),
                    onPressed: busy || !ready
                        ? null
                        : () => ref
                              .read(followUpSupervisionProvider.notifier)
                              .create(
                                FollowUpDraft(
                                  purpose: purpose,
                                  sourceId: _sourceId ??= _newSourceId(),
                                  ownerMemberId: owner,
                                  scope: scope.scope,
                                  nextAction: _next.text,
                                  dueAt: due,
                                  note: _note.text,
                                  reminders:
                                      purpose.fixedReminders ||
                                          !_customReminders
                                      ? null
                                      : [
                                          for (final c
                                              in followUpReminderChoices)
                                            if (_reminders.contains(c)) c,
                                        ],
                                ),
                                'the task',
                              ),
                    child: const Text('Create task'),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// Choose a new owner and reassign (scope holders, Admin).
class _ReassignButton extends ConsumerStatefulWidget {
  const _ReassignButton({
    required this.routing,
    required this.candidates,
    required this.busy,
    required this.onReassign,
  });

  final FollowUpRouting routing;
  final List<FollowUpPerson> candidates;
  final bool busy;
  final void Function(WidgetRef ref, String ownerMemberId) onReassign;

  @override
  ConsumerState<_ReassignButton> createState() => _ReassignButtonState();
}

class _ReassignButtonState extends ConsumerState<_ReassignButton> {
  bool _open = false;
  String? _owner;

  @override
  Widget build(BuildContext context) {
    final id = widget.routing.taskId;
    if (!_open) {
      return FocusRing(
        child: TextButton(
          key: Key('followup-reassign-$id'),
          onPressed: widget.busy ? null : () => setState(() => _open = true),
          child: const Text('Reassign'),
        ),
      );
    }
    final people = widget.candidates
        .where((p) => p.memberId != widget.routing.owner.memberId)
        .toList();
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 360),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _PersonPicker(
            pickerKey: 'followup-reassign-owner-$id',
            label: 'New owner',
            people: people,
            value: _owner,
            busy: widget.busy,
            onChanged: (v) => setState(() => _owner = v),
          ),
          Wrap(
            spacing: 8,
            children: [
              FocusRing(
                child: FilledButton(
                  key: Key('followup-reassign-save-$id'),
                  onPressed: widget.busy || _owner == null
                      ? null
                      : () {
                          widget.onReassign(ref, _owner!);
                          setState(() => _open = false);
                        },
                  child: const Text('Reassign'),
                ),
              ),
              TextButton(
                onPressed: () => setState(() => _open = false),
                child: const Text('Cancel'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Staff web, Admin: routing metadata only
// ---------------------------------------------------------------------------

String _waitingText(FollowUpHandoverWaiting w) {
  final parts = [
    if (w.tasks > 0) '${w.tasks} open task(s)',
    if (w.supervisions > 0) '${w.supervisions} supervision(s)',
  ];
  final why = switch (w.membershipState) {
    'deactivated' => 'membership deactivated',
    'deleting' => 'being deleted',
    _ => 'no longer in the task\'s group',
  };
  return '${parts.join(' and ')} wait for someone else ($why).';
}

/// Story 4.6, staff web, Admin only: every task's owner, supervisor, scope,
/// state and dates, and reassignment. No next action, outcome, source
/// context or private note is ever shown here.
class FollowUpRoutingScreen extends StatelessWidget {
  const FollowUpRoutingScreen({super.key});

  @override
  Widget build(BuildContext context) => _FollowUpsPage<FollowUpAdminRouting>(
    title: 'Follow-up routing',
    provider: followUpRoutingProvider,
    controller: (ref) => ref.read(followUpRoutingProvider.notifier),
    needs: 'Follow-up routing is for Admins.',
    loading: 'Loading follow-up routing…',
    body: (context, value, s) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _muted(
          context,
          'Routing only: owner, scope, status and dates. The next action, '
          'outcomes and private notes stay with the owner and the scope\'s '
          'leaders.',
        ),
        const SizedBox(height: 8),
        // Story 4.12 (review B1): what waits for a new owner or supervisor.
        if (value.handovers.isNotEmpty) ...[
          Text(
            'Waiting for handover',
            style: ChurchType.body.copyWith(fontWeight: FontWeight.w600),
          ),
          for (final w in value.handovers)
            _Card(
              key: Key('routing-handover-${w.memberId}'),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(w.displayName ?? 'A former member'),
                  Text(_waitingText(w)),
                  Consumer(
                    builder: (context, ref, _) => FocusRing(
                      child: OutlinedButton(
                        key: Key('routing-continue-handover-${w.memberId}'),
                        onPressed: s.busy
                            ? null
                            : () => ref
                                  .read(followUpRoutingProvider.notifier)
                                  .completeHandover(w),
                        child: const Text('Hand over the next 100'),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 8),
        ],
        if (value.tasks.isEmpty)
          _muted(
            context,
            'No follow-up tasks.',
            key: const Key('routing-empty'),
          ),
        for (final r in value.tasks)
          _Card(
            key: Key('routing-${r.taskId}'),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  r.purposeLabel,
                  style: ChurchType.body.copyWith(fontWeight: FontWeight.w600),
                ),
                Text('Owner: ${_personText(r.owner)}'),
                Text('Supervisor: ${_personText(r.supervisor)}'),
                _muted(context, 'Scope: ${r.scope.label}'),
                _muted(context, _datesText(context, r)),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    StatusLabel(
                      key: Key('routing-status-${r.taskId}'),
                      label: _statusLabel(r).$1,
                      tone: _statusLabel(r).$2,
                    ),
                    if (r.state.active)
                      _ReassignButton(
                        routing: r,
                        candidates: followUpCandidatesFor(
                          value.scopes,
                          r.scope,
                        ),
                        busy: s.busy,
                        onReassign: (ref, owner) => ref
                            .read(followUpRoutingProvider.notifier)
                            .reassign(
                              r,
                              ownerMemberId: owner,
                              subject: 'the task',
                            ),
                      ),
                  ],
                ),
              ],
            ),
          ),
        if (value.truncated)
          _muted(context, 'Only the first 500 tasks are shown.'),
      ],
    ),
  );
}

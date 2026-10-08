import 'package:church_design_system/church_design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../application/inbox_controllers.dart';
import '../domain/access_grants.dart';
import '../domain/inbox.dart';
import 'shell_routing.dart';

/// Story 3.1: the member's durable inbox on both clients. Items stay here
/// whether or not push is allowed; the list is read from the server each time
/// the screen opens, on **Check again** and when the app returns to the
/// foreground, and nothing is kept on the device.
class InboxScreen extends ConsumerStatefulWidget {
  const InboxScreen({super.key});

  @override
  ConsumerState<InboxScreen> createState() => _InboxScreenState();
}

class _InboxScreenState extends ConsumerState<InboxScreen> {
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onResume: _refresh);
    Future.microtask(_refresh);
  }

  void _refresh() {
    if (!mounted) return;
    ref.read(inboxProvider.notifier).refresh();
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = ChurchColors.of(context);
    final layout = ChurchLayout.of(context);
    // Story 3.7: while the inbox is open, the server's generic refresh
    // signal and a 2-minute poll re-read it.
    ref.watch(inboxLiveProvider);
    final s = ref.watch(inboxProvider);
    final inbox = s.inbox;
    final children = <Widget>[];
    if (s.result == null) {
      children.add(
        const RequestStateBanner(
          key: Key('inbox-loading'),
          tone: StatusTone.info,
          busy: true,
          title: 'Checking your inbox…',
          message: 'The server checks your access every time.',
        ),
      );
    } else if (inbox == null) {
      children.add(_problem(s.result!, 'inbox'));
    } else if (inbox.items.isEmpty) {
      children.add(
        const RequestStateBanner(
          key: Key('inbox-empty'),
          tone: StatusTone.neutral,
          icon: Icons.inbox_outlined,
          title: 'Nothing waiting for you',
          message:
              'Reminders for you appear here, even when notifications '
              'are turned off on this device.',
        ),
      );
    } else {
      children.add(
        Semantics(
          header: true,
          child: Text(
            inbox.items.length == 1
                ? '1 reminder'
                : '${inbox.items.length}${inbox.next == null ? '' : '+'} reminders',
            key: const Key('inbox-count'),
            style: ChurchType.cardTitle.copyWith(color: c.ink),
          ),
        ),
      );
      for (final item in inbox.items) {
        children.addAll([const SizedBox(height: 12), _InboxTile(item: item)]);
      }
      if (s.olderFailed) {
        children.addAll([
          const SizedBox(height: 12),
          const RequestStateBanner(
            key: Key('inbox-older-failed'),
            tone: StatusTone.danger,
            icon: Icons.error_outline,
            title: 'Couldn\'t load older reminders',
            message: 'The reminders above are unchanged. Try again.',
          ),
        ]);
      }
      if (inbox.next != null) {
        children.addAll([
          const SizedBox(height: 12),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: FocusRing(
              child: OutlinedButton.icon(
                key: const Key('inbox-older'),
                onPressed: s.loading
                    ? null
                    : () => ref.read(inboxProvider.notifier).loadOlder(),
                icon: const Icon(Icons.expand_more),
                label: const Text('Show older reminders'),
              ),
            ),
          ),
        ]);
      }
    }
    children.addAll([
      const SizedBox(height: ChurchGeometry.sectionGap),
      Wrap(
        spacing: 12,
        runSpacing: 12,
        children: [
          FocusRing(
            child: OutlinedButton.icon(
              key: const Key('refresh-inbox'),
              onPressed: s.loading ? null : _refresh,
              icon: const Icon(Icons.refresh),
              label: const Text('Check again'),
            ),
          ),
          // Story 3.7: push settings by category.
          FocusRing(
            child: OutlinedButton.icon(
              key: const Key('open-notification-settings'),
              onPressed: () => context.push(ClientPaths.notificationSettings),
              icon: const Icon(Icons.notifications_active_outlined),
              label: const Text('Notification settings'),
            ),
          ),
        ],
      ),
    ]);
    return Scaffold(
      appBar: AppBar(title: const Text('Inbox')),
      body: SafeArea(
        // Story 3.7: pull down to ask the server again (also on open, on
        // resume, on the server's refresh signal and every 2 minutes).
        child: RefreshIndicator(
          key: const Key('inbox-pull-to-refresh'),
          onRefresh: () => ref.read(inboxProvider.notifier).refresh(),
          child: SingleChildScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
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
      ),
    );
  }
}

Widget _problem<T>(
  AccessRead<T> r,
  String keyPrefix, {
  String failedTitle = 'Couldn\'t load your inbox',
}) => switch (r) {
  AccessReadOk() => const SizedBox.shrink(),
  AccessReadDenied(:final denial) => RequestStateBanner(
    key: Key('$keyPrefix-denied-${denial.name}'),
    tone: switch (denial) {
      AccessDenial.untrustedSession ||
      AccessDenial.reviewRequired => StatusTone.warning,
      AccessDenial.signedOut || AccessDenial.notLinked => StatusTone.info,
      _ => StatusTone.neutral,
    },
    icon: Icons.lock_outline,
    title: switch (denial) {
      AccessDenial.signedOut => 'Not signed in',
      AccessDenial.untrustedSession => 'Please sign in again',
      AccessDenial.notLinked => 'No member access yet',
      AccessDenial.reviewRequired => 'Access review required',
      AccessDenial.notGranted => 'Not available to you',
      AccessDenial.unavailable => 'Not available yet',
    },
    message: switch (denial) {
      AccessDenial.signedOut =>
        'Sign in with your phone number and password to see your reminders.',
      AccessDenial.untrustedSession => 'This sign-in is no longer valid.',
      AccessDenial.notLinked =>
        'This account is not yet linked to a church member record.',
      AccessDenial.reviewRequired =>
        'Your access needs a check by the church before it can continue. '
            'Please contact the church office for help.',
      AccessDenial.notGranted => 'Your account does not have this permission.',
      AccessDenial.unavailable => 'The inbox is not available here yet.',
    },
  ),
  AccessReadFailed(:final unreachable) => RequestStateBanner(
    key: Key('$keyPrefix-failed'),
    tone: StatusTone.danger,
    icon: unreachable ? Icons.cloud_off_outlined : Icons.error_outline,
    title: unreachable ? 'No connection' : failedTitle,
    message: unreachable
        ? 'We couldn\'t reach the church server. Nothing is shown until it '
              'answers; your reminders are kept there.'
        : 'The server answered in an unexpected way. Try again later.',
  ),
};

/// Story 3.7: snooze one current reminder for a policy choice. Only this
/// member's reminder moves; the server clamps it to when the reminder stops
/// mattering and drops it when the member answers or the source changes.
class _SnoozeSection extends ConsumerWidget {
  const _SnoozeSection({
    required this.itemId,
    required this.choices,
    required this.snoozedUntil,
    required this.when,
  });

  final String itemId;
  final List<String> choices;
  final DateTime? snoozedUntil;
  final String Function(DateTime) when;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = ChurchColors.of(context);
    final s = ref.watch(snoozeProvider(itemId));
    final sending = s.status == SnoozeStatus.sending;
    return Column(
      key: const Key('inbox-item-snooze'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          header: true,
          child: Text(
            'Remind me later',
            style: ChurchType.cardTitle.copyWith(color: c.ink),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          snoozedUntil == null
              ? 'Only your reminder moves. It comes back here at the time '
                    'you choose, unless you answer it first or it changes.'
              : 'Snoozed until ${when(snoozedUntil!)}. Choose again to '
                    'change it.',
          key: Key(
            snoozedUntil == null
                ? 'inbox-item-not-snoozed'
                : 'inbox-item-snoozed-until',
          ),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final choice in choices)
              FocusRing(
                child: OutlinedButton.icon(
                  key: Key('snooze-${choice.replaceAll(' ', '-')}'),
                  onPressed: sending
                      ? null
                      : () => ref
                            .read(snoozeProvider(itemId).notifier)
                            .snooze(choice),
                  icon: const Icon(Icons.snooze),
                  label: Text(choice),
                ),
              ),
          ],
        ),
        if (s.status != SnoozeStatus.idle) ...[
          const SizedBox(height: 12),
          _snoozeBanner(
            s,
            when,
            () => ref.read(snoozeProvider(itemId).notifier).retry(),
          ),
        ],
      ],
    );
  }
}

Widget _snoozeBanner(
  SnoozeState s,
  String Function(DateTime) when,
  VoidCallback retry,
) {
  final confirmed = s.confirmed;
  return switch (s.status) {
    SnoozeStatus.idle => const SizedBox.shrink(),
    SnoozeStatus.sending => RequestStateBanner(
      key: const Key('snooze-sending'),
      tone: StatusTone.info,
      busy: true,
      title: 'Snoozing…',
      message: 'Waiting for the server to confirm ${s.choice ?? ''}.',
    ),
    SnoozeStatus.confirmed when confirmed != null && confirmed.clamped =>
      RequestStateBanner(
        key: const Key('snooze-clamped'),
        tone: StatusTone.warning,
        icon: Icons.schedule,
        title: 'Snoozed until ${when(confirmed.scheduledAt)}',
        message:
            'It could not wait ${s.choice ?? 'that long'}: this reminder '
            'stops mattering then, so it comes back at that time instead.',
      ),
    SnoozeStatus.confirmed => RequestStateBanner(
      key: const Key('snooze-confirmed'),
      tone: StatusTone.success,
      icon: Icons.check_circle_outline,
      title: confirmed == null
          ? 'Snoozed'
          : 'Snoozed until ${when(confirmed.scheduledAt)}',
      message:
          'It comes back in your inbox then, unless you answer it first or '
          'it changes.',
    ),
    SnoozeStatus.outOfDate => const RequestStateBanner(
      key: Key('snooze-out-of-date'),
      tone: StatusTone.warning,
      icon: Icons.update,
      title: 'This reminder is out of date',
      message: 'Nothing was snoozed. There is nothing to do here.',
    ),
    SnoozeStatus.expired => const RequestStateBanner(
      key: Key('snooze-expired'),
      tone: StatusTone.warning,
      icon: Icons.event_busy,
      title: 'This reminder has ended',
      message:
          'Nothing was snoozed: what it was about has already started '
          'or passed.',
    ),
    SnoozeStatus.notFound => const RequestStateBanner(
      key: Key('snooze-not-found'),
      tone: StatusTone.neutral,
      icon: Icons.search_off,
      title: 'This reminder isn\'t available',
      message: 'Nothing was snoozed.',
    ),
    SnoozeStatus.refused => const RequestStateBanner(
      key: Key('snooze-refused'),
      tone: StatusTone.danger,
      icon: Icons.error_outline,
      title: 'Couldn\'t snooze',
      message: 'The server did not accept it. Nothing was snoozed.',
    ),
    SnoozeStatus.unknown => RequestStateBanner(
      key: const Key('snooze-unknown'),
      tone: StatusTone.danger,
      icon: Icons.help_outline,
      title: 'We don\'t know yet if it was snoozed',
      message:
          'The server did not answer. Try again: it sends the same request '
          'and the server tells us what happened.',
      actions: [
        BannerAction(
          'Try again',
          retry,
          key: const Key('snooze-retry'),
          primary: true,
        ),
      ],
    ),
    SnoozeStatus.notSent => const RequestStateBanner(
      key: Key('snooze-not-sent'),
      tone: StatusTone.neutral,
      icon: Icons.cloud_off_outlined,
      title: 'Not sent',
      message: 'This build has no server configured.',
    ),
  };
}

class _InboxTile extends StatelessWidget {
  const _InboxTile({required this.item});

  final InboxItem item;

  @override
  Widget build(BuildContext context) {
    final c = ChurchColors.of(context);
    final l10n = MaterialLocalizations.of(context);
    String when(DateTime at) {
      final local = at.toLocal();
      return '${l10n.formatMediumDate(local)} '
          '${l10n.formatTimeOfDay(TimeOfDay.fromDateTime(local))}';
    }

    return Semantics(
      container: true,
      button: true,
      child: InkWell(
        key: Key('open-inbox-item-${item.itemId}'),
        borderRadius: BorderRadius.circular(12),
        onTap: () => context.push(ClientPaths.inboxItem(item.itemId)),
        child: DecoratedBox(
          key: Key('inbox-item-${item.itemId}'),
          decoration: BoxDecoration(
            color: c.surface,
            border: Border.all(color: c.line),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.notifications_outlined, color: c.muted),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        item.title,
                        style: ChurchType.cardTitle.copyWith(color: c.ink),
                      ),
                      // Story 3.7: what the member did in the app, never
                      // whether a push arrived or was read.
                      if (item.opened != null || item.snoozedUntil != null) ...[
                        const SizedBox(height: 6),
                        Wrap(
                          spacing: 8,
                          runSpacing: 6,
                          children: [
                            if (item.opened == false)
                              StatusLabel(
                                key: Key('inbox-item-new-${item.itemId}'),
                                label: 'New',
                                tone: StatusTone.info,
                              ),
                            if (item.opened == true)
                              StatusLabel(
                                key: Key('inbox-item-opened-${item.itemId}'),
                                label: 'Opened',
                                tone: StatusTone.neutral,
                              ),
                            if (item.snoozedUntil != null)
                              StatusLabel(
                                key: Key('inbox-item-snoozed-${item.itemId}'),
                                label:
                                    'Snoozed until ${when(item.snoozedUntil!)}',
                                tone: StatusTone.warning,
                              ),
                          ],
                        ),
                      ],
                      if (item.body != null) ...[
                        const SizedBox(height: 4),
                        Text(item.body!),
                      ],
                      const SizedBox(height: 4),
                      Text('Due ${when(item.dueAt)}'),
                      Text(
                        'Arrived ${when(item.deliveredAt)}',
                        style: ChurchType.secondary.copyWith(color: c.muted),
                      ),
                    ],
                  ),
                ),
                Icon(Icons.chevron_right, color: c.muted),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Story 3.2: one opened inbox item (`/inbox/:itemId`). Each open asks the
/// server, which re-reads the item's source now: a current item offers its
/// authorised destination, anything else is the generic "out of date" state
/// with no detail about the source.
class InboxItemScreen extends ConsumerStatefulWidget {
  const InboxItemScreen({
    super.key,
    required this.itemId,
    this.knownTarget = ClientPaths.isKnownDeepLink,
  });

  final String itemId;

  /// Whether this build has a screen for a server-provided target.
  final bool Function(String target) knownTarget;

  @override
  ConsumerState<InboxItemScreen> createState() => _InboxItemScreenState();
}

class _InboxItemScreenState extends ConsumerState<InboxItemScreen> {
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onResume: _refresh);
  }

  void _refresh() {
    if (!mounted) return;
    ref.read(inboxItemProvider(widget.itemId).notifier).refresh();
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = ChurchColors.of(context);
    final layout = ChurchLayout.of(context);
    final l10n = MaterialLocalizations.of(context);
    String when(DateTime at) {
      final local = at.toLocal();
      return '${l10n.formatMediumDate(local)} '
          '${l10n.formatTimeOfDay(TimeOfDay.fromDateTime(local))}';
    }

    final s = ref.watch(inboxItemProvider(widget.itemId));
    final opened = s.opened;
    final item = opened?.item;
    final children = <Widget>[];
    if (s.result == null) {
      children.add(
        const RequestStateBanner(
          key: Key('inbox-item-loading'),
          tone: StatusTone.info,
          busy: true,
          title: 'Checking this reminder…',
          message: 'The server checks it again every time you open it.',
        ),
      );
    } else if (opened == null) {
      children.add(
        _problem(
          s.result!,
          'inbox-item',
          failedTitle: 'Couldn\'t open this reminder',
        ),
      );
      // Story 3.6: a tapped notification may open this screen signed out;
      // after sign-in the person returns here and the server checks again.
      if (s.result case AccessReadDenied(denial: AccessDenial.signedOut)) {
        children.addAll([
          const SizedBox(height: 12),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: FocusRing(
              child: FilledButton.icon(
                key: const Key('inbox-item-sign-in'),
                onPressed: () => context.go(
                  ClientPaths.signInThen(ClientPaths.inboxItem(widget.itemId)),
                ),
                icon: const Icon(Icons.login),
                label: const Text('Sign in'),
              ),
            ),
          ),
        ]);
      }
    } else if (opened.state == InboxItemState.notFound || item == null) {
      children.add(
        const RequestStateBanner(
          key: Key('inbox-item-not-found'),
          tone: StatusTone.neutral,
          icon: Icons.search_off,
          title: 'This reminder isn\'t available',
          message:
              'It may have been removed, or it belongs to another account.',
        ),
      );
    } else {
      children.addAll([
        Semantics(
          header: true,
          child: Text(
            item.title,
            key: const Key('inbox-item-title'),
            style: ChurchType.cardTitle.copyWith(color: c.ink),
          ),
        ),
        if (item.body != null) ...[
          const SizedBox(height: 8),
          Text(item.body!, key: const Key('inbox-item-body')),
        ],
        const SizedBox(height: 8),
        Text('Due ${when(item.dueAt)}'),
        Text(
          'Arrived ${when(item.deliveredAt)}',
          style: ChurchType.secondary.copyWith(color: c.muted),
        ),
        const SizedBox(height: 16),
      ]);
      final target = opened.target;
      if (opened.state == InboxItemState.superseded) {
        children.add(
          const RequestStateBanner(
            key: Key('inbox-item-superseded'),
            tone: StatusTone.warning,
            icon: Icons.update,
            title: 'This reminder is out of date',
            message:
                'What it was about has changed, ended or is no longer '
                'available to you. There is nothing to do here.',
          ),
        );
      } else if (target != null && widget.knownTarget(target)) {
        children.add(
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: FocusRing(
              child: FilledButton.icon(
                key: const Key('inbox-item-open-target'),
                onPressed: () => context.go(target),
                icon: const Icon(Icons.arrow_forward),
                label: const Text('Open'),
              ),
            ),
          ),
        );
      } else {
        children.add(
          const RequestStateBanner(
            key: Key('inbox-item-later-version'),
            tone: StatusTone.info,
            icon: Icons.info_outline,
            title: 'Still current',
            message:
                'The screen this reminder leads to is not in this version '
                'of the app yet.',
          ),
        );
      }
      if (opened.state == InboxItemState.current &&
          opened.snoozeChoices.isNotEmpty) {
        children.addAll([
          const SizedBox(height: ChurchGeometry.sectionGap),
          _SnoozeSection(
            itemId: widget.itemId,
            choices: opened.snoozeChoices,
            snoozedUntil: item.snoozedUntil,
            when: when,
          ),
        ]);
      }
    }
    // Story 3.7: after a snooze the server's answer may say the reminder is
    // out of date even when the last open still showed it current.
    if (opened?.state != InboxItemState.current) {
      final snooze = ref.watch(snoozeProvider(widget.itemId));
      if (snooze.status
          case SnoozeStatus.outOfDate ||
              SnoozeStatus.expired ||
              SnoozeStatus.notFound) {
        children.addAll([
          const SizedBox(height: 12),
          _snoozeBanner(snooze, when, () {}),
        ]);
      }
    }
    children.addAll([
      const SizedBox(height: ChurchGeometry.sectionGap),
      Wrap(
        spacing: 12,
        runSpacing: 12,
        children: [
          FocusRing(
            child: OutlinedButton.icon(
              key: const Key('refresh-inbox-item'),
              onPressed: s.loading ? null : _refresh,
              icon: const Icon(Icons.refresh),
              label: const Text('Check again'),
            ),
          ),
          FocusRing(
            child: OutlinedButton.icon(
              key: const Key('back-to-inbox'),
              onPressed: () => context.go(ClientPaths.inbox),
              icon: const Icon(Icons.inbox_outlined),
              label: const Text('Back to inbox'),
            ),
          ),
        ],
      ),
    ]);
    return Scaffold(
      appBar: AppBar(title: const Text('Reminder')),
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

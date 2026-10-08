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
      Align(
        alignment: AlignmentDirectional.centerStart,
        child: FocusRing(
          child: OutlinedButton.icon(
            key: const Key('refresh-inbox'),
            onPressed: s.loading ? null : _refresh,
            icon: const Icon(Icons.refresh),
            label: const Text('Check again'),
          ),
        ),
      ),
    ]);
    return Scaffold(
      appBar: AppBar(title: const Text('Inbox')),
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

import 'package:church_design_system/church_design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../application/inbox_controllers.dart';
import '../domain/access_grants.dart';
import '../domain/inbox.dart';

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
      children.add(_problem(s.result!));
    } else if (inbox.items.isEmpty) {
      children.add(
        const RequestStateBanner(
          key: Key('inbox-empty'),
          tone: StatusTone.neutral,
          icon: Icons.inbox_outlined,
          title: 'Nothing waiting for you',
          message: 'Reminders for you appear here, even when notifications '
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
                : '${inbox.items.length} reminders',
            key: const Key('inbox-count'),
            style: ChurchType.cardTitle.copyWith(color: c.ink),
          ),
        ),
      );
      for (final item in inbox.items) {
        children.addAll([const SizedBox(height: 12), _InboxTile(item: item)]);
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

Widget _problem(AccessRead<Inbox> r) => switch (r) {
  AccessReadOk() => const SizedBox.shrink(),
  AccessReadDenied(:final denial) => RequestStateBanner(
    key: Key('inbox-denied-${denial.name}'),
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
    key: const Key('inbox-failed'),
    tone: StatusTone.danger,
    icon: unreachable ? Icons.cloud_off_outlined : Icons.error_outline,
    title: unreachable ? 'No connection' : 'Couldn\'t load your inbox',
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
                    const SizedBox(height: 4),
                    Text('Due ${when(item.dueAt)}'),
                    Text(
                      'Arrived ${when(item.deliveredAt)}',
                      style: ChurchType.secondary.copyWith(color: c.muted),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

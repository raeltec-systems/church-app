import 'package:church_design_system/church_design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../application/account_controllers.dart';
import '../application/providers.dart';
import '../domain/member_access.dart';
import 'shell_routing.dart' show ClientPaths;

/// "My membership": the signed-in member's own summary from the server's
/// live-access-checked read, or a generic state that says what to do next.
/// Shown the same way on mobile and staff web.
class AccountScreen extends ConsumerWidget {
  const AccountScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = ChurchColors.of(context);
    final layout = ChurchLayout.of(context);
    final account = ref.watch(accountProvider);
    final s = ref.watch(memberSummaryControllerProvider);
    final signedIn = account.accountId != null;

    Future<void> signOut() async {
      await ref.read(accountAuthGatewayProvider).signOut();
      if (context.mounted) announce(context, 'Signed out');
    }

    final children = <Widget>[];
    if (account.lastChange == AccountChange.signedOut ||
        account.lastChange == AccountChange.switched) {
      children.addAll([
        RequestStateBanner(
          key: const Key('account-changed'),
          tone: StatusTone.info,
          icon: Icons.switch_account_outlined,
          title: account.lastChange == AccountChange.signedOut
              ? 'Signed out'
              : 'Account changed',
          message: 'Information from the previous session was cleared from this device.',
          actions: [
            BannerAction(
              'Dismiss',
              () => ref.read(accountProvider.notifier).acknowledgeChange(),
              key: const Key('dismiss-account-changed'),
            ),
          ],
        ),
        const SizedBox(height: ChurchGeometry.sectionGap),
      ]);
    }

    if (!signedIn) {
      children.addAll([
        Text(
          'Sign in with your phone number and password to see your membership.',
          style: layout.body.copyWith(color: c.ink),
        ),
        const SizedBox(height: ChurchGeometry.sectionGap),
        Wrap(
          spacing: 12,
          runSpacing: 8,
          children: [
            FocusRing(
              child: FilledButton(
                key: const Key('go-sign-in'),
                onPressed: () => context.go(ClientPaths.signIn),
                child: const Text('Sign in'),
              ),
            ),
            FocusRing(
              child: OutlinedButton(
                key: const Key('go-create-account'),
                onPressed: () => context.go(ClientPaths.createAccount),
                child: const Text('Create account'),
              ),
            ),
          ],
        ),
      ]);
    } else {
      final result = s.result;
      if (s.loading && result == null) {
        children.add(
          const RequestStateBanner(
            key: Key('summary-loading'),
            tone: StatusTone.info,
            busy: true,
            title: 'Loading your membership…',
            message: 'The server checks your access every time.',
          ),
        );
      } else if (result != null) {
        children.add(_resultView(context, ref, result));
      }
      children.addAll([
        const SizedBox(height: ChurchGeometry.sectionGap),
        Wrap(
          spacing: 12,
          runSpacing: 8,
          children: [
            FocusRing(
              child: OutlinedButton.icon(
                key: const Key('refresh-summary'),
                onPressed: s.loading
                    ? null
                    : () => ref
                          .read(memberSummaryControllerProvider.notifier)
                          .refresh(),
                icon: const Icon(Icons.refresh),
                label: const Text('Check again'),
              ),
            ),
            FocusRing(
              child: OutlinedButton.icon(
                key: const Key('sign-out'),
                onPressed: signOut,
                icon: const Icon(Icons.logout),
                label: const Text('Sign out'),
              ),
            ),
          ],
        ),
      ]);
    }

    return Scaffold(
      appBar: AppBar(title: const Text('My membership')),
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

  Widget _resultView(
    BuildContext context,
    WidgetRef ref,
    MemberAccessResult result,
  ) {
    final c = ChurchColors.of(context);
    switch (result) {
      case MemberAccessGranted(:final summary):
        return Container(
          key: const Key('member-summary'),
          padding: const EdgeInsets.all(ChurchGeometry.cardPadding),
          decoration: BoxDecoration(
            color: c.surface,
            border: Border.all(color: c.line),
            borderRadius: BorderRadius.circular(
              ChurchGeometry.mobileCardRadius,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Semantics(
                header: true,
                child: Text(
                  summary.displayName,
                  style: ChurchType.cardTitle.copyWith(color: c.ink),
                ),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  StatusLabel(
                    label: summary.membershipState == 'approved'
                        ? 'Church member'
                        : summary.membershipState,
                    tone: StatusTone.success,
                  ),
                  if (summary.isSynthetic)
                    const StatusLabel(
                      label: 'Synthetic test record',
                      tone: StatusTone.neutral,
                    ),
                ],
              ),
              const SizedBox(height: 12),
              Text('Sign-in username: ${summary.phoneUsername}'),
              const SizedBox(height: 4),
              Text(
                summary.hasRecoveryEmail
                    ? 'Recovery email: added and approved.'
                    : 'Recovery email: none. If you forget your password, '
                          'church staff will help you in person.',
                style: ChurchType.secondary.copyWith(color: c.muted),
              ),
            ],
          ),
        );
      case MemberAccessDenied(:final denial):
        final (title, message, tone) = switch (denial) {
          MemberAccessDenial.signedOut => (
            'Not signed in',
            'Sign in to see your membership.',
            StatusTone.info,
          ),
          MemberAccessDenial.untrustedSession => (
            'Please sign in again',
            'This sign-in is no longer valid. Sign out, then sign in with your '
                'phone number and password.',
            StatusTone.warning,
          ),
          MemberAccessDenial.notLinked => (
            'No member access yet',
            'You are signed in, but this account is not yet linked to a church '
                'member record. The church links accounts after checking who '
                'you are. Ask the church office if you are waiting.',
            StatusTone.info,
          ),
          MemberAccessDenial.reviewRequired => (
            'Access review required',
            'Your access needs a check by the church before it can continue. '
                'Please contact the church office for help.',
            StatusTone.warning,
          ),
          MemberAccessDenial.unavailable => (
            'Not available yet',
            'Member information is not available here yet.',
            StatusTone.neutral,
          ),
        };
        return RequestStateBanner(
          key: Key('denied-${denial.name}'),
          tone: tone,
          icon: Icons.lock_outline,
          title: title,
          message: message,
        );
      case MemberAccessFailed(:final unreachable):
        return RequestStateBanner(
          key: const Key('summary-failed'),
          tone: StatusTone.danger,
          icon: unreachable ? Icons.cloud_off_outlined : Icons.error_outline,
          title: unreachable
              ? 'No connection'
              : 'Couldn\'t load your membership',
          message: unreachable
              ? 'We couldn\'t reach the church server. Nothing is shown until it answers.'
              : 'The server answered in an unexpected way. Try again later.',
        );
    }
  }
}

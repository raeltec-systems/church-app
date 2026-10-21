import 'package:church_design_system/church_design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../application/account_controllers.dart';
import '../application/cell_controllers.dart' show myCellProvider;
import '../application/membership_lifecycle_controllers.dart';
import '../application/providers.dart';
import '../application/push_controllers.dart';
import '../domain/access_grants.dart' show AccessReadOk;
import '../domain/member_access.dart';
import 'church_widgets.dart';
import 'shell_routing.dart' show ClientPaths;

/// "My membership": the signed-in member's own summary from the server's
/// live-access-checked read, or a generic state that says what to do next.
/// Shown the same way on mobile and staff web.
///
/// When the app returns to the foreground (or a web tab becomes visible
/// again), the summary is asked for again before it is relied on (AD-13); the
/// server re-checks the session each time.
class AccountScreen extends ConsumerStatefulWidget {
  const AccountScreen({
    super.key,
    this.linkMembershipRequest = false,
    this.linkRecoveryEmail = false,
    this.memberMenu = false,
  });

  /// Story 2.4 (mobile): an account without member access links to its own
  /// membership request.
  final bool linkMembershipRequest;

  /// Story 2.7 (mobile): a member links to their own recovery email (also
  /// while access waits for its approval).
  final bool linkRecoveryEmail;

  /// Mobile: the member's own places (duties, history, cell, follow-ups) and
  /// settings as a menu, the design handoff's Profile.
  final bool memberMenu;

  @override
  ConsumerState<AccountScreen> createState() => _AccountScreenState();
}

class _AccountScreenState extends ConsumerState<AccountScreen> {
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onResume: _revalidate);
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  void _revalidate() {
    if (!mounted || ref.read(accountProvider).accountId == null) return;
    if (ref.read(memberSummaryControllerProvider).loading) return;
    ref.read(memberSummaryControllerProvider.notifier).refresh();
  }

  @override
  Widget build(BuildContext context) {
    final c = ChurchColors.of(context);
    final layout = ChurchLayout.of(context);
    final account = ref.watch(accountProvider);
    final s = ref.watch(memberSummaryControllerProvider);
    final signedIn = account.accountId != null;

    Future<void> signOut() async {
      // Story 3.6: this device stops receiving the account's pushes first.
      await ref.read(pushRegistrationProvider.notifier).retireBeforeSignOut();
      await ref.read(accountAuthGatewayProvider).signOut();
      if (context.mounted) announce(context, 'Signed out');
    }

    final children = <Widget>[];
    final change = account.lastChange;
    if (change == AccountChange.signedOut ||
        change == AccountChange.switched ||
        change == AccountChange.sessionEnded) {
      children.addAll([
        RequestStateBanner(
          key: Key(
            change == AccountChange.sessionEnded
                ? 'session-ended'
                : 'account-changed',
          ),
          tone: change == AccountChange.sessionEnded
              ? StatusTone.warning
              : StatusTone.info,
          icon: change == AccountChange.sessionEnded
              ? Icons.lock_clock_outlined
              : Icons.switch_account_outlined,
          title: switch (change) {
            AccountChange.sessionEnded => 'Please sign in again',
            AccountChange.signedOut => 'Signed out',
            _ => 'Account changed',
          },
          message: change == AccountChange.sessionEnded
              ? 'This sign-in is no longer valid, so it was ended on this '
                    'device and its information was cleared. Sign in with '
                    'your phone number and password.'
              : 'Information from the previous session was cleared from this device.',
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
        const Align(
          alignment: AlignmentDirectional.centerStart,
          child: ChurchLogo(size: 64),
        ),
        const SizedBox(height: 16),
        Text(
          'Sign in',
          style: ChurchType.mobileScreenTitle.copyWith(color: c.ink),
        ),
        const SizedBox(height: 6),
        Text(
          'Sign in with your phone number and password to see your membership.',
          style: layout.body.copyWith(color: c.muted),
        ),
        const SizedBox(height: 24),
        FocusRing(
          child: FilledButton(
            key: const Key('go-sign-in'),
            style: FilledButton.styleFrom(minimumSize: const Size(0, 52)),
            onPressed: () => context.go(ClientPaths.signIn),
            child: const Text('Sign in'),
          ),
        ),
        const SizedBox(height: 10),
        FocusRing(
          child: OutlinedButton(
            key: const Key('go-create-account'),
            style: OutlinedButton.styleFrom(minimumSize: const Size(0, 52)),
            onPressed: () => context.go(ClientPaths.createAccount),
            child: const Text('Create account'),
          ),
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
        const SizedBox(height: 16),
        ChurchCard(
          padding: EdgeInsets.zero,
          child: MenuRow(
            key: const Key('sign-out'),
            label: 'Sign out',
            danger: true,
            showDivider: false,
            onTap: signOut,
          ),
        ),
      ]);
    }
    final refresh = !signedIn || s.loading
        ? null
        : () => ref.read(memberSummaryControllerProvider.notifier).refresh();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Account'),
        actions: [
          if (signedIn)
            FocusRing(
              radius: 22,
              child: IconButton(
                key: const Key('refresh-summary'),
                tooltip: 'Check again',
                onPressed: refresh,
                icon: const Icon(Icons.refresh),
              ),
            ),
          const SizedBox(width: 4),
        ],
      ),
      body: SafeArea(
        child: RefreshIndicator(
          notificationPredicate: (n) => refresh != null && n.depth == 0,
          onRefresh: () async => refresh?.call(),
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

  Widget _resultView(
    BuildContext context,
    WidgetRef ref,
    MemberAccessResult result,
  ) {
    final c = ChurchColors.of(context);
    switch (result) {
      case MemberAccessGranted(:final summary):
        final cell = widget.memberMenu
            ? switch (ref.watch(myCellProvider).result) {
                AccessReadOk(:final value) => value.cell.primary?.label,
                _ => null,
              }
            : null;
        void go(String path) => context.push(path);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              key: const Key('member-summary'),
              children: [
                InitialsAvatar(name: summary.displayName, size: 64),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Semantics(
                        header: true,
                        child: Text(
                          summary.displayName,
                          style: ChurchType.mobileScreenTitle.copyWith(
                            color: c.ink,
                          ),
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        summary.phoneUsername,
                        key: const Key('summary-phone'),
                        semanticsLabel:
                            'Sign-in username ${summary.phoneUsername}',
                        style: ChurchType.figures.copyWith(color: c.muted),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            // Church membership and the cell are confirmed separately, so
            // they are two marks.
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
                if (cell != null)
                  StatusLabel(
                    key: const Key('summary-cell'),
                    label: 'Cell: $cell',
                    tone: StatusTone.info,
                  ),
                if (summary.isSynthetic)
                  const StatusLabel(
                    label: 'Synthetic test record',
                    tone: StatusTone.neutral,
                  ),
              ],
            ),
            if (widget.memberMenu) ...[
              const SizedBox(height: 24),
              const CardLabel('Your church'),
              const SizedBox(height: 8),
              ChurchCard(
                padding: EdgeInsets.zero,
                child: Column(
                  children: [
                    MenuRow(
                      key: const Key('go-my-duties'),
                      label: 'My duties',
                      onTap: () => context.go(ClientPaths.myDuties),
                    ),
                    MenuRow(
                      key: const Key('go-duty-history'),
                      label: 'My duty history',
                      onTap: () => go(ClientPaths.dutyHistory),
                    ),
                    MenuRow(
                      key: const Key('go-my-cell'),
                      label: 'My cell',
                      meta: cell,
                      onTap: () => context.go(ClientPaths.myCell),
                    ),
                    MenuRow(
                      key: const Key('go-my-followups'),
                      label: 'My follow-ups',
                      showDivider: false,
                      onTap: () => go(ClientPaths.myFollowUps),
                    ),
                  ],
                ),
              ),
            ],
            if (widget.linkRecoveryEmail) ...[
              const SizedBox(height: 24),
              const CardLabel('Settings'),
              const SizedBox(height: 8),
              ChurchCard(
                padding: EdgeInsets.zero,
                child: Column(
                  children: [
                    if (widget.memberMenu)
                      MenuRow(
                        key: const Key('go-notification-settings'),
                        label: 'Notifications',
                        onTap: () => go(ClientPaths.notificationSettings),
                      ),
                    // Story 2.8: reviewed username and recovery-email changes.
                    MenuRow(
                      key: const Key('go-sign-in-details'),
                      label: 'Sign-in details',
                      onTap: () => context.go(ClientPaths.signInDetails),
                    ),
                    MenuRow(
                      key: const Key('go-recovery-email'),
                      label: 'Recovery email',
                      meta: summary.hasRecoveryEmail ? 'Added' : 'None',
                      onTap: () => context.go(ClientPaths.recoveryEmail),
                    ),
                    MenuRow(
                      key: const Key('go-my-access'),
                      label: 'My roles',
                      showDivider: false,
                      onTap: () => context.go(ClientPaths.access),
                    ),
                  ],
                ),
              ),
              if (!summary.hasRecoveryEmail) ...[
                const SizedBox(height: 8),
                Text(
                  'With no recovery email, church staff help you in person if '
                  'you forget your password.',
                  style: ChurchType.secondary.copyWith(color: c.muted),
                ),
              ],
              const SizedBox(height: 16),
              // Story 2.11: the member deletes their own account; it comes
              // last and says what it does.
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: FocusRing(
                  child: TextButton(
                    key: const Key('go-delete-account'),
                    style: TextButton.styleFrom(foregroundColor: c.redFg),
                    onPressed: () => context.go(ClientPaths.deleteAccount),
                    child: const Text('Delete my account'),
                  ),
                ),
              ),
            ],
          ],
        );
      case MemberAccessDenied(:final denial):
        // Story 2.10: an account whose church membership was deactivated is
        // told so (never why), with the church contact, and is not sent to
        // the membership request.
        if (denial == MemberAccessDenial.notLinked) {
          final status = ref.watch(myMembershipStatusProvider);
          if (status case AccessReadOk(:final value) when value.deactivated) {
            final contact = value.churchContact;
            return RequestStateBanner(
              key: const Key('membership-deactivated'),
              tone: StatusTone.warning,
              icon: Icons.person_off_outlined,
              title: 'Church membership not active',
              message:
                  'Your church membership is not active at the moment, so '
                  'member information is closed on every device. Signing in '
                  'again does not change this. ${contact == null ? 'Please contact the church office' : 'Please contact the church: $contact'} '
                  'if you have questions or want to return.',
            );
          }
        }
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
          actions: [
            // Story 2.4: an applicant reaches only their own request.
            if (denial == MemberAccessDenial.notLinked &&
                widget.linkMembershipRequest)
              BannerAction(
                'My membership request',
                () => context.go(ClientPaths.membership),
                key: const Key('go-membership-request'),
                primary: true,
              ),
            // Story 2.8: the generic help screen (church contact and the
            // member's own current request).
            if (denial == MemberAccessDenial.reviewRequired)
              BannerAction(
                'Get help',
                () => context.go(ClientPaths.accessReview),
                key: const Key('go-access-review'),
                primary: true,
              ),
            // Story 2.7: a verified recovery email waiting for approval puts
            // access in review; the member can see why.
            if (denial == MemberAccessDenial.reviewRequired &&
                widget.linkRecoveryEmail)
              BannerAction(
                'Recovery email',
                () => context.go(ClientPaths.recoveryEmail),
                key: const Key('review-go-recovery-email'),
              ),
          ],
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

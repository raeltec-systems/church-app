import 'package:church_design_system/church_design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../application/access_controllers.dart';
import '../application/assisted_recovery_controllers.dart';
import '../application/credential_controllers.dart';
import '../application/member_deletion_controllers.dart';
import '../application/membership_lifecycle_controllers.dart';
import '../application/recovery_controllers.dart';
import '../application/review_controllers.dart';
import '../application/providers.dart';
import '../domain/access_grants.dart';
import 'access_screens.dart';
import 'assisted_recovery_screens.dart';
import 'credential_screens.dart';
import 'member_deletion_screens.dart';
import 'membership_lifecycle_screen.dart';
import 'membership_review_screen.dart';
import 'recovery_screens.dart';

/// These areas use the existing Identity reads and commands. The future
/// all-status directory/activity projection is not simulated by this workspace.
enum UserManagementArea {
  members(
    'members',
    'Members',
    'Search approved members, inspect roles and manage account access.',
  ),
  applications(
    'applications',
    'Applications',
    'Check identity before approving or linking a member.',
  ),
  roles(
    'roles',
    'Roles & access',
    'Grant explicitly; Admin does not imply private care or finance access.',
  ),
  accessReviews(
    'access-reviews',
    'Access reviews',
    'Review credential changes and security holds.',
  ),
  recoveryEmails(
    'recovery-emails',
    'Recovery emails',
    'Review same-account, verified recovery-email proposals.',
  ),
  recovery(
    'recovery',
    'Account recovery',
    'Help the person recover access without handling their password.',
  ),
  membership(
    'membership',
    'Membership status',
    'Review deactivated memberships, login holds and handovers.',
  ),
  deletions(
    'deletions',
    'Member deletions',
    'Track the separately authorised, resumable deletion process.',
  ),
  usernames(
    'usernames',
    'Username disputes',
    'Resolve a claimed sign-in username after an identity check.',
  );

  const UserManagementArea(this.path, this.label, this.description);
  final String path;
  final String label;
  final String description;

  static UserManagementArea parse(String? value) =>
      values.where((area) => area.path == value).firstOrNull ?? members;
  String get location =>
      Uri(path: '/admin/users', queryParameters: {'view': path}).toString();
}

/// One entry for real membership/access workflows. Only the selected work
/// area is mounted. Each retains its own server authorisation and mutations.
class UserManagementScreen extends ConsumerWidget {
  const UserManagementScreen({
    super.key,
    this.area = UserManagementArea.members,
  });
  final UserManagementArea area;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.listen(myAccessProvider, (previous, next) {
      if (previous?.grants?.isAdmin == true &&
          next.result != null &&
          next.grants?.isAdmin != true) {
        // Drop previously read people/cases when current authority ends.
        // Each area must fetch again if Admin access is restored later.
        ref.invalidate(membershipReviewProvider);
        ref.invalidate(grantAdminProvider);
        ref.invalidate(credentialReviewProvider);
        ref.invalidate(recoveryEmailReviewProvider);
        ref.invalidate(recoveryCasesProvider);
        ref.invalidate(membershipLifecycleProvider);
        ref.invalidate(memberDeletionAdminProvider);
      }
    });
    final access = ref.watch(myAccessProvider);
    final generation = ref.watch(accountGenerationProvider);
    final layout = ChurchLayout.of(context);
    final canManage = access.grants?.isAdmin == true;
    final failed = access.result is AccessReadFailed<MemberGrants>;
    final signedOut = ref.watch(
      accountProvider.select((s) => s.accountId == null),
    );
    final body = canManage
        ? Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: EdgeInsets.fromLTRB(
                  layout.pagePadding.left,
                  8,
                  layout.pagePadding.right,
                  8,
                ),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 560),
                  child: DropdownButtonFormField<UserManagementArea>(
                    key: ValueKey('users-area-${area.path}'),
                    initialValue: area,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: 'Users & access',
                    ),
                    items: [
                      for (final value in UserManagementArea.values)
                        DropdownMenuItem(
                          value: value,
                          child: Text(value.label),
                        ),
                    ],
                    onChanged: (value) {
                      if (value != null && value != area) {
                        context.go(value.location);
                      }
                    },
                  ),
                ),
              ),
              Expanded(
                child: KeyedSubtree(
                  key: ValueKey('users-$generation-${area.path}'),
                  child: switch (area) {
                    UserManagementArea.members => const MembershipReviewScreen(
                      initialSection: MembershipReviewSection.members,
                      showSectionSelector: false,
                    ),
                    UserManagementArea.applications =>
                      const MembershipReviewScreen(showSectionSelector: false),
                    UserManagementArea.roles => const GrantAdminScreen(),
                    UserManagementArea.accessReviews =>
                      const CredentialReviewScreen(),
                    UserManagementArea.recoveryEmails =>
                      const RecoveryEmailReviewScreen(),
                    UserManagementArea.recovery => const RecoveryCasesScreen(),
                    UserManagementArea.membership =>
                      const MembershipLifecycleScreen(),
                    UserManagementArea.deletions =>
                      const MemberDeletionScreen(),
                    UserManagementArea.usernames =>
                      const MembershipReviewScreen(
                        initialSection: MembershipReviewSection.reclaim,
                        showSectionSelector: false,
                      ),
                  },
                ),
              ),
            ],
          )
        : SingleChildScrollView(
            padding: layout.pagePadding,
            child: RequestStateBanner(
              key: const Key('users-access-state'),
              tone: access.result == null
                  ? StatusTone.info
                  : StatusTone.warning,
              busy: access.result == null,
              title: access.result == null
                  ? 'Checking access…'
                  : signedOut
                  ? 'Sign in to continue'
                  : failed
                  ? 'Could not check access'
                  : 'Admin access required',
              message: access.result == null
                  ? 'Waiting for the server before loading user records.'
                  : failed
                  ? 'No user records are shown. Check your connection and try again.'
                  : 'Users & access is available only with a current Admin grant. '
                        'Membership and other staff roles do not grant it.',
              actions: [
                if (signedOut)
                  BannerAction(
                    'Sign in',
                    () => context.go('/sign-in'),
                    primary: true,
                  )
                else if (!access.loading)
                  BannerAction(
                    'Check again',
                    () => ref.read(myAccessProvider.notifier).refresh(),
                    primary: true,
                  ),
              ],
            ),
          );
    // Existing work areas own their header and scroll region. Do not stack
    // a second sticky header: it consumes the narrow/high-text-scale viewport.
    if (canManage) return Scaffold(body: SafeArea(child: body));
    return ChurchPageScaffold(
      title: 'Users & access',
      subtitle: canManage
          ? area.description
          : 'Membership, accounts and permissions',
      body: body,
    );
  }
}

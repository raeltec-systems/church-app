import 'package:church_design_system/church_design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../application/access_controllers.dart';
import '../application/user_management_controllers.dart';
import 'user_directory_screen.dart';
import 'user_target_workspace.dart';
import '../domain/user_management.dart';
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

/// All areas use current-authority Identity reads and commands.
enum UserManagementArea {
  members(
    'members',
    'Members',
    'Search membership/account states, inspect roles and manage access.',
  ),
  addMember(
    'add-member',
    'Add member record',
    'Record an agreed member without creating a login.',
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
  bool get supportsPerson =>
      ![addMember, applications, usernames].contains(this);
  String get location => locationFor(null);
  String locationFor(String? memberId) => Uri(
    path: '/admin/users',
    queryParameters: {'view': path, 'member': ?memberId},
  ).toString();
}

/// One entry for real membership/access workflows. Only the selected work
/// area is mounted. Each retains its own server authorisation and mutations.
class UserManagementScreen extends ConsumerWidget {
  const UserManagementScreen({
    super.key,
    this.area = UserManagementArea.members,
    this.memberId,
  });
  final UserManagementArea area;
  final String? memberId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.listen(myAccessProvider, (previous, next) {
      if (previous?.grants?.isAdmin == true &&
          next.result != null &&
          next.grants?.isAdmin != true) {
        // Drop previously read people/cases when current authority ends.
        // Each area must fetch again if Admin access is restored later.
        ref.invalidate(userManagementProvider);
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
    final unsettled =
        canManage &&
        switch (area) {
          UserManagementArea.members || UserManagementArea.roles
              when memberId != null =>
            ref.watch(userManagementProvider.select((s) => s.unsettled)),
          UserManagementArea.members => ref.watch(
            userManagementProvider.select((s) => s.unsettled),
          ),
          UserManagementArea.roles => ref.watch(
            grantAdminProvider.select((s) => s.busy || s.unconfirmed != null),
          ),
          UserManagementArea.accessReviews => ref.watch(
            credentialReviewProvider.select(
              (s) => s.busy || s.unconfirmed != null,
            ),
          ),
          UserManagementArea.recoveryEmails => ref.watch(
            recoveryEmailReviewProvider.select(
              (s) => s.busy || s.unconfirmed != null,
            ),
          ),
          UserManagementArea.recovery => ref.watch(
            recoveryCasesProvider.select(
              (s) => s.busy || s.unconfirmed != null,
            ),
          ),
          UserManagementArea.membership => ref.watch(
            membershipLifecycleProvider.select(
              (s) => s.busy || s.unconfirmed != null,
            ),
          ),
          UserManagementArea.deletions => ref.watch(
            memberDeletionAdminProvider.select(
              (s) => s.busy || s.unconfirmed != null,
            ),
          ),
          _ => ref.watch(
            membershipReviewProvider.select(
              (s) => s.busy || s.unconfirmed != null,
            ),
          ),
        };
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
                    onChanged: unsettled
                        ? null
                        : (value) {
                            if (value != null && value != area) {
                              context.go(
                                value.locationFor(
                                  value.supportsPerson ? memberId : null,
                                ),
                              );
                            }
                          },
                  ),
                ),
              ),
              Expanded(
                child: KeyedSubtree(
                  key: ValueKey('users-$generation-${area.path}'),
                  child:
                      memberId != null &&
                          area.supportsPerson &&
                          area != UserManagementArea.members &&
                          area != UserManagementArea.roles
                      ? UserTargetWorkspace(
                          key: ValueKey('target-${area.path}-$memberId'),
                          memberId: memberId!,
                          area: area.path,
                          back: () => context.go(
                            UserManagementArea.members.locationFor(memberId),
                          ),
                          showEveryone: () => context.go(area.location),
                          builder: (target) => _area(context, target),
                        )
                      : _area(context, null),
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

  Widget _area(BuildContext context, UserDetail? target) => switch (area) {
    UserManagementArea.members => _directory(context),
    UserManagementArea.roles when memberId != null => _directory(context),
    UserManagementArea.roles => const GrantAdminScreen(),
    UserManagementArea.addMember => const MembershipReviewScreen(
      initialSection: MembershipReviewSection.members,
      showSectionSelector: false,
      initialAddMember: true,
    ),
    UserManagementArea.applications => const MembershipReviewScreen(
      showSectionSelector: false,
    ),
    UserManagementArea.accessReviews => CredentialReviewScreen(target: target),
    UserManagementArea.recoveryEmails => RecoveryEmailReviewScreen(
      targetMemberId: target?.member.id,
    ),
    UserManagementArea.recovery => RecoveryCasesScreen(target: target),
    UserManagementArea.membership => MembershipLifecycleScreen(target: target),
    UserManagementArea.deletions => MemberDeletionScreen(target: target),
    UserManagementArea.usernames => const MembershipReviewScreen(
      initialSection: MembershipReviewSection.reclaim,
      showSectionSelector: false,
    ),
  };
  Widget _directory(BuildContext context) => UserDirectoryScreen(
    memberId: memberId,
    selectLocation: (id) =>
        context.go(UserManagementArea.members.locationFor(id)),
    openArea: (view, id) =>
        context.go(UserManagementArea.parse(view).locationFor(id)),
  );
}

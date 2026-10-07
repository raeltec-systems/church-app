import 'package:church_design_system/church_design_system.dart';
import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';

import 'access_screens.dart';
import 'account_screen.dart';
import 'cell_screens.dart';
import 'fixture_command_screen.dart';
import 'membership_application_screen.dart';
import '../domain/password_recovery.dart';
import 'membership_review_screen.dart';
import 'page_address_stub.dart'
    if (dart.library.js_interop) 'page_address_web.dart'
    as page_address;
import 'platform_status_screen.dart';
import 'recovery_screens.dart';
import 'sign_in_screen.dart';

/// Destinations shared by both shells. Which ones a shell shows follows the
/// server's current grants (story 2.3, `myAccessProvider`); a route itself is
/// never the control: every screen's data comes from a server-checked read.
abstract final class ClientPaths {
  static const status = '/status';
  static const fixture = '/fixture';

  /// The signed-in member's own membership (story 2.1).
  static const account = '/account';
  static const signIn = '/sign-in';
  static const createAccount = '/create-account';

  /// The signed-in member's current roles and scopes (story 2.3).
  static const access = '/access';

  /// Staff web, Admin only: grant and remove roles (story 2.3).
  static const adminGrants = '/admin/grants';

  /// The applicant's own membership request and its status (story 2.4).
  static const membership = '/membership';

  /// Staff web, Admin only: applications, member records, unlinking and
  /// phone-username reclaim (story 2.5).
  static const adminMembers = '/admin/members';

  /// Staff web, Admin only: cells, leaders, requests and follow-up (2.6).
  static const adminCells = '/admin/cells';

  /// Staff web, cell leaders and assistants: their cell and its requests.
  static const cellLeader = '/cells/leader';

  /// The member's own cell and change request (story 2.6, mobile).
  static const myCell = '/my-cell';

  /// Story 2.7: forgot password (neutral acknowledgement).
  static const forgotPassword = '/forgot-password';

  /// Story 2.7: the allowlisted Auth email link targets.
  static final authRecovery = AuthLinkKind.recovery.path;
  static final authEmailConfirmed = AuthLinkKind.emailConfirmed.path;

  /// Story 2.7: the member's own recovery email (mobile).
  static const recoveryEmail = '/recovery-email';

  /// Story 2.7, staff web, Admin only: recovery email approvals.
  static const adminRecoveryEmails = '/admin/recovery-emails';
}

/// Story 2.7: the incoming Auth email link for this route, read once. Only
/// the allowlisted paths and their `code`/error parameters are read; on the
/// web the one-time code is then removed from the address bar and history.
AuthLink? _authLink(GoRouterState state) {
  final link = parseAuthLink(
    state.uri,
    page: page_address.currentPageAddress(),
  );
  page_address.dropPageQuery();
  return link;
}

/// `extra` of a navigation started from a shell tab by the keyboard: the
/// rebuilt shell puts focus back on the selected tab.
class NavFocusRequest {
  const NavFocusRequest();
}

/// Builds the app chrome around one destination [child].
typedef ShellBuilder = Widget Function(
  String location,
  bool focusSelectedNav,
  Widget child,
);

/// One navigator, no nested shell navigator: a nested navigator's focus scope
/// would confine keyboard traversal to the page and skip the navigation.
///
/// [membershipRequests] turns on the applicant flow (story 2.4, mobile only):
/// Create account continues to the membership request, and the account page
/// links an account without member access to it. Staff web leaves it off.
GoRouter buildClientRouter({
  required ShellBuilder shell,
  String initialLocation = ClientPaths.status,
  bool membershipRequests = false,
}) {
  final afterCreateAccount = membershipRequests
      ? ClientPaths.membership
      : ClientPaths.account;
  Page<void> page(GoRouterState state, Widget screen) => NoTransitionPage(
    key: state.pageKey,
    child: shell(state.uri.path, state.extra is NavFocusRequest, screen),
  );
  return GoRouter(
    initialLocation: initialLocation,
    routes: [
      GoRoute(path: '/', redirect: (_, _) => ClientPaths.status),
      GoRoute(
        path: ClientPaths.status,
        pageBuilder: (_, state) =>
            page(state, const PlatformStatusDestination()),
      ),
      GoRoute(
        path: ClientPaths.fixture,
        pageBuilder: (_, state) => page(state, const FixtureCommandScreen()),
      ),
      GoRoute(
        path: ClientPaths.account,
        pageBuilder: (_, state) => page(
          state,
          AccountScreen(
            linkMembershipRequest: membershipRequests,
            linkRecoveryEmail: membershipRequests,
          ),
        ),
      ),
      GoRoute(
        path: ClientPaths.access,
        pageBuilder: (_, state) => page(state, const MyAccessScreen()),
      ),
      GoRoute(
        path: ClientPaths.adminGrants,
        pageBuilder: (_, state) => page(state, const GrantAdminScreen()),
      ),
      GoRoute(
        path: ClientPaths.adminMembers,
        pageBuilder: (_, state) => page(state, const MembershipReviewScreen()),
      ),
      GoRoute(
        path: ClientPaths.adminCells,
        pageBuilder: (_, state) => page(state, const CellAdminScreen()),
      ),
      GoRoute(
        path: ClientPaths.cellLeader,
        pageBuilder: (_, state) => page(state, const CellLeaderScreen()),
      ),
      GoRoute(
        path: ClientPaths.myCell,
        pageBuilder: (_, state) => page(state, const MyCellScreen()),
      ),
      GoRoute(
        path: ClientPaths.membership,
        pageBuilder: (_, state) =>
            page(state, const MembershipApplicationScreen()),
      ),
      GoRoute(
        path: ClientPaths.forgotPassword,
        pageBuilder: (_, state) => page(state, const ForgotPasswordScreen()),
      ),
      GoRoute(
        path: ClientPaths.authRecovery,
        pageBuilder: (_, state) =>
            page(state, RecoveryLinkScreen(link: _authLink(state))),
      ),
      GoRoute(
        path: ClientPaths.authEmailConfirmed,
        pageBuilder: (_, state) =>
            page(state, EmailConfirmedScreen(link: _authLink(state))),
      ),
      GoRoute(
        path: ClientPaths.recoveryEmail,
        pageBuilder: (_, state) => page(state, const RecoveryEmailScreen()),
      ),
      GoRoute(
        path: ClientPaths.adminRecoveryEmails,
        pageBuilder: (_, state) =>
            page(state, const RecoveryEmailReviewScreen()),
      ),
      GoRoute(
        path: ClientPaths.signIn,
        pageBuilder: (_, state) =>
            page(state, SignInScreen(afterCreateAccount: afterCreateAccount)),
      ),
      GoRoute(
        path: ClientPaths.createAccount,
        pageBuilder: (_, state) => page(
          state,
          SignInScreen(
            createAccount: true,
            afterCreateAccount: afterCreateAccount,
          ),
        ),
      ),
    ],
  );
}

/// Navigates from a shell tab. Focus returns to the selected tab only when
/// the keyboard was used; a pointer or touch tap leaves no focus behind.
void goFromNav(BuildContext context, String path) => context.go(
  path,
  extra: keyboardFocusVisible ? const NavFocusRequest() : null,
);

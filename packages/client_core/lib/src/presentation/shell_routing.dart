import 'package:church_design_system/church_design_system.dart';
import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';

import 'account_screen.dart';
import 'fixture_command_screen.dart';
import 'platform_status_screen.dart';
import 'sign_in_screen.dart';

/// Platform destinations shared by both shells. Real member and staff
/// navigation (filtered by granted roles and scopes) arrives with the identity
/// and feature epics.
abstract final class ClientPaths {
  static const status = '/status';
  static const fixture = '/fixture';

  /// The signed-in member's own membership (story 2.1).
  static const account = '/account';
  static const signIn = '/sign-in';
  static const createAccount = '/create-account';
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
GoRouter buildClientRouter({
  required ShellBuilder shell,
  String initialLocation = ClientPaths.status,
}) {
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
        pageBuilder: (_, state) => page(state, const AccountScreen()),
      ),
      GoRoute(
        path: ClientPaths.signIn,
        pageBuilder: (_, state) => page(state, const SignInScreen()),
      ),
      GoRoute(
        path: ClientPaths.createAccount,
        pageBuilder: (_, state) =>
            page(state, const SignInScreen(createAccount: true)),
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

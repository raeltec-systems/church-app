import 'package:church_client_core/church_client_core.dart';
import 'package:church_design_system/church_design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

typedef MobileDestination = ({String path, String label, IconData icon});

/// Platform destinations plus the member's account (story 2.1). The five member tabs (Home, Bible & Hymns,
/// Sermons, Give, Calendar) arrive with their feature epics.
const mobileDestinations = <MobileDestination>[
  (
    path: ClientPaths.status,
    label: 'Status',
    icon: Icons.monitor_heart_outlined,
  ),
  (path: ClientPaths.fixture, label: 'Fixture', icon: Icons.science_outlined),
  (path: ClientPaths.account, label: 'Account', icon: Icons.person_outline),
];

/// Story 2.3: shown while the server grants the caller member access; lists
/// the caller's current roles and scopes. Admin grant work is on staff web.
const mobileAccessDestination = (
  path: ClientPaths.access,
  label: 'Access',
  icon: Icons.badge_outlined,
);

/// Story 2.6: shown while the server grants the caller member access; the
/// member's own cell and a request to join or change cell.
const mobileCellDestination = (
  path: ClientPaths.myCell,
  label: 'My cell',
  icon: Icons.groups_outlined,
);

/// The tabs for the caller's current grants (presentation only).
List<MobileDestination> mobileDestinationsFor(MemberGrants? grants) => [
  ...mobileDestinations,
  if (grants != null) mobileAccessDestination,
  if (grants != null) mobileCellDestination,
];

class MobileApp extends StatefulWidget {
  const MobileApp({
    super.key,
    this.initialLocation = ClientPaths.status,
    this.themeMode,
  });

  final String initialLocation;

  /// Defaults to the system setting (full light/dark swap).
  final ThemeMode? themeMode;

  @override
  State<MobileApp> createState() => _MobileAppState();
}

class _MobileAppState extends State<MobileApp> {
  late final GoRouter _router = buildClientRouter(
    initialLocation: widget.initialLocation,
    // Story 2.4: a new account continues to the membership request.
    membershipRequests: true,
    // Story 2.9: sign-in help links to staff-assisted recovery on this phone.
    assistedRecovery: true,
    shell: (location, focusSelectedNav, child) => MobileShell(
      location: location,
      focusSelectedNav: focusSelectedNav,
      child: child,
    ),
  );

  @override
  void dispose() {
    _router.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'BIC Kafue',
      theme: churchMobileTheme(Brightness.light),
      darkTheme: churchMobileTheme(Brightness.dark),
      themeMode: widget.themeMode ?? ThemeMode.system,
      routerConfig: _router,
    );
  }
}

/// Fixed bottom tabs on a surface bar with a 1 px top border.
class MobileShell extends ConsumerWidget {
  const MobileShell({
    super.key,
    required this.location,
    required this.child,
    this.focusSelectedNav = false,
  });

  /// Put focus on the selected tab (the user navigated with the tabs).
  final bool focusSelectedNav;

  final String location;
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = ChurchColors.of(context);
    final destinations = mobileDestinationsFor(
      ref.watch(myAccessProvider.select((s) => s.grants)),
    );
    // Story 2.3: every navigation (a new shell) and every resume asks the
    // server for the caller's grants again.
    return AccessRefresher(
      child: Scaffold(
        body: FocusTraversalGroup(
          policy: WidgetOrderTraversalPolicy(),
          child: Column(
            children: [
              // The tab bar below owns the bottom safe area; pages must not add
              // it again. This Scaffold also already shrinks for the on-screen
              // keyboard; the page's own Scaffold must not shrink for it a second
              // time, or the page body is left with no height while typing.
              Expanded(
                child: MediaQuery(
                  data: MediaQuery.of(context)
                      .removePadding(removeBottom: true)
                      .removeViewInsets(removeBottom: true),
                  child: FocusTraversalGroup(child: child),
                ),
              ),
              DecoratedBox(
                decoration: BoxDecoration(
                  color: c.surface,
                  border: Border(top: BorderSide(color: c.line)),
                ),
                child: SafeArea(
                  top: false,
                  child: FocusTraversalGroup(
                    child: Semantics(
                      role: SemanticsRole.tabBar,
                      label: 'App sections',
                      explicitChildNodes: true,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        child: Row(
                          children: [
                            for (final d in destinations)
                              Expanded(
                                child: NavItem(
                                  key: Key('nav-${d.path}'),
                                  label: d.label,
                                  icon: d.icon,
                                  vertical: true,
                                  selected: location == d.path,
                                  autofocus:
                                      focusSelectedNav && location == d.path,
                                  onTap: () => goFromNav(context, d.path),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

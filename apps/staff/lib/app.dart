import 'package:church_client_core/church_client_core.dart';
import 'package:church_design_system/church_design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

typedef StaffDestination = ({String path, String label, IconData icon});

/// Destinations every staff session sees.
const staffDestinations = <StaffDestination>[
  (
    path: ClientPaths.status,
    label: 'Platform status',
    icon: Icons.monitor_heart_outlined,
  ),
  (
    path: ClientPaths.fixture,
    label: 'Fixture command',
    icon: Icons.science_outlined,
  ),
  (path: ClientPaths.account, label: 'My account', icon: Icons.person_outline),
];

/// Story 2.3: shown while the server grants the caller member access.
const staffAccessDestination = (
  path: ClientPaths.access,
  label: 'My access',
  icon: Icons.badge_outlined,
);

/// Story 3.1: shown while the server grants the caller member access; the
/// durable inbox (browser push is not needed: the inbox holds every reminder).
const staffInboxDestination = (
  path: ClientPaths.inbox,
  label: 'Inbox',
  icon: Icons.inbox_outlined,
);

/// Story 2.3: shown while the server's current answer includes Admin.
const staffAdminDestination = (
  path: ClientPaths.adminGrants,
  label: 'Roles & access',
  icon: Icons.admin_panel_settings_outlined,
);

/// Story 2.5: shown while the server's current answer includes Admin.
const staffMembersDestination = (
  path: ClientPaths.adminMembers,
  label: 'Members & applications',
  icon: Icons.how_to_reg_outlined,
);

/// Story 2.7: shown while the server's current answer includes Admin.
const staffRecoveryEmailsDestination = (
  path: ClientPaths.adminRecoveryEmails,
  label: 'Recovery emails',
  icon: Icons.mark_email_read_outlined,
);

/// Story 2.8: shown while the server's current answer includes Admin.
const staffCredentialReviewsDestination = (
  path: ClientPaths.adminCredentialReviews,
  label: 'Access reviews',
  icon: Icons.shield_outlined,
);

/// Story 2.9: shown while the server's current answer includes Admin.
const staffAccountRecoveryDestination = (
  path: ClientPaths.adminAccountRecovery,
  label: 'Account recovery',
  icon: Icons.lock_reset_outlined,
);

/// Story 2.10: shown while the server's current answer includes Admin.
const staffMembershipLifecycleDestination = (
  path: ClientPaths.adminMembershipLifecycle,
  label: 'Membership status',
  icon: Icons.person_off_outlined,
);

/// Story 2.11: shown while the server's current answer includes Admin.
const staffMemberDeletionsDestination = (
  path: ClientPaths.adminMemberDeletions,
  label: 'Member deletions',
  icon: Icons.person_remove_outlined,
);

/// Story 2.6: shown while the server's current answer includes Admin.
const staffCellsDestination = (
  path: ClientPaths.adminCells,
  label: 'Cells',
  icon: Icons.groups_outlined,
);

/// Story 2.6: shown while the caller leads or assists a cell.
const staffCellLeaderDestination = (
  path: ClientPaths.cellLeader,
  label: 'My cell group',
  icon: Icons.diversity_3_outlined,
);

/// The sidebar for the caller's current grants. Presentation only: hiding an
/// entry is not a control, and every screen's data is checked by the server.
List<StaffDestination> staffDestinationsFor(MemberGrants? grants) => [
  ...staffDestinations,
  if (grants != null) staffInboxDestination,
  if (grants != null) staffAccessDestination,
  if (servesACell(grants)) staffCellLeaderDestination,
  if (grants?.isAdmin ?? false) staffMembersDestination,
  if (grants?.isAdmin ?? false) staffRecoveryEmailsDestination,
  if (grants?.isAdmin ?? false) staffCredentialReviewsDestination,
  if (grants?.isAdmin ?? false) staffAccountRecoveryDestination,
  if (grants?.isAdmin ?? false) staffMembershipLifecycleDestination,
  if (grants?.isAdmin ?? false) staffMemberDeletionsDestination,
  if (grants?.isAdmin ?? false) staffCellsDestination,
  if (grants?.isAdmin ?? false) staffAdminDestination,
];

class StaffApp extends StatefulWidget {
  const StaffApp({super.key, this.initialLocation = ClientPaths.status});

  final String initialLocation;

  @override
  State<StaffApp> createState() => _StaffAppState();
}

class _StaffAppState extends State<StaffApp> {
  late final GoRouter _router = buildClientRouter(
    initialLocation: widget.initialLocation,
    shell: (location, focusSelectedNav, child) => StaffShell(
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
      title: 'BIC Kafue staff',
      // Staff web uses the light palette only (design contract).
      theme: churchStaffTheme(),
      routerConfig: _router,
    );
  }
}

/// Navy sidebar (232 px) on wide windows; a navy top bar on narrow windows
/// or at large text sizes, so content never scrolls sideways.
class StaffShell extends ConsumerWidget {
  const StaffShell({
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
    final destinations = staffDestinationsFor(
      ref.watch(myAccessProvider.select((s) => s.grants)),
    );
    final nav = FocusTraversalGroup(
      child: Semantics(
        role: SemanticsRole.tabBar,
        label: 'Staff sections',
        explicitChildNodes: true,
        child: Builder(
          builder: (context) {
            final items = [
              for (final d in destinations)
                NavItem(
                  key: Key('nav-${d.path}'),
                  label: d.label,
                  icon: d.icon,
                  selected: location == d.path,
                  onDark: true,
                  autofocus: focusSelectedNav && location == d.path,
                  onTap: () => goFromNav(context, d.path),
                ),
            ];
            return _wide(context)
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: items,
                  )
                : Wrap(spacing: 4, runSpacing: 4, children: items);
          },
        ),
      ),
    );
    final brand = Semantics(
      header: true,
      child: Text(
        'BIC Kafue staff',
        style: ChurchType.cardTitle.copyWith(
          color: ChurchStaffChrome.onSidebar,
        ),
      ),
    );
    // Navigation first, then content: the same order the browser's DOM Tab
    // order follows, so widget tests and browsers agree.
    // The shell Scaffold already shrinks for an on-screen keyboard; the page's
    // own Scaffold must not shrink for it again (that left no room to type).
    final content = MediaQuery.removeViewInsets(
      context: context,
      removeBottom: true,
      child: FocusTraversalGroup(child: child),
    );
    // Story 2.3: every navigation (a new shell) and every resume asks the
    // server for the caller's grants again.
    return AccessRefresher(child: _layout(context, brand, nav, content));
  }

  Widget _layout(
    BuildContext context,
    Widget brand,
    Widget nav,
    Widget content,
  ) {
    if (_wide(context)) {
      return Scaffold(
        body: FocusTraversalGroup(
          policy: WidgetOrderTraversalPolicy(),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                width: ChurchGeometry.staffSidebarWidth,
                color: ChurchStaffChrome.sidebar,
                padding: const EdgeInsets.symmetric(
                  vertical: 20,
                  horizontal: 14,
                ),
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [brand, const SizedBox(height: 24), nav],
                  ),
                ),
              ),
              Expanded(child: content),
            ],
          ),
        ),
      );
    }
    return Scaffold(
      body: FocusTraversalGroup(
        policy: WidgetOrderTraversalPolicy(),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Material(
              color: ChurchStaffChrome.sidebar,
              child: SafeArea(
                bottom: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [brand, const SizedBox(height: 8), nav],
                  ),
                ),
              ),
            ),
            Expanded(child: content),
          ],
        ),
      ),
    );
  }

  static bool _wide(BuildContext context) {
    final mq = MediaQuery.of(context);
    // Large text needs the content width more than a fixed sidebar does.
    return mq.size.width >= ChurchGeometry.staffCompactBreakpoint &&
        mq.size.width / mq.textScaler.scale(1) >=
            ChurchGeometry.staffCompactBreakpoint;
  }
}

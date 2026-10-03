import 'package:church_client_core/church_client_core.dart';
import 'package:church_design_system/church_design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:go_router/go_router.dart';

/// Platform destinations only. Real staff navigation is filtered by granted
/// roles and scopes, which the identity epic provides.
const staffDestinations = [
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
class StaffShell extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final nav = FocusTraversalGroup(
      child: Semantics(
        role: SemanticsRole.tabBar,
        label: 'Staff sections',
        explicitChildNodes: true,
        child: Builder(
          builder: (context) {
            final items = [
              for (final d in staffDestinations)
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
    final content = FocusTraversalGroup(child: child);
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

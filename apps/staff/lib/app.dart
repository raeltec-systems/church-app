import 'package:church_client_core/church_client_core.dart';
import 'package:church_design_system/church_design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

typedef StaffDestination = ({String path, String label, IconData icon});

/// Signed-in staff land here: what needs them now, for the role they view.
const staffOverviewDestination = (
  path: ClientPaths.overview,
  label: 'Overview',
  icon: Icons.space_dashboard_outlined,
);

/// The caller's own membership and sign-in (every session).
const staffAccountDestination = (
  path: ClientPaths.account,
  label: 'My account',
  icon: Icons.person_outline,
);

/// Developer pages, in the System group: Admin only (presentation; the
/// routes stay reachable and every read is checked by the server).
const staffStatusDestination = (
  path: ClientPaths.status,
  label: 'Platform status',
  icon: Icons.monitor_heart_outlined,
);

const staffFixtureDestination = (
  path: ClientPaths.fixture,
  label: 'Fixture command',
  icon: Icons.science_outlined,
);

/// Story 3.8: the reminder health projection (System group, Admin only;
/// the health read enforces authorization on the server).
const staffReminderHealthDestination = (
  path: ClientPaths.notificationHealth,
  label: 'Reminder health',
  icon: Icons.notifications_active_outlined,
);

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
  label: 'Members',
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

/// Story 5.1: shown while the caller leads or assists a cell, or is an
/// Admin: cell schedules and meetings.
const staffCellMeetingsDestination = (
  path: ClientPaths.cellMeetings,
  label: 'Cell meetings',
  icon: Icons.event_repeat_outlined,
);

/// Story 4.1: shown while the caller leads or deputises a department, or is
/// an Admin or Pastor (read only).
const staffDutyLeaderDestination = (
  path: ClientPaths.dutyLeader,
  label: 'Duties',
  icon: Icons.assignment_outlined,
);

/// Story 4.3: the rota grid, shown with the Duties entry.
const staffDutyRotaDestination = (
  path: ClientPaths.dutyRota,
  label: 'Rota',
  icon: Icons.calendar_view_week_outlined,
);

/// Story 4.9: the coverage queue, shown with the Duties entry (Pastor and
/// Admin: the church-wide view of gaps).
const staffDutyCoverageDestination = (
  path: ClientPaths.dutyCoverage,
  label: 'Coverage',
  icon: Icons.fact_check_outlined,
);

/// Story 4.10: shown while the caller leads or deputises a department:
/// record and correct the outcomes of started duties.
const staffDutyOutcomesDestination = (
  path: ClientPaths.dutyOutcomes,
  label: 'Outcomes',
  icon: Icons.task_alt_outlined,
);

/// Special assignments (2026-10-21): shown while the caller holds the Pastor
/// role: give, change and cancel duties that belong to no department or cell,
/// and record their outcomes.
const staffDutySpecialDestination = (
  path: ClientPaths.dutySpecial,
  label: 'Special assignments',
  icon: Icons.assignment_ind_outlined,
);

/// Story 4.10: the caller's own duty history (every member).
const staffDutyHistoryDestination = (
  path: ClientPaths.dutyHistory,
  label: 'My duty history',
  icon: Icons.history_outlined,
);

/// Story 4.1: shown while the server's current answer includes Admin.
const staffDepartmentsDestination = (
  path: ClientPaths.adminDepartments,
  label: 'Departments',
  icon: Icons.workspaces_outline,
);

/// Story 4.6: shown while the server grants the caller member access; every
/// owner's own follow-up tasks.
const staffMyFollowUpsDestination = (
  path: ClientPaths.myFollowUps,
  label: 'My follow-ups',
  icon: Icons.checklist_outlined,
);

/// Story 4.6: shown while the caller leads or deputises a department or
/// leads or assists a cell: the tasks in those scopes.
const staffFollowUpSupervisionDestination = (
  path: ClientPaths.followUpSupervision,
  label: 'Follow-ups',
  icon: Icons.supervisor_account_outlined,
);

/// Story 4.6: shown while the server's current answer includes Admin;
/// routing metadata only.
const staffFollowUpRoutingDestination = (
  path: ClientPaths.adminFollowUps,
  label: 'Follow-up routing',
  icon: Icons.alt_route_outlined,
);

/// Story 6.1: shown while the caller holds Media, Pastor or Admin: draft,
/// publish, withdraw and archive church events.
const staffEventsDestination = (
  path: ClientPaths.contentEvents,
  label: 'Events',
  icon: Icons.event_outlined,
);

/// Story 6.13: shown while the caller holds Media, Pastor or Admin: draft,
/// publish (optionally notifying members), withdraw and archive church
/// announcements.
const staffAnnouncementsDestination = (
  path: ClientPaths.contentAnnouncements,
  label: 'Announcements',
  icon: Icons.campaign_outlined,
);

/// One group of the sidebar; [label] is null for the ungrouped top entry.
typedef StaffNavGroup = ({String? label, List<StaffDestination> items});

/// The sidebar for [grants], grouped the way staff think of their work:
/// Overview, People, Cells, Duties, Content, Me, then System (Admin only).
/// Presentation only: hiding an entry is not a control, and every screen's
/// data is checked by the server.
List<StaffNavGroup> staffNavGroupsFor(
  MemberGrants? grants, {
  bool signedIn = false,
}) {
  final admin = grants?.isAdmin ?? false;
  final member = grants != null;
  final duties = seesDutyBoard(grants);
  final groups = <StaffNavGroup>[
    (label: null, items: [if (signedIn) staffOverviewDestination]),
    (
      label: 'People',
      items: [
        if (admin) staffMembersDestination,
        if (supervisesFollowUps(grants)) staffFollowUpSupervisionDestination,
        if (admin) staffFollowUpRoutingDestination,
        if (admin) staffCredentialReviewsDestination,
        if (admin) staffAccountRecoveryDestination,
        if (admin) staffRecoveryEmailsDestination,
        if (admin) staffMembershipLifecycleDestination,
        if (admin) staffMemberDeletionsDestination,
        if (admin) staffAdminDestination,
      ],
    ),
    (
      label: 'Cells',
      items: [
        if (admin) staffCellsDestination,
        if (servesACell(grants)) staffCellLeaderDestination,
        if (servesACell(grants) || admin) staffCellMeetingsDestination,
      ],
    ),
    (
      label: 'Duties',
      items: [
        if (duties) staffDutyLeaderDestination,
        if (duties) staffDutyRotaDestination,
        if (duties) staffDutyCoverageDestination,
        if (leadsADepartment(grants)) staffDutyOutcomesDestination,
        if (givesSpecialAssignments(grants)) staffDutySpecialDestination,
        if (admin) staffDepartmentsDestination,
      ],
    ),
    // Story 6.1: public church content (Media, Pastor, Admin).
    (
      label: 'Content',
      items: [
        if (editsContent(grants)) staffEventsDestination,
        if (editsContent(grants)) staffAnnouncementsDestination,
      ],
    ),
    (
      label: 'Me',
      items: [
        staffAccountDestination,
        if (member) staffInboxDestination,
        if (member) staffAccessDestination,
        if (member) staffDutyHistoryDestination,
        if (member) staffMyFollowUpsDestination,
      ],
    ),
    (
      label: 'System',
      items: [
        if (admin) staffStatusDestination,
        if (admin) staffFixtureDestination,
        if (admin && signedIn) staffReminderHealthDestination,
      ],
    ),
  ];
  return [
    for (final g in groups)
      if (g.items.isNotEmpty) g,
  ];
}

/// Every sidebar entry for [grants], in order (see [staffNavGroupsFor]).
List<StaffDestination> staffDestinationsFor(
  MemberGrants? grants, {
  bool signedIn = false,
}) => [
  for (final g in staffNavGroupsFor(grants, signedIn: signedIn)) ...g.items,
];

/// Whether the wide sidebar is folded to a rail of icons. Memory only: it
/// lasts while the tab is open (staff web keeps nothing on the device).
class StaffSidebarController extends Notifier<bool> {
  @override
  bool build() => false;

  void toggle() => state = !state;
}

final staffSidebarCollapsedProvider =
    NotifierProvider<StaffSidebarController, bool>(StaffSidebarController.new);

class StaffApp extends StatefulWidget {
  const StaffApp({super.key, this.initialLocation = ClientPaths.overview});

  final String initialLocation;

  @override
  State<StaffApp> createState() => _StaffAppState();
}

class _StaffAppState extends State<StaffApp> {
  late final GoRouter _router = buildClientRouter(
    initialLocation: widget.initialLocation,
    reminderHealth: true,
    staffOverview: true,
    home: ClientPaths.overview,
    afterSignIn: ClientPaths.overview,
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
      title: 'BICC Kafue staff',
      // Staff web uses the light palette only (design contract).
      theme: churchStaffTheme(),
      routerConfig: _router,
    );
  }
}

/// The handoff's navy sidebar (232 px, foldable to a 72 px rail) on wide
/// windows; a navy top bar on narrow windows or at large text sizes, so
/// content never scrolls sideways. Signed out there is no navigation at all:
/// the page (the sign-in landing) stands alone.
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
    final signedIn = ref.watch(
      accountProvider.select((s) => s.accountId != null),
    );
    // The shell Scaffold already shrinks for an on-screen keyboard; the page's
    // own Scaffold must not shrink for it again (that left no room to type).
    final content = MediaQuery.removeViewInsets(
      context: context,
      removeBottom: true,
      child: FocusTraversalGroup(child: child),
    );
    // Story 2.3: every navigation (a new shell) and every resume asks the
    // server for the caller's grants again.
    if (!signedIn) return AccessRefresher(child: content);

    final grants = ref.watch(myAccessProvider.select((s) => s.grants));
    final roles = staffRolesOf(grants);
    final view = ref.watch(staffViewProvider);
    final viewGrants = ref.watch(staffViewGrantsProvider);
    final groups = staffNavGroupsFor(viewGrants, signedIn: true);
    final badges = _badges(ref, viewGrants);
    final wide = _wide(context);
    final collapsed = wide && ref.watch(staffSidebarCollapsedProvider);

    Widget item(StaffDestination d, {required bool compact}) {
      final badge = badges[d.path];
      return NavItem(
        key: Key('nav-${d.path}'),
        label: d.label,
        icon: d.icon,
        selected: location == d.path,
        onDark: true,
        compact: compact,
        fill: wide && !compact,
        badge: badge?.$1,
        badgeLabel: badge?.$2,
        autofocus: focusSelectedNav && location == d.path,
        onTap: () => goFromNav(context, d.path),
      );
    }

    final navChildren = <Widget>[];
    if (wide) {
      for (var i = 0; i < groups.length; i++) {
        final g = groups[i];
        if (g.label case final label?) {
          navChildren.add(
            collapsed
                ? Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: ExcludeSemantics(
                      child: Container(
                        height: 1,
                        color: ChurchStaffChrome.track,
                      ),
                    ),
                  )
                : _GroupLabel(label),
          );
        }
        for (final d in g.items) {
          navChildren.add(item(d, compact: collapsed));
        }
      }
    }
    Widget tabList(Widget child) => Semantics(
      role: SemanticsRole.tabBar,
      label: 'Staff sections',
      explicitChildNodes: true,
      child: child,
    );
    final nav = FocusTraversalGroup(
      child: wide
          ? tabList(
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: navChildren,
              ),
            )
          // Narrow windows: one row of tabs that scrolls sideways inside the
          // bar, never the page, however many destinations there are.
          : SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: tabList(
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final g in groups)
                      for (final d in g.items) ...[
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 420),
                          child: item(d, compact: false),
                        ),
                        const SizedBox(width: 4),
                      ],
                  ],
                ),
              ),
            ),
    );
    final roleSwitch = roles.length > 1 && view != null
        ? _RoleSwitch(
            roles: roles,
            selected: view,
            horizontal: !wide,
            onChanged: (r) =>
                ref.read(staffViewChoiceProvider.notifier).choose(r),
          )
        : null;

    if (wide) {
      final reduceMotion = MediaQuery.disableAnimationsOf(context);
      final width = collapsed
          ? ChurchGeometry.staffRailWidth
          : ChurchGeometry.staffSidebarWidth;
      final toggle = _SidebarToggle(
        collapsed: collapsed,
        onPressed: () =>
            ref.read(staffSidebarCollapsedProvider.notifier).toggle(),
      );
      final sidebar = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: collapsed
            ? [
                Center(child: toggle),
                const SizedBox(height: 10),
                const Center(child: ChurchLogo(size: 40)),
                const SizedBox(height: 18),
                nav,
              ]
            : [
                Stack(
                  children: [
                    const Center(
                      child: Padding(
                        padding: EdgeInsets.only(top: 4),
                        child: ChurchLogo(size: 84),
                      ),
                    ),
                    PositionedDirectional(top: 0, end: 0, child: toggle),
                  ],
                ),
                const SizedBox(height: 12),
                const _Brand(),
                const SizedBox(height: 20),
                if (roleSwitch != null) ...[
                  roleSwitch,
                  const SizedBox(height: 12),
                ],
                nav,
              ],
      );
      return AccessRefresher(
        child: Scaffold(
          body: FocusTraversalGroup(
            policy: WidgetOrderTraversalPolicy(),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                AnimatedContainer(
                  key: const Key('staff-sidebar'),
                  duration: reduceMotion
                      ? Duration.zero
                      : const Duration(milliseconds: 200),
                  curve: Curves.easeOutCubic,
                  width: width,
                  color: ChurchStaffChrome.sidebar,
                  child: ClipRect(
                    child: OverflowBox(
                      alignment: AlignmentDirectional.topStart,
                      minWidth: width,
                      maxWidth: width,
                      child: SingleChildScrollView(
                        padding: EdgeInsets.symmetric(
                          vertical: collapsed ? 14 : 20,
                          horizontal: 14,
                        ),
                        child: sidebar,
                      ),
                    ),
                  ),
                ),
                Expanded(child: content),
              ],
            ),
          ),
        ),
      );
    }
    return AccessRefresher(
      child: Scaffold(
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
                      children: [
                        Row(
                          children: [
                            const ChurchLogo(size: 36),
                            const SizedBox(width: 10),
                            Flexible(
                              child: Semantics(
                                header: true,
                                child: Text(
                                  'BICC Kafue staff',
                                  style: ChurchType.cardTitle.copyWith(
                                    color: ChurchStaffChrome.onSidebar,
                                    fontSize: 17,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        if (roleSwitch != null) ...[
                          roleSwitch,
                          const SizedBox(height: 8),
                        ],
                        nav,
                      ],
                    ),
                  ),
                ),
              ),
              Expanded(child: content),
            ],
          ),
        ),
      ),
    );
  }

  /// Counts of work waiting, only where a read the screens already make
  /// gives the number: applications (Members), cell requests (Cells, My
  /// cell group). Each is (count, what it counts).
  static Map<String, (int, String)> _badges(
    WidgetRef ref,
    MemberGrants? grants,
  ) {
    final out = <String, (int, String)>{};
    if (grants == null) return out;
    if (grants.isAdmin) {
      final review = ref.watch(membershipReviewProvider);
      if (review.queueResult is AccessReadOk) {
        final n = review.applications.length;
        out[ClientPaths.adminMembers] = (
          n,
          '$n${review.queueNext == null ? '' : '+'} '
              '${n == 1 ? 'application' : 'applications'} waiting',
        );
      }
      final cells = ref.watch(cellAdminProvider).value;
      if (cells != null) {
        final n = cells.requests.length;
        out[ClientPaths.adminCells] = (
          n,
          '$n cell ${n == 1 ? 'request' : 'requests'} waiting',
        );
      }
    }
    if (servesACell(grants)) {
      final queue = ref.watch(cellLeaderProvider).value;
      if (queue != null) {
        final n = queue.cells.fold(0, (a, c) => a + c.requests.length);
        out[ClientPaths.cellLeader] = (
          n,
          '$n ${n == 1 ? 'request' : 'requests'} to confirm',
        );
      }
    }
    return out;
  }

  static bool _wide(BuildContext context) {
    final mq = MediaQuery.of(context);
    // Large text needs the content width more than a fixed sidebar does.
    return mq.size.width >= ChurchGeometry.staffCompactBreakpoint &&
        mq.size.width / mq.textScaler.scale(1) >=
            ChurchGeometry.staffCompactBreakpoint;
  }
}

/// The product's name under the seal, and a quiet line for whose app it is.
class _Brand extends StatelessWidget {
  const _Brand();

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Semantics(
        header: true,
        child: Text(
          'BICC Kafue',
          textAlign: TextAlign.center,
          style: ChurchType.cardTitle.copyWith(
            color: ChurchStaffChrome.onSidebar,
            fontSize: 17,
          ),
        ),
      ),
      Text(
        'Staff',
        textAlign: TextAlign.center,
        style: ChurchType.secondary.copyWith(
          color: ChurchStaffChrome.groupLabel,
          fontSize: 13,
        ),
      ),
    ],
  );
}

/// A sidebar group's name: sentence case, 12/600, the quiet tint. Visual
/// only: the tab list holds tabs alone.
class _GroupLabel extends StatelessWidget {
  const _GroupLabel(this.label);

  final String label;

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: Padding(
      padding: const EdgeInsets.fromLTRB(12, 16, 12, 6),
      child: Text(
        label,
        style: const TextStyle(
          fontFamily: ChurchFonts.body,
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: ChurchStaffChrome.groupLabel,
        ),
      ),
    ),
  );
}

/// Folds the sidebar to a rail and back.
class _SidebarToggle extends StatelessWidget {
  const _SidebarToggle({required this.collapsed, required this.onPressed});

  final bool collapsed;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final label = collapsed ? 'Expand menu' : 'Collapse menu';
    return FocusRing(
      color: ChurchStaffChrome.onSidebar,
      radius: 22,
      child: IconButton(
        key: const Key('sidebar-toggle'),
        tooltip: label,
        onPressed: onPressed,
        color: ChurchStaffChrome.onSidebarMuted,
        icon: Icon(
          collapsed
              ? Icons.keyboard_double_arrow_right
              : Icons.keyboard_double_arrow_left,
          size: 20,
        ),
      ),
    );
  }
}

/// The handoff's role switch (Admin / Cell leader / Pastor), shown only to
/// someone who holds more than one. It narrows the navigation and the
/// Overview; the server still checks every read and command.
class _RoleSwitch extends StatelessWidget {
  const _RoleSwitch({
    required this.roles,
    required this.selected,
    required this.onChanged,
    this.horizontal = false,
  });

  final List<StaffRole> roles;
  final StaffRole selected;
  final ValueChanged<StaffRole> onChanged;
  final bool horizontal;

  @override
  Widget build(BuildContext context) {
    Widget option(StaffRole r) {
      final on = r == selected;
      return FocusRing(
        color: ChurchStaffChrome.onSidebar,
        radius: 9,
        child: TextButton(
          key: Key('role-view-${r.name}'),
          onPressed: () => onChanged(r),
          style: TextButton.styleFrom(
            minimumSize: const Size(0, 36),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            backgroundColor: on ? Colors.white : Colors.transparent,
            foregroundColor: on
                ? ChurchStaffChrome.sidebar
                : ChurchStaffChrome.onSidebar,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
            textStyle: const TextStyle(
              fontFamily: ChurchFonts.body,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
          child: Semantics(
            inMutuallyExclusiveGroup: true,
            checked: on,
            child: Text(r.label),
          ),
        ),
      );
    }

    final options = [for (final r in roles) option(r)];
    return Semantics(
      role: SemanticsRole.radioGroup,
      label: 'View as',
      explicitChildNodes: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (!horizontal)
            const ExcludeSemantics(
              child: Padding(
                padding: EdgeInsets.fromLTRB(10, 0, 10, 6),
                child: Text(
                  'Viewing as',
                  style: TextStyle(
                    fontFamily: ChurchFonts.body,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: ChurchStaffChrome.groupLabel,
                  ),
                ),
              ),
            ),
          Container(
            padding: const EdgeInsets.all(3),
            decoration: BoxDecoration(
              color: ChurchStaffChrome.track,
              borderRadius: BorderRadius.circular(10),
            ),
            child: horizontal
                ? Wrap(spacing: 2, runSpacing: 2, children: options)
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (var i = 0; i < options.length; i++) ...[
                        options[i],
                      ],
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

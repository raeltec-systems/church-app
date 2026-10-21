import 'package:church_design_system/church_design_system.dart';
import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';

import 'access_screens.dart';
import 'assisted_recovery_screens.dart';
import 'account_screen.dart';
import 'calendar_screens.dart';
import 'content_screens.dart';
import 'cell_screens.dart';
import 'credential_screens.dart';
import 'duties_screens.dart';
import 'followups_screens.dart';
import 'home_screen.dart';
import 'fixture_command_screen.dart';
import 'fixture_reminder_screens.dart';
import 'notification_settings_screen.dart';
import 'notification_health_screen.dart';
import 'inbox_screen.dart';
import 'membership_application_screen.dart';
import 'member_deletion_screens.dart';
import 'membership_lifecycle_screen.dart';
import '../domain/password_recovery.dart';
import 'membership_review_screen.dart';
import 'page_address_stub.dart'
    if (dart.library.js_interop) 'page_address_web.dart'
    as page_address;
import 'platform_status_screen.dart';
import 'recovery_screens.dart';
import 'sign_in_screen.dart';
import 'staff_overview_screen.dart';

/// Destinations shared by both shells. Which ones a shell shows follows the
/// server's current grants (story 2.3, `myAccessProvider`); a route itself is
/// never the control: every screen's data comes from a server-checked read.
abstract final class ClientPaths {
  static const status = '/status';
  static const fixture = '/fixture';

  /// Staff web: the signed-in person's Overview (what needs attention for
  /// the roles they hold); the sign-in landing while signed out.
  static const overview = '/overview';

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

  /// Story 5.1, staff web: cell schedules and meetings (cell leaders and
  /// assistants, Admin).
  static const cellMeetings = '/cells/meetings';

  /// The member's own cell and change request (story 2.6, mobile).
  static const myCell = '/my-cell';

  /// Story 4.1 (mobile): the member's own duties; `/duties/assignments/<id>`
  /// is one assignment (the reminder's deep link).
  static const myDuties = DutyPaths.mine;

  /// The mobile Home tab (story 4.5; story 6.1: everyone, signed in or
  /// not). Later features add their cards.
  static const home = DutyPaths.home;

  /// Story 6.1 (mobile): the public Calendar tab.
  static const calendar = CalendarPaths.calendar;

  /// Story 6.1 (mobile): one published event.
  static String calendarEvent(String eventId) => CalendarPaths.event(eventId);

  /// Story 6.1, staff web: the Events editor (Media, Pastor, Admin).
  static const contentEvents = ContentPaths.events;

  /// Story 4.1, staff web: department leaders and deputies (Admin; Pastor
  /// read only): publish a duty and see the responses.
  static const dutyLeader = DutyPaths.leader;

  /// Story 4.3 (staff web): the rota grid.
  static const dutyRota = DutyPaths.rota;

  /// Story 4.9 (staff web and mobile): the coverage queue.
  static const dutyCoverage = DutyPaths.coverage;

  /// Story 4.10 (staff web and mobile): record and correct duty outcomes.
  static const dutyOutcomes = DutyPaths.outcomes;

  /// Story 4.10: the reader's own duty history (a leader opens a member's
  /// with `?member=<id>`).
  static const dutyHistory = DutyPaths.history;

  /// Special assignments (staff web, the Pastors): give, change, cancel and
  /// record the outcome of duties that belong to no department or cell.
  static const dutySpecial = DutyPaths.special;

  /// Story 4.1, staff web, Admin only: departments, leaders, deputies and
  /// members.
  static const adminDepartments = DutyPaths.adminDepartments;

  /// Story 4.6: My follow-ups (every owner; mobile from the Home card, staff
  /// web in the sidebar); `/followups/tasks/<id>` is one task.
  static const myFollowUps = FollowUpPaths.mine;

  /// Story 4.6, staff web: the tasks in the scopes the caller holds.
  static const followUpSupervision = FollowUpPaths.supervision;

  /// Story 4.6, staff web, Admin only: routing metadata of every task.
  static const adminFollowUps = FollowUpPaths.adminRouting;

  /// Story 2.7: forgot password (neutral acknowledgement).
  static const forgotPassword = '/forgot-password';

  /// Story 2.7: the allowlisted Auth email link targets.
  static final authRecovery = AuthLinkKind.recovery.path;
  static final authEmailConfirmed = AuthLinkKind.emailConfirmed.path;

  /// Story 2.7: the member's own recovery email (mobile).
  static const recoveryEmail = '/recovery-email';

  /// Story 2.7, staff web, Admin only: recovery email approvals.
  static const adminRecoveryEmails = '/admin/recovery-emails';

  /// Story 2.8: the generic "Access review required" help screen.
  static const accessReview = '/access-review';

  /// Story 2.8 (mobile): the member's sign-in details and reviewed changes.
  static const signInDetails = '/sign-in-details';

  /// Story 2.8, staff web, Admin only: credential changes, reviews, holds.
  static const adminCredentialReviews = '/admin/credential-reviews';

  /// Story 2.9 (mobile, signed out): "I need help accessing my account".
  static const accountHelp = '/account-help';

  /// Story 2.9, staff web, Admin only: staff-assisted recovery cases.
  static const adminAccountRecovery = '/admin/account-recovery';

  /// Story 2.10, staff web, Admin only: login holds, church deactivation,
  /// reviewed restoration and pending handovers.
  static const adminMembershipLifecycle = '/admin/membership-status';

  /// Story 2.11 (mobile): the member deletes their own account.
  static const deleteAccount = '/delete-account';

  /// Story 2.11, staff web, Admin only: member deletions and the staff route
  /// for members who cannot use the app.
  static const adminMemberDeletions = '/admin/member-deletions';

  /// Story 3.1 (both clients): the member's durable inbox.
  static const inbox = '/inbox';

  /// Story 3.2: one opened inbox item, `/inbox/<item id>`.
  static String inboxItem(String itemId) => '$inbox/$itemId';

  /// Story 3.7 (both clients): push on or off by reminder category.
  static const notificationSettings = '/notification-settings';

  /// Story 3.8, staff web only (the route exists only when the router is
  /// built with `reminderHealth`): the reminder health projection;
  /// authorization is checked by the server for every read.
  static const notificationHealth = '/admin/reminder-health';

  /// Story 3.7, SYNTHETIC (local/staging only): test reminders for the
  /// signed-in member, and one test source (`/fixture/reminders/<id>`, the
  /// fixture contract's registered link).
  static const fixtureReminders = '/fixture/reminders';
  static String fixtureReminder(String sourceId) =>
      '$fixtureReminders/$sourceId';

  /// Story 3.2: the server-provided deep-link targets this build has screens
  /// for. A source owner adds its route pattern here with its first screen;
  /// any other target is shown as current but not yet openable.
  static final List<RegExp> deepLinkTargets = [
    RegExp(
      r'^/fixture/reminders/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
    ),
    // Story 5.2: meeting reminders and notices open My cell, which reads the
    // meeting again (a pointer, not a grant).
    RegExp(r'^/my-cell$'),
    // Story 5.7: a Cannot attend notice opens Cell meetings for the leader.
    RegExp(r'^/cells/meetings$'),
    // Story 4.1: the duties_assignment contract's link.
    RegExp(
      r'^/duties/assignments/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
    ),
    // Story 4.2: the duty_released notice opens My duties.
    RegExp(r'^/duties$'),
    // Story 4.8: the leaders' overdue and short-notice alerts open the
    // Duties board, which reads the duty again (a pointer, not a grant).
    RegExp(r'^/duties/leader$'),
    // Story 4.16: the leaders' review notice opens the board's reviews.
    RegExp(r'^/duties/leader/reviews$'),
    // Story 4.9: the leaders' decline alert opens the coverage queue, which
    // reads every position again.
    RegExp(r'^/duties/coverage$'),
    // Story 4.7: the follow-up reminders (followups_task and
    // followups_supervision contracts) open the task, which reads it again.
    RegExp(
      r'^/followups/tasks/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
    ),
  ];

  static bool isKnownDeepLink(String target) =>
      deepLinkTargets.any((p) => p.hasMatch(target));

  /// Story 3.6: sign in, then continue to [target] (an inbox item).
  static String signInThen(String target) =>
      Uri(path: signIn, queryParameters: {'then': target}).toString();

  /// The continuation a sign-in may follow: only an inbox item path
  /// (`/inbox/<uuid>`), never any other address, so a link cannot send a
  /// fresh session anywhere else.
  static String? continuationFrom(String? then) =>
      then != null && _inboxItemPath.hasMatch(then) ? then : null;

  static final _inboxItemPath = RegExp(
    r'^/inbox/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
  );
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
///
/// [assistedRecovery] links the sign-in help to "I need help accessing my
/// account" (story 2.9, mobile only: the member chooses the password on the
/// phone that created the setup request).
///
/// [reminderHealth] registers the staff reminder-health screen (story 3.8,
/// staff web only).
///
/// [staffOverview] registers the staff Overview (staff web only); [home] is
/// where `/` goes and [afterSignIn] where a sign-in continues.
GoRouter buildClientRouter({
  required ShellBuilder shell,
  String initialLocation = ClientPaths.status,
  bool membershipRequests = false,
  bool assistedRecovery = false,
  bool reminderHealth = false,
  bool memberHome = false,
  bool staffOverview = false,
  String home = ClientPaths.status,
  String afterSignIn = ClientPaths.account,
}) {
  final afterCreateAccount = membershipRequests
      ? ClientPaths.membership
      : ClientPaths.account;
  // Story 2.8: while the server says this session's access is in review,
  // private destinations show only the generic help screen.
  Page<void> page(GoRouterState state, Widget screen) => NoTransitionPage(
    key: state.pageKey,
    child: shell(
      state.uri.path,
      state.extra is NavFocusRequest,
      AccessReviewGate(path: state.uri.path, child: screen),
    ),
  );
  return GoRouter(
    initialLocation: initialLocation,
    routes: [
      GoRoute(path: '/', redirect: (_, _) => home),
      if (staffOverview)
        GoRoute(
          path: ClientPaths.overview,
          pageBuilder: (_, state) => page(state, const StaffOverviewScreen()),
        ),
      GoRoute(
        path: ClientPaths.status,
        pageBuilder: (_, state) =>
            page(state, const PlatformStatusDestination()),
      ),
      GoRoute(
        path: ClientPaths.fixture,
        pageBuilder: (_, state) => page(state, const FixtureCommandScreen()),
        routes: [
          GoRoute(
            path: 'reminders',
            pageBuilder: (_, state) =>
                page(state, const FixtureRemindersScreen()),
            routes: [
              GoRoute(
                path: ':sourceId',
                pageBuilder: (_, state) => page(
                  state,
                  FixtureRemindersScreen(
                    sourceId: state.pathParameters['sourceId'],
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
      GoRoute(
        path: ClientPaths.notificationSettings,
        pageBuilder: (_, state) =>
            page(state, const NotificationSettingsScreen()),
      ),
      // Story 3.8: staff web only (the mobile app has no operator screens).
      if (reminderHealth)
        GoRoute(
          path: ClientPaths.notificationHealth,
          pageBuilder: (_, state) =>
              page(state, const NotificationHealthScreen()),
        ),
      GoRoute(
        path: ClientPaths.account,
        pageBuilder: (_, state) => page(
          state,
          AccountScreen(
            linkMembershipRequest: membershipRequests,
            linkRecoveryEmail: membershipRequests,
            memberMenu: memberHome,
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
        path: ClientPaths.cellMeetings,
        pageBuilder: (_, state) => page(state, const CellMeetingsScreen()),
        routes: [
          // Story 5.3: one meeting's programme (CellPaths.plan).
          GoRoute(
            path: ':meetingId/plan',
            pageBuilder: (_, state) => page(
              state,
              PlanMeetingScreen(
                key: ValueKey(state.pathParameters['meetingId']),
                meetingId: state.pathParameters['meetingId']!,
              ),
            ),
          ),
        ],
      ),
      GoRoute(
        path: ClientPaths.myCell,
        pageBuilder: (_, state) => page(state, const MyCellScreen()),
      ),
      // Story 4.5: Home is a mobile destination only. Story 6.1: so is the
      // public Calendar, with each event's detail.
      if (memberHome) ...[
        GoRoute(
          path: ClientPaths.home,
          pageBuilder: (_, state) => page(state, const HomeScreen()),
        ),
        GoRoute(
          path: ClientPaths.calendar,
          pageBuilder: (_, state) => page(state, const CalendarScreen()),
          routes: [
            GoRoute(
              path: 'events/:eventId',
              pageBuilder: (_, state) => page(
                state,
                EventDetailScreen(
                  key: ValueKey(state.pathParameters['eventId']),
                  eventId: state.pathParameters['eventId']!,
                ),
              ),
            ),
          ],
        ),
      ],
      // Story 6.1, staff web: the Events editor (the server checks every read
      // and command).
      GoRoute(
        path: ClientPaths.contentEvents,
        pageBuilder: (_, state) => page(state, const StaffEventsScreen()),
      ),
      GoRoute(
        path: ClientPaths.myDuties,
        pageBuilder: (_, state) => page(state, const MyDutiesScreen()),
        routes: [
          GoRoute(
            path: 'leader',
            pageBuilder: (_, state) => page(state, const DutyLeaderScreen()),
            routes: [
              // Story 4.16: the review notice's link (both apps).
              GoRoute(
                path: 'reviews',
                pageBuilder: (_, state) =>
                    page(state, const DutyLeaderScreen(reviewsOnly: true)),
              ),
            ],
          ),
          GoRoute(
            path: 'rota',
            pageBuilder: (_, state) => page(state, const DutyRotaScreen()),
          ),
          // Story 4.9: both apps (the leader's essential actions on mobile).
          GoRoute(
            path: 'coverage',
            pageBuilder: (_, state) => page(state, const DutyCoverageScreen()),
          ),
          // Story 4.10: both apps.
          GoRoute(
            path: 'outcomes',
            pageBuilder: (_, state) => page(state, const DutyOutcomesScreen()),
          ),
          // Special assignments: the Pastors (staff web's sidebar; the
          // server checks every read and command).
          GoRoute(
            path: 'special',
            pageBuilder: (_, state) => page(state, const DutySpecialScreen()),
          ),
          GoRoute(
            path: 'history',
            pageBuilder: (_, state) => page(
              state,
              DutyHistoryScreen(
                key: ValueKey(state.uri.queryParameters['member']),
                memberId: _memberParam(state.uri.queryParameters['member']),
              ),
            ),
          ),
          GoRoute(
            path: 'assignments/:assignmentId',
            pageBuilder: (_, state) => page(
              state,
              MyDutiesScreen(
                assignmentId: state.pathParameters['assignmentId'],
              ),
            ),
          ),
        ],
      ),
      GoRoute(
        path: ClientPaths.adminDepartments,
        pageBuilder: (_, state) => page(state, const DutyAdminScreen()),
      ),
      GoRoute(
        path: ClientPaths.myFollowUps,
        pageBuilder: (_, state) => page(state, const MyFollowUpsScreen()),
        routes: [
          GoRoute(
            path: 'supervision',
            pageBuilder: (_, state) =>
                page(state, const FollowUpSupervisionScreen()),
          ),
          GoRoute(
            path: 'tasks/:taskId',
            pageBuilder: (_, state) => page(
              state,
              FollowUpTaskScreen(taskId: state.pathParameters['taskId']!),
            ),
          ),
        ],
      ),
      GoRoute(
        path: ClientPaths.adminFollowUps,
        pageBuilder: (_, state) => page(state, const FollowUpRoutingScreen()),
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
        path: ClientPaths.accessReview,
        pageBuilder: (_, state) => page(state, const AccessReviewScreen()),
      ),
      GoRoute(
        path: ClientPaths.signInDetails,
        pageBuilder: (_, state) => page(state, const SignInDetailsScreen()),
      ),
      GoRoute(
        path: ClientPaths.adminCredentialReviews,
        pageBuilder: (_, state) => page(state, const CredentialReviewScreen()),
      ),
      GoRoute(
        path: ClientPaths.accountHelp,
        pageBuilder: (_, state) => page(state, const AccountHelpScreen()),
      ),
      GoRoute(
        path: ClientPaths.adminAccountRecovery,
        pageBuilder: (_, state) => page(state, const RecoveryCasesScreen()),
      ),
      GoRoute(
        path: ClientPaths.adminMembershipLifecycle,
        pageBuilder: (_, state) =>
            page(state, const MembershipLifecycleScreen()),
      ),
      GoRoute(
        path: ClientPaths.deleteAccount,
        pageBuilder: (_, state) => page(state, const DeleteAccountScreen()),
      ),
      GoRoute(
        path: ClientPaths.adminMemberDeletions,
        pageBuilder: (_, state) => page(state, const MemberDeletionScreen()),
      ),
      GoRoute(
        path: ClientPaths.inbox,
        pageBuilder: (_, state) => page(state, const InboxScreen()),
        routes: [
          GoRoute(
            path: ':itemId',
            pageBuilder: (_, state) => page(
              state,
              InboxItemScreen(itemId: state.pathParameters['itemId']!),
            ),
          ),
        ],
      ),
      GoRoute(
        path: ClientPaths.signIn,
        pageBuilder: (_, state) => page(
          state,
          SignInScreen(
            afterCreateAccount: afterCreateAccount,
            afterSignIn: afterSignIn,
            assistedRecovery: assistedRecovery,
            continueTo: ClientPaths.continuationFrom(
              state.uri.queryParameters['then'],
            ),
          ),
        ),
      ),
      GoRoute(
        path: ClientPaths.createAccount,
        pageBuilder: (_, state) => page(
          state,
          SignInScreen(
            createAccount: true,
            afterCreateAccount: afterCreateAccount,
            assistedRecovery: assistedRecovery,
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

/// Story 4.10: a history link's member id (a UUID only; anything else opens
/// the reader's own history).
String? _memberParam(String? v) =>
    v != null &&
        RegExp(
          r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
        ).hasMatch(v)
    ? v
    : null;

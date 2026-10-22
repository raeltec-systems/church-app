import 'dart:io';

import 'package:bic_kafue_staff/app.dart';
import 'package:church_client_core/church_client_core.dart';
import 'package:church_client_core/testing.dart';
import 'package:church_contracts/church_contracts.dart';
import 'package:church_design_system/church_design_system.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

typedef Harness = ClientTestHarness;

Future<Harness> pumpStaff(
  WidgetTester tester, {
  Size size = const Size(1280, 800),
  double textScale = 1,
  String location = '/status',
  bool configured = true,
  NotificationHealthRepository? healthRepository,
  String? account = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
  void Function(Harness h)? setUp,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  final h = ClientTestHarness(account: account);
  setUp?.call(h);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        ...h.overrides(configured: configured),
        if (healthRepository != null)
          notificationHealthRepositoryProvider.overrideWithValue(
            healthRepository,
          ),
      ],
      child: StaffApp(initialLocation: location),
    ),
  );
  await tester.pumpAndSettle();
  return h;
}

Future<void> tapKey(WidgetTester tester, String key) async {
  await tester.ensureVisible(find.byKey(Key(key)));
  await tester.tap(find.byKey(Key(key)));
  await tester.pump();
}

/// The server answers that the caller is an Admin (the System group with
/// the developer pages is shown to Admins only).
void asAdmin(Harness h) =>
    h.grants.myAccess = AccessReadOk(syntheticGrants(roles: ['admin']));

void main() {
  // Each test starts as a fresh app: no input seen yet.
  setUp(FocusVisibility.instance.reset);

  testWidgets('tracer read shows in the shell; sidebar tabs are named', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await pumpStaff(tester, setUp: asAdmin);
    expect(find.text('Status: operational'), findsOneWidget);
    expect(find.text('BICC Kafue'), findsOneWidget);
    final tab = tester.getSemantics(
      find.bySemanticsLabel('Platform status').first,
    );
    expect(tab.role, SemanticsRole.tab);
    final list = tester.getSemantics(find.bySemanticsLabel('Staff sections'));
    expect(list.role, SemanticsRole.tabBar);
    handle.dispose();
  });

  testWidgets('reminder health maps each server refusal to its own message', (
    tester,
  ) async {
    const cases = <AccessDenial, (String, String)>{
      AccessDenial.notGranted: (
        'Reminder health unavailable',
        'This account is not authorized to view reminder health.',
      ),
      AccessDenial.notLinked: (
        'Reminder health unavailable',
        'This account is not authorized to view reminder health.',
      ),
      AccessDenial.signedOut: (
        'Not signed in',
        'Sign in to view reminder health.',
      ),
      AccessDenial.untrustedSession: (
        'Please sign in again',
        'This sign-in is no longer valid.',
      ),
      AccessDenial.reviewRequired: (
        'Access review required',
        'Your access needs a check by the church before it can continue.',
      ),
      AccessDenial.unavailable: (
        'Reminder health not available here',
        'The server does not offer reminder health here yet.',
      ),
    };
    for (final MapEntry(key: denial, value: (title, message))
        in cases.entries) {
      // A fresh app per reason: overrides apply only to a new ProviderScope.
      await tester.pumpWidget(const SizedBox.shrink());
      await pumpStaff(
        tester,
        location: ClientPaths.notificationHealth,
        healthRepository: _HealthRepository(AccessReadDenied(denial)),
        setUp: asAdmin,
      );
      expect(
        find.byKey(const Key('nav-${ClientPaths.notificationHealth}')),
        findsOneWidget,
      );
      expect(
        find.byKey(Key('notification-health-denied-${denial.name}')),
        findsOneWidget,
        reason: denial.name,
      );
      expect(find.text(title), findsOneWidget, reason: denial.name);
      expect(find.text(message), findsOneWidget, reason: denial.name);
    }
  });

  testWidgets(
    'reminder health reports a failed read separately from a refusal',
    (tester) async {
      await pumpStaff(
        tester,
        location: ClientPaths.notificationHealth,
        healthRepository: _HealthRepository(
          const AccessReadFailed(unreachable: true),
        ),
      );
      expect(
        find.byKey(const Key('notification-health-failed')),
        findsOneWidget,
      );
      expect(find.text('No connection'), findsOneWidget);
      expect(
        find.text('This account is not authorized to view reminder health.'),
        findsNothing,
      );
    },
  );

  testWidgets('reminder health is not in the navigation while signed out', (
    tester,
  ) async {
    await pumpStaff(tester, account: null);
    expect(
      find.byKey(const Key('nav-${ClientPaths.notificationHealth}')),
      findsNothing,
    );
    expect(
      staffDestinationsFor(null),
      isNot(contains(staffReminderHealthDestination)),
    );
    // The developer pages (System) are for Admins only.
    expect(
      staffDestinationsFor(null, signedIn: true),
      isNot(contains(staffReminderHealthDestination)),
    );
    final admin = syntheticGrants(roles: ['admin']);
    expect(
      staffDestinationsFor(admin, signedIn: true),
      containsAll([
        staffReminderHealthDestination,
        staffStatusDestination,
        staffFixtureDestination,
      ]),
    );
    // Every destination there is has its own icon (the rail shows icons
    // only).
    final everyone = syntheticGrants(
      roles: ['admin', 'pastor'],
      scopes: const [
        ScopeGrant(
          scopeKind: 'department_leader',
          scopeId: '44444444-4444-4444-8444-444444444444',
        ),
        ScopeGrant(
          scopeKind: 'cell_leader',
          scopeId: '77777777-7777-4777-8777-777777777777',
        ),
      ],
    );
    final all = staffDestinationsFor(everyone, signedIn: true);
    expect(
      {for (final d in all) d.icon}.length,
      all.length,
      reason: 'every destination has its own icon',
    );
  });

  test('story 4.10: Outcomes for department leaders, history for members', () {
    final leader = syntheticGrants(
      scopes: const [
        ScopeGrant(
          scopeKind: 'department_leader',
          scopeId: '44444444-4444-4444-8444-444444444444',
        ),
      ],
    );
    expect(
      staffDestinationsFor(leader),
      contains(staffDutyOutcomesDestination),
    );
    expect(staffDestinationsFor(leader), contains(staffDutyHistoryDestination));
    final member = syntheticGrants();
    expect(
      staffDestinationsFor(member),
      isNot(contains(staffDutyOutcomesDestination)),
    );
    expect(staffDestinationsFor(member), contains(staffDutyHistoryDestination));
    // The Admin role alone records no outcomes (the department's leaders do).
    final admin = syntheticGrants(roles: const ['admin']);
    expect(
      staffDestinationsFor(admin),
      isNot(contains(staffDutyOutcomesDestination)),
    );
    expect(
      staffDestinationsFor(null),
      isNot(contains(staffDutyHistoryDestination)),
    );
  });

  test('special assignments: the Pastors only', () {
    final pastor = syntheticGrants(roles: const ['pastor']);
    expect(staffDestinationsFor(pastor), contains(staffDutySpecialDestination));
    final leader = syntheticGrants(
      scopes: const [
        ScopeGrant(
          scopeKind: 'department_leader',
          scopeId: '44444444-4444-4444-8444-444444444444',
        ),
      ],
    );
    for (final g in [
      leader,
      syntheticGrants(roles: const ['admin']),
      syntheticGrants(),
      null,
    ]) {
      expect(
        staffDestinationsFor(g),
        isNot(contains(staffDutySpecialDestination)),
      );
    }
    final icons = {for (final d in staffDestinationsFor(pastor)) d.icon};
    expect(
      icons,
      contains(staffDutySpecialDestination.icon),
      reason: 'its own icon in the sidebar',
    );
  });

  test('story 6.1: Events for Media, Pastor and Admin only', () {
    for (final role in const ['media', 'pastor', 'admin']) {
      expect(
        staffDestinationsFor(syntheticGrants(roles: [role])),
        contains(staffEventsDestination),
        reason: role,
      );
    }
    final leader = syntheticGrants(
      scopes: const [
        ScopeGrant(
          scopeKind: 'department_leader',
          scopeId: '44444444-4444-4444-8444-444444444444',
        ),
      ],
    );
    for (final g in [leader, syntheticGrants(), null]) {
      expect(staffDestinationsFor(g), isNot(contains(staffEventsDestination)));
      expect(
        staffDestinationsFor(g, signedIn: true),
        isNot(contains(staffEventsDestination)),
      );
    }
    final icons = {
      for (final d in staffDestinationsFor(
        syntheticGrants(roles: const ['media']),
      ))
        d.icon,
    };
    expect(icons, contains(staffEventsDestination.icon));
    expect(
      staffDestinationsFor(syntheticGrants(roles: const ['admin'])).length,
      {
        for (final d in staffDestinationsFor(
          syntheticGrants(roles: const ['admin']),
        ))
          d.icon,
      }.length,
      reason: 'every sidebar entry has its own icon',
    );
  });

  testWidgets(
    'story 6.1: a Media member opens Events from the sidebar and drafts an '
    'event',
    (tester) async {
      final h = await pumpStaff(
        tester,
        size: const Size(1280, 1600),
        setUp: (h) {
          h.grants.myAccess = AccessReadOk(
            syntheticGrants(roles: const ['media']),
          );
          h.content.staffEvents = AccessReadOk(
            StaffEvents.fromJson(staffEventsData([])),
          );
        },
      );
      await tapKey(tester, 'nav-${ClientPaths.contentEvents}');
      await tester.pumpAndSettle();
      expect(find.byType(StaffEventsScreen), findsOneWidget);
      await tapKey(tester, 'events-new');
      await tester.pumpAndSettle();
      for (final (key, value) in [
        ('event-title-new', 'SYNTHETIC Harvest Thanksgiving'),
        ('event-description-new', 'SYNTHETIC two days of thanksgiving.'),
        ('event-start-date-new', '2099-10-10'),
        ('event-start-time-new', '09:00'),
        ('event-end-date-new', '2099-10-11'),
        ('event-end-time-new', '12:00'),
        ('event-location-new', 'SYNTHETIC Main sanctuary'),
      ]) {
        await tester.enterText(find.byKey(Key(key)), value);
      }
      await tester.pumpAndSettle();
      await tapKey(tester, 'event-save-new');
      final sent = h.gateway.sent.single;
      expect(sent.function, 'content_command');
      expect(sent.wire['command'], 'content.create_event');
      expect(
        (sent.wire['payload'] as Map)['ends_at'],
        '2099-10-11T10:00:00.000Z',
      );
      expect(tester.takeException(), isNull);
    },
  );

  test('story 6.13: Announcements for Media, Pastor and Admin only', () {
    for (final role in const ['media', 'pastor', 'admin']) {
      final groups = staffNavGroupsFor(syntheticGrants(roles: [role]));
      final content = groups.firstWhere((g) => g.label == 'Content').items;
      expect(content, [
        staffEventsDestination,
        staffAnnouncementsDestination,
      ], reason: role);
    }
    for (final g in [syntheticGrants(), null]) {
      expect(
        staffDestinationsFor(g, signedIn: true),
        isNot(contains(staffAnnouncementsDestination)),
      );
    }
  });

  testWidgets(
    'story 6.13: a Media member opens Announcements from the sidebar; a plain '
    'member has no entry',
    (tester) async {
      await pumpStaff(
        tester,
        size: const Size(1280, 1600),
        setUp: (h) {
          h.grants.myAccess = AccessReadOk(
            syntheticGrants(roles: const ['media']),
          );
          h.announcements.staffAnnouncements = AccessReadOk(
            StaffAnnouncements.fromJson(staffAnnouncementsData([])),
          );
        },
      );
      await tapKey(tester, 'nav-${ClientPaths.contentAnnouncements}');
      await tester.pumpAndSettle();
      expect(find.byType(StaffAnnouncementsScreen), findsOneWidget);
      expect(find.byKey(const Key('announcements-new')), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('story 6.13: a plain member sees no Announcements entry', (
    tester,
  ) async {
    await pumpStaff(
      tester,
      setUp: (h) => h.grants.myAccess = AccessReadOk(syntheticGrants()),
    );
    expect(
      find.byKey(const Key('nav-${ClientPaths.contentAnnouncements}')),
      findsNothing,
    );
  });

  testWidgets(
    'reminder health renders aggregate status for an authorized read',
    (tester) async {
      await pumpStaff(
        tester,
        location: ClientPaths.notificationHealth,
        healthRepository: _HealthRepository(),
      );
      expect(find.text('Due and pending'), findsOneWidget);
      expect(find.text('Without a route in 24 hours'), findsOneWidget);
      expect(find.text('Failed push attempts in 24 hours'), findsOneWidget);
      expect(find.text('2'), findsOneWidget);
      expect(find.text('Last successful scheduler handoff'), findsOneWidget);
      expect(find.text('2026-10-13T11:59:00.000Z'), findsNWidgets(2));
      expect(
        find.textContaining('no reminder content or recipient details'),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'story 2.1: account tab -> member summary; sign out; phone sign-in again',
    (tester) async {
      final h = await pumpStaff(tester);
      await tapKey(tester, 'nav-/account');
      for (var i = 0; i < 3; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.text('Account'), findsWidgets);
      h.memberAccess.answer(MemberAccessGranted(syntheticMemberSummary()));
      await tester.pumpAndSettle();
      expect(find.text('SYNTHETIC Member One'), findsOneWidget);
      expect(find.text('+12025550101'), findsOneWidget);

      await tapKey(tester, 'sign-out');
      await tester.pumpAndSettle();
      expect(find.text('SYNTHETIC Member One'), findsNothing);
      await tapKey(tester, 'go-sign-in');
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('phone-field')),
        '+44 7700 900123',
      );
      await tester.enterText(
        find.byKey(const Key('password-field')),
        'Synthetic-pw',
      );
      await tapKey(tester, 'submit-button');
      expect(h.auth.last.phoneE164, '+447700900123');
      h.auth.succeed('cccccccc-cccc-4ccc-8ccc-cccccccccccc');
      for (var i = 0; i < 3; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      // Staff land on the Overview after signing in.
      expect(find.byKey(const Key('page-title')), findsOneWidget);
      expect(find.text('Overview'), findsWidgets);
      await tapKey(tester, 'nav-/account');
      for (var i = 0; i < 3; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      h.memberAccess.answer(
        MemberAccessGranted(
          syntheticMemberSummary(
            name: 'SYNTHETIC Member Three',
            phone: '+447700900123',
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('SYNTHETIC Member Three'), findsOneWidget);
      expect(h.memberAccess.calls, 2);
    },
  );

  testWidgets(
    'story 2.2: refresh and resume keep the session; a session the server no '
    'longer trusts is ended and its state cleared',
    (tester) async {
      final h = await pumpStaff(tester);
      await tapKey(tester, 'nav-/account');
      for (var i = 0; i < 3; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      h.memberAccess.answer(MemberAccessGranted(syntheticMemberSummary()));
      await tester.pumpAndSettle();
      expect(find.text('SYNTHETIC Member One'), findsOneWidget);

      // Token refresh: same account id, nothing is dropped or re-asked.
      h.session.switchTo(h.session.currentAccountId);
      await tester.pumpAndSettle();
      expect(find.text('SYNTHETIC Member One'), findsOneWidget);
      expect(h.memberAccess.calls, 1);

      // Back to the foreground: the server is asked again, no password prompt.
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(h.memberAccess.calls, 2);
      expect(find.byKey(const Key('password-field')), findsNothing);
      // Revoked elsewhere (or a credential change): the answer is untrusted.
      h.memberAccess.answer(
        const MemberAccessDenied(MemberAccessDenial.untrustedSession),
      );
      await tester.pumpAndSettle();
      expect(h.auth.signOuts, 1);
      expect(h.session.currentAccountId, isNull);
      expect(find.byKey(const Key('session-ended')), findsOneWidget);
      expect(find.text('SYNTHETIC Member One'), findsNothing);
      expect(find.byKey(const Key('go-sign-in')), findsOneWidget);
    },
  );

  testWidgets('unconfigured build explains itself and does not send commands', (
    tester,
  ) async {
    await pumpStaff(tester, configured: false);
    expect(find.byKey(const Key('missing-config')), findsOneWidget);
    // The developer pages are not in the navigation without Admin; their
    // addresses still open.
    GoRouter.of(tester.element(find.byType(Scaffold).first))
        .go(ClientPaths.fixture);
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('intent-key-field')), 'k');
    await tapKey(tester, 'create-button');
    await tester.pump();
    expect(find.text('Not sent: no server configured'), findsOneWidget);
    expect(find.text(UnconfiguredCommandGateway.reason), findsOneWidget);
    expect(find.byKey(const Key('try-again-button')), findsNothing);
  });

  testWidgets('synthetic read/write fixture: create, change, conflict kept', (
    tester,
  ) async {
    final h = await pumpStaff(tester, setUp: asAdmin);
    await tapKey(tester, 'nav-/fixture');
    await tester.pumpAndSettle();
    expect(find.text('Fixture command'), findsWidgets);

    await tester.enterText(
      find.byKey(const Key('intent-key-field')),
      'staff-web',
    );
    await tapKey(tester, 'create-button');
    expect(find.text('Sending…'), findsOneWidget);
    h.gateway.sent.last.confirm(fixtureCounterData(intentKey: 'staff-web'), 1);
    await tester.pump();
    expect(find.text('Confirmed by server · revision 1'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('by-field')), '5');
    await tapKey(tester, 'increment-button');
    h.gateway.sent.last.refuse(
      ErrorCode.conflict,
      currentRevision: const Optional.of(2),
    );
    await tester.pump();
    expect(find.byKey(const Key('state-conflict')), findsOneWidget);
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('by-field')))
          .controller!
          .text,
      '5',
    );

    h.session.switchTo(null);
    await tester.pump();
    await tester.pump();
    expect(find.text('You were signed out'), findsOneWidget);
    expect(find.byKey(const Key('counter-card')), findsNothing);
  });

  testWidgets(
    'story 2.3: the sidebar follows the server\'s current grants at the next '
    'navigation (grant, then revoke in another tab)',
    (tester) async {
      final h = await pumpStaff(tester);
      expect(find.byKey(const Key('nav-/admin/grants')), findsNothing);
      expect(find.byKey(const Key('nav-/access')), findsNothing);

      // An Admin elsewhere grants Admin; this already open tab sees it at its
      // next protected request (the navigation asks again).
      h.grants.myAccess = AccessReadOk(syntheticGrants(roles: ['admin']));
      await tapKey(tester, 'nav-/account');
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byKey(const Key('nav-/admin/grants')), findsOneWidget);
      expect(find.byKey(const Key('nav-/access')), findsOneWidget);
      expect(find.byKey(const Key('nav-/inbox')), findsOneWidget);

      // Admin removed elsewhere: the next navigation drops the entry.
      h.grants.myAccess = AccessReadOk(syntheticGrants(revision: 3));
      await tapKey(tester, 'nav-/access');
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byKey(const Key('nav-/admin/grants')), findsNothing);
      expect(find.byKey(const Key('no-roles')), findsOneWidget);
    },
  );

  testWidgets(
    'story 4.1: Duties follows a department scope and Departments the Admin '
    'grant; a cell scope gives neither',
    (tester) async {
      final h = await pumpStaff(tester);
      expect(find.byKey(const Key('nav-/duties/leader')), findsNothing);
      h.grants.myAccess = AccessReadOk(
        syntheticGrants(
          scopes: const [
            ScopeGrant(
              scopeKind: 'cell_leader',
              scopeId: '44444444-4444-4444-8444-444444444444',
            ),
          ],
        ),
      );
      await tapKey(tester, 'nav-/account');
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byKey(const Key('nav-/duties/leader')), findsNothing);
      h.grants.myAccess = AccessReadOk(
        syntheticGrants(
          scopes: const [
            ScopeGrant(
              scopeKind: 'department_leader',
              scopeId: '44444444-4444-4444-8444-444444444444',
            ),
          ],
        ),
      );
      h.duties.board = AccessReadOk(
        DutyLeaderBoard.fromJson({'departments': const <Object?>[]}),
      );
      await tapKey(tester, 'nav-/access');
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byKey(const Key('nav-/admin/departments')), findsNothing);
      await tapKey(tester, 'nav-/duties/leader');
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byKey(const Key('leader-no-departments')), findsOneWidget);
      h.grants.myAccess = AccessReadOk(syntheticGrants(roles: ['admin']));
      await tapKey(tester, 'nav-/account');
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byKey(const Key('nav-/admin/departments')), findsOneWidget);
      expect(find.byKey(const Key('nav-/duties/leader')), findsOneWidget);
    },
  );

  testWidgets(
    'story 4.6: My follow-ups follows member access, Follow-ups a leader '
    'scope and Follow-up routing the Admin grant',
    (tester) async {
      final h = await pumpStaff(tester, size: const Size(1280, 1600));
      expect(find.byKey(const Key('nav-/followups')), findsNothing);
      h.grants.myAccess = AccessReadOk(syntheticGrants());
      h.followUps.mine = AccessReadOk(
        MyFollowUps.fromJson({
          'member_id': '22222222-2222-4222-8222-222222222222',
          'tasks': [followUpTaskData()],
          'truncated': false,
        }),
      );
      await tapKey(tester, 'nav-/account');
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byKey(const Key('nav-/followups/supervision')), findsNothing);
      expect(find.byKey(const Key('nav-/admin/followups')), findsNothing);
      await tapKey(tester, 'nav-/followups');
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('SYNTHETIC: phone and check in'), findsOneWidget);
      h.grants.myAccess = AccessReadOk(
        syntheticGrants(
          roles: ['admin'],
          scopes: const [
            ScopeGrant(
              scopeKind: 'cell_leader',
              scopeId: '44444444-4444-4444-8444-444444444444',
            ),
          ],
        ),
      );
      await tapKey(tester, 'nav-/account');
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));
      // Admin and Cell leader: the role switch narrows the sidebar to one
      // role at a time (the Admin view first).
      expect(find.byKey(const Key('nav-/admin/followups')), findsOneWidget);
      expect(find.byKey(const Key('nav-/followups/supervision')), findsNothing);
      await tapKey(tester, 'role-view-cellLeader');
      await tester.pump(const Duration(milliseconds: 100));
      expect(
        find.byKey(const Key('nav-/followups/supervision')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('nav-/admin/followups')), findsNothing);
    },
  );

  testWidgets(
    'story 4.7: a supervisor\'s overdue alert opens the follow-up task',
    (tester) async {
      const item = '33333333-3333-4333-8333-323232323232';
      const task = '46464646-4646-4646-8646-464646464646';
      final h = await pumpStaff(
        tester,
        size: const Size(1280, 2000),
        location: '/inbox/$item',
        setUp: (h) {
          h.grants.myAccess = AccessReadOk(syntheticGrants());
          h.inbox.opened[item] = AccessReadOk(
            OpenedInboxItem.fromJson({
              ...inboxItemData(
                id: item,
                kind: 'followup_overdue',
                title: 'Follow-up task overdue',
                body:
                    'A follow-up task you supervise is overdue. Open it to '
                    'follow up with its owner.',
              ),
              'state': 'current',
              'target': '/followups/tasks/$task',
            }),
          );
          h.followUps.task = AccessReadOk(
            FollowUpDetail.fromJson({
              'view': 'full',
              'task': followUpTaskData(capacity: 'supervisor', overdue: true),
              'activity': const <Object?>[],
              'notes': const <Object?>[],
            }),
          );
        },
      );
      expect(find.text('Follow-up task overdue'), findsOneWidget);
      await tapKey(tester, 'inbox-item-open-target');
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));
      expect(h.followUps.taskReads, contains(task));
      expect(find.byKey(const Key('followup-summary')), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('story 4.8: a leader\'s overdue alert opens the Duties board', (
    tester,
  ) async {
    const item = '35353535-3535-4535-8535-353535353535';
    final h = await pumpStaff(
      tester,
      size: const Size(1280, 2000),
      location: '/inbox/$item',
      setUp: (h) {
        h.grants.myAccess = AccessReadOk(
          syntheticGrants(
            scopes: const [
              ScopeGrant(
                scopeKind: 'department_leader',
                scopeId: '44444444-4444-4444-8444-444444444444',
              ),
            ],
          ),
        );
        h.inbox.opened[item] = AccessReadOk(
          OpenedInboxItem.fromJson({
            ...inboxItemData(
              id: item,
              kind: 'duty_response_overdue',
              title: 'Duty answer overdue',
              body:
                  'A duty in your department passed its answer-by time '
                  'without an answer. Open Duties to follow it up.',
            ),
            'state': 'current',
            'target': '/duties/leader',
          }),
        );
        h.duties.board = AccessReadOk(
          DutyLeaderBoard.fromJson({'departments': const <Object?>[]}),
        );
      },
    );
    expect(find.text('Duty answer overdue'), findsOneWidget);
    await tapKey(tester, 'inbox-item-open-target');
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
    expect(h.duties.boardCalls, greaterThan(0));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'story 4.3: Rota follows the department scope and opens the rota grid',
    (tester) async {
      final h = await pumpStaff(tester);
      expect(find.byKey(const Key('nav-/duties/rota')), findsNothing);
      h.grants.myAccess = AccessReadOk(
        syntheticGrants(
          scopes: const [
            ScopeGrant(
              scopeKind: 'department_deputy',
              scopeId: '44444444-4444-4444-8444-444444444444',
            ),
          ],
        ),
      );
      h.duties.rota = AccessReadOk(
        DutyRota.fromJson({'departments': const <Object?>[]}),
      );
      await tapKey(tester, 'nav-/account');
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));
      await tapKey(tester, 'nav-/duties/rota');
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byKey(const Key('rota-no-departments')), findsOneWidget);
      expect(h.duties.rotaCalls, greaterThan(0));
    },
  );

  testWidgets(
    'story 4.9: Coverage follows the department scope and opens the queue',
    (tester) async {
      final h = await pumpStaff(tester);
      expect(find.byKey(const Key('nav-/duties/coverage')), findsNothing);
      h.grants.myAccess = AccessReadOk(
        syntheticGrants(
          scopes: const [
            ScopeGrant(
              scopeKind: 'department_leader',
              scopeId: '44444444-4444-4444-8444-444444444444',
            ),
          ],
        ),
      );
      h.coverage.coverage = AccessReadOk(
        DutyCoverage.fromJson({
          'window': {'from': '2099-01-01', 'to': '2099-01-07'},
          'departments': const <Object?>[],
        }),
      );
      await tapKey(tester, 'nav-/account');
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));
      await tapKey(tester, 'nav-/duties/coverage');
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('No departments to show.'), findsOneWidget);
      expect(h.coverage.queries, isNotEmpty);
    },
  );

  testWidgets(
    'story 2.5: Members & applications follows the Admin grant and opens the '
    'review queue',
    (tester) async {
      final h = await pumpStaff(tester);
      expect(find.byKey(const Key('nav-/admin/members')), findsNothing);
      h.grants.myAccess = AccessReadOk(syntheticGrants(roles: ['admin']));
      h.review.queue = reviewQueueWith([reviewApplicationData()]);
      await tapKey(tester, 'nav-/account');
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));
      await tapKey(tester, 'nav-/admin/members');
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('Members & applications'), findsWidgets);
      expect(find.text('SYNTHETIC Ruth Mwale'), findsOneWidget);

      // Admin removed elsewhere: the entry goes and the server's denial shows.
      h.grants.myAccess = AccessReadOk(syntheticGrants(revision: 3));
      h.review.queue = const AccessReadDenied(AccessDenial.notGranted);
      await tapKey(tester, 'review-reload');
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('SYNTHETIC Ruth Mwale'), findsNothing);
      expect(find.byKey(const Key('nav-/admin/members')), findsNothing);
    },
  );

  testWidgets(
    'story 2.6: Cells follows the Admin grant and My cell group follows a '
    'cell scope',
    (tester) async {
      final h = await pumpStaff(tester);
      expect(find.byKey(const Key('nav-/admin/cells')), findsNothing);
      expect(find.byKey(const Key('nav-/cells/leader')), findsNothing);
      h.grants.myAccess = AccessReadOk(
        syntheticGrants(
          scopes: const [
            ScopeGrant(
              scopeKind: 'cell_leader',
              scopeId: '77777777-7777-4777-8777-777777777777',
            ),
          ],
        ),
      );
      h.cells.leader = AccessReadOk(
        LeaderQueue.fromJson({
          'cells': [
            {
              'cell_id': '77777777-7777-4777-8777-777777777777',
              'name': 'SYNTHETIC Cell X',
              'broad_area': 'SYNTHETIC North',
              'role': 'leader',
              'members': const [],
              'requests': const [],
            },
          ],
        }),
      );
      await tapKey(tester, 'nav-/account');
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byKey(const Key('nav-/admin/cells')), findsNothing);
      await tapKey(tester, 'nav-/cells/leader');
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('SYNTHETIC Cell X'), findsOneWidget);

      // An Admin who leads no cell sees Cells, not My cell group.
      h.grants.myAccess = AccessReadOk(syntheticGrants(roles: ['admin']));
      h.cells.admin = AccessReadOk(
        CellAdminOverview.fromJson({
          'cells': [adminCellData()],
          'requests': const [],
          'members': const [],
        }),
      );
      await tapKey(tester, 'nav-/account');
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byKey(const Key('nav-/cells/leader')), findsNothing);
      await tapKey(tester, 'nav-/admin/cells');
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));
      // Two panes: the cell in the list and, chosen, on the right.
      expect(
        find.byKey(const Key('cell-list-77777777-7777-4777-8777-777777777777')),
        findsOneWidget,
      );
      expect(find.text('SYNTHETIC Cell X'), findsNWidgets(2));
      expect(
        staffDestinationsFor(null),
        isNot(contains(staffCellsDestination)),
      );
    },
  );

  testWidgets('Admins see Recovery emails; the queue is the server answer', (
    tester,
  ) async {
    final h = await pumpStaff(tester, location: '/fixture');
    expect(find.byKey(const Key('nav-/admin/recovery-emails')), findsNothing);
    expect(
      staffDestinationsFor(null),
      isNot(contains(staffRecoveryEmailsDestination)),
    );
    h.grants.myAccess = AccessReadOk(syntheticGrants(roles: ['admin']));
    h.recoveryEmail.queue = AccessReadOk(
      RecoveryEmailQueue.fromJson({
        'proposals': [recoveryReviewItemData()],
      }),
    );
    await tapKey(tester, 'nav-/account');
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
    await tapKey(tester, 'nav-/admin/recovery-emails');
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('SYNTHETIC Ruth Mwale'), findsOneWidget);
    expect(h.recoveryEmail.queueCalls, greaterThanOrEqualTo(1));
  });

  testWidgets(
    'story 2.8: Admins see Access reviews; the queue is the server answer',
    (tester) async {
      final h = await pumpStaff(tester, location: '/fixture');
      expect(
        find.byKey(const Key('nav-/admin/credential-reviews')),
        findsNothing,
      );
      expect(
        staffDestinationsFor(null),
        isNot(contains(staffCredentialReviewsDestination)),
      );
      h.grants.myAccess = AccessReadOk(syntheticGrants(roles: ['admin']));
      h.credentials.queue = AccessReadOk(
        CredentialQueue.fromJson(
          credentialQueueData(
            changes: [credentialChangeItemData()],
            holds: [holdItemData()],
          ),
        ),
      );
      await tapKey(tester, 'nav-/account');
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));
      await tapKey(tester, 'nav-/admin/credential-reviews');
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('SYNTHETIC Grace Phiri'), findsOneWidget);
      expect(find.text('SYNTHETIC Mary Tembo'), findsOneWidget);
      expect(h.credentials.queueCalls, greaterThanOrEqualTo(1));
    },
  );

  testWidgets(
    'story 2.9: Admins see Account recovery; the cases are the server answer',
    (tester) async {
      final h = await pumpStaff(tester, location: '/fixture');
      expect(
        find.byKey(const Key('nav-/admin/account-recovery')),
        findsNothing,
      );
      expect(
        staffDestinationsFor(null),
        isNot(contains(staffAccountRecoveryDestination)),
      );
      h.grants.myAccess = AccessReadOk(syntheticGrants(roles: ['admin']));
      h.recoveryCases.cases = AccessReadOk(
        RecoveryCases.fromJson({
          'cases': [
            recoveryCaseData(grantState: 'issued'),
            recoveryCaseData(
              caseId: '30303030-3030-4030-8030-303030303030',
              name: 'SYNTHETIC Peter Zulu',
              operationState: 'uncertain',
            ),
          ],
          'accepting': true,
        }),
      );
      await tapKey(tester, 'nav-/account');
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));
      await tapKey(tester, 'nav-/admin/account-recovery');
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('SYNTHETIC Ruth Mwale'), findsOneWidget);
      expect(find.text('SYNTHETIC Peter Zulu'), findsOneWidget);
      expect(
        find.byKey(
          const Key('recovery-reconcile-30303030-3030-4030-8030-303030303030'),
        ),
        findsOneWidget,
      );
      expect(find.textContaining('arg_'), findsNothing);
      expect(h.recoveryCases.calls, greaterThanOrEqualTo(1));
    },
  );

  testWidgets(
    'story 2.10: Admins see Membership status; deactivated members, login '
    'holds and handovers are the server answer',
    (tester) async {
      final h = await pumpStaff(tester, location: '/fixture');
      expect(
        find.byKey(const Key('nav-/admin/membership-status')),
        findsNothing,
      );
      expect(
        staffDestinationsFor(null),
        isNot(contains(staffMembershipLifecycleDestination)),
      );
      h.grants.myAccess = AccessReadOk(syntheticGrants(roles: ['admin']));
      h.lifecycle.overview = AccessReadOk(
        MembershipLifecycleOverview.fromJson(
          membershipLifecycleData(
            deactivated: [deactivatedMemberData()],
            loginHolds: [loginHoldData()],
            handovers: [handoverData()],
          ),
        ),
      );
      await tapKey(tester, 'nav-/account');
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));
      await tapKey(tester, 'nav-/admin/membership-status');
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('SYNTHETIC Esther Banda'), findsWidgets);
      expect(find.text('SYNTHETIC Moses Phiri'), findsOneWidget);
      expect(
        find.byKey(
          const Key('lifecycle-restore-81818181-8181-4181-8181-818181818181'),
        ),
        findsOneWidget,
      );
      expect(h.lifecycle.overviewCalls, greaterThanOrEqualTo(1));
    },
  );

  testWidgets(
    'story 2.11: Admins see Member deletions; deletions and their steps are '
    'the server answer',
    (tester) async {
      final h = await pumpStaff(tester, location: '/fixture');
      expect(
        find.byKey(const Key('nav-/admin/member-deletions')),
        findsNothing,
      );
      expect(
        staffDestinationsFor(null),
        isNot(contains(staffMemberDeletionsDestination)),
      );
      h.grants.myAccess = AccessReadOk(syntheticGrants(roles: ['admin']));
      h.deletions.overview = AccessReadOk(
        MemberDeletionOverview.fromJson(
          memberDeletionOverviewData(
            deletions: [memberDeletionData()],
            deactivated: [deletionCandidateData()],
          ),
        ),
      );
      await tapKey(tester, 'nav-/account');
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));
      await tapKey(tester, 'nav-/admin/member-deletions');
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('SYNTHETIC Grace Mwale'), findsOneWidget);
      expect(find.text('SYNTHETIC Daniel Zulu'), findsOneWidget);
      expect(
        find.byKey(
          const Key('deletion-request-87878787-8787-4787-8787-878787878787'),
        ),
        findsOneWidget,
      );
      expect(h.deletions.overviewCalls, greaterThanOrEqualTo(1));
    },
  );

  testWidgets(
    'story 2.11: a non-Admin opening Member deletions sees only the denial',
    (tester) async {
      final h = await pumpStaff(tester, location: '/admin/member-deletions');
      expect(
        find.byKey(const Key('deletions-denied-notGranted')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('deletion-search-field')), findsNothing);
      expect(h.gateway.sent, isEmpty);
    },
  );

  testWidgets(
    'story 2.10: a deactivated membership on staff web says so after sign-in',
    (tester) async {
      final h = await pumpStaff(tester, location: '/fixture');
      await tapKey(tester, 'nav-/account');
      for (var i = 0; i < 3; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      h.lifecycle.status = const AccessReadOk(
        MyMembershipStatus(deactivated: true),
      );
      h.memberAccess.answer(
        const MemberAccessDenied(MemberAccessDenial.notLinked),
      );
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.byKey(const Key('membership-deactivated')), findsOneWidget);
      expect(find.text('Church membership not active'), findsOneWidget);
    },
  );

  testWidgets(
    'story 2.8: a held session on staff web sees only the help screen',
    (tester) async {
      final h = await pumpStaff(tester, location: '/fixture');
      h.grants.myAccess = const AccessReadDenied(AccessDenial.reviewRequired);
      h.memberAccess.next = const MemberAccessDenied(
        MemberAccessDenial.reviewRequired,
      );
      h.credentials.mine = AccessReadOk(
        MyCredentials.fromJson(
          myCredentialsData(access: 'review_required', canRequest: false),
        ),
      );
      await tapKey(tester, 'nav-/account');
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byKey(const Key('access-review-required')), findsOneWidget);
      expect(find.byKey(const Key('member-summary')), findsNothing);
      expect(find.byKey(const Key('nav-/admin/members')), findsNothing);
      expect(find.byKey(const Key('nav-/access')), findsNothing);
    },
  );

  testWidgets('an account switch drops the protected state', (tester) async {
    final h = await pumpStaff(tester, location: '/fixture');
    await tester.enterText(find.byKey(const Key('intent-key-field')), 'k');
    await tapKey(tester, 'create-button');
    h.gateway.sent.last.confirm(
      fixtureCounterData(intentKey: 'k', value: 3),
      1,
    );
    await tester.pump();
    expect(find.text('Value 3'), findsOneWidget);
    h.session.switchTo('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb');
    await tester.pump();
    await tester.pump();
    expect(find.text('Value 3'), findsNothing);
    expect(find.text('The signed-in account changed'), findsOneWidget);
  });

  testWidgets(
    'leaving and returning keeps this account\'s in-memory state (AD-13 '
    'clears it on account change, not on navigation)',
    (tester) async {
      final h = await pumpStaff(tester, location: '/fixture', setUp: asAdmin);
      await tester.enterText(find.byKey(const Key('intent-key-field')), 'k');
      await tapKey(tester, 'create-button');
      h.gateway.sent.last.unknown();
      await tester.pump();
      expect(find.text('Not confirmed'), findsOneWidget);
      await tapKey(tester, 'nav-/status');
      await tester.pumpAndSettle();
      expect(find.text('Not confirmed'), findsNothing);
      await tapKey(tester, 'nav-/fixture');
      await tester.pumpAndSettle();
      // The unconfirmed command is still known, so it is checked again under
      // its own request id instead of being resubmitted as a new one.
      expect(find.text('Not confirmed'), findsOneWidget);
      await tapKey(tester, 'check-again-button');
      expect(
        h.gateway.sent.last.request.requestId,
        h.gateway.sent.first.request.requestId,
      );
    },
  );

  for (final kind in [PointerDeviceKind.touch, PointerDeviceKind.mouse]) {
    testWidgets('a $kind tap on a tab leaves no focus ring behind', (
      tester,
    ) async {
      await pumpStaff(tester, setUp: asAdmin);
      // An Admin's sidebar is long: bring the entry into view first.
      await tester.ensureVisible(find.byKey(const Key('nav-/fixture')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('nav-/fixture')), kind: kind);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('intent-key-field')), findsOneWidget);
      expect(
        FocusManager.instance.primaryFocus?.context
            ?.findAncestorWidgetOfExactType<NavItem>(),
        isNull,
        reason: 'a tap does not move focus to the tab',
      );
      // No FocusRing anywhere draws a ring after pointer use.
      for (final ring in tester.widgetList<Container>(
        find.descendant(
          of: find.byType(FocusRing),
          matching: find.byType(Container),
        ),
      )) {
        final d = ring.decoration;
        if (d is BoxDecoration && d.border is Border) {
          expect((d.border! as Border).top.color, Colors.transparent);
        }
      }
    });
  }

  testWidgets('keyboard: Tab reaches the menu button, then the nav tabs; Enter '
      'navigates', (tester) async {
    await pumpStaff(tester, setUp: asAdmin);
    String? navLabel() => FocusManager.instance.primaryFocus?.context
        ?.findAncestorWidgetOfExactType<NavItem>()
        ?.label;
    String? buttonLabel() => FocusManager.instance.primaryFocus?.context
        ?.findAncestorWidgetOfExactType<IconButton>()
        ?.tooltip;
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(buttonLabel(), 'Collapse menu');
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(navLabel(), 'Overview');
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(navLabel(), 'Members');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('review-reload')), findsOneWidget);
    // Focus stays on the selected tab after keyboard navigation.
    expect(navLabel(), 'Members');
  });

  for (final (size, label) in [
    (const Size(1280, 800), 'desktop'),
    (const Size(390, 844), 'narrow'),
  ]) {
    testWidgets('2x text, $label: both destinations render without overflow', (
      tester,
    ) async {
      await pumpStaff(tester, size: size, textScale: 2, setUp: asAdmin);
      expect(tester.takeException(), isNull);
      await tapKey(tester, 'nav-/fixture');
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('create-button')), findsOneWidget);
    });
  }

  testWidgets('sidebar at 1x; top bar at 2x text on the same window', (
    tester,
  ) async {
    double dy(String k) => tester.getTopLeft(find.byKey(Key(k))).dy;
    await pumpStaff(tester, setUp: asAdmin);
    expect(dy('nav-/fixture'), greaterThan(dy('nav-/status')));
    await pumpStaff(tester, textScale: 2, setUp: asAdmin);
    expect(dy('nav-/fixture'), dy('nav-/status'));
  });

  testWidgets(
    'signed out: the sign-in landing with one way in, no navigation and no '
    'developer page',
    (tester) async {
      expect(const StaffApp().initialLocation, ClientPaths.overview);
      await pumpStaff(tester, account: null, location: ClientPaths.overview);
      expect(find.byKey(const Key('staff-landing')), findsOneWidget);
      expect(find.text('BICC Kafue staff'), findsOneWidget);
      expect(find.byType(NavItem), findsNothing);
      expect(find.text('Platform status'), findsNothing);
      expect(find.text('Fixture command'), findsNothing);
      await tapKey(tester, 'landing-sign-in');
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('phone-field')), findsOneWidget);
    },
  );

  testWidgets(
    'an Admin\'s Overview: figures from the existing reads, what needs '
    'attention, each opening the screen that resolves it',
    (tester) async {
      const app = '55555555-5555-4555-8555-555555555555';
      await pumpStaff(
        tester,
        location: ClientPaths.overview,
        setUp: (h) {
          asAdmin(h);
          h.review.queue = reviewQueueWith([reviewApplicationData()]);
          h.cells.admin = AccessReadOk(
            CellAdminOverview.fromJson({
              'cells': [adminCellData()],
              'requests': const [],
              'members': const [],
            }),
          );
        },
      );
      String figure(String id) => tester
          .widgetList<Text>(
            find.descendant(
              of: find.byKey(Key('overview-figure-$id')),
              matching: find.byType(Text),
            ),
          )
          .first
          .data!;
      expect(find.byKey(const Key('page-title')), findsOneWidget);
      expect(find.byKey(const Key('page-subtitle')), findsOneWidget);
      expect(figure('applications'), '1');
      expect(figure('cell-requests'), '0');
      // A read the server refused shows a dash, never a zero.
      expect(figure('duty-gaps'), '—');
      expect(
        find.byKey(const Key('overview-attention-application-$app')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('overview-problems')), findsOneWidget);
      // The Members entry counts the applications waiting.
      expect(
        find.descendant(
          of: find.byKey(const Key('nav-/admin/members')),
          matching: find.text('1'),
        ),
        findsOneWidget,
      );
      await tapKey(tester, 'overview-open-application-$app');
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byKey(const Key('application-card-$app')), findsOneWidget);
    },
  );

  testWidgets(
    'a cell leader\'s Overview: requests to join their cell; a read the '
    'server refused is a dash, never a zero',
    (tester) async {
      const request = '88888888-8888-4888-8888-888888888888';
      await pumpStaff(
        tester,
        location: ClientPaths.overview,
        setUp: (h) {
          h.grants.myAccess = AccessReadOk(
            syntheticGrants(
              scopes: const [
                ScopeGrant(
                  scopeKind: 'cell_leader',
                  scopeId: '77777777-7777-4777-8777-777777777777',
                ),
              ],
            ),
          );
          h.cells.leader = AccessReadOk(
            LeaderQueue.fromJson({
              'cells': [
                {
                  'cell_id': '77777777-7777-4777-8777-777777777777',
                  'name': 'SYNTHETIC Cell X',
                  'broad_area': 'SYNTHETIC North',
                  'role': 'leader',
                  'members': const [],
                  'requests': [
                    {
                      'request_id': request,
                      'member_id': '66666666-6666-4666-8666-666666666666',
                      'display_name': 'SYNTHETIC Ruth Mwale',
                      'kind': 'join',
                      'member_revision': 2,
                      'own_record': false,
                    },
                  ],
                },
              ],
            }),
          );
        },
      );
      String figure(String id) => tester
          .widgetList<Text>(
            find.descendant(
              of: find.byKey(Key('overview-figure-$id')),
              matching: find.byType(Text),
            ),
          )
          .first
          .data!;
      expect(figure('my-cell-requests'), '1');
      expect(figure('next-meeting'), '—');
      expect(
        find.byKey(const Key('overview-attention-my-cell-request-$request')),
        findsOneWidget,
      );
      // No Admin figures, and no role switch for one staff role.
      expect(
        find.byKey(const Key('overview-figure-applications')),
        findsNothing,
      );
      expect(find.byKey(const Key('role-view-cellLeader')), findsNothing);
      // The My cell group entry counts the requests to confirm.
      expect(
        find.descendant(
          of: find.byKey(const Key('nav-/cells/leader')),
          matching: find.text('1'),
        ),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'the sidebar folds to a rail of named icons and back; the choice lasts '
    'across screens and the content takes the width',
    (tester) async {
      final handle = tester.ensureSemantics();
      await pumpStaff(tester, location: ClientPaths.overview, setUp: asAdmin);
      double sidebar() =>
          tester.getSize(find.byKey(const Key('staff-sidebar'))).width;
      double contentLeft() =>
          tester.getTopLeft(find.byKey(const Key('page-title'))).dx;
      expect(sidebar(), ChurchGeometry.staffSidebarWidth);
      final wideLeft = contentLeft();
      expect(find.text('People'), findsOneWidget);

      await tapKey(tester, 'sidebar-toggle');
      await tester.pumpAndSettle();
      expect(sidebar(), ChurchGeometry.staffRailWidth);
      expect(contentLeft(), lessThan(wideLeft));
      expect(find.text('People'), findsNothing);
      // Each item keeps its icon, its tab role and its name.
      final tab = tester.getSemantics(
        find.byKey(const Key('nav-/admin/members')),
      );
      expect(tab.label, 'Members');
      expect(tab.role, SemanticsRole.tab);
      expect(
        find.descendant(
          of: find.byKey(const Key('nav-/admin/members')),
          matching: find.byIcon(Icons.how_to_reg_outlined),
        ),
        findsOneWidget,
      );
      expect(
        tester
            .widget<IconButton>(find.byKey(const Key('sidebar-toggle')))
            .tooltip,
        'Expand menu',
      );

      // Another screen keeps the rail.
      await tapKey(tester, 'nav-/status');
      await tester.pumpAndSettle();
      expect(find.text('Status: operational'), findsOneWidget);
      expect(sidebar(), ChurchGeometry.staffRailWidth);
      expect(
        tester.getSemantics(find.byKey(const Key('nav-/status'))).label,
        'Platform status',
      );

      await tapKey(tester, 'sidebar-toggle');
      await tester.pumpAndSettle();
      expect(sidebar(), ChurchGeometry.staffSidebarWidth);
      expect(find.text('People'), findsOneWidget);
      handle.dispose();
    },
  );

  testWidgets(
    'the role switch appears only with two staff roles and narrows the '
    'sidebar to the role being viewed',
    (tester) async {
      final h = await pumpStaff(
        tester,
        location: ClientPaths.overview,
        setUp: asAdmin,
      );
      expect(find.byKey(const Key('role-view-admin')), findsNothing);
      expect(find.text('System'), findsOneWidget);
      h.grants.myAccess = AccessReadOk(
        syntheticGrants(roles: ['admin', 'pastor']),
      );
      await tapKey(tester, 'nav-/account');
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byKey(const Key('role-view-admin')), findsOneWidget);
      expect(find.byKey(const Key('role-view-pastor')), findsOneWidget);
      expect(find.byKey(const Key('role-view-cellLeader')), findsNothing);
      expect(find.byKey(const Key('nav-/admin/members')), findsOneWidget);
      expect(find.byKey(const Key('nav-/duties/special')), findsNothing);

      await tapKey(tester, 'role-view-pastor');
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byKey(const Key('nav-/duties/special')), findsOneWidget);
      expect(find.byKey(const Key('nav-/admin/members')), findsNothing);
      // The developer pages belong to the Admin view.
      expect(find.byKey(const Key('nav-/status')), findsNothing);
    },
  );

  test('only the composition root reaches Supabase; no client persistence', () {
    final files = Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'));
    final persistence = RegExp(
      r'''package:(shared_preferences|hive|sqflite|drift|isar|path_provider|flutter_secure_storage)/|dart:html|localStorage|sessionStorage|indexedDB''',
    );
    for (final f in files) {
      final path = f.path.replaceAll('\\', '/');
      final src = f.readAsStringSync();
      final reached = boundaryViolations(path, src);
      if (path == 'lib/main.dart') {
        expect(reached, ['package:church_client_core/composition.dart']);
      } else {
        expect(reached, isEmpty, reason: path);
      }
      expect(persistence.hasMatch(src), isFalse, reason: path);
    }
  });

  test('the app guard catches a shell that reaches the adapters', () {
    for (final src in [
      "import 'package:church_client_core/supabase_adapters.dart';",
      "import 'package:church_client_core/composition.dart';",
      "import 'package:supabase_flutter/supabase_flutter.dart';",
    ]) {
      expect(boundaryViolations('lib/app.dart', src), isNotEmpty, reason: src);
    }
  });
  testWidgets(
    'story 3.1: a member opens the Inbox and sees the server\'s item; '
    'signing out drops it',
    (tester) async {
      final h = await pumpStaff(tester);
      expect(find.byKey(const Key('nav-/inbox')), findsNothing);
      h.grants.myAccess = AccessReadOk(syntheticGrants());
      h.inbox.inbox = AccessReadOk(
        Inbox.fromJson({
          'items': [inboxItemData()],
        }),
      );
      await tapKey(tester, 'nav-/account');
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));
      await tapKey(tester, 'nav-/inbox');
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('SYNTHETIC test reminder'), findsOneWidget);
      expect(h.inbox.calls, greaterThanOrEqualTo(1));

      h.session.switchTo(null);
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('SYNTHETIC test reminder'), findsNothing);
    },
  );

  testWidgets(
    'story 3.7: staff web shows markers, snooze and the same settings; a '
    'signal re-reads the inbox',
    (tester) async {
      const item = '31313131-3131-4131-8131-313131313131';
      final h = await pumpStaff(tester);
      h.grants.myAccess = AccessReadOk(syntheticGrants());
      h.inbox.inbox = AccessReadOk(
        Inbox.fromJson({
          'items': [inboxItemData(id: item, opened: true)],
        }),
      );
      h.inbox.opened[item] = AccessReadOk(
        OpenedInboxItem.fromJson(
          openedItemData(
            id: item,
            snoozeChoices: const ['1 hour', '24 hours', '2 days'],
          ),
        ),
      );
      h.notificationSettings.settings = AccessReadOk(
        NotificationSettings.fromJson({
          'categories': [pushCategoryData()],
        }),
      );
      Future<void> settle() async {
        for (var i = 0; i < 4; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
      }

      await tapKey(tester, 'nav-/account');
      await settle();
      await tapKey(tester, 'nav-/inbox');
      await settle();
      expect(find.byKey(const Key('inbox-item-opened-$item')), findsOneWidget);
      final reads = h.inbox.calls;
      h.signals.signal();
      await settle();
      expect(h.inbox.calls, reads + 1);

      await tapKey(tester, 'open-inbox-item-$item');
      await settle();
      expect(find.byKey(const Key('snooze-1-hour')), findsOneWidget);
      await tapKey(tester, 'back-to-inbox');
      await settle();
      await tapKey(tester, 'open-notification-settings');
      await settle();
      expect(
        find.byKey(const Key('push-category-fixture_reminder-fixture_due')),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'story 3.7: a signed-out link to an item returns to it after sign-in',
    (tester) async {
      const item = '31313131-3131-4131-8131-313131313131';
      final h = await pumpStaff(tester);
      h.session.switchTo(null);
      await tester.pump(const Duration(milliseconds: 100));
      h.inbox.opened[item] = AccessReadOk(
        OpenedInboxItem.fromJson(openedItemData(id: item)),
      );
      final router = GoRouter.of(tester.element(find.byType(Scaffold).first));
      router.go(ClientPaths.inboxItem(item));
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(
        find.byKey(const Key('inbox-item-denied-signedOut')),
        findsOneWidget,
      );
      await tapKey(tester, 'inbox-item-sign-in');
      await tester.pump(const Duration(milliseconds: 100));
      await tester.enterText(
        find.byKey(const Key('phone-field')),
        '+12025550101',
      );
      await tester.enterText(
        find.byKey(const Key('password-field')),
        'Synthetic-pw-1',
      );
      await tapKey(tester, 'submit-button');
      h.auth.succeed('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa');
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.byKey(const Key('inbox-item-title')), findsOneWidget);
      expect(h.inbox.openedIds, [item]);
    },
  );
}

class _HealthRepository implements NotificationHealthRepository {
  _HealthRepository([this.answer]);

  /// A refusal or failure to answer with; null answers the sample health.
  final AccessRead<ReminderHealth>? answer;

  @override
  Future<AccessRead<ReminderHealth>> fetchHealth() async =>
      answer ??
      AccessReadOk(
        ReminderHealth.fromJson({
          'captured_at': '2026-10-13T12:00:00Z',
          'scheduler': {
            'jobs': 1,
            'cron_runs_24h': <String, int>{},
            'stale': false,
            'last_tick_at': '2026-10-13T11:59:00Z',
            'last_tick_outcome': 'sent',
            'last_success_at': '2026-10-13T11:59:00Z',
          },
          'jobs': {
            'due_pending': 2,
            'oldest_due_at': '2026-10-13T11:30:00Z',
            'leased': 1,
            'failed_attempts_24h': 0,
            'lapsed_leases_24h': 0,
          },
          'push': {
            'enabled': true,
            'outbound_open': true,
            'pending': 0,
            'leased': 0,
            'failed_attempts_24h': 0,
          },
          'tokens': {'retired': 0, 'retired_24h': 0, 'last_retired_at': null},
          'direct_contact': {
            'backlog': 0,
            'oldest_due_at': null,
            'routed_24h': 0,
            'total_unrouted': 0,
            'total': 0,
          },
        }),
      );
}

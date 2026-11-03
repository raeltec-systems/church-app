import 'dart:async';

import 'package:church_client_core/church_client_core.dart';
import 'package:church_client_core/testing.dart';
import 'package:church_contracts/church_contracts.dart';
import 'package:church_design_system/church_design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

const id = '66666666-6666-4666-8666-666666666666';
const secondId = '77777777-7777-4777-8777-777777777777';
ManagedMember person({
  String memberId = id,
  int revision = 1,
  int grants = 1,
  String membership = 'approved',
  String account = 'no_login',
  List<String> roles = const [],
  bool deleting = false,
}) => ManagedMember.fromJson(
  managedMemberData(
    id: memberId,
    revision: revision,
    grantRevision: grants,
    membership: membership,
    account: account,
    roles: roles,
    deleting: deleting,
  ),
);
const catalogue = [
  RoleOption('admin', available: true),
  RoleOption('media', available: true),
  RoleOption('lead_pastor', available: false),
];
void seed(ClientTestHarness h, [ManagedMember? value]) {
  final m = value ?? person();
  h.grants.myAccess = AccessReadOk(syntheticGrants(roles: ['admin']));
  h.users.page = AccessReadOk(
    UserDirectoryPage(members: [m], roles: catalogue),
  );
  h.users.details[m.id] = AccessReadOk(UserDetail(m, ownRecord: false));
}

Future<void> tick() async {
  for (var i = 0; i < 8; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

Future<(ClientTestHarness, ProviderContainer)> setup() async {
  final h = ClientTestHarness();
  seed(h);
  final c = ProviderContainer(overrides: h.overrides());
  addTearDown(c.dispose);
  c.listen(userManagementProvider, (_, _) {});
  await tick();
  return (h, c);
}

Future<void> pump(
  WidgetTester tester,
  ClientTestHarness h, {
  String? memberId,
  double width = 1280,
  double scale = 1,
  String area = 'members',
}) async {
  tester.view.physicalSize = Size(width, 1800);
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = scale;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  final router = buildClientRouter(
    initialLocation: Uri(
      path: '/admin/users',
      queryParameters: {'view': area, 'member': ?memberId},
    ).toString(),
    shell: (_, _, child) => AccessRefresher(child: child),
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: h.overrides(),
      child: MaterialApp.router(
        theme: churchStaffTheme(),
        routerConfig: router,
      ),
    ),
  );
  await settle(tester);
}

Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 40));
  }
}

Future<void> tap(WidgetTester tester, String key) async {
  final f = find.byKey(Key(key));
  await tester.ensureVisible(f);
  await tester.tap(f);
  await settle(tester);
}

void main() {
  test('management keeps membership, account and grants distinct', () {
    final m = person(membership: 'deactivated', account: 'access_review');
    expect(m.membershipLabel, 'Deactivated');
    expect(m.accountLabel, 'Access review');
    expect(m.editable, isTrue);
    expect(person(deleting: true).editable, isFalse);
    expect(
      () => ManagedMember.fromJson({
        ...managedMemberData(),
        'grants': grantsData(memberId: secondId),
      }),
      throwsFormatException,
    );
    expect(
      () => ManagedMember.fromJson({
        ...managedMemberData(),
        'membership_state': 'invented',
      }),
      throwsFormatException,
    );
    expect(
      () => UserDirectoryPage.fromJson({
        'members': List.filled(26, managedMemberData()),
        'roles': [],
      }),
      throwsFormatException,
    );
  });
  test('activity preserves microsecond cursor and string ids', () {
    final page = UserActivityPage.fromJson({
      'events': [
        {
          'source': 'profile',
          'event_id': '9007199254740993',
          'at': '2026-10-31T14:00:00.123456Z',
          'action': 'profile_corrected',
          'actor_label': 'Church office',
          'role': null,
          'changed_fields': ['full_name'],
        },
      ],
      'next': {
        'after_at': '2026-10-31T14:00:00.123456Z',
        'after_source': 'profile',
        'after_event_id': '9007199254740993',
      },
    });
    expect(page.next!.at, '2026-10-31T14:00:00.123456Z');
    expect(page.next!.eventId, '9007199254740993');
  });
  test('filters are passed together to the bounded repository', () async {
    final (h, c) = await setup();
    await c
        .read(userManagementProvider.notifier)
        .search(
          const UserFilter(
            query: 'Ruth',
            membership: 'deactivated',
            account: 'no_login',
            role: 'media',
          ),
        );
    final f = h.users.directoryCalls.last.$1;
    expect(
      [f.query, f.membership, f.account, f.role],
      ['Ruth', 'deactivated', 'no_login', 'media'],
    );
  });
  test('late search cannot replace the newest filters', () async {
    final (h, c) = await setup();
    final old = Completer<AccessRead<UserDirectoryPage>>();
    h.users.onDirectory = (f, _) => f.query == 'old'
        ? old.future
        : Future.value(
            const AccessReadOk(UserDirectoryPage(members: [], roles: [])),
          );
    final pending = c
        .read(userManagementProvider.notifier)
        .search(const UserFilter(query: 'old'));
    await c
        .read(userManagementProvider.notifier)
        .search(const UserFilter(query: 'new'));
    old.complete(
      AccessReadOk(UserDirectoryPage(members: [person()], roles: catalogue)),
    );
    await pending;
    expect(c.read(userManagementProvider).members, isEmpty);
    expect(c.read(userManagementProvider).filter.query, 'new');
  });
  test('switching person discards late detail and activity', () async {
    final (h, c) = await setup();
    final delayed = Completer<AccessRead<UserDetail>>();
    h.users.onDetail = (memberId) => memberId == id
        ? delayed.future
        : Future.value(
            AccessReadOk(
              UserDetail(person(memberId: secondId), ownRecord: false),
            ),
          );
    final old = c.read(userManagementProvider.notifier).select(id);
    await c.read(userManagementProvider.notifier).select(secondId);
    delayed.complete(AccessReadOk(UserDetail(person(), ownRecord: false)));
    await old;
    expect(c.read(userManagementProvider).detail!.member.id, secondId);
  });
  test('unknown mutation is fenced and check-again sends identical immutable request', () async {
    final (h, c) = await setup();
    final ctl = c.read(userManagementProvider.notifier);
    await ctl.select(id);
    final contacts = <Map<String, Object?>>[
      {'phone': '+12025550101', 'belongs_to': 'member', 'holder_label': null},
    ];
    final send = ctl.updateProfile(
      person(),
      'SYNTHETIC Ruth Updated',
      contacts,
      ConsentBasis.inPerson,
    );
    await tick();
    contacts[0]['phone'] = '+12025550102';
    h.gateway.sent.last.unknown();
    await send;
    await ctl.select(secondId);
    await ctl.search(const UserFilter(query: 'another'));
    expect(c.read(userManagementProvider).selectedId, id);
    expect(c.read(userManagementProvider).retry, isNotNull);
    final retry = ctl.checkAgain();
    await tick();
    expect(h.gateway.sent[1].wire, h.gateway.sent[0].wire);
    expect(
      (h.gateway.sent[1].request.payload['contact_routes'] as List)
          .first['phone'],
      '+12025550101',
    );
    h.gateway.sent.last.confirm({}, 2);
    await retry;
    expect(c.read(userManagementProvider).notice, UserChangeNotice.saved);
    expect(c.read(userManagementProvider).retry, isNull);
  });
  test('role commands use grant revision, profile and lifecycle use member revision', () async {
    final (h, c) = await setup();
    final m = person(revision: 8, grants: 14);
    seed(h, m);
    final ctl = c.read(userManagementProvider.notifier);
    await ctl.select(id);
    final send = ctl.setRole(m, 'media', true);
    await tick();
    expect(h.gateway.sent.last.function, GrantCommands.function);
    expect(h.gateway.sent.last.wire['expected_revision'], 14);
    h.gateway.sent.last.refuse(ErrorCode.conflict);
    await send;
    final edit = ctl.updateProfile(
      m,
      'SYNTHETIC Ruth',
      [],
      ConsentBasis.inPerson,
    );
    await tick();
    expect(h.gateway.sent.last.function, UserManagementCommands.function);
    expect(h.gateway.sent.last.wire['expected_revision'], 8);
    h.gateway.sent.last.refuse(ErrorCode.conflict);
    await edit;
  });
  test(
    'denied detail clears previously protected directory and selection',
    () async {
      final (h, c) = await setup();
      h.users.details[id] = const AccessReadDenied(AccessDenial.notGranted);
      await c.read(userManagementProvider.notifier).select(id);
      expect(c.read(userManagementProvider).members, isEmpty);
      expect(c.read(userManagementProvider).detail, isNull);
    },
  );
  test('account change drops unresolved edits and late response', () async {
    final (h, c) = await setup();
    final ctl = c.read(userManagementProvider.notifier);
    await ctl.select(id);
    final send = ctl.updateProfile(
      person(),
      'SYNTHETIC Ruth Updated',
      [],
      ConsentBasis.inPerson,
    );
    await tick();
    h.grants.myAccess = const AccessReadDenied(AccessDenial.notGranted);
    h.session.switchTo(secondId);
    await tick();
    h.gateway.sent.last.confirm({}, 2);
    await send;
    expect(c.read(userManagementProvider).pending, isNull);
    expect(c.read(userManagementProvider).detail, isNull);
    expect(c.read(userManagementProvider).notice, isNull);
  });
  test('activity failure is distinct from empty history', () async {
    final (h, c) = await setup();
    await c.read(userManagementProvider.notifier).select(id);
    h.users.activityPages[id] = const AccessReadFailed(unreachable: true);
    await c.read(userManagementProvider.notifier).loadActivity();
    expect(
      c.read(userManagementProvider).activityResult,
      isA<AccessReadFailed<UserActivityPage>>(),
    );
  });

  testWidgets(
    'directory opens selected person and saves agreed contact fields through real command contract',
    (tester) async {
      final h = ClientTestHarness();
      seed(h);
      await pump(tester, h);
      await tap(tester, 'user-row-$id');
      expect(find.byKey(const Key('user-edit-profile')), findsOneWidget);
      await tap(tester, 'user-edit-profile');
      await tester.enterText(
        find.byKey(const Key('user-profile-name')),
        'SYNTHETIC Ruth Updated',
      );
      await tap(tester, 'user-profile-add-contact');
      await tester.enterText(
        find.byKey(const Key('user-profile-phone-0')),
        '+12025550181',
      );
      final consent = tester.widget<DropdownButtonFormField<ConsentBasis>>(
        find.byKey(const Key('user-profile-consent')),
      );
      consent.onChanged!(ConsentBasis.inPerson);
      await tester.pump();
      await tap(tester, 'user-profile-save');
      expect(h.gateway.sent.single.function, UserManagementCommands.function);
      expect(h.gateway.sent.single.request.payload['member_id'], id);
      expect(
        h.gateway.sent.single.request.payload.containsKey('password'),
        isFalse,
      );
      expect(find.text('Saved'), findsNothing);
      seed(
        h,
        ManagedMember.fromJson(
          managedMemberData(
            name: 'SYNTHETIC Ruth Updated',
            revision: 2,
            routes: [
              {
                'route_id': secondId,
                'phone': '+12025550181',
                'belongs_to': 'member',
                'holder_label': null,
              },
            ],
          ),
        ),
      );
      h.gateway.sent.single.confirm({}, 2);
      await settle(tester);
      expect(find.byKey(const Key('user-profile-name')), findsNothing);
      expect(find.text('Saved'), findsOneWidget);
      expect(find.textContaining('SYNTHETIC Ruth Updated'), findsWidgets);
    },
  );
  testWidgets(
    'self profile changes are unavailable but record remains readable',
    (tester) async {
      final h = ClientTestHarness();
      seed(h);
      h.users.details[id] = AccessReadOk(UserDetail(person(), ownRecord: true));
      await pump(tester, h, memberId: id);
      final button = tester.widget<OutlinedButton>(
        find.byKey(const Key('user-edit-profile')),
      );
      expect(button.onPressed, isNull);
    },
  );
  testWidgets('failed directory is not labelled empty', (tester) async {
    final h = ClientTestHarness();
    seed(h);
    h.users.page = const AccessReadFailed(unreachable: true);
    await pump(tester, h);
    expect(find.byKey(const Key('users-directory-failed')), findsOneWidget);
    expect(find.byKey(const Key('users-empty')), findsNothing);
  });
  testWidgets(
    'deactivated person has restore action, not active-role controls',
    (tester) async {
      final h = ClientTestHarness();
      seed(h, person(membership: 'deactivated'));
      await pump(tester, h, memberId: id);
      expect(find.byKey(const Key('user-restore')), findsOneWidget);
      expect(find.byKey(const Key('user-deactivate')), findsNothing);
      expect(find.byKey(const Key('user-role-admin')), findsNothing);
    },
  );
  testWidgets(
    'observed access revocation removes an open private profile dialog',
    (tester) async {
      final h = ClientTestHarness();
      seed(h);
      await pump(tester, h, memberId: id);
      await tap(tester, 'user-edit-profile');
      final c = ProviderScope.containerOf(
        tester.element(find.byType(UserManagementScreen)),
        listen: false,
      );
      h.grants.myAccess = const AccessReadDenied(AccessDenial.notGranted);
      await c.read(myAccessProvider.notifier).refresh();
      await settle(tester);
      expect(find.byKey(const Key('user-profile-name')), findsNothing);
      expect(find.byKey(Key('user-detail-$id')), findsNothing);
    },
  );
  testWidgets(
    'selected-person deep link keeps id while entering support and returning',
    (tester) async {
      final h = ClientTestHarness();
      seed(h);
      await pump(tester, h, memberId: id);
      await tap(tester, 'user-recovery');
      expect(find.byKey(const Key('users-selected-context')), findsOneWidget);
      final router = GoRouter.of(
        tester.element(find.byType(UserManagementScreen)),
      );
      expect(
        router.routeInformationProvider.value.uri.queryParameters['member'],
        id,
      );
      expect(find.byKey(const Key('recovery-search-field')), findsNothing);
      await tap(tester, 'users-back-to-person');
      expect(find.byKey(Key('user-detail-$id')), findsOneWidget);
    },
  );
  testWidgets(
    'narrow layout with selected person and double text scale has no overflow',
    (tester) async {
      final h = ClientTestHarness();
      seed(h);
      await pump(tester, h, memberId: id, width: 390, scale: 2);
      expect(find.byKey(Key('user-detail-$id')), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}

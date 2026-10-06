// Story 2.3: grant reads, the caller's access controller, and the Admin grant
// screen with honest command states. Fakes only; the real adapter is covered
// by identity_adapters_test-style mapping tests below and by
// tools/identity-e2e/grants.mjs against the local stack.
import 'dart:async';

import 'package:church_client_core/church_client_core.dart';
import 'package:church_client_core/supabase_adapters.dart' show accessDenialFor;
import 'package:church_client_core/testing.dart';
import 'package:church_contracts/church_contracts.dart';
import 'package:church_design_system/church_design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

const _member = '33333333-3333-4333-8333-333333333333';

Future<ClientTestHarness> pumpAt(
  WidgetTester tester,
  String location, {
  void Function(ClientTestHarness h)? setUp,
}) async {
  final h = ClientTestHarness();
  setUp?.call(h);
  final router = buildClientRouter(
    initialLocation: location,
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
  return h;
}

Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Finder byKey(String k) => find.byKey(Key(k));

Future<void> tapKey(WidgetTester tester, String key) async {
  await tester.ensureVisible(byKey(key));
  await tester.tap(byKey(key));
  await tester.pump();
}

void main() {
  group('wire mapping', () {
    test('grants and roster parse strictly', () {
      final g = MemberGrants.fromJson({
        'member_id': _member,
        'revision': 3,
        'roles': ['admin', 'pastor'],
        'scopes': [
          {'scope_kind': 'fixture_care', 'scope_id': _member},
        ],
      });
      expect(g.isAdmin, isTrue);
      expect(g.scopes.single.scopeKind, 'fixture_care');
      for (final bad in [
        {'member_id': _member, 'revision': 0, 'roles': [], 'scopes': []},
        {
          'member_id': _member,
          'revision': 1,
          'roles': [1],
          'scopes': [],
        },
        {
          'member_id': _member,
          'revision': 1,
          'roles': [],
          'scopes': [{}],
        },
        'x',
      ]) {
        expect(() => MemberGrants.fromJson(bad), throwsFormatException);
      }
      final roster = GrantRoster.fromJson({
        'members': [
          {
            'member_id': _member,
            'display_name': 'SYNTHETIC Two',
            'is_synthetic': true,
            'account': 'no_login',
            'grants': {
              'member_id': _member,
              'revision': 1,
              'roles': [],
              'scopes': [],
            },
          },
        ],
        'next': null,
        'roles': [
          {'role': 'lead_pastor', 'available': false},
        ],
        'scope_kinds': ['fixture_care'],
      });
      expect(roster.members.single.account, AccountStanding.noLogin);
      expect(roster.roles.single.available, isFalse);
      expect(
        () => GrantRoster.fromJson({
          'members': [
            {
              'member_id': _member,
              'display_name': 'x',
              'is_synthetic': true,
              'account': 'admin_view',
              'grants': {},
            },
          ],
          'roles': [],
        }),
        throwsFormatException,
      );
    });

    test('server denials map to the caller\'s own reason', () {
      expect(
        accessDenialFor('PT403', 'forbidden', 'not_granted'),
        AccessDenial.notGranted,
      );
      expect(
        accessDenialFor('PT403', 'forbidden', 'not_linked'),
        AccessDenial.notLinked,
      );
      expect(
        accessDenialFor('PT403', 'forbidden', 'review_required'),
        AccessDenial.reviewRequired,
      );
      expect(
        accessDenialFor('PT401', 'unauthenticated', 'untrusted_session'),
        AccessDenial.untrustedSession,
      );
      expect(
        accessDenialFor('PT401', 'unauthenticated', 'unauthenticated'),
        AccessDenial.signedOut,
      );
      expect(
        accessDenialFor('42501', 'permission denied', null),
        AccessDenial.signedOut,
      );
      expect(
        accessDenialFor('PT403', 'unavailable', 'unavailable'),
        AccessDenial.unavailable,
      );
      expect(accessDenialFor('PGRST301', 'JWT expired', null), isNull);
    });
  });

  group('my access', () {
    test('an untrusted session is ended; a new account starts fresh', () async {
      final h = ClientTestHarness();
      final c = ProviderContainer(overrides: h.overrides());
      addTearDown(c.dispose);
      h.grants.myAccess = AccessReadOk(syntheticGrants(roles: ['pastor']));
      c.read(myAccessProvider);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(c.read(myAccessProvider).grants?.roles, ['pastor']);

      // Revoked elsewhere: the next read says so.
      h.grants.myAccess = AccessReadOk(syntheticGrants(revision: 2));
      await c.read(myAccessProvider.notifier).refresh();
      expect(c.read(myAccessProvider).grants?.roles, isEmpty);

      h.grants.myAccess = const AccessReadDenied(AccessDenial.untrustedSession);
      await c.read(myAccessProvider.notifier).refresh();
      await Future<void>.delayed(Duration.zero);
      expect(h.auth.signOuts, 1);
      expect(c.read(accountProvider).lastChange, AccountChange.sessionEnded);
      expect(c.read(myAccessProvider).grants, isNull);
    });

    testWidgets('My access lists the server\'s current roles', (tester) async {
      await pumpAt(
        tester,
        ClientPaths.access,
        setUp: (h) => h.grants.myAccess = AccessReadOk(
          syntheticGrants(roles: ['admin', 'media']),
        ),
      );
      expect(byKey('my-role-admin'), findsOneWidget);
      expect(find.text('Media'), findsOneWidget);
      expect(byKey('no-scopes'), findsOneWidget);
    });

    testWidgets('each navigation asks the server again', (tester) async {
      final h = await pumpAt(tester, ClientPaths.access);
      final before = h.grants.myAccessCalls;
      h.grants.myAccess = AccessReadOk(syntheticGrants(roles: ['pastor']));
      final ctx = tester.element(find.byType(MyAccessScreen));
      GoRouterHelper(ctx).go(ClientPaths.account);
      await settle(tester);
      GoRouterHelper(tester.element(find.byType(AccountScreen)))
          .go(ClientPaths.access);
      await settle(tester);
      expect(h.grants.myAccessCalls, greaterThan(before));
      expect(byKey('my-role-pastor'), findsOneWidget);
    });
  });

  group('protected denials and coalescing', () {
    Future<void> flush() async {
      for (var i = 0; i < 5; i++) {
        await Future<void>.delayed(Duration.zero);
      }
    }

    test(
      'a refresh during an in-flight read is followed by another read',
      () async {
        final h = ClientTestHarness();
        final c = ProviderContainer(overrides: h.overrides());
        addTearDown(c.dispose);
        final gate = Completer<void>();
        h.grants.myAccessGate = gate;
        c.read(myAccessProvider);
        await flush();
        expect(h.grants.myAccessCalls, 1);
        // A navigation while the first read is still in flight.
        await c.read(myAccessProvider.notifier).refresh();
        expect(h.grants.myAccessCalls, 1);
        h.grants.myAccessGate = null;
        h.grants.myAccess = AccessReadOk(syntheticGrants(roles: ['media']));
        gate.complete();
        await flush();
        expect(h.grants.myAccessCalls, 2);
        expect(c.read(myAccessProvider).grants?.roles, ['media']);
      },
    );

    test('an untrusted answer drops a pending re-read', () async {
      final h = ClientTestHarness();
      final c = ProviderContainer(overrides: h.overrides());
      addTearDown(c.dispose);
      final gate = Completer<void>();
      h.grants.myAccessGate = gate;
      h.grants.myAccess = const AccessReadDenied(AccessDenial.untrustedSession);
      c.read(myAccessProvider);
      await flush();
      await c.read(myAccessProvider.notifier).refresh();
      gate.complete();
      await flush();
      expect(h.auth.signOuts, 1);
      expect(h.grants.myAccessCalls, 1);
      // Signed in again: one fresh read, no leftover re-read.
      h.grants.myAccessGate = null;
      h.grants.myAccess = AccessReadOk(syntheticGrants());
      h.session.switchTo('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb');
      await flush();
      c.read(myAccessProvider);
      await flush();
      expect(h.grants.myAccessCalls, 2);
    });

    test(
      'a forbidden fixture command re-reads access (one denial hook)',
      () async {
        final h = ClientTestHarness();
        final c = ProviderContainer(overrides: h.overrides());
        addTearDown(c.dispose);
        c.read(myAccessProvider);
        await flush();
        final before = h.grants.myAccessCalls;
        final sent = c
            .read(fixtureCounterControllerProvider.notifier)
            .create('synthetic-k');
        await flush();
        h.gateway.sent.single.refuse(ErrorCode.forbidden);
        await sent;
        await flush();
        expect(h.grants.myAccessCalls, before + 1);
      },
    );

    test('a denied member summary re-reads access (one denial hook)', () async {
      final h = ClientTestHarness();
      final c = ProviderContainer(overrides: h.overrides());
      addTearDown(c.dispose);
      c.read(myAccessProvider);
      await flush();
      final before = h.grants.myAccessCalls;
      c.read(memberSummaryControllerProvider);
      await flush();
      h.memberAccess.answer(
        const MemberAccessDenied(MemberAccessDenial.reviewRequired),
      );
      await flush();
      expect(h.grants.myAccessCalls, before + 1);
    });
  });

  group('Admin grant screen', () {
    Future<ClientTestHarness> openRoster(
      WidgetTester tester, {
      List<String> roles = const [],
      bool leadPastorAvailable = true,
    }) async {
      final h = await pumpAt(
        tester,
        ClientPaths.adminGrants,
        setUp: (h) =>
            h.grants.myAccess = AccessReadOk(syntheticGrants(roles: ['admin'])),
      );
      h.grants.answerRoster(
        AccessReadOk(
          syntheticRoster(
            roles: roles,
            leadPastorAvailable: leadPastorAvailable,
          ),
        ),
      );
      await settle(tester);
      return h;
    }

    testWidgets('grant sends the 1.4 envelope; confirmation updates the row', (
      tester,
    ) async {
      final h = await openRoster(tester, leadPastorAvailable: false);
      expect(find.text('SYNTHETIC Member Two'), findsOneWidget);
      expect(find.text('App account'), findsOneWidget);
      // A role whose church setting is unset cannot be granted here.
      expect(
        tester
            .widget<OutlinedButton>(byKey('role-$_member-lead_pastor'))
            .onPressed,
        isNull,
      );
      await tapKey(tester, 'role-$_member-pastor');
      final sent = h.gateway.sent.single;
      expect(sent.function, 'identity_grant_command');
      expect(sent.wire, {
        'version': 1,
        'command': 'identity.grant_role',
        'request_id': '00000000-0000-4000-8000-000000000001',
        'expected_revision': 1,
        'payload': {'member_id': _member, 'role': 'pastor'},
      });
      expect(byKey('grant-pending'), findsOneWidget);
      sent.confirm(grantsData(roles: ['pastor']), 2);
      await settle(tester);
      expect(byKey('grant-notice-granted'), findsOneWidget);
      expect(find.text('Pastor · Remove'), findsOneWidget);
    });

    testWidgets('a stale revision reloads the roster', (tester) async {
      final h = await openRoster(tester);
      await tapKey(tester, 'role-$_member-media');
      h.gateway.sent.single.refuse(
        ErrorCode.conflict,
        currentRevision: const Optional.of(3),
      );
      await settle(tester);
      expect(byKey('grant-notice-changedElsewhere'), findsOneWidget);
      expect(h.grants.rosterCalls.length, 2);
      h.grants.answerRoster(
        AccessReadOk(syntheticRoster(revision: 3, roles: ['media'])),
      );
      await settle(tester);
      expect(find.text('Media · Remove'), findsOneWidget);
      // The next action uses the reloaded revision.
      await tapKey(tester, 'role-$_member-media');
      expect(h.gateway.sent.last.wire['expected_revision'], 3);
    });

    testWidgets('the last Admin refusal is explained and changes nothing', (
      tester,
    ) async {
      final h = await openRoster(tester, roles: ['admin']);
      await tapKey(tester, 'role-$_member-admin');
      expect(h.gateway.sent.single.wire['command'], 'identity.revoke_role');
      h.gateway.sent.single.refuse(
        ErrorCode.forbidden,
        fieldErrors: {'role': 'unsupported'},
      );
      await settle(tester);
      expect(byKey('grant-notice-lastAdmin'), findsOneWidget);
      expect(find.text('Admin · Remove'), findsOneWidget);
    });

    testWidgets('a removed Admin\'s stale tab: refused, navigation refreshed', (
      tester,
    ) async {
      final h = await openRoster(tester);
      final calls = h.grants.myAccessCalls;
      await tapKey(tester, 'role-$_member-media');
      h.grants.myAccess = AccessReadOk(syntheticGrants());
      h.gateway.sent.single.refuse(ErrorCode.forbidden);
      await settle(tester);
      expect(byKey('grant-notice-noLongerAdmin'), findsOneWidget);
      h.grants.answerRoster(const AccessReadDenied(AccessDenial.notGranted));
      await settle(tester);
      expect(byKey('access-denied-notGranted'), findsOneWidget);
      expect(find.text('SYNTHETIC Member Two'), findsNothing);
      expect(h.grants.myAccessCalls, greaterThan(calls));
    });

    testWidgets('an unknown outcome is checked again with the same request', (
      tester,
    ) async {
      final h = await openRoster(tester);
      await tapKey(tester, 'role-$_member-pastor');
      final first = h.gateway.sent.single;
      first.unknown();
      await settle(tester);
      expect(byKey('grant-notice-unconfirmed'), findsOneWidget);
      await tapKey(tester, 'grant-check-again');
      expect(h.gateway.sent.length, 2);
      expect(h.gateway.sent.last.wire, first.wire);
    });

    testWidgets('a failed reload drops the roster and its buttons', (
      tester,
    ) async {
      final h = await openRoster(tester);
      expect(find.text('SYNTHETIC Member Two'), findsOneWidget);
      await tapKey(tester, 'roster-reload');
      h.grants.answerRoster(const AccessReadFailed(unreachable: true));
      await settle(tester);
      expect(byKey('access-failed'), findsOneWidget);
      expect(find.text('SYNTHETIC Member Two'), findsNothing);
      expect(byKey('role-$_member-pastor'), findsNothing);
    });

    testWidgets('an Admin cannot grant to itself (separation of duty)', (
      tester,
    ) async {
      final h = await pumpAt(
        tester,
        ClientPaths.adminGrants,
        setUp: (h) => h.grants.myAccess = AccessReadOk(
          syntheticGrants(memberId: _member, roles: ['admin']),
        ),
      );
      h.grants.answerRoster(AccessReadOk(syntheticRoster(roles: ['admin'])));
      await settle(tester);
      expect(
        tester.widget<OutlinedButton>(byKey('role-$_member-pastor')).onPressed,
        isNull,
      );
      // Removing its own role is still allowed (the server keeps one Admin).
      expect(
        tester.widget<FilledButton>(byKey('role-$_member-admin')).onPressed,
        isNotNull,
      );
    });

    testWidgets('a self-grant refusal is explained without a reload', (
      tester,
    ) async {
      final h = await openRoster(tester);
      await tapKey(tester, 'role-$_member-pastor');
      h.gateway.sent.single.refuse(
        ErrorCode.forbidden,
        fieldErrors: {'member_id': 'unsupported'},
      );
      await settle(tester);
      expect(byKey('grant-notice-selfGrant'), findsOneWidget);
      expect(h.grants.rosterCalls.length, 1);
    });

    testWidgets('a non-Admin sees the server\'s denial, not members', (
      tester,
    ) async {
      final h = await pumpAt(tester, ClientPaths.adminGrants);
      h.grants.answerRoster(const AccessReadDenied(AccessDenial.notGranted));
      await settle(tester);
      expect(byKey('access-denied-notGranted'), findsOneWidget);
    });
  });
}

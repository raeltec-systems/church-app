// Story 2.10: the Admin lifecycle screen on staff web (login hold, church
// deactivation, reviewed restoration, pending handovers) and the member's
// "membership not active" state on the account page (both clients). Fakes
// only; the server behaviour is covered by
// supabase/tests/membership_lifecycle_test.sql and
// tools/identity-e2e/lifecycle.mjs.
import 'package:church_client_core/church_client_core.dart';
import 'package:church_client_core/testing.dart';
import 'package:church_contracts/church_contracts.dart';
import 'package:church_design_system/church_design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _member = '66666666-6666-4666-8666-666666666666';
const _deactivated = '81818181-8181-4181-8181-818181818181';
const _hold = '82828282-8282-4282-8282-828282828282';
const _handover = '84848484-8484-4484-8484-848484848484';

Future<ClientTestHarness> pumpAt(
  WidgetTester tester,
  String location, {
  void Function(ClientTestHarness h)? setUp,
}) async {
  tester.view.physicalSize = const Size(1200, 5000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final h = ClientTestHarness();
  setUp?.call(h);
  final router = buildClientRouter(
    initialLocation: location,
    membershipRequests: true,
    shell: (_, _, child) => AccessRefresher(child: child),
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: h.overrides(),
      child: MaterialApp.router(
        theme: churchMobileTheme(Brightness.light),
        routerConfig: router,
      ),
    ),
  );
  await settle(tester);
  return h;
}

Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Finder byKey(String k) => find.byKey(Key(k));

Future<void> tapKey(WidgetTester tester, String key) async {
  await tester.ensureVisible(byKey(key));
  await tester.tap(byKey(key));
  await tester.pump();
}

bool enabled(WidgetTester tester, String key) {
  final w = tester.widget(byKey(key));
  return switch (w) {
    ButtonStyleButton() => w.onPressed != null,
    _ => throw StateError('not a button: $key'),
  };
}

AccessRead<MembershipLifecycleOverview> overviewWith({
  List<Map<String, Object?>> deactivated = const [],
  List<Map<String, Object?>> loginHolds = const [],
  List<Map<String, Object?>> handovers = const [],
}) => AccessReadOk(
  MembershipLifecycleOverview.fromJson(
    membershipLifecycleData(
      deactivated: deactivated,
      loginHolds: loginHolds,
      handovers: handovers,
    ),
  ),
);

void searchFinds(ClientTestHarness h, {int revision = 7}) {
  h.review.search = AccessReadOk(
    MemberSearchPage.fromJson({
      'members': [memberRecordData(revision: revision, account: 'app_account')],
      'next': null,
    }),
  );
}

Future<void> search(WidgetTester tester) async {
  await tester.enterText(byKey('lifecycle-search-field'), 'Ruth');
  await tapKey(tester, 'lifecycle-search');
  await settle(tester);
}

void main() {
  group('Admin membership lifecycle (staff web)', () {
    testWidgets('a non-Admin sees the server denial only', (tester) async {
      final h = await pumpAt(tester, ClientPaths.adminMembershipLifecycle);
      expect(byKey('lifecycle-denied-notGranted'), findsOneWidget);
      expect(byKey('lifecycle-search-field'), findsNothing);
      expect(h.lifecycle.overviewCalls, 1);
    });

    testWidgets('lists deactivated members, login holds and handovers', (
      tester,
    ) async {
      await pumpAt(
        tester,
        ClientPaths.adminMembershipLifecycle,
        setUp: (h) => h.lifecycle.overview = overviewWith(
          deactivated: [deactivatedMemberData()],
          loginHolds: [loginHoldData()],
          handovers: [handoverData()],
        ),
      );
      expect(byKey('lifecycle-deactivated-$_deactivated'), findsOneWidget);
      expect(find.text('Reason: The member asked to leave'), findsOneWidget);
      expect(find.text('1 handover(s) still pending'), findsOneWidget);
      expect(byKey('lifecycle-login-hold-$_hold'), findsOneWidget);
      expect(byKey('lifecycle-handover-$_handover'), findsOneWidget);
      expect(find.text('fixture door duty (owner: fixture)'), findsOneWidget);
    });

    testWidgets('an empty overview says so', (tester) async {
      await pumpAt(
        tester,
        ClientPaths.adminMembershipLifecycle,
        setUp: (h) => h.lifecycle.overview = overviewWith(),
      );
      expect(byKey('lifecycle-no-deactivated'), findsOneWidget);
      expect(byKey('lifecycle-no-login-holds'), findsOneWidget);
      expect(byKey('lifecycle-no-handovers'), findsOneWidget);
    });

    testWidgets('a login hold is placed on a searched member', (tester) async {
      final h = await pumpAt(
        tester,
        ClientPaths.adminMembershipLifecycle,
        setUp: (h) {
          h.lifecycle.overview = overviewWith();
          searchFinds(h);
        },
      );
      await search(tester);
      expect(h.review.searchCalls, ['Ruth']);
      await tapKey(tester, 'lifecycle-hold-login-$_member');
      final sent = h.gateway.sent.single;
      expect(sent.function, 'identity_credential_command');
      expect(sent.wire['command'], 'identity.place_hold');
      expect(sent.wire['expected_revision'], 7);
      expect(sent.wire['payload'], {
        'member_id': _member,
        'reason_code': 'login_disabled',
      });
      sent.confirm({'member_id': _member}, 8);
      await settle(tester);
      expect(byKey('lifecycle-notice-loginHeld'), findsOneWidget);
      // The found member's revision changed: search again before acting.
      expect(byKey('lifecycle-target-$_member'), findsNothing);
      expect(h.lifecycle.overviewCalls, 2);
    });

    testWidgets('deactivation needs a reason and is sent once', (tester) async {
      final h = await pumpAt(
        tester,
        ClientPaths.adminMembershipLifecycle,
        setUp: (h) {
          h.lifecycle.overview = overviewWith();
          searchFinds(h);
        },
      );
      await search(tester);
      expect(enabled(tester, 'lifecycle-deactivate-$_member'), isFalse);
      await tapKey(tester, 'lifecycle-$_member-reason-moved_away');
      await tapKey(tester, 'lifecycle-deactivate-$_member');
      final sent = h.gateway.sent.single;
      expect(sent.function, 'identity_lifecycle_command');
      expect(sent.wire['command'], 'identity.deactivate_membership');
      expect(sent.wire['expected_revision'], 7);
      expect(sent.wire['payload'], {
        'member_id': _member,
        'reason_code': 'moved_away',
      });
      // While it is in flight nothing else can be sent.
      expect(enabled(tester, 'lifecycle-deactivate-$_member'), isFalse);
      sent.confirm({
        'member_id': _member,
        'membership_state': 'deactivated',
      }, 8);
      await settle(tester);
      expect(byKey('lifecycle-notice-deactivated'), findsOneWidget);
    });

    testWidgets('the last Admin and the last responsible person are refused '
        'with their own notices', (tester) async {
      final h = await pumpAt(
        tester,
        ClientPaths.adminMembershipLifecycle,
        setUp: (h) {
          h.lifecycle.overview = overviewWith();
          searchFinds(h);
        },
      );
      await search(tester);
      await tapKey(tester, 'lifecycle-$_member-reason-church_decision');
      await tapKey(tester, 'lifecycle-deactivate-$_member');
      h.gateway.sent.last.refuse(
        ErrorCode.forbidden,
        fieldErrors: const {'member_id': 'last_admin'},
      );
      await settle(tester);
      expect(byKey('lifecycle-notice-lastAdmin'), findsOneWidget);
      await tapKey(tester, 'lifecycle-deactivate-$_member');
      h.gateway.sent.last.refuse(
        ErrorCode.conflict,
        fieldErrors: const {'member_id': 'handover_required'},
      );
      await settle(tester);
      expect(byKey('lifecycle-notice-handoverRequired'), findsOneWidget);
    });

    testWidgets('an unknown outcome is checked again with the same request', (
      tester,
    ) async {
      final h = await pumpAt(
        tester,
        ClientPaths.adminMembershipLifecycle,
        setUp: (h) {
          h.lifecycle.overview = overviewWith();
          searchFinds(h);
        },
      );
      await search(tester);
      await tapKey(tester, 'lifecycle-$_member-reason-moved_away');
      await tapKey(tester, 'lifecycle-deactivate-$_member');
      h.gateway.sent.single.unknown();
      await settle(tester);
      expect(byKey('lifecycle-notice-unconfirmed'), findsOneWidget);
      await tapKey(tester, 'lifecycle-check-again');
      expect(h.gateway.sent, hasLength(2));
      expect(
        h.gateway.sent.last.request.requestId,
        h.gateway.sent.first.request.requestId,
      );
      expect(h.gateway.sent.last.function, 'identity_lifecycle_command');
    });

    testWidgets('a restoration needs an identity check', (tester) async {
      final h = await pumpAt(
        tester,
        ClientPaths.adminMembershipLifecycle,
        setUp: (h) => h.lifecycle.overview = overviewWith(
          deactivated: [deactivatedMemberData()],
        ),
      );
      expect(enabled(tester, 'lifecycle-restore-$_deactivated'), isFalse);
      await tapKey(tester, 'lifecycle-restore-$_deactivated-check-in_person');
      await tapKey(tester, 'lifecycle-restore-$_deactivated');
      final sent = h.gateway.sent.single;
      expect(sent.wire['command'], 'identity.restore_membership');
      expect(sent.wire['expected_revision'], 4);
      expect(sent.wire['payload'], {
        'member_id': _deactivated,
        'identity_check': 'in_person',
      });
      sent.confirm({'member_id': _deactivated}, 5);
      await settle(tester);
      expect(byKey('lifecycle-notice-restored'), findsOneWidget);
    });

    testWidgets('the Admin\'s own record is for another Admin', (tester) async {
      await pumpAt(
        tester,
        ClientPaths.adminMembershipLifecycle,
        setUp: (h) => h.lifecycle.overview = overviewWith(
          deactivated: [deactivatedMemberData(ownMember: true)],
          loginHolds: [loginHoldData(ownMember: true)],
        ),
      );
      await tapKey(tester, 'lifecycle-restore-$_deactivated-check-in_person');
      expect(enabled(tester, 'lifecycle-restore-$_deactivated'), isFalse);
      await tapKey(tester, 'lifecycle-release-$_hold-check-in_person');
      expect(enabled(tester, 'lifecycle-release-$_hold'), isFalse);
    });

    testWidgets('a login hold is released after an identity check', (
      tester,
    ) async {
      final h = await pumpAt(
        tester,
        ClientPaths.adminMembershipLifecycle,
        setUp: (h) =>
            h.lifecycle.overview = overviewWith(loginHolds: [loginHoldData()]),
      );
      expect(enabled(tester, 'lifecycle-release-$_hold'), isFalse);
      await tapKey(
        tester,
        'lifecycle-release-$_hold-check-established_relationship',
      );
      await tapKey(tester, 'lifecycle-release-$_hold');
      final sent = h.gateway.sent.single;
      expect(sent.function, 'identity_credential_command');
      expect(sent.wire['command'], 'identity.release_hold');
      expect(sent.wire['expected_revision'], 3);
      expect(sent.wire['payload'], {
        'member_id': '83838383-8383-4383-8383-838383838383',
        'hold_id': _hold,
        'identity_check': 'established_relationship',
      });
      sent.confirm({'member_id': '83838383-8383-4383-8383-838383838383'}, 4);
      await settle(tester);
      expect(byKey('lifecycle-notice-holdReleased'), findsOneWidget);
    });

    testWidgets('a login hold shows as such in Access reviews', (tester) async {
      await pumpAt(
        tester,
        ClientPaths.adminCredentialReviews,
        setUp: (h) => h.credentials.queue = AccessReadOk(
          CredentialQueue.fromJson(
            credentialQueueData(
              holds: [
                {...holdItemData(), 'hold_kind': 'login', 'reason_code': null},
              ],
            ),
          ),
        ),
      );
      expect(find.textContaining('Disable login for now'), findsOneWidget);
    });
  });

  group('the member\'s own membership status (both clients)', () {
    testWidgets('a deactivated membership is shown as not active, without '
        'a membership request link', (tester) async {
      final h = await pumpAt(
        tester,
        ClientPaths.account,
        setUp: (h) {
          h.memberAccess.next = const MemberAccessDenied(
            MemberAccessDenial.notLinked,
          );
          h.lifecycle.status = const AccessReadOk(
            MyMembershipStatus(
              deactivated: true,
              churchContact: 'SYNTHETIC church office',
            ),
          );
        },
      );
      expect(byKey('membership-deactivated'), findsOneWidget);
      expect(
        find.textContaining(
          'Please contact the church: SYNTHETIC church office',
        ),
        findsOneWidget,
      );
      expect(byKey('go-membership-request'), findsNothing);
      expect(byKey('denied-notLinked'), findsNothing);
      expect(h.lifecycle.statusCalls, greaterThanOrEqualTo(1));
    });

    testWidgets('an account not linked yet keeps the request link', (
      tester,
    ) async {
      await pumpAt(
        tester,
        ClientPaths.account,
        setUp: (h) => h.memberAccess.next = const MemberAccessDenied(
          MemberAccessDenial.notLinked,
        ),
      );
      expect(byKey('denied-notLinked'), findsOneWidget);
      expect(byKey('go-membership-request'), findsOneWidget);
      expect(byKey('membership-deactivated'), findsNothing);
    });

    testWidgets('a granted member never asks for the status', (tester) async {
      final h = await pumpAt(
        tester,
        ClientPaths.account,
        setUp: (h) =>
            h.memberAccess.next = MemberAccessGranted(syntheticMemberSummary()),
      );
      expect(byKey('membership-deactivated'), findsNothing);
      expect(h.lifecycle.statusCalls, 0);
    });

    test('the status read carries only the flag and the church contact', () {
      expect(
        () => MyMembershipStatus.fromJson({'deactivated': 'yes'}),
        throwsFormatException,
      );
      final s = MyMembershipStatus.fromJson({
        'deactivated': true,
        'church_contact': null,
      });
      expect(s.deactivated, isTrue);
      expect(s.churchContact, isNull);
    });
  });
}

// Story 2.11: the member's in-app deletion request (mobile) and the Admin's
// member deletions screen with the staff route (staff web). Fakes only; the
// server behaviour is covered by supabase/tests/member_deletion_test.sql and
// tools/identity-e2e/deletion.mjs.
import 'package:church_client_core/church_client_core.dart';
import 'package:church_client_core/testing.dart';
import 'package:church_contracts/church_contracts.dart';
import 'package:church_design_system/church_design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _deletion = '85858585-8585-4585-8585-858585858585';
const _candidate = '87878787-8787-4787-8787-878787878787';
const _found = '66666666-6666-4666-8666-666666666666';

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

void granted(ClientTestHarness h) {
  h.grants.myAccess = AccessReadOk(
    MemberGrants.fromJson({
      'member_id': '22222222-2222-4222-8222-222222222222',
      'revision': 1,
      'roles': <String>[],
      'scopes': <Object>[],
    }),
  );
  h.memberAccess.next = MemberAccessGranted(syntheticMemberSummary());
}

Future<void> fillAndSubmit(
  WidgetTester tester, {
  String pw = 'Synthetic-pw-1',
}) async {
  await tapKey(tester, 'delete-understand');
  await tester.enterText(byKey('delete-password-field'), pw);
  await tester.pump();
  await tapKey(tester, 'delete-account-submit');
  await settle(tester);
}

AccessRead<MemberDeletionOverview> overviewWith({
  List<Map<String, Object?>> deletions = const [],
  List<Map<String, Object?>> deactivated = const [],
  bool accepting = true,
}) => AccessReadOk(
  MemberDeletionOverview.fromJson(
    memberDeletionOverviewData(
      deletions: deletions,
      deactivated: deactivated,
      accepting: accepting,
    ),
  ),
);

void main() {
  group('Delete my account (mobile)', () {
    testWidgets('the account page links a member to the deletion screen', (
      tester,
    ) async {
      await pumpAt(tester, ClientPaths.account, setUp: granted);
      expect(byKey('go-delete-account'), findsOneWidget);
      await tapKey(tester, 'go-delete-account');
      await settle(tester);
      expect(byKey('delete-account-submit'), findsOneWidget);
    });

    testWidgets(
      'nothing is sent until the member confirms and types the password',
      (tester) async {
        final h = await pumpAt(
          tester,
          ClientPaths.deleteAccount,
          setUp: granted,
        );
        expect(enabled(tester, 'delete-account-submit'), isFalse);
        await tapKey(tester, 'delete-understand');
        expect(enabled(tester, 'delete-account-submit'), isFalse);
        await tester.enterText(
          byKey('delete-password-field'),
          'Synthetic-pw-1',
        );
        await tester.pump();
        expect(enabled(tester, 'delete-account-submit'), isTrue);
        expect(h.gateway.sent, isEmpty);
      },
    );

    testWidgets(
      'the password is confirmed, the request sent, and the device signed out',
      (tester) async {
        final h = await pumpAt(
          tester,
          ClientPaths.deleteAccount,
          setUp: granted,
        );
        await fillAndSubmit(tester);
        expect(h.recoveryEmail.passwordsChecked, ['Synthetic-pw-1']);
        final sent = h.gateway.sent.single;
        expect(sent.function, 'identity_deletion_command');
        expect(sent.wire['command'], 'identity.request_my_deletion');
        expect(sent.wire['expected_revision'], isNull);
        expect(sent.wire['payload'], {'confirm': 'delete_my_account'});
        sent.confirm({
          'deletion_id': _deletion,
          'deletion_state': 'requested',
          'signed_out': true,
        }, 1);
        await settle(tester);
        expect(byKey('delete-requested'), findsOneWidget);
        expect(h.auth.signOuts, 1);
        expect(
          find.textContaining('signed out on every device'),
          findsOneWidget,
        );
      },
    );

    testWidgets('a wrong password sends nothing', (tester) async {
      final h = await pumpAt(
        tester,
        ClientPaths.deleteAccount,
        setUp: (h) {
          granted(h);
          h.recoveryEmail.passwordAnswer = const AuthFailed(
            AuthFailure.invalidCredentials,
          );
        },
      );
      await fillAndSubmit(tester);
      expect(byKey('delete-notice-wrongPassword'), findsOneWidget);
      expect(h.gateway.sent, isEmpty);
      expect(h.auth.signOuts, 0);
    });

    for (final (code, fields, notice) in [
      (ErrorCode.forbidden, {'member_id': 'last_admin'}, 'lastAdmin'),
      (ErrorCode.forbidden, {'session': 'reauthenticate'}, 'reauthenticate'),
      (
        ErrorCode.conflict,
        {'member_id': 'deletion_requested'},
        'alreadyRequested',
      ),
      (ErrorCode.forbidden, <String, String>{}, 'notMember'),
      (ErrorCode.unavailable, <String, String>{}, 'notAccepting'),
    ]) {
      testWidgets('a refusal ($notice) keeps the account signed in', (
        tester,
      ) async {
        final h = await pumpAt(
          tester,
          ClientPaths.deleteAccount,
          setUp: granted,
        );
        await fillAndSubmit(tester);
        h.gateway.sent.single.refuse(code, fieldErrors: fields);
        await settle(tester);
        expect(byKey('delete-notice-$notice'), findsOneWidget);
        expect(byKey('delete-requested'), findsNothing);
        expect(h.auth.signOuts, 0);
      });
    }

    testWidgets('an unconfirmed request is checked again with the same id', (
      tester,
    ) async {
      final h = await pumpAt(tester, ClientPaths.deleteAccount, setUp: granted);
      await fillAndSubmit(tester);
      final first = h.gateway.sent.single;
      first.unknown();
      await settle(tester);
      expect(byKey('delete-notice-unconfirmed'), findsOneWidget);
      await tapKey(tester, 'delete-check-again');
      await settle(tester);
      expect(h.gateway.sent, hasLength(2));
      expect(h.gateway.sent[1].wire['request_id'], first.wire['request_id']);
      h.gateway.sent[1].confirm({'deletion_id': _deletion}, 1);
      await settle(tester);
      expect(byKey('delete-requested'), findsOneWidget);
    });

    testWidgets('signed out, the screen only asks to sign in', (tester) async {
      final h = ClientTestHarness(account: null);
      tester.view.physicalSize = const Size(1200, 5000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final router = buildClientRouter(
        initialLocation: ClientPaths.deleteAccount,
        membershipRequests: true,
        shell: (_, _, child) => child,
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
      expect(byKey('delete-signed-out'), findsOneWidget);
      expect(byKey('delete-account-submit'), findsNothing);
    });
  });

  group('Member deletions (staff web, Admin)', () {
    testWidgets('a non-Admin sees the server denial only', (tester) async {
      final h = await pumpAt(tester, ClientPaths.adminMemberDeletions);
      expect(byKey('deletions-denied-notGranted'), findsOneWidget);
      expect(byKey('deletion-search-field'), findsNothing);
      expect(h.deletions.overviewCalls, 1);
    });

    testWidgets('lists deletions with their steps, waits and attempts', (
      tester,
    ) async {
      await pumpAt(
        tester,
        ClientPaths.adminMemberDeletions,
        setUp: (h) => h.deletions.overview = overviewWith(
          deletions: [
            memberDeletionData(
              done: 4,
              authAttempts: 2,
              pendingObligations: 1,
              next: {
                'step': 'erase_identity',
                'action': 'wait',
                'reason': 'handover_pending',
                'attempts': 0,
              },
            ),
            memberDeletionData(
              id: '88888888-8888-4888-8888-888888888888',
              done: 8,
              hadAccount: false,
              origin: 'staff_request',
            ),
          ],
        ),
      );
      expect(byKey('deletion-$_deletion'), findsOneWidget);
      expect(find.text('Deleting (4 of 11 steps)'), findsOneWidget);
      expect(byKey('deletion-waiting-$_deletion'), findsOneWidget);
      expect(find.text('App account deleted (2 attempts)'), findsOneWidget);
      expect(find.text('1 handover(s) still pending'), findsOneWidget);
      expect(find.text('Deleted'), findsOneWidget);
      expect(find.text('Deleted member'), findsOneWidget);
      expect(
        byKey(
          'deletion-88888888-8888-4888-8888-888888888888-step-auth_account',
        ),
        findsNothing,
      );
    });

    testWidgets('when erasure is gated the screen says so', (tester) async {
      await pumpAt(
        tester,
        ClientPaths.adminMemberDeletions,
        setUp: (h) => h.deletions.overview = overviewWith(accepting: false),
      );
      expect(byKey('deletions-erasure-gated'), findsOneWidget);
      expect(byKey('deletions-none'), findsOneWidget);
    });

    testWidgets('a deactivated member is deleted after an identity check', (
      tester,
    ) async {
      final h = await pumpAt(
        tester,
        ClientPaths.adminMemberDeletions,
        setUp: (h) => h.deletions.overview = overviewWith(
          deactivated: [deletionCandidateData()],
        ),
      );
      expect(enabled(tester, 'deletion-request-$_candidate'), isFalse);
      await tapKey(tester, 'deletion-$_candidate-check-in_person');
      expect(enabled(tester, 'deletion-request-$_candidate'), isTrue);
      await tapKey(tester, 'deletion-request-$_candidate');
      await settle(tester);
      final sent = h.gateway.sent.single;
      expect(sent.function, 'identity_deletion_command');
      expect(sent.wire['command'], 'identity.request_member_deletion');
      expect(sent.wire['expected_revision'], 5);
      expect(sent.wire['payload'], {
        'member_id': _candidate,
        'identity_check': 'in_person',
      });
      sent.confirm(memberDeletionData(memberId: _candidate), 1);
      await settle(tester);
      expect(byKey('deletion-notice-requested'), findsOneWidget);
      expect(h.deletions.overviewCalls, 2);
    });

    testWidgets('a member who can use the app cannot be deleted here', (
      tester,
    ) async {
      final h = await pumpAt(
        tester,
        ClientPaths.adminMemberDeletions,
        setUp: (h) {
          h.deletions.overview = overviewWith();
          h.review.search = AccessReadOk(
            MemberSearchPage.fromJson({
              'members': [
                memberRecordData(revision: 7, account: 'app_account'),
              ],
              'next': null,
            }),
          );
        },
      );
      await tester.enterText(byKey('deletion-search-field'), 'Ruth');
      await tapKey(tester, 'deletion-search');
      await settle(tester);
      expect(byKey('deletion-target-found-$_found'), findsOneWidget);
      expect(
        find.text('Uses the app: they delete their account there'),
        findsOneWidget,
      );
      expect(enabled(tester, 'deletion-request-$_found'), isFalse);
      expect(h.gateway.sent, isEmpty);
    });

    testWidgets(
      'a server refusal for a member who can use the app is explained',
      (tester) async {
        final h = await pumpAt(
          tester,
          ClientPaths.adminMemberDeletions,
          setUp: (h) => h.deletions.overview = overviewWith(
            deactivated: [deletionCandidateData()],
          ),
        );
        await tapKey(
          tester,
          'deletion-$_candidate-check-established_relationship',
        );
        await tapKey(tester, 'deletion-request-$_candidate');
        await settle(tester);
        h.gateway.sent.single.refuse(
          ErrorCode.conflict,
          fieldErrors: {'member_id': 'member_can_use_app'},
        );
        await settle(tester);
        expect(byKey('deletion-notice-canUseApp'), findsOneWidget);
      },
    );

    testWidgets('the own record is not offered', (tester) async {
      await pumpAt(
        tester,
        ClientPaths.adminMemberDeletions,
        setUp: (h) => h.deletions.overview = overviewWith(
          deactivated: [deletionCandidateData(ownMember: true)],
        ),
      );
      expect(
        find.text('This is your own record: delete it in the app.'),
        findsOneWidget,
      );
      expect(enabled(tester, 'deletion-request-$_candidate'), isFalse);
    });
  });
}

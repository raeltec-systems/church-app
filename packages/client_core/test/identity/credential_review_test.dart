// Story 2.8: the generic "Access review required" help screen and the review
// gate (both clients), the member's reviewed sign-in detail changes (mobile)
// and the Admin credential review (staff web). Fakes only; the server
// behaviour is covered by supabase/tests/credential_review_test.sql and
// tools/identity-e2e/credentials.mjs.
import 'package:church_client_core/church_client_core.dart';
import 'package:church_client_core/testing.dart';
import 'package:church_contracts/church_contracts.dart';
import 'package:church_design_system/church_design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _change = '88888888-8888-4888-8888-888888888888';
const _reviewMember = 'abababab-abab-4bab-8bab-abababababab';
const _hold = 'cdcdcdcd-cdcd-4dcd-8dcd-cdcdcdcdcdcd';
const _holdMember = 'efefefef-efef-4fef-8fef-efefefefefef';
const _proposal = '77777777-7777-4777-8777-777777777777';

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

AccessRead<MyCredentials> mineWith(Map<String, Object?> data) =>
    AccessReadOk(MyCredentials.fromJson(data));

AccessRead<CredentialQueue> queueWith({
  List<Map<String, Object?>> changes = const [],
  List<Map<String, Object?>> reviews = const [],
  List<Map<String, Object?>> holds = const [],
}) => AccessReadOk(
  CredentialQueue.fromJson(
    credentialQueueData(changes: changes, reviews: reviews, holds: holds),
  ),
);

void inReview(ClientTestHarness h, {Map<String, Object?>? data}) {
  h.grants.myAccess = const AccessReadDenied(AccessDenial.reviewRequired);
  h.memberAccess.next = const MemberAccessDenied(
    MemberAccessDenial.reviewRequired,
  );
  h.credentials.mine = mineWith(
    data ?? myCredentialsData(access: 'review_required', canRequest: false),
  );
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

void main() {
  group('access review required (help screen and gate)', () {
    testWidgets('a session in review sees only the generic help screen', (
      tester,
    ) async {
      await pumpAt(tester, ClientPaths.account, setUp: inReview);
      expect(byKey('access-review-gate'), findsOneWidget);
      expect(byKey('access-review-required'), findsOneWidget);
      expect(byKey('member-summary'), findsNothing);
      expect(find.text('Access review required'), findsWidgets);
      expect(byKey('access-review-contact'), findsOneWidget);
      // Generic: no reason (hold, dispute, lost device) is ever shown.
      for (final word in ['hold', 'dispute', 'lost', 'stolen']) {
        expect(
          find.textContaining(RegExp(word, caseSensitive: false)),
          findsNothing,
          reason: word,
        );
      }
    });

    testWidgets('every private destination is gated while in review', (
      tester,
    ) async {
      for (final path in [
        ClientPaths.access,
        ClientPaths.myCell,
        ClientPaths.signInDetails,
        ClientPaths.adminCredentialReviews,
        ClientPaths.adminMembers,
      ]) {
        await pumpAt(tester, path, setUp: inReview);
        expect(byKey('access-review-gate'), findsOneWidget, reason: path);
      }
    });

    testWidgets('public routes and sign-in stay reachable', (tester) async {
      await pumpAt(tester, ClientPaths.forgotPassword, setUp: inReview);
      expect(byKey('access-review-gate'), findsNothing);
    });

    testWidgets('the church contact is shown when the church set one', (
      tester,
    ) async {
      await pumpAt(
        tester,
        ClientPaths.accessReview,
        setUp: (h) => inReview(
          h,
          data: myCredentialsData(
            access: 'review_required',
            canRequest: false,
            churchContact: 'SYNTHETIC church office, Sunday after service',
          ),
        ),
      );
      expect(
        find.textContaining('SYNTHETIC church office, Sunday after service'),
        findsOneWidget,
      );
    });

    testWidgets('the current request can be withdrawn from the help screen', (
      tester,
    ) async {
      final h = await pumpAt(
        tester,
        ClientPaths.accessReview,
        setUp: (h) => inReview(
          h,
          data: myCredentialsData(
            access: 'review_required',
            canRequest: false,
            email: null,
            pendingChange: credentialChangeData(
              kind: 'recovery_email_replace',
              phone: null,
              email: 'synthetic-new@example.test',
              verified: false,
              revision: 2,
            ),
          ),
        ),
      );
      expect(byKey('access-review-pending-change'), findsOneWidget);
      await tapKey(tester, 'access-review-withdraw-change');
      final sent = h.gateway.sent.single;
      expect(sent.function, 'identity_credential_command');
      expect(sent.wire['command'], 'identity.withdraw_credential_change');
      expect(sent.wire['expected_revision'], 2);
      expect(sent.wire['payload'], {'change_id': _change});
      h.credentials.mine = mineWith(myCredentialsData());
      sent.confirm(credentialChangeData(state: 'withdrawn'), 3);
      await settle(tester);
      expect(byKey('credential-notice-withdrawn'), findsOneWidget);
    });

    testWidgets('a pending recovery-email addition is withdrawn with 2.7', (
      tester,
    ) async {
      final h = await pumpAt(
        tester,
        ClientPaths.accessReview,
        setUp: (h) => inReview(
          h,
          data: myCredentialsData(
            access: 'review_required',
            canRequest: false,
            pendingRecoveryEmail: recoveryProposalData(verified: true),
          ),
        ),
      );
      await tapKey(tester, 'access-review-withdraw-email');
      final sent = h.gateway.sent.single;
      expect(sent.function, 'identity_recovery_email_command');
      expect(sent.wire['command'], 'identity.withdraw_recovery_email');
      expect(sent.wire['payload'], {'proposal_id': _proposal});
    });

    testWidgets('outside review the account page is shown, with links', (
      tester,
    ) async {
      await pumpAt(tester, ClientPaths.account, setUp: granted);
      expect(byKey('access-review-gate'), findsNothing);
      expect(byKey('member-summary'), findsOneWidget);
      expect(byKey('go-sign-in-details'), findsOneWidget);
    });

    testWidgets('the account page review banner links to the help screen', (
      tester,
    ) async {
      await pumpAt(
        tester,
        ClientPaths.account,
        setUp: (h) {
          h.memberAccess.next = const MemberAccessDenied(
            MemberAccessDenial.reviewRequired,
          );
          h.credentials.mine = mineWith(
            myCredentialsData(access: 'review_required', canRequest: false),
          );
        },
      );
      await tapKey(tester, 'go-access-review');
      await settle(tester);
      expect(byKey('access-review-required'), findsOneWidget);
    });
  });

  group('sign-in details (member)', () {
    testWidgets('a phone-username change: password check, then review', (
      tester,
    ) async {
      final h = await pumpAt(tester, ClientPaths.signInDetails, setUp: granted);
      expect(byKey('sign-in-details-username'), findsOneWidget);
      // Without an approved recovery email only the username can change.
      expect(byKey('change-kind-recovery_email_remove'), findsNothing);
      await tapKey(tester, 'change-kind-phone_username');
      await tester.enterText(
        byKey('new-phone-username-field'),
        '+44 7700 900340',
      );
      await tester.enterText(
        byKey('change-current-password-field'),
        'Synthetic-pw',
      );
      await tapKey(tester, 'send-credential-change');
      await settle(tester);
      expect(h.recoveryEmail.passwordsChecked, ['Synthetic-pw']);
      final sent = h.gateway.sent.single;
      expect(sent.function, 'identity_credential_command');
      expect(sent.wire['command'], 'identity.request_credential_change');
      expect(sent.wire['expected_revision'], isNull);
      expect(sent.wire['payload'], {
        'change_kind': 'phone_username',
        'phone_username': '+447700900340',
      });
      h.credentials.mine = mineWith(
        myCredentialsData(
          canRequest: false,
          pendingChange: credentialChangeData(),
        ),
      );
      sent.confirm(credentialChangeData(), 1);
      await settle(tester);
      expect(byKey('credential-notice-requested'), findsOneWidget);
      expect(byKey('sign-in-details-pending'), findsOneWidget);
      expect(h.recoveryEmail.verificationsRequested, isEmpty);
    });

    testWidgets('an invalid number or a wrong password sends nothing', (
      tester,
    ) async {
      final h = await pumpAt(
        tester,
        ClientPaths.signInDetails,
        setUp: (h) {
          granted(h);
          h.recoveryEmail.passwordAnswer = const AuthFailed(
            AuthFailure.invalidCredentials,
          );
        },
      );
      await tapKey(tester, 'change-kind-phone_username');
      await tester.enterText(byKey('new-phone-username-field'), '12');
      await tester.enterText(byKey('change-current-password-field'), 'x');
      await tapKey(tester, 'send-credential-change');
      await settle(tester);
      expect(h.recoveryEmail.passwordsChecked, isEmpty);
      await tester.enterText(
        byKey('new-phone-username-field'),
        '+447700900340',
      );
      await tester.enterText(byKey('change-current-password-field'), 'x');
      await tapKey(tester, 'send-credential-change');
      await settle(tester);
      expect(h.gateway.sent, isEmpty);
      expect(byKey('credential-notice-wrongPassword'), findsOneWidget);
    });

    testWidgets('a replacement asks Auth to confirm the new address', (
      tester,
    ) async {
      final h = await pumpAt(
        tester,
        ClientPaths.signInDetails,
        setUp: (h) {
          granted(h);
          h.credentials.mine = mineWith(
            myCredentialsData(email: 'synthetic-old@example.test'),
          );
        },
      );
      await tapKey(tester, 'change-kind-recovery_email_replace');
      await tester.enterText(
        byKey('replacement-email-field'),
        'Synthetic-New@Example.test',
      );
      await tester.enterText(
        byKey('change-current-password-field'),
        'Synthetic-pw',
      );
      await tapKey(tester, 'send-credential-change');
      await settle(tester);
      final sent = h.gateway.sent.single;
      expect(sent.wire['payload'], {
        'change_kind': 'recovery_email_replace',
        'email': 'synthetic-new@example.test',
      });
      sent.confirm(credentialChangeData(kind: 'recovery_email_replace'), 1);
      await settle(tester);
      expect(h.recoveryEmail.verificationsRequested, [
        'synthetic-new@example.test',
      ]);
      expect(byKey('credential-notice-checkInbox'), findsOneWidget);
    });

    testWidgets('a removal sends only the kind', (tester) async {
      final h = await pumpAt(
        tester,
        ClientPaths.signInDetails,
        setUp: (h) {
          granted(h);
          h.credentials.mine = mineWith(
            myCredentialsData(email: 'synthetic-old@example.test'),
          );
        },
      );
      await tapKey(tester, 'change-kind-recovery_email_remove');
      await tester.enterText(
        byKey('change-current-password-field'),
        'Synthetic-pw',
      );
      await tapKey(tester, 'send-credential-change');
      await settle(tester);
      expect(h.gateway.sent.single.wire['payload'], {
        'change_kind': 'recovery_email_remove',
      });
    });

    testWidgets('server refusals are explained', (tester) async {
      final h = await pumpAt(tester, ClientPaths.signInDetails, setUp: granted);
      Future<void> send() async {
        await tapKey(tester, 'change-kind-phone_username');
        await tester.enterText(
          byKey('new-phone-username-field'),
          '+447700900340',
        );
        await tester.enterText(
          byKey('change-current-password-field'),
          'Synthetic-pw',
        );
        await tapKey(tester, 'send-credential-change');
        await settle(tester);
      }

      await send();
      h.gateway.sent.last.refuse(
        ErrorCode.conflict,
        fieldErrors: const {'phone_username': 'unavailable'},
      );
      await settle(tester);
      expect(byKey('credential-notice-numberUnavailable'), findsOneWidget);
      await send();
      h.gateway.sent.last.refuse(
        ErrorCode.forbidden,
        fieldErrors: const {'session': 'reauthenticate'},
      );
      await settle(tester);
      expect(byKey('credential-notice-reauthenticate'), findsOneWidget);
    });

    testWidgets('a pending request shows withdraw and no new form', (
      tester,
    ) async {
      await pumpAt(
        tester,
        ClientPaths.signInDetails,
        setUp: (h) {
          granted(h);
          h.credentials.mine = mineWith(
            myCredentialsData(
              canRequest: false,
              pendingChange: credentialChangeData(),
            ),
          );
        },
      );
      expect(byKey('sign-in-details-pending'), findsOneWidget);
      expect(byKey('sign-in-details-withdraw'), findsOneWidget);
      expect(byKey('change-kind-phone_username'), findsNothing);
    });
  });

  group('Admin credential review', () {
    testWidgets('a non-Admin sees the server denial only', (tester) async {
      await pumpAt(tester, ClientPaths.adminCredentialReviews);
      expect(byKey('credential-review-denied-notGranted'), findsOneWidget);
    });

    testWidgets('approve needs an identity check and sends the revision', (
      tester,
    ) async {
      final h = await pumpAt(
        tester,
        ClientPaths.adminCredentialReviews,
        setUp: (h) => h.credentials.queue = queueWith(
          changes: [
            credentialChangeItemData(change: credentialChangeData(revision: 2)),
          ],
        ),
      );
      expect(byKey('credential-change-$_change'), findsOneWidget);
      expect(enabled(tester, 'credential-change-approve-$_change'), isFalse);
      await tapKey(tester, 'credential-review-$_change-check-in_person');
      expect(enabled(tester, 'credential-change-approve-$_change'), isTrue);
      await tapKey(tester, 'credential-change-approve-$_change');
      final sent = h.gateway.sent.single;
      expect(sent.wire['command'], 'identity.approve_credential_change');
      expect(sent.wire['expected_revision'], 2);
      expect(sent.wire['payload'], {
        'change_id': _change,
        'identity_check': 'in_person',
      });
      h.credentials.queue = queueWith();
      sent.confirm(credentialChangeItemData(), 3);
      await settle(tester);
      expect(byKey('credential-review-notice-approved'), findsOneWidget);
      expect(byKey('credential-review-no-changes'), findsOneWidget);
    });

    testWidgets(
      'unconfirmed, taken, other changes and own account cannot be approved',
      (tester) async {
        const a = '88888888-8888-4888-8888-88888888888a';
        const b = '88888888-8888-4888-8888-88888888888b';
        const c = '88888888-8888-4888-8888-88888888888c';
        const d = '88888888-8888-4888-8888-88888888888d';
        await pumpAt(
          tester,
          ClientPaths.adminCredentialReviews,
          setUp: (h) => h.credentials.queue = queueWith(
            changes: [
              credentialChangeItemData(
                change: credentialChangeData(
                  id: a,
                  kind: 'recovery_email_replace',
                  phone: null,
                  email: 'synthetic-new@example.test',
                  verified: false,
                ),
              ),
              credentialChangeItemData(
                change: credentialChangeData(id: b),
                phoneAvailable: false,
              ),
              credentialChangeItemData(
                change: credentialChangeData(id: c),
                otherChanges: true,
              ),
              credentialChangeItemData(
                change: credentialChangeData(id: d),
                ownAccount: true,
              ),
            ],
          ),
        );
        for (final id in [a, b, c, d]) {
          await tapKey(tester, 'credential-review-$id-check-in_person');
          expect(
            enabled(tester, 'credential-change-approve-$id'),
            isFalse,
            reason: id,
          );
        }
        expect(enabled(tester, 'credential-change-reject-$d'), isFalse);
        expect(byKey('credential-change-own-$d'), findsOneWidget);
      },
    );

    testWidgets('reject sends a reason code; a taken number is explained', (
      tester,
    ) async {
      final h = await pumpAt(
        tester,
        ClientPaths.adminCredentialReviews,
        setUp: (h) => h.credentials.queue = queueWith(
          changes: [credentialChangeItemData()],
        ),
      );
      await tapKey(
        tester,
        'credential-change-$_change-reason-contact_church_office',
      );
      await tapKey(tester, 'credential-change-reject-$_change');
      expect(h.gateway.sent.single.wire['payload'], {
        'change_id': _change,
        'reason': 'contact_church_office',
      });
      h.gateway.sent.single.refuse(
        ErrorCode.conflict,
        fieldErrors: const {'phone_username': 'taken'},
      );
      await settle(tester);
      expect(byKey('credential-review-notice-taken'), findsOneWidget);
    });

    testWidgets('an account in review is restored or accepted after a check', (
      tester,
    ) async {
      final h = await pumpAt(
        tester,
        ClientPaths.adminCredentialReviews,
        setUp: (h) =>
            h.credentials.queue = queueWith(reviews: [accessReviewItemData()]),
      );
      expect(byKey('credential-review-$_reviewMember'), findsOneWidget);
      expect(
        enabled(tester, 'credential-review-restore-$_reviewMember'),
        isFalse,
      );
      await tapKey(
        tester,
        'credential-review-review-$_reviewMember-check-established_relationship',
      );
      expect(
        enabled(tester, 'credential-review-accept-$_reviewMember'),
        isTrue,
      );
      await tapKey(tester, 'credential-review-restore-$_reviewMember');
      final sent = h.gateway.sent.single;
      expect(sent.wire['command'], 'identity.restore_credentials');
      expect(sent.wire['expected_revision'], 4);
      expect(sent.wire['payload'], {
        'member_id': _reviewMember,
        'identity_check': 'established_relationship',
      });
      h.credentials.queue = queueWith();
      sent.confirm({'member_id': _reviewMember}, 5);
      await settle(tester);
      expect(byKey('credential-review-notice-restored'), findsOneWidget);
    });

    testWidgets('an extra sign-in factor can only be restored', (tester) async {
      await pumpAt(
        tester,
        ClientPaths.adminCredentialReviews,
        setUp: (h) => h.credentials.queue = queueWith(
          reviews: [accessReviewItemData(extraFactors: true)],
        ),
      );
      await tapKey(
        tester,
        'credential-review-review-$_reviewMember-check-in_person',
      );
      expect(
        enabled(tester, 'credential-review-accept-$_reviewMember'),
        isFalse,
      );
      expect(
        enabled(tester, 'credential-review-restore-$_reviewMember'),
        isTrue,
      );
    });

    testWidgets('a hold is released only after an identity check', (
      tester,
    ) async {
      final h = await pumpAt(
        tester,
        ClientPaths.adminCredentialReviews,
        setUp: (h) => h.credentials.queue = queueWith(holds: [holdItemData()]),
      );
      expect(enabled(tester, 'credential-hold-release-$_hold'), isFalse);
      await tapKey(tester, 'credential-review-hold-$_hold-check-in_person');
      await tapKey(tester, 'credential-hold-release-$_hold');
      final sent = h.gateway.sent.single;
      expect(sent.wire['command'], 'identity.release_hold');
      expect(sent.wire['expected_revision'], 2);
      expect(sent.wire['payload'], {
        'member_id': _holdMember,
        'hold_id': _hold,
        'identity_check': 'in_person',
      });
    });

    testWidgets('a release before the member\'s own reset is explained', (
      tester,
    ) async {
      final h = await pumpAt(
        tester,
        ClientPaths.adminCredentialReviews,
        setUp: (h) => h.credentials.queue = queueWith(
          holds: [holdItemData(reason: 'lost_device')],
          changes: [credentialChangeItemData()],
        ),
      );
      await tapKey(tester, 'credential-review-hold-$_hold-check-in_person');
      await tapKey(tester, 'credential-hold-release-$_hold');
      h.gateway.sent.last.refuse(
        ErrorCode.conflict,
        fieldErrors: const {'hold_id': 'password_reset_required'},
      );
      await settle(tester);
      expect(
        byKey('credential-review-notice-passwordResetRequired'),
        findsOneWidget,
      );
      await tapKey(tester, 'credential-review-$_change-check-in_person');
      await tapKey(tester, 'credential-change-approve-$_change');
      h.gateway.sent.last.refuse(
        ErrorCode.conflict,
        fieldErrors: const {'member_id': 'held'},
      );
      await settle(tester);
      expect(byKey('credential-review-notice-held'), findsOneWidget);
    });

    testWidgets('the Admin\'s own hold is for another Admin', (tester) async {
      await pumpAt(
        tester,
        ClientPaths.adminCredentialReviews,
        setUp: (h) => h.credentials.queue = queueWith(
          holds: [holdItemData(ownMember: true)],
        ),
      );
      await tapKey(tester, 'credential-review-hold-$_hold-check-in_person');
      expect(enabled(tester, 'credential-hold-release-$_hold'), isFalse);
    });

    testWidgets('a lost-device hold is placed on a searched member', (
      tester,
    ) async {
      const member = '66666666-6666-4666-8666-666666666666';
      final h = await pumpAt(
        tester,
        ClientPaths.adminCredentialReviews,
        setUp: (h) {
          h.credentials.queue = queueWith();
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
      await tester.enterText(byKey('credential-hold-search-field'), 'Ruth');
      await tapKey(tester, 'credential-hold-search');
      await settle(tester);
      expect(h.review.searchCalls, ['Ruth']);
      expect(enabled(tester, 'credential-hold-place-$member'), isFalse);
      await tapKey(tester, 'credential-hold-$member-reason-lost_device');
      await tapKey(tester, 'credential-hold-place-$member');
      final sent = h.gateway.sent.single;
      expect(sent.wire['command'], 'identity.place_hold');
      expect(sent.wire['expected_revision'], 7);
      expect(sent.wire['payload'], {
        'member_id': member,
        'reason_code': 'lost_device',
      });
      sent.confirm({'member_id': member}, 8);
      await settle(tester);
      expect(byKey('credential-review-notice-holdPlaced'), findsOneWidget);
    });
  });
}

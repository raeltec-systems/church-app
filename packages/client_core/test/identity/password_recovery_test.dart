// Story 2.7: forgot password through the approved recovery email (neutral
// answer), the allowlisted recovery and email-confirmed links, the isolated
// recovery session that can only set a password, the member's own recovery
// email (mobile) and the Admin approval queue (staff web). Fakes only; the
// server behaviour is covered by supabase/tests/recovery_email_test.sql and
// tools/identity-e2e/recovery.mjs.
import 'package:church_client_core/church_client_core.dart';
import 'package:church_client_core/testing.dart';
import 'package:church_contracts/church_contracts.dart';
import 'package:church_design_system/church_design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

const _proposal = '77777777-7777-4777-8777-777777777777';
const _code = '0b5c1a2e-3f4d-4e5f-8a9b-0c1d2e3f4a5b';

Future<ClientTestHarness> pumpAt(
  WidgetTester tester,
  String location, {
  void Function(ClientTestHarness h)? setUp,
  String? account = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
}) async {
  tester.view.physicalSize = const Size(1200, 4000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final h = ClientTestHarness(account: account);
  setUp?.call(h);
  final router = buildClientRouter(
    initialLocation: location,
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

void main() {
  group('incoming Auth links (allowlist)', () {
    test('only the two Auth link paths are accepted', () {
      expect(
        parseAuthLink(Uri.parse('/auth/recovery?code=$_code'))?.kind,
        AuthLinkKind.recovery,
      );
      expect(
        parseAuthLink(Uri.parse('/auth/email-confirmed?code=$_code'))?.kind,
        AuthLinkKind.emailConfirmed,
      );
      for (final other in [
        '/auth/recovery/extra?code=$_code',
        '/admin/grants?code=$_code',
        '/account?code=$_code',
        '/auth/callback?code=$_code',
      ]) {
        expect(parseAuthLink(Uri.parse(other)), isNull, reason: other);
      }
    });

    test('reads only a well-formed code and error code', () {
      final ok = parseAuthLink(
        Uri.parse('/auth/recovery?code=$_code&next=/admin'),
      )!;
      expect(ok.usable, isTrue);
      expect(ok.code, _code);
      final bad = parseAuthLink(Uri.parse('/auth/recovery?code=%3Cscript%3E'))!;
      expect(bad.code, isNull);
      expect(bad.usable, isFalse);
      final used = parseAuthLink(
        Uri.parse('/auth/recovery?error=access_denied&error_code=otp_expired'),
      )!;
      expect(used.errorCode, 'otp_expired');
      expect(used.usable, isFalse);
    });

    test('on the web the code comes from the page query before the hash', () {
      final link = parseAuthLink(
        Uri.parse('/auth/recovery'),
        page: Uri.parse('https://staff.example/?code=$_code#/auth/recovery'),
      )!;
      expect(link.code, _code);
    });

    test('redirect targets are the app scheme and the staff origin', () {
      expect(
        AuthRedirects.mobile.recovery.toString(),
        'zm.bickafue.mobile://callback/auth/recovery',
      );
      expect(
        AuthRedirects.mobile.emailConfirmed.toString(),
        'zm.bickafue.mobile://callback/auth/email-confirmed',
      );
      final web = AuthRedirects.web(
        Uri.parse('https://staff.example:8443/#/sign-in?x=1'),
      );
      expect(
        web.recovery.toString(),
        'https://staff.example:8443/#/auth/recovery',
      );
      expect(
        web.emailConfirmed.toString(),
        'https://staff.example:8443/#/auth/email-confirmed',
      );
    });
  });

  group('forgot password', () {
    testWidgets('an invalid address is not sent', (tester) async {
      final h = await pumpAt(tester, ClientPaths.forgotPassword);
      await tester.enterText(byKey('reset-email-field'), 'not-an-email');
      await tapKey(tester, 'send-reset-link');
      expect(h.recovery.resetEmails, isEmpty);
      expect(find.textContaining('Enter an email address'), findsOneWidget);
    });

    testWidgets('the acknowledgement is neutral and the same for any answer', (
      tester,
    ) async {
      final h = await pumpAt(tester, ClientPaths.forgotPassword);
      await tester.enterText(
        byKey('reset-email-field'),
        ' Someone@Example.test ',
      );
      await tapKey(tester, 'send-reset-link');
      await settle(tester);
      expect(h.recovery.resetEmails, ['Someone@Example.test']);
      expect(byKey('reset-requested'), findsOneWidget);
      expect(
        find.textContaining('If this is the approved recovery email'),
        findsOneWidget,
      );
      // Nothing says whether an account or address exists.
      for (final leak in [
        'not found',
        'no account',
        'unknown',
        'not approved',
      ]) {
        expect(
          find.textContaining(leak, findRichText: true),
          findsNothing,
          reason: leak,
        );
      }
      expect(byKey('recovery-church-help'), findsOneWidget);
    });

    testWidgets('only a transport failure is distinguished', (tester) async {
      final h = await pumpAt(
        tester,
        ClientPaths.forgotPassword,
        setUp: (h) => h.recovery.resetAnswer = ResetRequestOutcome.unreachable,
      );
      await tester.enterText(
        byKey('reset-email-field'),
        'someone@example.test',
      );
      await tapKey(tester, 'send-reset-link');
      await settle(tester);
      expect(h.recovery.resetEmails, hasLength(1));
      expect(byKey('reset-unreachable'), findsOneWidget);
      expect(byKey('reset-requested'), findsNothing);
    });
  });

  group('recovery link', () {
    testWidgets('a usable link opens a session that can only set a password', (
      tester,
    ) async {
      final h = await pumpAt(tester, '${ClientPaths.authRecovery}?code=$_code');
      expect(h.recovery.openedCodes, [_code]);
      expect(byKey('new-password-field'), findsOneWidget);
      expect(byKey('confirm-password-field'), findsOneWidget);
      // No member data, no other action than setting the password.
      expect(byKey('member-summary'), findsNothing);
      expect(find.byType(FilledButton), findsOneWidget);
      expect(h.memberAccess.calls, 0);

      await tester.enterText(byKey('new-password-field'), 'Synthetic-new-1');
      await tester.enterText(
        byKey('confirm-password-field'),
        'Synthetic-new-2',
      );
      await tapKey(tester, 'set-password');
      expect(h.recovery.passwordsSet, isEmpty);
      expect(find.textContaining('not the same'), findsOneWidget);

      await tester.enterText(
        byKey('confirm-password-field'),
        'Synthetic-new-1',
      );
      await tapKey(tester, 'set-password');
      await settle(tester);
      expect(h.recovery.passwordsSet, ['Synthetic-new-1']);
      expect(byKey('password-set'), findsOneWidget);
      expect(h.recovery.sessionOpen, isFalse);
      // This device's own session ends too: a fresh password sign-in follows.
      expect(h.auth.signOuts, 1);
      await tapKey(tester, 'recovery-go-sign-in');
      await settle(tester);
      expect(byKey('phone-field'), findsOneWidget);
    });

    testWidgets('a link without a code, or with an error, is never opened', (
      tester,
    ) async {
      final h = await pumpAt(
        tester,
        '${ClientPaths.authRecovery}?error=access_denied&error_code=otp_expired',
      );
      expect(h.recovery.openedCodes, isEmpty);
      expect(byKey('recovery-link-unusable'), findsOneWidget);
      expect(byKey('new-password-field'), findsNothing);
      await tapKey(tester, 'recovery-ask-again');
      await settle(tester);
      expect(byKey('send-reset-link'), findsOneWidget);
    });

    testWidgets('a refused link is the same neutral answer', (tester) async {
      final h = await pumpAt(
        tester,
        '${ClientPaths.authRecovery}?code=$_code',
        setUp: (h) => h.recovery.linkAnswer = RecoveryLinkOutcome.unusable,
      );
      expect(h.recovery.openedCodes, [_code]);
      expect(byKey('recovery-link-unusable'), findsOneWidget);
      expect(byKey('new-password-field'), findsNothing);
    });

    testWidgets('a weak password keeps the form; an expired session does not', (
      tester,
    ) async {
      final h = await pumpAt(
        tester,
        '${ClientPaths.authRecovery}?code=$_code',
        setUp: (h) => h.recovery.setAnswer = const PasswordNotSet(
          SetPasswordFailure.weakPassword,
          serverReasons: ['length'],
        ),
      );
      await tester.enterText(byKey('new-password-field'), 'x');
      await tester.enterText(byKey('confirm-password-field'), 'x');
      await tapKey(tester, 'set-password');
      await settle(tester);
      expect(byKey('recovery-weak-password'), findsOneWidget);
      expect(byKey('new-password-field'), findsOneWidget);
      h.recovery.setAnswer = const PasswordNotSet(
        SetPasswordFailure.linkExpired,
      );
      await tapKey(tester, 'set-password');
      await settle(tester);
      expect(byKey('recovery-link-unusable'), findsOneWidget);
    });

    testWidgets(
      'leaving without setting a password ends the recovery session',
      (tester) async {
        final h = await pumpAt(
          tester,
          '${ClientPaths.authRecovery}?code=$_code',
        );
        expect(h.recovery.sessionOpen, isTrue);
        final router = GoRouterHelper(tester);
        router.go(ClientPaths.status);
        await settle(tester);
        expect(h.recovery.discards, greaterThanOrEqualTo(1));
        expect(h.recovery.sessionOpen, isFalse);
      },
    );
  });

  group('email-confirmed link', () {
    testWidgets('the code is never used and nobody is signed in', (
      tester,
    ) async {
      final h = await pumpAt(
        tester,
        '${ClientPaths.authEmailConfirmed}?code=$_code',
        account: null,
      );
      expect(byKey('email-confirmed'), findsOneWidget);
      expect(h.recovery.openedCodes, isEmpty);
      expect(h.session.currentAccountId, isNull);
    });

    testWidgets('an expired confirmation says so', (tester) async {
      await pumpAt(
        tester,
        '${ClientPaths.authEmailConfirmed}?error=access_denied&error_code=otp_expired',
      );
      expect(byKey('email-confirm-failed'), findsOneWidget);
    });
  });

  group('the member\'s recovery email', () {
    testWidgets('add: password check, proposal, then the confirmation email', (
      tester,
    ) async {
      final h = await pumpAt(tester, ClientPaths.recoveryEmail);
      expect(byKey('recovery-email-none'), findsOneWidget);
      await tester.enterText(
        byKey('new-recovery-email-field'),
        'Me@Example.test',
      );
      await tester.enterText(byKey('current-password-field'), 'Synthetic-pw');
      await tapKey(tester, 'add-recovery-email');
      await settle(tester);
      expect(h.recoveryEmail.passwordsChecked, ['Synthetic-pw']);
      final sent = h.gateway.sent.single;
      expect(sent.function, 'identity_recovery_email_command');
      expect(sent.wire['command'], 'identity.propose_recovery_email');
      expect(sent.wire['expected_revision'], isNull);
      expect(sent.wire['payload'], {'email': 'me@example.test'});
      h.recoveryEmail.mine = AccessReadOk(
        MyRecoveryEmail.fromJson(
          myRecoveryEmailData(
            canPropose: false,
            proposal: recoveryProposalData(email: 'me@example.test'),
          ),
        ),
      );
      sent.confirm(recoveryProposalData(email: 'me@example.test'), 1);
      await settle(tester);
      expect(h.recoveryEmail.verificationsRequested, ['me@example.test']);
      expect(byKey('recovery-email-notice-checkInbox'), findsOneWidget);
      expect(byKey('recovery-email-check-inbox'), findsOneWidget);
    });

    testWidgets('a wrong password sends no proposal', (tester) async {
      final h = await pumpAt(
        tester,
        ClientPaths.recoveryEmail,
        setUp: (h) => h.recoveryEmail.passwordAnswer = const AuthFailed(
          AuthFailure.invalidCredentials,
        ),
      );
      await tester.enterText(
        byKey('new-recovery-email-field'),
        'me@example.test',
      );
      await tester.enterText(byKey('current-password-field'), 'wrong');
      await tapKey(tester, 'add-recovery-email');
      await settle(tester);
      expect(h.gateway.sent, isEmpty);
      expect(byKey('recovery-email-notice-wrongPassword'), findsOneWidget);
    });

    testWidgets('an old sign-in must confirm the password again', (
      tester,
    ) async {
      final h = await pumpAt(tester, ClientPaths.recoveryEmail);
      await tester.enterText(
        byKey('new-recovery-email-field'),
        'me@example.test',
      );
      await tester.enterText(byKey('current-password-field'), 'Synthetic-pw');
      await tapKey(tester, 'add-recovery-email');
      await settle(tester);
      h.gateway.sent.single.refuse(
        ErrorCode.forbidden,
        fieldErrors: const {'session': 'reauthenticate'},
      );
      await settle(tester);
      expect(byKey('recovery-email-notice-reauthenticate'), findsOneWidget);
      expect(h.recoveryEmail.verificationsRequested, isEmpty);
    });

    testWidgets('an unknown outcome is checked again with the same request', (
      tester,
    ) async {
      final h = await pumpAt(tester, ClientPaths.recoveryEmail);
      await tester.enterText(
        byKey('new-recovery-email-field'),
        'me@example.test',
      );
      await tester.enterText(byKey('current-password-field'), 'Synthetic-pw');
      await tapKey(tester, 'add-recovery-email');
      await settle(tester);
      h.gateway.sent.single.unknown();
      await settle(tester);
      expect(byKey('recovery-email-notice-unconfirmed'), findsOneWidget);
      await tapKey(tester, 'recovery-email-check-again');
      await settle(tester);
      expect(h.gateway.sent, hasLength(2));
      expect(
        h.gateway.sent[1].wire['request_id'],
        h.gateway.sent[0].wire['request_id'],
      );
    });

    testWidgets('a verified email waits for church approval', (tester) async {
      await pumpAt(
        tester,
        ClientPaths.recoveryEmail,
        setUp: (h) => h.recoveryEmail.mine = AccessReadOk(
          MyRecoveryEmail.fromJson(
            myRecoveryEmailData(
              access: 'review_required',
              canPropose: false,
              proposal: recoveryProposalData(verified: true),
            ),
          ),
        ),
      );
      expect(byKey('recovery-email-awaiting-approval'), findsOneWidget);
      expect(byKey('add-recovery-email'), findsNothing);
    });

    testWidgets('approved and rejected states', (tester) async {
      final h = await pumpAt(
        tester,
        ClientPaths.recoveryEmail,
        setUp: (h) => h.recoveryEmail.mine = AccessReadOk(
          MyRecoveryEmail.fromJson(
            myRecoveryEmailData(
              approvedEmail: 'me@example.test',
              canPropose: false,
            ),
          ),
        ),
      );
      expect(byKey('recovery-email-approved'), findsOneWidget);
      expect(find.textContaining('contact the church office'), findsOneWidget);
      h.recoveryEmail.mine = AccessReadOk(
        MyRecoveryEmail.fromJson(
          myRecoveryEmailData(
            proposal: recoveryProposalData(
              state: 'rejected',
              decisionReason: 'contact_church_office',
            ),
          ),
        ),
      );
      final container = ProviderScope.containerOf(
        tester.element(byKey('recovery-email-approved')),
      );
      await container.read(myRecoveryEmailProvider.notifier).reload();
      await settle(tester);
      expect(byKey('recovery-email-rejected'), findsOneWidget);
    });

    testWidgets('the account page links a member to it', (tester) async {
      final h = ClientTestHarness();
      h.memberAccess.next = MemberAccessGranted(syntheticMemberSummary());
      final router = buildClientRouter(
        initialLocation: ClientPaths.account,
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
      await tapKey(tester, 'go-recovery-email');
      await settle(tester);
      expect(byKey('recovery-email-none'), findsOneWidget);
    });
  });

  group('Admin recovery email approvals', () {
    AccessRead<RecoveryEmailQueue> queueWith(
      List<Map<String, Object?>> items,
    ) => AccessReadOk(RecoveryEmailQueue.fromJson({'proposals': items}));

    testWidgets('a non-Admin sees the server denial only', (tester) async {
      await pumpAt(tester, ClientPaths.adminRecoveryEmails);
      expect(byKey('recovery-review-denied-notGranted'), findsOneWidget);
      expect(byKey('recovery-review-$_proposal'), findsNothing);
    });

    testWidgets('approve needs an identity check and sends the revision', (
      tester,
    ) async {
      final h = await pumpAt(
        tester,
        ClientPaths.adminRecoveryEmails,
        setUp: (h) => h.recoveryEmail.queue = queueWith([
          recoveryReviewItemData(revision: 3),
        ]),
      );
      expect(byKey('recovery-review-$_proposal'), findsOneWidget);
      expect(enabled(tester, 'recovery-review-approve-$_proposal'), isFalse);
      await tapKey(tester, 'recovery-review-$_proposal-check-in_person');
      expect(enabled(tester, 'recovery-review-approve-$_proposal'), isTrue);
      await tapKey(tester, 'recovery-review-approve-$_proposal');
      final sent = h.gateway.sent.single;
      expect(sent.wire['command'], 'identity.approve_recovery_email');
      expect(sent.wire['expected_revision'], 3);
      expect(sent.wire['payload'], {
        'proposal_id': _proposal,
        'identity_check': 'in_person',
      });
      h.recoveryEmail.queue = queueWith([]);
      sent.confirm(recoveryReviewItemData(), 4);
      await settle(tester);
      expect(byKey('recovery-review-notice-approved'), findsOneWidget);
      expect(byKey('recovery-review-empty'), findsOneWidget);
    });

    testWidgets(
      'unconfirmed, other changes and own account cannot be approved',
      (tester) async {
        const a = '77777777-7777-4777-8777-77777777777a';
        const b = '77777777-7777-4777-8777-77777777777b';
        const c = '77777777-7777-4777-8777-77777777777c';
        await pumpAt(
          tester,
          ClientPaths.adminRecoveryEmails,
          setUp: (h) => h.recoveryEmail.queue = queueWith([
            recoveryReviewItemData(id: a, verified: false),
            recoveryReviewItemData(id: b, otherChanges: true),
            recoveryReviewItemData(id: c, ownAccount: true),
          ]),
        );
        for (final id in [a, b, c]) {
          await tapKey(tester, 'recovery-review-$id-check-in_person');
          expect(
            enabled(tester, 'recovery-review-approve-$id'),
            isFalse,
            reason: id,
          );
        }
        expect(enabled(tester, 'recovery-review-reject-$c'), isFalse);
        expect(byKey('recovery-review-own-$c'), findsOneWidget);
      },
    );

    testWidgets('reject sends a code; a server refusal is explained', (
      tester,
    ) async {
      final h = await pumpAt(
        tester,
        ClientPaths.adminRecoveryEmails,
        setUp: (h) =>
            h.recoveryEmail.queue = queueWith([recoveryReviewItemData()]),
      );
      await tapKey(
        tester,
        'recovery-review-$_proposal-reason-contact_church_office',
      );
      await tapKey(tester, 'recovery-review-reject-$_proposal');
      final sent = h.gateway.sent.single;
      expect(sent.wire['command'], 'identity.reject_recovery_email');
      expect(sent.wire['payload'], {
        'proposal_id': _proposal,
        'reason': 'contact_church_office',
      });
      sent.refuse(
        ErrorCode.conflict,
        fieldErrors: const {'proposal_id': 'other_changes'},
      );
      await settle(tester);
      expect(byKey('recovery-review-notice-otherChanges'), findsOneWidget);
    });
  });
}

/// Navigation from a test without a BuildContext of the router.
class GoRouterHelper {
  GoRouterHelper(this.tester);
  final WidgetTester tester;

  void go(String location) {
    final context = tester.element(find.byType(Scaffold).first);
    GoRouter.of(context).go(location);
  }
}

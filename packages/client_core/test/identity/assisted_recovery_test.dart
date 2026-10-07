// Story 2.9: "I need help accessing my account" on the member's phone (the
// device holds the grant secret; only its digest leaves before the password
// step) and the Admin's recovery cases on staff web. Fakes and a mock HTTP
// client for the real adapter; the server behaviour is covered by
// supabase/tests/assisted_recovery_test.sql and tools/identity-e2e/assisted.mjs.
import 'dart:convert';

import 'package:church_client_core/church_client_core.dart';
import 'package:church_client_core/supabase_adapters.dart';
import 'package:church_client_core/testing.dart';
import 'package:church_contracts/church_contracts.dart';
import 'package:church_design_system/church_design_system.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _case = '29292929-2929-4929-8929-292929292929';
const _member = '66666666-6666-4666-8666-666666666666';

Future<ClientTestHarness> pumpAt(
  WidgetTester tester,
  String location, {
  bool assisted = true,
  String? account = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
  void Function(ClientTestHarness h)? setUp,
}) async {
  tester.view.physicalSize = const Size(1200, 5000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final h = ClientTestHarness(account: account);
  setUp?.call(h);
  final router = buildClientRouter(
    initialLocation: location,
    membershipRequests: assisted,
    assistedRecovery: assisted,
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

AccessRead<RecoveryCases> casesWith(
  List<Map<String, Object?>> cases, {
  bool accepting = true,
}) => AccessReadOk(
  RecoveryCases.fromJson({'cases': cases, 'accepting': accepting}),
);

Future<void> requestHelp(WidgetTester tester) async {
  await tester.enterText(byKey('help-phone-field'), '+44 7700 900431');
  await tapKey(tester, 'help-start');
  await settle(tester);
}

void main() {
  group('domain', () {
    test('a grant secret is 32 random bytes and its digest is sha256', () {
      final a = GrantSecret.generate();
      final b = GrantSecret.generate();
      expect(a.value, matches(RegExp(r'^arg_[A-Za-z0-9_-]{43}$')));
      expect(a.value, isNot(b.value));
      expect(a.digest, sha256.convert(utf8.encode(a.value)).toString());
      expect(a.digest, matches(RegExp(r'^[0-9a-f]{64}$')));
      expect(a.toString(), isNot(contains(a.value)));
    });

    test('request codes are read as staff type them', () {
      expect(normalizeRequestCode('abcd-2345'), 'ABCD2345');
      expect(looksLikeRequestCode('ABCD 2345'), isTrue);
      expect(looksLikeRequestCode('ABCD 0O1I'), isFalse);
      expect(looksLikeRequestCode('ABC'), isFalse);
    });

    test('the password is checked before the single-use setup is spent', () {
      expect(setupPasswordProblem('short', 'short'), isNotNull);
      expect(setupPasswordProblem('x' * 73, 'x' * 73), isNotNull);
      expect(setupPasswordProblem('long enough', 'long enougH'), isNotNull);
      expect(setupPasswordProblem('long enough', 'long enough'), isNull);
    });

    test('a case parses; reconciliation and in-flight states are derived', () {
      final c = RecoveryCaseItem.fromJson(
        recoveryCaseData(grantState: 'consumed', operationState: 'stuck'),
      );
      expect(c.needsReconciliation, isTrue);
      expect(c.evidence, [
        RecoveryEvidence.knownInPerson,
        RecoveryEvidence.photoId,
      ]);
      expect(
        () => RecoveryCases.fromJson({'cases': 'x', 'accepting': true}),
        throwsFormatException,
      );
    });
  });

  group('real adapter (mock HTTP)', () {
    late List<http.Request> sent;
    SupabaseAssistedRecoveryGateway gateway(
      Map<String, Object?> Function(Map<String, Object?> body) answer, {
      int status = 200,
    }) {
      sent = [];
      return SupabaseAssistedRecoveryGateway(
        supabaseUrl: 'http://127.0.0.1:54321/',
        publishableKey: 'sb_publishable_synthetic',
        httpClient: MockClient((req) async {
          sent.add(req);
          final body = jsonDecode(req.body) as Map<String, Object?>;
          return http.Response(jsonEncode(answer(body)), status);
        }),
      );
    }

    test('request sends the digest only, with the publishable key', () async {
      final g = gateway(
        (_) => {
          'outcome': 'received',
          'request_code': 'ABCD2345',
          'expires_at': '2026-10-07T12:30:00Z',
        },
      );
      final secret = GrantSecret.generate();
      final r = await g.request('+447700900431', secret.digest);
      expect(r, isA<RecoveryRequestReceived>());
      expect((r as RecoveryRequestReceived).requestCode, 'ABCD2345');
      final req = sent.single;
      expect(
        req.url.toString(),
        'http://127.0.0.1:54321/functions/v1/identity-assisted-recovery',
      );
      expect(req.headers['apikey'], 'sb_publishable_synthetic');
      expect(req.headers.containsKey('Authorization'), isFalse);
      expect(jsonDecode(req.body), {
        'action': 'request',
        'phone_username': '+447700900431',
        'grant_digest': secret.digest,
      });
      expect(req.body, isNot(contains(secret.value)));
    });

    test('redeem outcomes map one to one; a 400 is invalid', () async {
      final secret = GrantSecret.generate();
      for (final (wire, expected) in [
        ('succeeded', RedeemOutcome.succeeded),
        ('rejected', RedeemOutcome.rejected),
        ('password_rejected', RedeemOutcome.passwordRejected),
        ('uncertain', RedeemOutcome.uncertain),
        ('unavailable', RedeemOutcome.unavailable),
      ]) {
        final g = gateway((_) => {'outcome': wire});
        expect(
          await g.redeem('+447700900431', secret, 'long enough'),
          expected,
        );
        expect(jsonDecode(sent.single.body), {
          'action': 'redeem',
          'phone_username': '+447700900431',
          'grant_secret': secret.value,
          'password': 'long enough',
        });
      }
      final bad = gateway((_) => {'outcome': 'invalid'}, status: 400);
      expect(
        await bad.redeem('+447700900431', secret, 'long enough'),
        RedeemOutcome.invalid,
      );
    });

    test('no connection is unreachable, never a success', () async {
      final g = SupabaseAssistedRecoveryGateway(
        supabaseUrl: 'http://127.0.0.1:54321',
        publishableKey: 'sb_publishable_synthetic',
        httpClient: MockClient((_) async => throw http.ClientException('x')),
      );
      expect(
        await g.redeem('+447700900431', GrantSecret.generate(), 'long enough'),
        RedeemOutcome.unreachable,
      );
      expect(await g.status('a' * 64), isA<RecoveryStatusFailed>());
    });
  });

  group('mobile: I need help accessing my account', () {
    testWidgets('the sign-in help links to it only where it is enabled', (
      tester,
    ) async {
      await pumpAt(tester, ClientPaths.signIn, account: null);
      await tapKey(tester, 'church-help');
      await settle(tester);
      expect(byKey('account-help-link'), findsOneWidget);
      await tapKey(tester, 'account-help-link');
      await settle(tester);
      expect(byKey('help-phone-field'), findsOneWidget);
      expect(find.text('I need help accessing my account'), findsWidgets);
    });

    testWidgets('staff web (off): no link', (tester) async {
      await pumpAt(tester, ClientPaths.signIn, assisted: false, account: null);
      await tapKey(tester, 'church-help');
      await settle(tester);
      expect(byKey('account-help-link'), findsNothing);
    });

    testWidgets(
      'request shows the code; the password is set with the same secret once',
      (tester) async {
        final h = await pumpAt(tester, ClientPaths.accountHelp, account: null);
        await requestHelp(tester);
        final (phone, digest) = h.assisted.requests.single;
        expect(phone, '+447700900431');
        expect(digest, matches(RegExp(r'^[0-9a-f]{64}$')));
        expect(find.text('ABCD 2345'), findsOneWidget);
        expect(find.textContaining('arg_'), findsNothing);

        h.assisted.statusAnswer = const RecoveryStatus(
          RecoveryGrantState.waiting,
          null,
        );
        await tapKey(tester, 'help-check');
        await settle(tester);
        expect(byKey('help-notice-stillWaiting'), findsOneWidget);
        expect(h.assisted.statusDigests.last, digest);

        h.assisted.statusAnswer = const RecoveryStatus(
          RecoveryGrantState.ready,
          null,
        );
        await tapKey(tester, 'help-check');
        await settle(tester);
        expect(byKey('help-password'), findsOneWidget);

        await tester.enterText(byKey('help-password'), 'Synthetic-new-pw-1');
        await tester.enterText(byKey('help-password-confirm'), 'different!');
        await tapKey(tester, 'help-set-password');
        await settle(tester);
        expect(h.assisted.redeems, isEmpty);
        expect(find.text('The two passwords are different.'), findsOneWidget);

        await tester.enterText(byKey('help-password'), 'Synthetic-new-pw-1');
        await tester.enterText(
          byKey('help-password-confirm'),
          'Synthetic-new-pw-1',
        );
        await tapKey(tester, 'help-set-password');
        await settle(tester);
        final (rPhone, secret, pw) = h.assisted.redeems.single;
        expect(rPhone, '+447700900431');
        expect(secret.digest, digest, reason: 'the secret behind the request');
        expect(pw, 'Synthetic-new-pw-1');
        expect(byKey('help-succeeded'), findsOneWidget);
        expect(find.textContaining('Synthetic-new-pw-1'), findsNothing);

        await tapKey(tester, 'help-sign-in');
        await settle(tester);
        expect(byKey('phone-field'), findsOneWidget);
      },
    );

    for (final (answer, notice) in [
      (RedeemOutcome.rejected, 'rejected'),
      (RedeemOutcome.uncertain, 'uncertain'),
      (RedeemOutcome.passwordRejected, 'passwordRejected'),
    ]) {
      testWidgets('a $notice redemption ends the request', (tester) async {
        final h = await pumpAt(
          tester,
          ClientPaths.accountHelp,
          account: null,
          setUp: (h) => h.assisted.redeemAnswer = answer,
        );
        await requestHelp(tester);
        await tapKey(tester, 'help-check');
        await settle(tester);
        await tester.enterText(byKey('help-password'), 'Synthetic-new-pw-1');
        await tester.enterText(
          byKey('help-password-confirm'),
          'Synthetic-new-pw-1',
        );
        await tapKey(tester, 'help-set-password');
        await settle(tester);
        expect(byKey('help-notice-$notice'), findsOneWidget);
        expect(byKey('help-set-password'), findsNothing);
        await tapKey(tester, 'help-start-over');
        await settle(tester);
        expect(byKey('help-phone-field'), findsOneWidget);
        expect(h.assisted.redeems, hasLength(1));
      });
    }

    testWidgets('no answer to the password step keeps it retryable', (
      tester,
    ) async {
      await pumpAt(
        tester,
        ClientPaths.accountHelp,
        account: null,
        setUp: (h) => h.assisted.redeemAnswer = RedeemOutcome.unreachable,
      );
      await requestHelp(tester);
      await tapKey(tester, 'help-check');
      await settle(tester);
      await tester.enterText(byKey('help-password'), 'Synthetic-new-pw-1');
      await tester.enterText(
        byKey('help-password-confirm'),
        'Synthetic-new-pw-1',
      );
      await tapKey(tester, 'help-set-password');
      await settle(tester);
      expect(byKey('help-notice-redeemUnreachable'), findsOneWidget);
      expect(byKey('help-set-password'), findsOneWidget);
    });

    testWidgets('a refused request says so and keeps the form', (tester) async {
      await pumpAt(
        tester,
        ClientPaths.accountHelp,
        account: null,
        setUp: (h) => h.assisted.requestAnswer =
            const RecoveryRequestNotReceived(RecoveryFailure.rateLimited),
      );
      await requestHelp(tester);
      expect(byKey('help-notice-rateLimited'), findsOneWidget);
      expect(byKey('help-phone-field'), findsOneWidget);
    });

    testWidgets('an invalid number is caught on the phone', (tester) async {
      final h = await pumpAt(tester, ClientPaths.accountHelp, account: null);
      await tester.enterText(byKey('help-phone-field'), '12');
      await tapKey(tester, 'help-start');
      await settle(tester);
      expect(h.assisted.requests, isEmpty);
    });
  });

  group('staff web: recovery cases', () {
    testWidgets('an Admin issues a setup for the code; nothing secret shows', (
      tester,
    ) async {
      final h = await pumpAt(
        tester,
        ClientPaths.adminAccountRecovery,
        setUp: (h) => h.recoveryCases.cases = casesWith([recoveryCaseData()]),
      );
      expect(find.text('SYNTHETIC Ruth Mwale'), findsOneWidget);
      expect(find.text('No setup issued yet'), findsOneWidget);
      await tester.enterText(byKey('recovery-code-$_case'), 'abcd-2345');
      await tapKey(tester, 'recovery-issue-$_case');
      final sent = h.gateway.sent.single;
      expect(sent.function, 'identity_recovery_command');
      expect(sent.wire['command'], 'identity.issue_recovery_grant');
      expect(sent.wire['expected_revision'], 2);
      expect(sent.wire['payload'], {
        'case_id': _case,
        'request_code': 'ABCD2345',
      });
      h.recoveryCases.cases = casesWith([
        recoveryCaseData(grantState: 'issued'),
      ]);
      sent.confirm(recoveryCaseData(grantState: 'issued'), 3);
      await settle(tester);
      expect(byKey('recovery-notice-issued'), findsOneWidget);
      expect(find.textContaining('Setup issued'), findsWidgets);
      expect(find.textContaining('arg_'), findsNothing);
      expect(find.textContaining('ABCD2345'), findsNothing);
    });

    testWidgets('a code from another number is refused with its own notice', (
      tester,
    ) async {
      final h = await pumpAt(
        tester,
        ClientPaths.adminAccountRecovery,
        setUp: (h) => h.recoveryCases.cases = casesWith([recoveryCaseData()]),
      );
      await tester.enterText(byKey('recovery-code-$_case'), 'ABCD2345');
      await tapKey(tester, 'recovery-issue-$_case');
      h.gateway.sent.single.refuse(
        ErrorCode.conflict,
        fieldErrors: {'request_code': 'mismatch'},
      );
      await settle(tester);
      expect(byKey('recovery-notice-codeMismatch'), findsOneWidget);
    });

    testWidgets(
      'an uncertain reset: no new setup, reconcile after an identity check',
      (tester) async {
        final h = await pumpAt(
          tester,
          ClientPaths.adminAccountRecovery,
          setUp: (h) => h.recoveryCases.cases = casesWith([
            recoveryCaseData(
              grantState: 'consumed',
              operationState: 'uncertain',
              held: true,
            ),
          ]),
        );
        expect(byKey('recovery-issue-$_case'), findsNothing);
        expect(
          find.text('Not confirmed: the account is held until you reconcile'),
          findsOneWidget,
        );
        expect(enabled(tester, 'recovery-reconcile-$_case'), isFalse);
        await tapKey(tester, 'recovery-$_case-check-in_person');
        await tapKey(tester, 'recovery-reconcile-$_case');
        final sent = h.gateway.sent.single;
        expect(sent.wire['command'], 'identity.reconcile_recovery_operation');
        expect(sent.wire['payload'], {
          'case_id': _case,
          'identity_check': 'in_person',
        });
      },
    );

    testWidgets('open a case: member, identity check and evidence', (
      tester,
    ) async {
      final h = await pumpAt(
        tester,
        ClientPaths.adminAccountRecovery,
        setUp: (h) {
          h.recoveryCases.cases = casesWith(const []);
          h.review.search = AccessReadOk(
            MemberSearchPage.fromJson({
              'members': [memberRecordData(account: 'app_account')],
              'next': null,
            }),
          );
        },
      );
      expect(byKey('recovery-no-open'), findsOneWidget);
      await tester.enterText(byKey('recovery-search-field'), 'Ruth');
      await tapKey(tester, 'recovery-search');
      await settle(tester);
      await tapKey(tester, 'recovery-pick-$_member');
      await settle(tester);
      expect(enabled(tester, 'recovery-open'), isFalse);
      await tapKey(tester, 'recovery-open-check-in_person');
      await tapKey(tester, 'recovery-evidence-photo_id');
      await tapKey(tester, 'recovery-evidence-church_records');
      await settle(tester);
      expect(enabled(tester, 'recovery-open'), isTrue);
      await tapKey(tester, 'recovery-open');
      final sent = h.gateway.sent.single;
      expect(sent.wire['command'], 'identity.open_recovery_case');
      expect(sent.wire['expected_revision'], isNull);
      expect(sent.wire['payload'], {
        'member_id': _member,
        'identity_check': 'in_person',
        'evidence': ['photo_id', 'church_records'],
      });
    });

    testWidgets('a cancelled case and a non-Admin answer', (tester) async {
      final h = await pumpAt(
        tester,
        ClientPaths.adminAccountRecovery,
        setUp: (h) => h.recoveryCases.cases = casesWith([recoveryCaseData()]),
      );
      await tapKey(tester, 'recovery-cancel-$_case');
      final sent = h.gateway.sent.single;
      expect(sent.wire['command'], 'identity.cancel_recovery_case');
      expect(sent.wire['payload'], {
        'case_id': _case,
        'reason': 'member_withdrew',
      });
      h.recoveryCases.cases = const AccessReadDenied(AccessDenial.notGranted);
      sent.refuse(ErrorCode.forbidden);
      await settle(tester);
      expect(byKey('recovery-denied-notGranted'), findsOneWidget);
      expect(find.text('SYNTHETIC Ruth Mwale'), findsNothing);
    });

    testWidgets('the screen is gated while the Admin\'s own access is in '
        'review', (tester) async {
      await pumpAt(
        tester,
        ClientPaths.adminAccountRecovery,
        setUp: (h) {
          h.grants.myAccess = const AccessReadDenied(
            AccessDenial.reviewRequired,
          );
          h.recoveryCases.cases = casesWith([recoveryCaseData()]);
        },
      );
      expect(byKey('access-review-gate'), findsOneWidget);
      expect(find.text('SYNTHETIC Ruth Mwale'), findsNothing);
      expect(
        accessReviewGatedPaths,
        contains(ClientPaths.adminAccountRecovery),
      );
      expect(accessReviewGatedPaths, isNot(contains(ClientPaths.accountHelp)));
    });
  });
}

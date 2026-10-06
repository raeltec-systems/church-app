import 'package:church_client_core/church_client_core.dart';
import 'package:church_client_core/testing.dart';
import 'package:church_design_system/church_design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

const _a = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const _b = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';

Future<ClientTestHarness> pumpAt(
  WidgetTester tester,
  String location, {
  String? account,
}) async {
  final h = ClientTestHarness(account: account);
  final router = buildClientRouter(
    initialLocation: location,
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
  // Not pumpAndSettle: a loading banner's spinner never settles.
  await tester.pump();
  await tester.pump();
  return h;
}

/// Lets navigation and microtasks finish while a spinner may be showing.
Future<void> settleShort(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Finder byKey(String k) => find.byKey(Key(k));

Future<void> tapKey(WidgetTester tester, String key) async {
  await tester.ensureVisible(byKey(key));
  await tester.tap(byKey(key));
  await tester.pump();
}

/// Picks [isoCode] through the picker's own change callback (the menu itself
/// is Flutter's DropdownButton).
Future<void> chooseCountry(WidgetTester tester, String isoCode) async {
  final country = dialingCountries.firstWhere((c) => c.isoCode == isoCode);
  tester
      .widget<DropdownButton<DialingCountry>>(
        find.byType(DropdownButton<DialingCountry>),
      )
      .onChanged!(country);
  await tester.pump();
  expect(find.text(country.label), findsOneWidget);
}

void main() {
  group('sign-in screen', () {
    testWidgets(
      'phone and password only: no SMS code, resend or verification UI',
      (tester) async {
        await pumpAt(tester, ClientPaths.signIn);
        expect(byKey('phone-field'), findsOneWidget);
        expect(byKey('password-field'), findsOneWidget);
        expect(
          find.text('Zambia (+260)'),
          findsOneWidget,
          reason: 'picker starts at +260',
        );
        for (final banned in [
          'Send code',
          'Resend',
          'Verification code',
          'Enter code',
          'OTP',
        ]) {
          expect(find.textContaining(banned), findsNothing, reason: banned);
        }
        expect(
          find.textContaining('does not verify that you own it'),
          findsOneWidget,
        );
        expect(byKey('forgot-password'), findsOneWidget);
        expect(byKey('church-help'), findsOneWidget);
      },
    );

    testWidgets(
      'password is hidden by default and can be shown with a labelled toggle',
      (tester) async {
        await pumpAt(tester, ClientPaths.signIn);
        TextField pw() => tester.widget<TextField>(byKey('password-field'));
        expect(pw().obscureText, isTrue);
        expect(pw().autofillHints, [AutofillHints.password]);
        expect(find.byTooltip('Show password'), findsOneWidget);
        await tapKey(tester, 'toggle-password');
        expect(pw().obscureText, isFalse);
        expect(find.byTooltip('Hide password'), findsOneWidget);
        expect(tester.widget<TextField>(byKey('phone-field')).autofillHints, [
          AutofillHints.telephoneNumber,
        ]);
      },
    );

    testWidgets(
      'an international number is normalized and signs in, then shows the membership',
      (tester) async {
        final h = await pumpAt(tester, ClientPaths.signIn);
        await tester.enterText(byKey('phone-field'), '+1 (202) 555-0101');
        await tester.enterText(byKey('password-field'), 'Synthetic-pw-1');
        await tapKey(tester, 'submit-button');
        expect(byKey('sign-in-pending'), findsOneWidget);
        expect(h.auth.last.createAccount, isFalse);
        expect(h.auth.last.phoneE164, '+12025550101');
        h.auth.succeed(_a);
        await settleShort(tester);
        expect(find.text('My membership'), findsOneWidget);
        expect(h.memberAccess.calls, 1);
        h.memberAccess.answer(MemberAccessGranted(syntheticMemberSummary()));
        await tester.pumpAndSettle();
        expect(byKey('member-summary'), findsOneWidget);
        expect(find.text('SYNTHETIC Member One'), findsOneWidget);
      },
    );

    testWidgets('create account with a local number and another country code', (
      tester,
    ) async {
      final h = await pumpAt(tester, ClientPaths.createAccount);
      expect(tester.widget<TextField>(byKey('password-field')).autofillHints, [
        AutofillHints.newPassword,
      ]);
      await chooseCountry(tester, 'GB');
      await tester.enterText(byKey('phone-field'), '07700 900123');
      await tester.enterText(byKey('password-field'), 'Synthetic-pw-2');
      await tapKey(tester, 'submit-button');
      expect(h.auth.last.createAccount, isTrue);
      expect(h.auth.last.phoneE164, '+447700900123');
    });

    testWidgets('local validation: nothing is sent', (tester) async {
      final h = await pumpAt(tester, ClientPaths.signIn);
      await tapKey(tester, 'submit-button');
      expect(find.text('Enter your phone number.'), findsOneWidget);
      expect(find.text('Enter your password.'), findsOneWidget);
      await tester.enterText(byKey('phone-field'), '+1 202');
      await tapKey(tester, 'submit-button');
      expect(find.text('This number is too short.'), findsOneWidget);
      expect(h.auth.sent, isEmpty);
    });

    for (final (failure, title) in [
      (AuthFailure.invalidCredentials, "Couldn't sign in"),
      (AuthFailure.rateLimited, 'Too many attempts'),
      (AuthFailure.unreachable, 'No connection'),
      (AuthFailure.unavailable, "Couldn't sign in"),
    ]) {
      testWidgets('sign-in failure $failure keeps input and shows "$title"', (
        tester,
      ) async {
        final h = await pumpAt(tester, ClientPaths.signIn);
        await tester.enterText(byKey('phone-field'), '+12025550101');
        await tester.enterText(byKey('password-field'), 'wrong');
        await tapKey(tester, 'submit-button');
        h.auth.fail(failure);
        await tester.pumpAndSettle();
        expect(byKey('sign-in-failure'), findsOneWidget);
        expect(find.text(title), findsWidgets);
        expect(
          tester.widget<TextField>(byKey('phone-field')).controller!.text,
          '+12025550101',
        );
        expect(h.session.currentAccountId, isNull);
      });
    }

    testWidgets('the credential error never says which part was wrong', (
      tester,
    ) async {
      final h = await pumpAt(tester, ClientPaths.signIn);
      await tester.enterText(byKey('phone-field'), '+12025550199');
      await tester.enterText(byKey('password-field'), 'x');
      await tapKey(tester, 'submit-button');
      h.auth.fail(AuthFailure.invalidCredentials);
      await tester.pumpAndSettle();
      expect(
        find.textContaining('phone number or password is not right'),
        findsOneWidget,
      );
      expect(find.textContaining('no account'), findsNothing);
      expect(find.textContaining('not registered'), findsNothing);
    });

    testWidgets('create account: username in use and weak password', (
      tester,
    ) async {
      final h = await pumpAt(tester, ClientPaths.createAccount);
      await tester.enterText(byKey('phone-field'), '+12025550101');
      await tester.enterText(byKey('password-field'), 'x');
      await tapKey(tester, 'submit-button');
      h.auth.fail(AuthFailure.usernameUnavailable);
      await tester.pumpAndSettle();
      expect(find.text("Couldn't create the account"), findsOneWidget);
      await tester.enterText(byKey('password-field'), 'y');
      await tapKey(tester, 'submit-button');
      h.auth.fail(AuthFailure.weakPassword, reasons: ['length']);
      await tester.pumpAndSettle();
      expect(find.text('Choose a stronger password'), findsOneWidget);
      expect(find.textContaining('Reason: length'), findsOneWidget);
    });

    testWidgets(
      'the form shows the exact international username before submit',
      (tester) async {
        await pumpAt(tester, ClientPaths.signIn);
        expect(
          find.text('For example +260 …, or a local number.'),
          findsOneWidget,
        );
        await tester.enterText(byKey('phone-field'), '12025550101');
        await tester.pump();
        expect(find.text("You'll sign in as +260 12025550101"), findsOneWidget);
        await tester.enterText(byKey('phone-field'), '+1 202 555 0101');
        await tester.pump();
        expect(find.text("You'll sign in as +12025550101"), findsOneWidget);
      },
    );

    testWidgets('help routes explain staff help without SMS', (tester) async {
      await pumpAt(tester, ClientPaths.signIn);
      await tapKey(tester, 'forgot-password');
      expect(byKey('help-panel'), findsOneWidget);
      expect(
        find.textContaining('never ask for, choose or see your password'),
        findsOneWidget,
      );
    });
  });

  group('my membership screen', () {
    testWidgets('signed out: sign-in and create-account routes, no request', (
      tester,
    ) async {
      final h = await pumpAt(tester, ClientPaths.account);
      expect(byKey('go-sign-in'), findsOneWidget);
      expect(byKey('go-create-account'), findsOneWidget);
      expect(h.memberAccess.calls, 0);
      await tapKey(tester, 'go-sign-in');
      await settleShort(tester);
      expect(byKey('phone-field'), findsOneWidget);
    });

    for (final (denial, key, text) in [
      (
        MemberAccessDenial.notLinked,
        'denied-notLinked',
        'No member access yet',
      ),
      (
        MemberAccessDenial.reviewRequired,
        'denied-reviewRequired',
        'Access review required',
      ),
      // Story 2.2: an untrusted session is also ended on this device.
      (
        MemberAccessDenial.untrustedSession,
        'session-ended',
        'Please sign in again',
      ),
      (
        MemberAccessDenial.unavailable,
        'denied-unavailable',
        'Not available yet',
      ),
    ]) {
      testWidgets('server denial $denial shows only a generic state', (
        tester,
      ) async {
        final h = await pumpAt(tester, ClientPaths.account, account: _a);
        h.memberAccess.answer(MemberAccessDenied(denial));
        await tester.pumpAndSettle();
        expect(byKey(key), findsOneWidget);
        expect(find.text(text), findsOneWidget);
        expect(byKey('member-summary'), findsNothing);
      });
    }

    testWidgets('unreachable and malformed answers never show data', (
      tester,
    ) async {
      final h = await pumpAt(tester, ClientPaths.account, account: _a);
      h.memberAccess.answer(const MemberAccessFailed(unreachable: true));
      await tester.pumpAndSettle();
      expect(find.text('No connection'), findsOneWidget);
      await tapKey(tester, 'refresh-summary');
      await tester.pump();
      h.memberAccess.answer(MemberAccessGranted(syntheticMemberSummary()));
      await tester.pumpAndSettle();
      expect(byKey('member-summary'), findsOneWidget);
    });

    testWidgets('sign-out clears the summary and late answers are discarded', (
      tester,
    ) async {
      final h = await pumpAt(tester, ClientPaths.account, account: _a);
      h.memberAccess.answer(MemberAccessGranted(syntheticMemberSummary()));
      await tester.pumpAndSettle();
      expect(find.text('SYNTHETIC Member One'), findsOneWidget);
      await tapKey(tester, 'refresh-summary');
      await tester.pump();
      await tapKey(tester, 'sign-out');
      await settleShort(tester);
      expect(h.auth.signOuts, 1);
      expect(find.text('SYNTHETIC Member One'), findsNothing);
      expect(byKey('account-changed'), findsOneWidget);
      // The refresh started before sign-out answers late: it must not appear.
      h.memberAccess.answer(MemberAccessGranted(syntheticMemberSummary()));
      await tester.pumpAndSettle();
      expect(find.text('SYNTHETIC Member One'), findsNothing);
      expect(byKey('go-sign-in'), findsOneWidget);
    });

    testWidgets(
      'signing in again as the same account replaces a stale denial',
      (tester) async {
        final h = await pumpAt(tester, ClientPaths.account, account: _a);
        h.memberAccess.answer(
          const MemberAccessDenied(MemberAccessDenial.reviewRequired),
        );
        await settleShort(tester);
        expect(byKey('denied-reviewRequired'), findsOneWidget);
        GoRouter.of(tester.element(byKey('refresh-summary')))
            .go(ClientPaths.signIn);
        await settleShort(tester);
        await tester.enterText(byKey('phone-field'), '+12025550101');
        await tester.enterText(byKey('password-field'), 'Synthetic-pw-1');
        await tapKey(tester, 'submit-button');
        h.auth.succeed(_a); // same account id: no account change event
        await settleShort(tester);
        expect(byKey('denied-reviewRequired'), findsNothing);
        expect(h.memberAccess.calls, 2);
        h.memberAccess.answer(MemberAccessGranted(syntheticMemberSummary()));
        await settleShort(tester);
        expect(byKey('member-summary'), findsOneWidget);
      },
    );

    testWidgets('an account switch drops the previous member and reads again', (
      tester,
    ) async {
      final h = await pumpAt(tester, ClientPaths.account, account: _a);
      h.memberAccess.answer(MemberAccessGranted(syntheticMemberSummary()));
      await tester.pumpAndSettle();
      h.session.switchTo(_b);
      await settleShort(tester);
      expect(find.text('SYNTHETIC Member One'), findsNothing);
      expect(byKey('summary-loading'), findsOneWidget);
      h.memberAccess.answer(
        MemberAccessGranted(
          syntheticMemberSummary(
            name: 'SYNTHETIC Member Two',
            phone: '+447700900124',
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('SYNTHETIC Member Two'), findsOneWidget);
      expect(h.memberAccess.calls, 2);
    });
  });
}

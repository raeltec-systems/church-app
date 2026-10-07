import 'package:church_client_core/church_client_core.dart';
import 'package:church_client_core/testing.dart';
import 'package:church_contracts/church_contracts.dart';
import 'package:church_design_system/church_design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _applicant = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';
const _riverside = '00000000-0000-4000-c000-00000000c241';

Future<ClientTestHarness> pumpAt(
  WidgetTester tester,
  String location, {
  String? account = _applicant,
  void Function(ClientTestHarness h)? setUp,
  bool membershipRequests = true,
}) async {
  tester.view.physicalSize = const Size(390, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final h = ClientTestHarness(account: account);
  setUp?.call(h);
  final router = buildClientRouter(
    initialLocation: location,
    shell: (_, _, child) => child,
    membershipRequests: membershipRequests,
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
  await settleShort(tester);
  return h;
}

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

Future<void> fillForm(
  WidgetTester tester, {
  String name = 'SYNTHETIC Applicant',
  required String choiceKey,
}) async {
  await tester.enterText(byKey('full-name-field'), name);
  await tapKey(tester, choiceKey);
}

void main() {
  group('domain', () {
    test('my application parses; church and cell states are separate', () {
      final r = MyApplication.fromJson({
        'application': applicationData(),
        'privacy_notice': {'version': 'draft-2026-10-07', 'draft': true},
        'accepting_applications': true,
      });
      final a = r.application!;
      expect(a.churchStatus, ChurchStatus.awaitingApproval);
      expect(a.cellStatus, CellStatus.requested);
      expect(a.cellChoice.cellId, _riverside);
      expect(a.correctable, isTrue);
      expect(r.privacyNotice.draft, isTrue);
    });

    test('unexpected shapes are failures, never shown as data', () {
      expect(
        () => MembershipApplication.fromJson({
          ...applicationData(),
          'church_status': 'member',
        }),
        throwsFormatException,
      );
      expect(
        () => CellChoice.fromJson({'choice': 'not_sure', 'cell_id': 'x'}),
        throwsFormatException,
      );
      expect(
        () => cellOptionsFromJson({
          'options': [
            {'cell_id': 'x', 'broad_area': 'a', 'revision': 1},
          ],
        }),
        throwsFormatException,
      );
    });

    test('undecided answers carry no cell', () {
      expect(const CellChoice.notSure().toJson(), {'choice': 'not_sure'});
      expect(const CellChoice.notInCell().toJson(), {'choice': 'not_in_cell'});
      expect(
        const CellChoice.cell(cellId: _riverside, cellRevision: 3).toJson(),
        {'choice': 'cell', 'cell_id': _riverside, 'cell_revision': 3},
      );
    });
  });

  group('sign-up continues to the membership request', () {
    testWidgets('Create account on mobile opens the request form', (
      tester,
    ) async {
      final h = await pumpAt(tester, ClientPaths.createAccount, account: null);
      final phone = tester.widget<TextField>(byKey('phone-field'));
      final password = tester.widget<TextField>(byKey('password-field'));
      expect(
        phone.enableInteractiveSelection && password.enableInteractiveSelection,
        isTrue,
        reason: 'paste works in both fields',
      );
      expect(password.autofillHints, [AutofillHints.newPassword]);
      expect(find.textContaining('does not verify that you own it'), findsOne);

      await tester.enterText(byKey('phone-field'), '+1 202 555 0181');
      await tester.enterText(byKey('password-field'), 'Synthetic-password-1');
      await tapKey(tester, 'submit-button');
      expect(h.auth.last.createAccount, isTrue);
      expect(h.auth.last.phoneE164, '+12025550181');
      h.auth.succeed(_applicant);
      await settleShort(tester);

      expect(find.text('Join the church'), findsWidgets);
      expect(byKey('application-form'), findsOneWidget);
      expect(find.text('Which cell group do you belong to?'), findsOneWidget);
      expect(find.text('SYNTHETIC Riverside'), findsOneWidget);
      expect(find.text('SYNTHETIC North side'), findsOneWidget);
      expect(byKey('cell-choice-not_sure'), findsOneWidget);
      expect(byKey('cell-choice-not_in_cell'), findsOneWidget);
      expect(
        find.text('Privacy notice (DRAFT, awaiting church approval)'),
        findsOneWidget,
      );
      expect(byKey('recovery-email-note'), findsOneWidget);
      expect(find.textContaining('Email'), findsWidgets);
      expect(
        find.byWidgetPredicate(
          (w) =>
              w is TextField &&
              (w.decoration?.labelText ?? '').toLowerCase().contains('email'),
        ),
        findsNothing,
        reason: 'no email is collected to join',
      );
    });

    testWidgets('a sign-in (not a new account) still goes to the account', (
      tester,
    ) async {
      final h = await pumpAt(tester, ClientPaths.signIn, account: null);
      await tester.enterText(byKey('phone-field'), '+1 202 555 0181');
      await tester.enterText(byKey('password-field'), 'Synthetic-password-1');
      await tapKey(tester, 'submit-button');
      h.auth.succeed(_applicant);
      await settleShort(tester);
      expect(find.text('My membership'), findsWidgets);
    });
  });

  group('applying', () {
    for (final (key, wire, cellText) in [
      (
        'cell-choice-$_riverside',
        <String, Object?>{
          'choice': 'cell',
          'cell_id': _riverside,
          'cell_revision': 1,
        },
        'Cell requested: SYNTHETIC Riverside (SYNTHETIC North side)',
      ),
      (
        'cell-choice-not_sure',
        <String, Object?>{'choice': 'not_sure'},
        'Cell: not sure yet. The church will follow up.',
      ),
      (
        'cell-choice-not_in_cell',
        <String, Object?>{'choice': 'not_in_cell'},
        'Cell: not in a cell yet. The church will follow up.',
      ),
    ]) {
      testWidgets('submit with ${wire['choice']}: separate church and cell '
          'states', (tester) async {
        final h = await pumpAt(tester, ClientPaths.membership);
        await fillForm(tester, choiceKey: key);
        await tapKey(tester, 'send-application');
        final sent = h.gateway.sent.single;
        expect(sent.function, 'identity_application_command');
        expect(sent.wire['command'], 'identity.submit_application');
        expect(sent.wire.containsKey('expected_revision'), isTrue);
        expect(sent.wire['expected_revision'], isNull);
        expect(sent.wire['payload'], {
          'full_name': 'SYNTHETIC Applicant',
          'cell_choice': wire,
          'privacy_notice_version': 'draft-2026-10-07',
        }, reason: 'never a membership or cell status');
        expect(byKey('application-pending'), findsOneWidget);
        sent.confirm(applicationData(cellChoice: wire), 1);
        await settleShort(tester);
        expect(byKey('application-status'), findsOneWidget);
        expect(find.text('Request sent'), findsOneWidget);
        expect(find.text('Awaiting church approval'), findsOneWidget);
        expect(find.text(cellText), findsOneWidget);
        expect(find.text('Not confirmed yet'), findsOneWidget);
      });
    }

    testWidgets('name and answer are required before anything is sent', (
      tester,
    ) async {
      final h = await pumpAt(tester, ClientPaths.membership);
      await tapKey(tester, 'send-application');
      expect(find.text('Enter your full name.'), findsOneWidget);
      expect(find.text('Choose one answer.'), findsOneWidget);
      expect(h.gateway.sent, isEmpty);
    });

    testWidgets('a cell no longer offered: the list reloads, choose again', (
      tester,
    ) async {
      final h = await pumpAt(tester, ClientPaths.membership);
      await fillForm(tester, choiceKey: 'cell-choice-$_riverside');
      await tapKey(tester, 'send-application');
      final calls = h.membership.calls;
      h.gateway.sent.single.refuse(
        ErrorCode.validationFailed,
        fieldErrors: {'cell_id': 'invalid'},
      );
      await settleShort(tester);
      expect(find.text('The cell list changed'), findsOneWidget);
      expect(find.text('Choose again from the current list.'), findsOneWidget);
      expect(h.membership.calls, greaterThan(calls));
    });

    testWidgets('unknown outcome: Check again resends the same request', (
      tester,
    ) async {
      final h = await pumpAt(tester, ClientPaths.membership);
      await fillForm(tester, choiceKey: 'cell-choice-not_sure');
      await tapKey(tester, 'send-application');
      h.gateway.sent.single.unknown();
      await settleShort(tester);
      expect(find.text('Not confirmed yet'), findsOneWidget);
      await tapKey(tester, 'application-check-again');
      expect(h.gateway.sent, hasLength(2));
      expect(
        h.gateway.sent.last.wire,
        h.gateway.sent.first.wire,
        reason: 'same request_id and body',
      );
    });

    testWidgets('requests not accepted here: no form', (tester) async {
      await pumpAt(
        tester,
        ClientPaths.membership,
        setUp: (h) => h.membership.mine = const AccessReadOk(
          MyApplication(
            application: null,
            privacyNotice: PrivacyNotice(
              version: 'draft-2026-10-07',
              draft: true,
            ),
            accepting: false,
          ),
        ),
      );
      expect(byKey('application-not-accepting'), findsOneWidget);
      expect(byKey('application-form'), findsNothing);
    });

    testWidgets('access review shows only the generic help state', (
      tester,
    ) async {
      await pumpAt(
        tester,
        ClientPaths.membership,
        setUp: (h) => h.membership.mine = const AccessReadDenied(
          AccessDenial.reviewRequired,
        ),
      );
      expect(byKey('application-denied-reviewRequired'), findsOneWidget);
      expect(byKey('application-form'), findsNothing);
      expect(byKey('application-status'), findsNothing);
    });

    testWidgets('signed out: create an account or sign in', (tester) async {
      await pumpAt(tester, ClientPaths.membership, account: null);
      expect(byKey('application-create-account'), findsOneWidget);
      expect(byKey('application-form'), findsNothing);
    });
  });

  group('correcting', () {
    testWidgets('correct the request; status stays separate', (tester) async {
      final h = await pumpAt(
        tester,
        ClientPaths.membership,
        setUp: (h) => h.membership.mine = myApplicationWith(applicationData()),
      );
      expect(find.text('Awaiting church approval'), findsOneWidget);
      await tapKey(tester, 'correct-application');
      expect(
        tester.widget<TextField>(byKey('full-name-field')).controller!.text,
        'SYNTHETIC Applicant',
      );
      await tester.enterText(byKey('full-name-field'), 'SYNTHETIC Corrected');
      await tapKey(tester, 'cell-choice-not_sure');
      await tapKey(tester, 'send-application');
      final sent = h.gateway.sent.single;
      expect(sent.wire['command'], 'identity.correct_application');
      expect(sent.wire['expected_revision'], 1);
      expect(sent.wire['payload'], {
        'application_id': '44444444-4444-4444-8444-444444444444',
        'full_name': 'SYNTHETIC Corrected',
        'cell_choice': {'choice': 'not_sure'},
      });
      sent.confirm(
        applicationData(
          revision: 2,
          name: 'SYNTHETIC Corrected',
          cellChoice: const {'choice': 'not_sure'},
        ),
        2,
      );
      await settleShort(tester);
      expect(find.text('Request updated'), findsOneWidget);
      expect(find.text('SYNTHETIC Corrected'), findsOneWidget);
      expect(
        find.text('Cell: not sure yet. The church will follow up.'),
        findsOneWidget,
      );
      expect(find.text('Awaiting church approval'), findsOneWidget);
    });

    testWidgets('changed elsewhere: conflict reloads the latest request', (
      tester,
    ) async {
      final h = await pumpAt(
        tester,
        ClientPaths.membership,
        setUp: (h) => h.membership.mine = myApplicationWith(applicationData()),
      );
      await tapKey(tester, 'correct-application');
      await tapKey(tester, 'cell-choice-not_in_cell');
      final calls = h.membership.calls;
      h.membership.mine = myApplicationWith(
        applicationData(revision: 3, name: 'SYNTHETIC Elsewhere'),
      );
      await tapKey(tester, 'send-application');
      h.gateway.sent.single.refuse(
        ErrorCode.conflict,
        currentRevision: const Optional.of(3),
      );
      await settleShort(tester);
      expect(find.text('Your request changed'), findsOneWidget);
      expect(h.membership.calls, greaterThan(calls));
      await tapKey(tester, 'cancel-correction');
      expect(find.text('SYNTHETIC Elsewhere'), findsOneWidget);
    });

    testWidgets('details requested: still correctable', (tester) async {
      await pumpAt(
        tester,
        ClientPaths.membership,
        setUp: (h) => h.membership.mine = myApplicationWith(
          applicationData(churchStatus: 'details_requested'),
        ),
      );
      expect(find.text('The church asked for more details'), findsOneWidget);
      expect(byKey('correct-application'), findsOneWidget);
    });
  });

  testWidgets('staff web: Create account stays on the account page, no link', (
    tester,
  ) async {
    final h = await pumpAt(
      tester,
      ClientPaths.createAccount,
      account: null,
      membershipRequests: false,
    );
    await tester.enterText(byKey('phone-field'), '+1 202 555 0181');
    await tester.enterText(byKey('password-field'), 'Synthetic-password-1');
    await tapKey(tester, 'submit-button');
    h.auth.succeed(_applicant);
    await settleShort(tester);
    expect(find.text('My membership'), findsWidgets);
    h.memberAccess.answer(
      const MemberAccessDenied(MemberAccessDenial.notLinked),
    );
    await settleShort(tester);
    expect(byKey('denied-notLinked'), findsOneWidget);
    expect(byKey('go-membership-request'), findsNothing);
  });

  testWidgets('account screen: no member access leads to the request', (
    tester,
  ) async {
    final h = await pumpAt(tester, ClientPaths.account);
    h.memberAccess.answer(
      const MemberAccessDenied(MemberAccessDenial.notLinked),
    );
    await settleShort(tester);
    await tapKey(tester, 'go-membership-request');
    await settleShort(tester);
    expect(byKey('application-form'), findsOneWidget);
  });
}

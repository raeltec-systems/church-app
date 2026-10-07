import 'dart:io';

import 'package:bic_kafue_mobile/app.dart';
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

Future<Harness> pumpMobile(
  WidgetTester tester, {
  Size size = const Size(390, 844),
  ThemeMode themeMode = ThemeMode.light,
  double textScale = 1,
  String location = '/status',
  bool configured = true,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  final h = ClientTestHarness();
  await tester.pumpWidget(
    ProviderScope(
      overrides: h.overrides(configured: configured),
      child: MobileApp(initialLocation: location, themeMode: themeMode),
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

void main() {
  // Each test starts as a fresh app: no input seen yet.
  setUp(FocusVisibility.instance.reset);

  testWidgets(
    'story 2.9: I need help accessing my account, then a private password',
    (tester) async {
      final h = await pumpMobile(
        tester,
        size: const Size(390, 1600),
        location: '/sign-in',
      );
      await tapKey(tester, 'church-help');
      await tester.pump(const Duration(milliseconds: 100));
      await tapKey(tester, 'account-help-link');
      await tester.pump(const Duration(milliseconds: 100));
      await tester.enterText(
        find.byKey(const Key('help-phone-field')),
        '+447700900431',
      );
      await tapKey(tester, 'help-start');
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('ABCD 2345'), findsOneWidget);
      final digest = h.assisted.requests.single.$2;
      await tapKey(tester, 'help-check');
      await tester.pump(const Duration(milliseconds: 100));
      await tester.enterText(
        find.byKey(const Key('help-password')),
        'Synthetic-mobile-1',
      );
      await tester.enterText(
        find.byKey(const Key('help-password-confirm')),
        'Synthetic-mobile-1',
      );
      await tapKey(tester, 'help-set-password');
      await tester.pump(const Duration(milliseconds: 100));
      expect(h.assisted.redeems.single.$2.digest, digest);
      expect(find.byKey(const Key('help-succeeded')), findsOneWidget);
      expect(find.textContaining('arg_'), findsNothing);
    },
  );

  testWidgets(
    'story 2.8: a held session reaches only the generic help screen',
    (tester) async {
      final h = await pumpMobile(
        tester,
        size: const Size(390, 1400),
        location: '/fixture',
      );
      h.grants.myAccess = const AccessReadDenied(AccessDenial.reviewRequired);
      h.memberAccess.next = const MemberAccessDenied(
        MemberAccessDenial.reviewRequired,
      );
      h.credentials.mine = AccessReadOk(
        MyCredentials.fromJson(
          myCredentialsData(
            access: 'review_required',
            canRequest: false,
            pendingChange: credentialChangeData(),
          ),
        ),
      );
      await tapKey(tester, 'nav-/account');
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byKey(const Key('access-review-required')), findsOneWidget);
      expect(
        find.byKey(const Key('access-review-pending-change')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('member-summary')), findsNothing);
      expect(find.byKey(const Key('nav-/my-cell')), findsNothing);
    },
  );

  testWidgets(
    'story 2.8: sign-in details from the account page; a new username goes '
    'to church review, never by SMS',
    (tester) async {
      final h = await pumpMobile(
        tester,
        size: const Size(390, 1600),
        location: '/fixture',
      );
      h.grants.myAccess = AccessReadOk(syntheticGrants());
      h.memberAccess.next = MemberAccessGranted(syntheticMemberSummary());
      await tapKey(tester, 'nav-/account');
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));
      await tapKey(tester, 'go-sign-in-details');
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));
      await tapKey(tester, 'change-kind-phone_username');
      await tester.enterText(
        find.byKey(const Key('new-phone-username-field')),
        '+44 7700 900340',
      );
      await tester.enterText(
        find.byKey(const Key('change-current-password-field')),
        'Synthetic-pw',
      );
      await tapKey(tester, 'send-credential-change');
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));
      final sent = h.gateway.sent.single;
      expect(sent.function, 'identity_credential_command');
      expect(sent.wire['payload'], {
        'change_kind': 'phone_username',
        'phone_username': '+447700900340',
      });
      expect(h.auth.sent, isEmpty);
    },
  );

  testWidgets(
    'story 2.7: the recovery deep link opens a set-password form only, and '
    'the Android manifest accepts only the app scheme under /auth/',
    (tester) async {
      final h = await pumpMobile(
        tester,
        size: const Size(390, 1400),
        location: '/auth/recovery?code=0b5c1a2e-3f4d-4e5f-8a9b-0c1d2e3f4a5b',
      );
      expect(h.recovery.openedCodes, ['0b5c1a2e-3f4d-4e5f-8a9b-0c1d2e3f4a5b']);
      expect(find.byKey(const Key('new-password-field')), findsOneWidget);
      expect(find.byKey(const Key('member-summary')), findsNothing);
      final manifest = File('android/app/src/main/AndroidManifest.xml')
          .readAsStringSync();
      expect(manifest, contains('android:scheme="zm.bickafue.mobile"'));
      expect(manifest, contains('android:host="callback"'));
      expect(manifest, contains('android:pathPrefix="/auth/"'));
      expect(manifest, isNot(contains('android:scheme="http')));
    },
  );

  testWidgets(
    'story 2.5: the applicant sees the church decision, separately from the '
    'cell, and no staff review data',
    (tester) async {
      final h = await pumpMobile(tester, size: const Size(390, 1400));
      h.membership.mine = myApplicationWith({
        ...applicationData(),
        'application_state': 'rejected',
        'church_status': 'not_approved',
        'decision_reason': 'not_known_to_church',
        'reapply_from': '2026-01-01T00:00:00.000000Z',
      });
      GoRouter.of(tester.element(find.byType(Scaffold).first))
          .go('/membership');
      await tester.pumpAndSettle();
      expect(find.text('Not approved'), findsOneWidget);
      expect(find.byKey(const Key('cell-status')), findsOneWidget);
      expect(find.text('The church does not know you yet.'), findsOneWidget);
      expect(find.byKey(const Key('reapply')), findsOneWidget);
      expect(find.textContaining('Possible existing'), findsNothing);
      expect(find.byKey(const Key('nav-/admin/members')), findsNothing);
    },
  );

  testWidgets('tracer read shows in the shell; bottom tabs are named', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await pumpMobile(tester);
    expect(find.text('Status: operational'), findsOneWidget);
    final tab = tester.getSemantics(find.bySemanticsLabel('Status').first);
    expect(tab.role, SemanticsRole.tab);
    final list = tester.getSemantics(find.bySemanticsLabel('App sections'));
    expect(list.role, SemanticsRole.tabBar);
    handle.dispose();
  });

  testWidgets(
    'story 2.1: account tab -> member summary; sign out; phone sign-in again',
    (tester) async {
      final h = await pumpMobile(tester);
      await tapKey(tester, 'nav-/account');
      for (var i = 0; i < 3; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.text('My membership'), findsWidgets);
      h.memberAccess.answer(MemberAccessGranted(syntheticMemberSummary()));
      await tester.pumpAndSettle();
      expect(find.text('SYNTHETIC Member One'), findsOneWidget);
      expect(find.text('Sign-in username: +12025550101'), findsOneWidget);

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
    'story 2.6: My cell follows member access and shows the confirmed cell '
    'separately from church membership',
    (tester) async {
      final h = await pumpMobile(tester, size: const Size(390, 1400));
      expect(find.byKey(const Key('nav-/my-cell')), findsNothing);
      h.grants.myAccess = AccessReadOk(syntheticGrants());
      h.cells.mine = AccessReadOk(
        MyCell.fromJson(
          myCellData(
            primary: {
              'membership_id': '88888888-8888-4888-8888-888888888888',
              'cell_id': syntheticCellOptions.first.cellId,
              'label': 'SYNTHETIC Riverside',
              'broad_area': 'SYNTHETIC North side',
              'since': '2026-10-07T12:00:00.000000Z',
            },
          ),
        ),
      );
      await tapKey(tester, 'nav-/account');
      for (var i = 0; i < 3; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      await tapKey(tester, 'nav-/my-cell');
      for (var i = 0; i < 3; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.text('SYNTHETIC Riverside'), findsOneWidget);
      expect(find.text('Confirmed'), findsOneWidget);
      expect(find.byKey(const Key('nav-/admin/cells')), findsNothing);
    },
  );

  testWidgets(
    'story 2.2: refresh and resume keep the session; a session the server no '
    'longer trusts is ended and its state cleared',
    (tester) async {
      final h = await pumpMobile(tester);
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

  testWidgets(
    'story 2.4: Create account -> membership request -> separate church and '
    'cell status; still no member access',
    (tester) async {
      final h = await pumpMobile(tester, size: const Size(390, 1400));
      await tapKey(tester, 'nav-/account');
      await tester.pump(const Duration(milliseconds: 100));
      h.memberAccess.answer(
        const MemberAccessDenied(MemberAccessDenial.signedOut),
      );
      await tester.pumpAndSettle();
      await tapKey(tester, 'sign-out');
      await tester.pumpAndSettle();
      await tapKey(tester, 'go-create-account');
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('phone-field')),
        '+1 202 555 0182',
      );
      await tester.enterText(
        find.byKey(const Key('password-field')),
        'Synthetic-pw-2',
      );
      await tapKey(tester, 'submit-button');
      expect(h.auth.last.createAccount, isTrue);
      h.auth.succeed('cccccccc-cccc-4ccc-8ccc-cccccccccccc');
      await tester.pumpAndSettle();

      expect(find.text('Join the church'), findsWidgets);
      expect(
        find.byKey(const Key('nav-/access')),
        findsNothing,
        reason: 'an applicant has no access destination',
      );
      await tester.enterText(
        find.byKey(const Key('full-name-field')),
        'SYNTHETIC Applicant Two',
      );
      await tapKey(tester, 'cell-choice-not_in_cell');
      await tapKey(tester, 'privacy-accept');
      await tapKey(tester, 'send-application');
      final sent = h.gateway.sent.single;
      expect(sent.wire['command'], 'identity.submit_application');
      sent.confirm(
        applicationData(
          name: 'SYNTHETIC Applicant Two',
          cellChoice: const {'choice': 'not_in_cell'},
        ),
        1,
      );
      await tester.pumpAndSettle();
      expect(find.text('Awaiting church approval'), findsOneWidget);
      expect(
        find.text('Cell: not in a cell yet. The church will follow up.'),
        findsOneWidget,
      );
    },
  );

  testWidgets('unconfigured build explains itself and does not send commands', (
    tester,
  ) async {
    await pumpMobile(tester, configured: false);
    expect(find.byKey(const Key('missing-config')), findsOneWidget);
    await tapKey(tester, 'nav-/fixture');
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
    final h = await pumpMobile(tester);
    await tapKey(tester, 'nav-/fixture');
    await tester.pumpAndSettle();
    expect(find.text('Fixture command'), findsWidgets);

    await tester.enterText(find.byKey(const Key('intent-key-field')), 'mobile');
    await tapKey(tester, 'create-button');
    expect(find.text('Sending…'), findsOneWidget);
    h.gateway.sent.last.confirm(fixtureCounterData(intentKey: 'mobile'), 1);
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
    'story 2.3: an already signed-in session shows a role granted and then '
    'revoked elsewhere at its next request, without signing in again',
    (tester) async {
      final h = await pumpMobile(tester);
      expect(find.byKey(const Key('nav-/access')), findsNothing);

      h.grants.myAccess = AccessReadOk(syntheticGrants(roles: ['pastor']));
      await tapKey(tester, 'nav-/account');
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));
      await tapKey(tester, 'nav-/access');
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byKey(const Key('my-role-pastor')), findsOneWidget);

      // Revoked on staff web; the app returns to the foreground.
      h.grants.myAccess = AccessReadOk(syntheticGrants(revision: 3));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byKey(const Key('my-role-pastor')), findsNothing);
      expect(find.byKey(const Key('no-roles')), findsOneWidget);
      expect(h.auth.signOuts, 0);
      // No Admin grant screen on mobile (staff web only).
      expect(find.byKey(const Key('nav-/admin/grants')), findsNothing);
    },
  );

  testWidgets('an account switch drops the protected state', (tester) async {
    final h = await pumpMobile(tester, location: '/fixture');
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
      final h = await pumpMobile(tester, location: '/fixture');
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
      await pumpMobile(tester);
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

  testWidgets('keyboard: page actions, then the tabs; Enter navigates', (
    tester,
  ) async {
    await pumpMobile(tester);
    String? navLabel() => FocusManager.instance.primaryFocus?.context
        ?.findAncestorWidgetOfExactType<NavItem>()
        ?.label;
    final seen = <String?>[];
    for (var i = 0; i < 3; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      seen.add(navLabel());
    }
    // Reload (page action), then Status, then Fixture.
    expect(seen, [null, 'Status', 'Fixture']);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('intent-key-field')), findsOneWidget);
    // Focus stays on the selected tab after keyboard navigation.
    expect(navLabel(), 'Fixture');
  });

  for (final (size, mode) in [
    (const Size(390, 844), ThemeMode.light),
    (const Size(360, 640), ThemeMode.dark),
  ]) {
    testWidgets('2x text, $size $mode: both destinations, no overflow', (
      tester,
    ) async {
      await pumpMobile(tester, size: size, textScale: 2, themeMode: mode);
      expect(tester.takeException(), isNull);
      await tapKey(tester, 'nav-/fixture');
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('create-button')), findsOneWidget);
    });
  }

  testWidgets('the bottom safe area is applied once, by the tab bar', (
    tester,
  ) async {
    tester.view.padding = const FakeViewPadding(bottom: 34);
    addTearDown(tester.view.resetPadding);
    await pumpMobile(tester, location: '/fixture');
    final page = tester.element(find.byType(FixtureCommandScreen));
    expect(MediaQuery.paddingOf(page).bottom, 0);
    final bar = tester.getRect(find.bySemanticsLabel('App sections'));
    final screen = tester.getRect(find.byType(FixtureCommandScreen));
    expect(screen.bottom, lessThanOrEqualTo(bar.top + 0.5));
    // The bar sits above the 34 px inset.
    expect(844 - bar.bottom, greaterThanOrEqualTo(34 - 0.5));
  });

  testWidgets(
    'with the keyboard open, the focused sign-in field stays visible',
    (tester) async {
      // Owner device report: typing into the phone or password field left a
      // blank page, because the shell and the page both shrank for the keyboard.
      await pumpMobile(tester, location: '/sign-in');
      for (final key in ['phone-field', 'password-field']) {
        tester.view.viewInsets = const FakeViewPadding(bottom: 336);
        addTearDown(tester.view.resetViewInsets);
        await tester.tap(find.byKey(Key(key)));
        await tester.pumpAndSettle();
        final page = tester.element(find.byType(SignInScreen));
        expect(MediaQuery.viewInsetsOf(page).bottom, 0, reason: key);
        final field = tester.getRect(find.byKey(Key(key)));
        final bar = tester.getRect(find.bySemanticsLabel('App sections'));
        expect(field.height, greaterThan(20), reason: key);
        expect(field.top, greaterThanOrEqualTo(0), reason: key);
        expect(field.bottom, lessThanOrEqualTo(bar.top + 0.5), reason: key);
        expect(bar.bottom, lessThanOrEqualTo(844 - 336 + 0.5), reason: key);
        tester.view.resetViewInsets();
        await tester.pumpAndSettle();
      }
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
      final path = f.path.replaceAll(r'\\', '/');
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
}

import 'dart:io';

import 'package:bic_kafue_staff/app.dart';
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

typedef Harness = ClientTestHarness;

Future<Harness> pumpStaff(
  WidgetTester tester, {
  Size size = const Size(1280, 800),
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
      child: StaffApp(initialLocation: location),
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

  testWidgets('tracer read shows in the shell; sidebar tabs are named', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await pumpStaff(tester);
    expect(find.text('Status: operational'), findsOneWidget);
    expect(find.text('BIC Kafue staff'), findsOneWidget);
    final tab = tester.getSemantics(
      find.bySemanticsLabel('Platform status').first,
    );
    expect(tab.role, SemanticsRole.tab);
    final list = tester.getSemantics(find.bySemanticsLabel('Staff sections'));
    expect(list.role, SemanticsRole.tabBar);
    handle.dispose();
  });

  testWidgets(
    'story 2.1: account tab -> member summary; sign out; phone sign-in again',
    (tester) async {
      final h = await pumpStaff(tester);
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
    'story 2.2: refresh and resume keep the session; a session the server no '
    'longer trusts is ended and its state cleared',
    (tester) async {
      final h = await pumpStaff(tester);
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

  testWidgets('unconfigured build explains itself and does not send commands', (
    tester,
  ) async {
    await pumpStaff(tester, configured: false);
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
    final h = await pumpStaff(tester);
    await tapKey(tester, 'nav-/fixture');
    await tester.pumpAndSettle();
    expect(find.text('Fixture command'), findsWidgets);

    await tester.enterText(
      find.byKey(const Key('intent-key-field')),
      'staff-web',
    );
    await tapKey(tester, 'create-button');
    expect(find.text('Sending…'), findsOneWidget);
    h.gateway.sent.last.confirm(fixtureCounterData(intentKey: 'staff-web'), 1);
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
    'story 2.3: the sidebar follows the server\'s current grants at the next '
    'navigation (grant, then revoke in another tab)',
    (tester) async {
      final h = await pumpStaff(tester);
      expect(find.byKey(const Key('nav-/admin/grants')), findsNothing);
      expect(find.byKey(const Key('nav-/access')), findsNothing);

      // An Admin elsewhere grants Admin; this already open tab sees it at its
      // next protected request (the navigation asks again).
      h.grants.myAccess = AccessReadOk(syntheticGrants(roles: ['admin']));
      await tapKey(tester, 'nav-/account');
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byKey(const Key('nav-/admin/grants')), findsOneWidget);
      expect(find.byKey(const Key('nav-/access')), findsOneWidget);

      // Admin removed elsewhere: the next navigation drops the entry.
      h.grants.myAccess = AccessReadOk(syntheticGrants(revision: 3));
      await tapKey(tester, 'nav-/access');
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byKey(const Key('nav-/admin/grants')), findsNothing);
      expect(find.byKey(const Key('no-roles')), findsOneWidget);
    },
  );

  testWidgets('an account switch drops the protected state', (tester) async {
    final h = await pumpStaff(tester, location: '/fixture');
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
      final h = await pumpStaff(tester, location: '/fixture');
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
      await pumpStaff(tester);
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

  testWidgets('keyboard: Tab reaches the nav tabs first; Enter navigates', (
    tester,
  ) async {
    await pumpStaff(tester);
    String? navLabel() => FocusManager.instance.primaryFocus?.context
        ?.findAncestorWidgetOfExactType<NavItem>()
        ?.label;
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(navLabel(), 'Platform status');
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(navLabel(), 'Fixture command');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('intent-key-field')), findsOneWidget);
    // Focus stays on the selected tab after keyboard navigation.
    expect(navLabel(), 'Fixture command');
  });

  for (final (size, label) in [
    (const Size(1280, 800), 'desktop'),
    (const Size(390, 844), 'narrow'),
  ]) {
    testWidgets('2x text, $label: both destinations render without overflow', (
      tester,
    ) async {
      await pumpStaff(tester, size: size, textScale: 2);
      expect(tester.takeException(), isNull);
      await tapKey(tester, 'nav-/fixture');
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('create-button')), findsOneWidget);
    });
  }

  testWidgets('sidebar at 1x; top bar at 2x text on the same window', (
    tester,
  ) async {
    double dy(String k) => tester.getTopLeft(find.byKey(Key(k))).dy;
    await pumpStaff(tester);
    expect(dy('nav-/fixture'), greaterThan(dy('nav-/status')));
    await pumpStaff(tester, textScale: 2);
    expect(dy('nav-/fixture'), dy('nav-/status'));
  });

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

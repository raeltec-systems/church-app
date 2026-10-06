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

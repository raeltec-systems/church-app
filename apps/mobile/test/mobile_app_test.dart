import 'dart:io';

import 'package:bic_kafue_mobile/app.dart';
import 'package:church_client_core/church_client_core.dart';
import 'package:church_client_core/testing.dart';
import 'package:church_contracts/church_contracts.dart';
import 'package:church_design_system/church_design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _Status implements PlatformStatusRepository {
  @override
  Future<PlatformStatus?> fetch() async => PlatformStatus(
    status: 'operational',
    message: 'SYNTHETIC tracer status',
    isSynthetic: true,
    updatedAt: DateTime.utc(2026, 10, 3, 9, 5),
  );
}

class Harness {
  final gateway = FakeCommandGateway();
  final session = FakeSession('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa');
}

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
  final h = Harness();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        commandGatewayProvider.overrideWithValue(h.gateway),
        sessionRepositoryProvider.overrideWithValue(h.session),
        requestIdsProvider.overrideWithValue(SequentialRequestIds()),
        if (configured)
          platformStatusRepositoryProvider.overrideWithValue(_Status()),
      ],
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

  testWidgets('unconfigured build explains itself and refuses commands', (
    tester,
  ) async {
    await pumpMobile(tester, configured: false);
    expect(find.byKey(const Key('missing-config')), findsOneWidget);
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

  testWidgets('protected state is dropped when leaving and returning', (
    tester,
  ) async {
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

  test('only the composition root imports Supabase; no client persistence', () {
    final files = Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'));
    final sdk = RegExp(
      r'''package:(supabase|supabase_flutter|gotrue|postgrest|http)/''',
    );
    final persistence = RegExp(
      r'''package:(shared_preferences|hive|sqflite|drift|isar|path_provider|flutter_secure_storage)/|dart:html|localStorage|sessionStorage|indexedDB''',
    );
    for (final f in files) {
      final src = f.readAsStringSync();
      if (!f.path.endsWith('main.dart')) {
        expect(sdk.hasMatch(src), isFalse, reason: f.path);
      }
      expect(persistence.hasMatch(src), isFalse, reason: f.path);
    }
    expect(
      File('lib/main.dart').readAsStringSync(),
      contains('persistSession: false'),
    );
  });
}

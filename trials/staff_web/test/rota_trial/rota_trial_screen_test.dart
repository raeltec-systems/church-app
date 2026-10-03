import 'dart:ui' show CheckedState;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:staff_web_trial/main.dart';
import 'package:staff_web_trial/rota_trial/csv_export.dart';
import 'package:staff_web_trial/rota_trial/rota_fixture.dart';
import 'package:staff_web_trial/rota_trial/rota_trial_screen.dart';

class FakeDownload {
  final calls = <(String, String, String)>[];
  bool result = true;
  bool call(String name, String content, String mime) {
    calls.add((name, content, mime));
    return result;
  }
}

Future<FakeDownload> pumpTrial(
  WidgetTester tester, {
  Size size = const Size(1600, 1100),
  double textScale = 1,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final download = FakeDownload();
  await tester.pumpWidget(
    MaterialApp(
      theme: trialTheme(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: RotaTrialScreen(
        fixture: RotaFixture.synthetic(),
        download: download.call,
      ),
    ),
  );
  return download;
}

String? focused() => FocusManager.instance.primaryFocus?.debugLabel;

Future<void> tabTo(WidgetTester tester, String label) async {
  for (var i = 0; i < 12 && focused() != label; i++) {
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
  }
  expect(focused(), label);
}

void main() {
  testWidgets(
    'grid exposes table, row, column header and labelled slot buttons',
    (tester) async {
      final handle = tester.ensureSemantics();
      await pumpTrial(tester);

      final table = tester.getSemantics(find.byKey(const Key('rota-grid')));
      expect(table.getSemanticsData().role, SemanticsRole.table);

      final roles = <SemanticsRole>{};
      void walk(SemanticsNode n) {
        roles.add(n.getSemanticsData().role);
        n.visitChildren((c) {
          walk(c);
          return true;
        });
      }

      walk(table);
      expect(
        roles,
        containsAll([
          SemanticsRole.row,
          SemanticsRole.columnHeader,
          SemanticsRole.cell,
        ]),
      );

      final slot = tester.getSemantics(
        find.bySemanticsLabel(RegExp(r'^Main door, Sun 4 Oct: .+, Confirmed$')),
      );
      expect(slot.getSemanticsData().flagsCollection.isButton, isTrue);
      final grid = tester
          .getSemantics(find.bySemanticsLabel('Grid'))
          .getSemanticsData()
          .flagsCollection;
      expect(grid.isInMutuallyExclusiveGroup, isTrue);
      expect(grid.isChecked, CheckedState.isTrue);
      handle.dispose();
    },
  );

  testWidgets(
    'arrow, Home/End and Control keys move a roving focus; Tab leaves',
    (tester) async {
      await pumpTrial(tester);
      await tabTo(tester, 'slot 0,0');

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();
      expect(focused(), 'slot 0,0', reason: 'stops at the left edge');
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pump();
      expect(focused(), 'slot 0,0', reason: 'stops at the top edge');

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(focused(), 'slot 0,1');
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(focused(), 'slot 1,1');
      await tester.sendKeyEvent(LogicalKeyboardKey.end);
      await tester.pump();
      expect(focused(), 'slot 1,7');
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.end);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      expect(focused(), 'slot 5,7');
      await tester.sendKeyEvent(LogicalKeyboardKey.home);
      await tester.pump();
      expect(focused(), 'slot 5,0');

      // Tab leaves the grid (one tab stop), Shift+Tab returns to the active slot.
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(focused(), isNot(startsWith('slot ')));
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pump();
      expect(focused(), 'slot 5,0');
    },
  );

  testWidgets(
    'Enter opens the slot; a saved status shows in grid and is announced',
    (tester) async {
      final announced = <String>[];
      tester.binding.defaultBinaryMessenger.setMockDecodedMessageHandler<
        dynamic
      >(SystemChannels.accessibility, (message) async {
        final data = (message as Map)['data'] as Map;
        if (data['message'] != null) announced.add(data['message'] as String);
        return null;
      });
      addTearDown(
        () => tester.binding.defaultBinaryMessenger
            .setMockDecodedMessageHandler<dynamic>(
              SystemChannels.accessibility,
              null,
            ),
      );
      await pumpTrial(tester);
      await tabTo(tester, 'slot 0,0');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(find.text('Main door — Sun 4 Oct'), findsOneWidget);

      await tester.tap(find.byKey(const Key('slot-status')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Declined').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('slot-save')));
      await tester.pumpAndSettle();

      expect(
        find.bySemanticsLabel(RegExp(r'^Main door, Sun 4 Oct: .+, Declined$')),
        findsOneWidget,
      );
      expect(
        tester.widget<Text>(find.byKey(const Key('announcement'))).data,
        startsWith('Saved. Main door, Sun 4 Oct'),
      );
      expect(focused(), 'slot 0,0', reason: 'focus returns to the slot');
      await tester.pump(kAnnouncementDelay);

      // The list view and the export show the same edited state.
      await tester.tap(find.text('List'));
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byKey(const Key('list-0-0')),
          matching: find.text('Declined'),
        ),
        findsOneWidget,
      );
      expect(announced, [
        matches(RegExp(r'^Saved\. Main door, Sun 4 Oct: .+, Declined\.$')),
      ]);
    },
  );

  testWidgets('keyboard moves scroll the focused slot into view', (
    tester,
  ) async {
    await pumpTrial(tester, size: const Size(700, 900));
    await tabTo(tester, 'slot 0,0');
    await tester.sendKeyEvent(LogicalKeyboardKey.end);
    await tester.pumpAndSettle();
    expect(focused(), 'slot 0,7');
    final rect = tester.getRect(
      find.bySemanticsLabel(RegExp(r'^Main door, Sun 22 Nov: ')),
    );
    expect(rect.left, greaterThanOrEqualTo(0));
    expect(rect.right, lessThanOrEqualTo(700));
  });

  testWidgets('Cancel leaves the slot unchanged', (tester) async {
    await pumpTrial(tester);
    final before = find.bySemanticsLabel(RegExp(r'^Main door, Sun 4 Oct: '));
    final label = tester.getSemantics(before).label;
    await tester.tap(before);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(tester.getSemantics(before).label, label);
  });

  testWidgets('the list view shows every slot with a labelled Change button', (
    tester,
  ) async {
    await pumpTrial(tester);
    await tester.tap(find.text('List'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('rota-list')), findsOneWidget);
    expect(find.byKey(const Key('rota-grid')), findsNothing);
    expect(find.text('Change'), findsNWidgets(48));
    expect(find.bySemanticsLabel('Change Parking, Sun 22 Nov'), findsOneWidget);
  });

  testWidgets(
    'a filter that matches nothing shows a message and blocks export',
    (tester) async {
      await pumpTrial(tester);
      await tester.enterText(find.byKey(const Key('position-filter')), 'zzz');
      await tester.pump();
      expect(find.byKey(const Key('empty-filter')), findsOneWidget);
      expect(find.byKey(const Key('export-blocked-reason')), findsOneWidget);
      final button = tester.widget<ButtonStyleButton>(
        find.byKey(const Key('export-button')),
      );
      expect(button.onPressed, isNull);
    },
  );

  testWidgets(
    'export previews scope and downloads the filtered allowlisted CSV',
    (tester) async {
      final download = await pumpTrial(tester);
      await tester.enterText(find.byKey(const Key('position-filter')), 'door');
      await tester.pump();
      await tester.tap(find.byKey(const Key('export-button')));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Scope: 3 positions × 8 Sundays = 24 rows'),
        findsOneWidget,
      );
      expect(
        find.text('Not included: phone numbers and care notes.'),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('export-download')));
      await tester.pumpAndSettle();

      final (name, content, mime) = download.calls.single;
      expect(name, kCsvFilename);
      expect(mime, 'text/csv;charset=utf-8');
      final fixture = RotaFixture.synthetic();
      final doorSlots = [
        for (final row in fixture.slots)
          if (row.first.position.toLowerCase().contains('door')) ...row,
      ];
      expect(content, buildRotaCsv(doorSlots, fixture.memberById));
      expect(
        tester.widget<Text>(find.byKey(const Key('announcement'))).data,
        'Downloaded $kCsvFilename with 24 rows.',
      );
    },
  );

  testWidgets('a failed download is reported, not claimed', (tester) async {
    final download = await pumpTrial(tester);
    download.result = false;
    await tester.tap(find.byKey(const Key('export-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('export-download')));
    await tester.pumpAndSettle();
    expect(
      tester.widget<Text>(find.byKey(const Key('announcement'))).data,
      startsWith('The download did not start'),
    );
  });

  for (final view in ['Grid', 'List']) {
    testWidgets('$view view lays out at 200% text on a narrow window', (
      tester,
    ) async {
      await pumpTrial(tester, size: const Size(640, 900), textScale: 2);
      await tester.tap(find.text(view));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('shell opens on the rota trial and reaches the tracer tab', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MainApp(
        home: TrialShell(
          rota: RotaTrialScreen(fixture: RotaFixture.synthetic()),
          status: const MissingConfigScreen(),
        ),
      ),
    );
    expect(find.text('Duty rotas'), findsOneWidget);
    await tester.tap(find.text('Platform status'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('Platform status not configured'),
      findsOneWidget,
    );
  });
}

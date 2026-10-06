import 'dart:convert';
import 'dart:io';
import 'dart:ui' show CheckedState;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:staff_web_trial/main.dart';
import 'package:staff_web_trial/rota_trial/csv_export.dart';
import 'package:staff_web_trial/rota_trial/rota_fixture.dart';
import 'package:staff_web_trial/rota_trial/rota_trial_screen.dart';

/// Golden CSV shared with the browser harness: position filter "door",
/// status filter "all", after editing Main door / Sun 4 Oct to Declined.
const goldenPath = 'test/rota_trial/golden/door-export-after-edit.csv';

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

Future<void> key(WidgetTester tester, LogicalKeyboardKey k) async {
  await tester.sendKeyEvent(k);
  await tester.pumpAndSettle();
}

Future<void> tabTo(WidgetTester tester, String label) async {
  for (var i = 0; i < 12 && focused() != label; i++) {
    await key(tester, LogicalKeyboardKey.tab);
  }
  expect(focused(), label);
}

Finder slot(String prefix) => find.bySemanticsLabel(RegExp('^$prefix'));

Future<void> choose(WidgetTester tester, Key field, String option) async {
  await tester.tap(find.byKey(field));
  await tester.pumpAndSettle();
  await tester.tap(find.text(option).last);
  await tester.pumpAndSettle();
}

Future<void> openSlotDialog(WidgetTester tester) async {
  await tabTo(tester, 'slot 0,0');
  await key(tester, LogicalKeyboardKey.enter);
  expect(find.text('Main door — Sun 4 Oct'), findsOneWidget);
}

/// Changes both member and status in the open slot dialog.
Future<void> editMemberAndStatus(WidgetTester tester) async {
  await choose(tester, const Key('slot-member'), 'Test Ruth D');
  await choose(tester, const ValueKey('slot-status-false'), 'Needs contact');
}

/// No visible text is ellipsised or cut at a line limit.
void expectNoTruncatedText(WidgetTester tester) {
  final cut = tester.allRenderObjects
      .whereType<RenderParagraph>()
      .where((p) => p.didExceedMaxLines)
      .map((p) => p.text.toPlainText())
      .toList();
  expect(cut, isEmpty);
}

void main() {
  testWidgets('grid, view toggle and dialogs expose roles and names', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await pumpTrial(tester);

    final table = tester.getSemantics(find.byKey(const Key('rota-grid')));
    expect(table.getSemanticsData().role, SemanticsRole.table);
    expect(table.label, 'Ushering rota: positions by Sunday');
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
    final s = tester.getSemantics(
      slot(r'Main door, Sun 4 Oct: .+, Confirmed$'),
    );
    expect(s.getSemanticsData().flagsCollection.isButton, isTrue);

    final grid = tester
        .getSemantics(find.bySemanticsLabel('Grid'))
        .getSemanticsData()
        .flagsCollection;
    expect(grid.isInMutuallyExclusiveGroup, isTrue);
    expect(grid.isChecked, CheckedState.isTrue);

    await tester.tap(slot('Main door, Sun 4 Oct'));
    await tester.pumpAndSettle();
    final dialog = tester.getSemantics(
      find.bySemanticsLabel('Main door — Sun 4 Oct').first,
    );
    expect(dialog.getSemanticsData().role, SemanticsRole.dialog);
    handle.dispose();
  });

  testWidgets('arrow/Home/End/Control keys move focus and clamp at all edges', (
    tester,
  ) async {
    await pumpTrial(tester);
    await tabTo(tester, 'slot 0,0');
    final moves = <(LogicalKeyboardKey, bool, String, String)>[
      (LogicalKeyboardKey.arrowLeft, false, 'slot 0,0', 'left edge'),
      (LogicalKeyboardKey.arrowUp, false, 'slot 0,0', 'top edge'),
      (LogicalKeyboardKey.arrowRight, false, 'slot 0,1', 'right'),
      (LogicalKeyboardKey.arrowDown, false, 'slot 1,1', 'down'),
      (LogicalKeyboardKey.end, false, 'slot 1,7', 'End'),
      (LogicalKeyboardKey.arrowRight, false, 'slot 1,7', 'right edge'),
      (LogicalKeyboardKey.end, true, 'slot 5,7', 'Control+End'),
      (LogicalKeyboardKey.arrowDown, false, 'slot 5,7', 'bottom edge'),
      (LogicalKeyboardKey.home, false, 'slot 5,0', 'Home'),
      (LogicalKeyboardKey.home, true, 'slot 0,0', 'Control+Home'),
    ];
    for (final (k, ctrl, expected, why) in moves) {
      if (ctrl) await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(k);
      if (ctrl) await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      expect(focused(), expected, reason: why);
    }

    // Tab leaves the grid (one tab stop), Shift+Tab returns to the active slot.
    await key(tester, LogicalKeyboardKey.tab);
    expect(focused(), isNot(startsWith('slot ')));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pumpAndSettle();
    expect(focused(), 'slot 0,0');
  });

  testWidgets('keyboard moves scroll the focused slot into view', (
    tester,
  ) async {
    await pumpTrial(tester, size: const Size(700, 900));
    await tabTo(tester, 'slot 0,0');
    await key(tester, LogicalKeyboardKey.end);
    expect(focused(), 'slot 0,7');
    final rect = tester.getRect(slot('Main door, Sun 22 Nov: '));
    expect(rect.left, greaterThanOrEqualTo(0));
    expect(rect.right, lessThanOrEqualTo(700));
  });

  testWidgets(
    'a saved status shows in grid, list and CSV, and is announced after close',
    (tester) async {
      final announced = <String>[];
      tester.binding.defaultBinaryMessenger
          .setMockDecodedMessageHandler<dynamic>(SystemChannels.accessibility, (
            message,
          ) async {
            final data = (message as Map)['data'] as Map;
            if (data['message'] != null) {
              announced.add(data['message'] as String);
            }
            return null;
          });
      addTearDown(
        () => tester.binding.defaultBinaryMessenger
            .setMockDecodedMessageHandler<dynamic>(
              SystemChannels.accessibility,
              null,
            ),
      );
      final download = await pumpTrial(tester);
      await openSlotDialog(tester);
      await choose(tester, const ValueKey('slot-status-false'), 'Declined');
      await tester.tap(find.byKey(const Key('slot-save')));
      await tester.pumpAndSettle();

      expect(slot(r'Main door, Sun 4 Oct: .+, Declined$'), findsOneWidget);
      expect(focused(), 'slot 0,0', reason: 'focus returns to the slot');
      await tester.pump(kAnnouncementDelay);
      expect(announced, [
        matches(RegExp(r'^Saved\. Main door, Sun 4 Oct: .+, Declined\.$')),
      ]);

      await tester.tap(find.text('List'));
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byKey(const Key('list-0-0')),
          matching: find.text('Declined'),
        ),
        findsOneWidget,
      );

      await tester.enterText(find.byKey(const Key('position-filter')), 'door');
      await tester.pump();
      await tester.tap(find.byKey(const Key('export-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('export-download')));
      await tester.pumpAndSettle();
      final csv = download.calls.single.$2;
      expect(
        csv,
        contains('"2026-10-04","Main door","Test Mwila A","Declined"'),
      );
      // The browser harness compares its download byte-for-byte with this.
      final golden = File(goldenPath);
      if (Platform.environment['UPDATE_GOLDEN'] == '1') {
        golden.writeAsBytesSync(utf8.encode(csv));
      }
      // Compare bytes: decoding as a string would drop the BOM.
      expect(utf8.encode(csv), golden.readAsBytesSync());
    },
  );

  for (final how in ['Cancel', 'Escape']) {
    testWidgets('$how after changing member and status leaves the slot', (
      tester,
    ) async {
      await pumpTrial(tester);
      final before = tester.getSemantics(slot('Main door, Sun 4 Oct')).label;
      await openSlotDialog(tester);
      await editMemberAndStatus(tester);
      if (how == 'Cancel') {
        await tester.tap(find.byKey(const Key('slot-cancel')));
      } else {
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      }
      await tester.pumpAndSettle();
      expect(find.text('Main door — Sun 4 Oct'), findsNothing);
      expect(tester.getSemantics(slot('Main door, Sun 4 Oct')).label, before);
      expect(
        tester.widget<Text>(find.byKey(const Key('announcement'))).data,
        isEmpty,
      );
    });
  }

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

  testWidgets('the status filter narrows grid and list to matching slots', (
    tester,
  ) async {
    await pumpTrial(tester);
    await choose(tester, const Key('status-filter'), 'Unfilled');
    final fixture = RotaFixture.synthetic();
    final unfilled = [
      for (final row in fixture.slots)
        for (final s in row)
          if (s.status == SlotStatus.unfilled) s,
    ];
    expect(unfilled, isNotEmpty);
    expect(
      find.bySemanticsLabel(RegExp(r', Unfilled$')),
      findsNWidgets(unfilled.length),
    );
    expect(find.bySemanticsLabel(RegExp(r', Confirmed$')), findsNothing);
    await tester.tap(find.text('List'));
    await tester.pumpAndSettle();
    expect(find.text('Change'), findsNWidgets(unfilled.length));
  });

  testWidgets('filters that match no slot say so and block export', (
    tester,
  ) async {
    await pumpTrial(tester);
    // Main door has no Draft slot in the fixture.
    await tester.enterText(
      find.byKey(const Key('position-filter')),
      'Main door',
    );
    await tester.pump();
    await choose(tester, const Key('status-filter'), 'Draft');
    expect(find.byKey(const Key('empty-filter')), findsOneWidget);
    expect(find.textContaining('No slots match'), findsOneWidget);
    expect(find.byKey(const Key('export-blocked-reason')), findsOneWidget);
    final button = tester.widget<ButtonStyleButton>(
      find.byKey(const Key('export-button')),
    );
    expect(button.onPressed, isNull);
  });

  testWidgets(
    'export preview states scope, leaks no private field, and downloads',
    (tester) async {
      final download = await pumpTrial(tester);
      await tester.enterText(find.byKey(const Key('position-filter')), 'door');
      await tester.pump();
      await tester.tap(find.byKey(const Key('export-button')));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Scope: 24 rows — positions: matching “door”'),
        findsOneWidget,
      );
      expect(
        find.text('Not included: phone numbers and care notes.'),
        findsOneWidget,
      );
      final preview = tester
          .widget<Text>(find.byKey(const Key('export-preview')))
          .data!;
      expect(preview, isNot(contains('+260')));
      expect(preview, isNot(contains('care note')));
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
        'Download started: $kCsvFilename (24 rows).',
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

  testWidgets('all buttons and fields meet the 44 px target', (tester) async {
    await pumpTrial(tester);
    for (final k in [
      'export-button',
      'view-Grid',
      'view-List',
      'position-filter',
      'status-filter',
    ]) {
      final size = tester.getSize(find.byKey(Key(k)));
      expect(size.height, greaterThanOrEqualTo(kMinTarget), reason: k);
      expect(size.width, greaterThanOrEqualTo(kMinTarget), reason: k);
    }
  });

  for (final view in ['Grid', 'List']) {
    testWidgets(
      '$view view, both dialogs and the member menu fit at 200% text',
      (tester) async {
        await pumpTrial(tester, size: const Size(640, 900), textScale: 2);
        await tester.tap(find.text(view));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expectNoTruncatedText(tester);

        final opener = view == 'Grid'
            ? slot('Main door, Sun 4 Oct')
            : find.text('Change').first;
        await tester.ensureVisible(opener);
        await tester.pumpAndSettle();
        await tester.tap(opener);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expectNoTruncatedText(tester);
        await tester.tap(find.byKey(const Key('slot-member')));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expectNoTruncatedText(tester);
        await tester.tap(find.textContaining('HYPERLINK').last);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expectNoTruncatedText(tester);
        await tester.tap(find.byKey(const Key('slot-cancel')));
        await tester.pumpAndSettle();

        await tester.ensureVisible(find.byKey(const Key('export-button')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('export-button')));
        await tester.pumpAndSettle();
        expect(find.text('Export rota CSV'), findsOneWidget);
        expect(tester.takeException(), isNull);
        expectNoTruncatedText(tester);
      },
    );
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

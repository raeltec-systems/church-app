// The shared staff web pieces of the redesign: filter pills with counts, the
// table rows and header, the progress bar and the confirmation dialog.
import 'package:church_design_system/church_design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _host(Widget child, {double width = 1000}) => MaterialApp(
  theme: churchStaffTheme(),
  home: Scaffold(
    body: Center(
      child: SizedBox(width: width, child: child),
    ),
  ),
);

void main() {
  testWidgets('filter pills: counts, one checked, a 44 px target each', (
    tester,
  ) async {
    var chosen = 'all';
    await tester.pumpWidget(
      StatefulBuilder(
        builder: (context, setState) => _host(
          StaffFilterPills<String>(
            label: 'Show',
            selected: chosen,
            onChanged: (v) => setState(() => chosen = v),
            options: const [
              StaffFilterOption('all', 'All', count: 12, key: Key('f-all')),
              StaffFilterOption(
                'unfilled',
                'Unfilled',
                count: 0,
                key: Key('f-unfilled'),
              ),
            ],
          ),
        ),
      ),
    );
    expect(find.text('All'), findsOneWidget);
    expect(find.text('12'), findsOneWidget);
    // A real zero is printed.
    expect(find.text('0'), findsOneWidget);
    expect(
      tester.getSize(find.byKey(const Key('f-all'))).height,
      greaterThanOrEqualTo(ChurchGeometry.minTarget),
    );
    expect(
      tester.getSemantics(find.byKey(const Key('f-all'))),
      matchesSemantics(
        label: 'All, 12',
        isButton: true,
        hasCheckedState: true,
        isChecked: true,
        isInMutuallyExclusiveGroup: true,
        hasEnabledState: true,
        isEnabled: true,
        hasTapAction: true,
        isFocusable: true,
        hasFocusAction: true,
      ),
    );
    await tester.tap(find.byKey(const Key('f-unfilled')));
    await tester.pump();
    expect(chosen, 'unfilled');
  });

  testWidgets('filter pills scroll sideways in one row on a phone', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        width: 360,
        StaffFilterPills<int>(
          label: 'Show',
          selected: 0,
          onChanged: (_) {},
          options: [
            for (var i = 0; i < 7; i++)
              StaffFilterOption(i, 'Needs contact $i', count: i),
          ],
        ),
      ),
    );
    expect(find.byType(SingleChildScrollView), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a table header is grey sentence case; numbers end right', (
    tester,
  ) async {
    const cols = [
      StaffColumn('Position', flex: 3),
      StaffColumn('Confirmed', width: 120, numeric: true),
    ];
    await tester.pumpWidget(
      _host(
        const StaffTableFrame(
          children: [
            StaffTableHeader(columns: cols),
            StaffTableRow(
              divider: false,
              child: StaffColumnsRow(
                columns: cols,
                cells: [Text('Side door'), Text('3 of 4')],
              ),
            ),
          ],
        ),
      ),
    );
    final head = tester.widget<Text>(find.text('Confirmed'));
    expect(head.style!.fontSize, 12);
    expect(head.textAlign, TextAlign.end);
    final headRight = tester.getTopRight(find.text('Confirmed')).dx;
    final cellRight = tester.getTopRight(find.text('3 of 4')).dx;
    expect((headRight - cellRight).abs(), lessThan(1));
  });

  testWidgets('a progress bar has no stub at zero', (tester) async {
    await tester.pumpWidget(_host(const StaffProgressBar(value: 0, max: 10)));
    expect(find.byType(FractionallySizedBox), findsNothing);
    await tester.pumpWidget(_host(const StaffProgressBar(value: 6, max: 10)));
    final f = tester.widget<FractionallySizedBox>(
      find.byType(FractionallySizedBox),
    );
    expect(f.widthFactor, 0.6);
  });

  testWidgets('confirmation names the action and waits for an answer', (
    tester,
  ) async {
    bool? answer;
    String? reason;
    await tester.pumpWidget(
      _host(
        Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              answer = await confirmStaffAction(
                context,
                title: 'Deactivate Grace Banda\'s membership?',
                message: 'Every device of Grace Banda is signed out.',
                confirmLabel: 'Deactivate membership',
                canConfirm: () => reason != null,
                extra: (context, setState) => TextButton(
                  key: const Key('pick'),
                  onPressed: () => setState(() => reason = 'moved'),
                  child: const Text('Moved away'),
                ),
              );
            },
            child: const Text('Open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(find.text('Deactivate Grace Banda\'s membership?'), findsOneWidget);
    final confirm = find.byKey(const Key('confirm-action'));
    expect(tester.widget<FilledButton>(confirm).onPressed, isNull);
    await tester.tap(find.byKey(const Key('pick')));
    await tester.pump();
    expect(tester.widget<FilledButton>(confirm).onPressed, isNotNull);
    await tester.tap(find.byKey(const Key('confirm-cancel')));
    await tester.pumpAndSettle();
    expect(answer, isFalse);

    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirm-action')));
    await tester.pumpAndSettle();
    expect(answer, isTrue);
  });
}

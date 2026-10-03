import 'dart:math' as math;
import 'dart:ui' show CheckedState, Tristate;

import 'package:church_design_system/church_design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

double _luminance(Color c) {
  double ch(double v) =>
      v <= 0.03928 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
  return 0.2126 * ch(c.r) + 0.7152 * ch(c.g) + 0.0722 * ch(c.b);
}

double contrast(Color a, Color b) {
  final la = _luminance(a), lb = _luminance(b);
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
}

Widget _host(Widget child, {ThemeData? theme, double textScale = 1}) =>
    MaterialApp(
      theme: theme ?? churchStaffTheme(),
      home: MediaQuery(
        data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
        child: Scaffold(body: Center(child: child)),
      ),
    );

/// Whether the [FocusRing] around the control labelled [label] is drawn.
bool ringShown(WidgetTester tester, String label) {
  final ring = find.ancestor(
    of: find.text(label),
    matching: find.byType(FocusRing),
  );
  final box = tester.widget<Container>(
    find.descendant(of: ring, matching: find.byType(Container)).first,
  );
  final border = (box.decoration! as BoxDecoration).border! as Border;
  return border.top.color != Colors.transparent;
}

void main() {
  group('tokens', () {
    for (final (name, c) in [
      ('light', ChurchColors.light),
      ('dark', ChurchColors.dark),
    ]) {
      test('$name text pairs meet 4.5:1', () {
        final pairs = {
          'ink/bg': (c.ink, c.bg),
          'ink/surface': (c.ink, c.surface),
          'muted/surface': (c.muted, c.surface),
          'muted/bg': (c.muted, c.bg),
          'brand/bg': (c.brand, c.bg),
          'link/surface': (c.link, c.surface),
          'amber': (c.amberFg, c.amberBg),
          'green': (c.greenFg, c.greenBg),
          'red': (c.redFg, c.redBg),
          'blue': (c.blueFg, c.blueBg),
          'gray chip': (c.muted, c.grayBg),
          'ink on red banner': (c.ink, c.redBg),
          'ink on amber banner': (c.ink, c.amberBg),
          'ink on blue banner': (c.ink, c.blueBg),
          'sidebar text': (c.onSidebarMuted, c.sidebar),
        };
        pairs.forEach((k, v) {
          expect(contrast(v.$1, v.$2), greaterThanOrEqualTo(4.5), reason: k);
        });
      });

      test('$name focus ring is >=3:1 against bg and surface', () {
        expect(contrast(c.focus, c.bg), greaterThanOrEqualTo(3));
        expect(contrast(c.focus, c.surface), greaterThanOrEqualTo(3));
        expect(contrast(c.onSidebar, c.sidebar), greaterThanOrEqualTo(3));
      });
    }

    test('design-contract values are carried verbatim', () {
      expect(ChurchColors.light.bg, const Color(0xFFF4F6FA));
      expect(ChurchColors.dark.bg, const Color(0xFF0A0F1E));
      expect(ChurchColors.light.primary, const Color(0xFF14246B));
      expect(ChurchColors.dark.primary, const Color(0xFF2A6FD0));
      expect(ChurchColors.light.accent, const Color(0xFF0A7FE0));
    });

    test('themes expose the tokens; staff is light only', () {
      expect(churchStaffTheme().extension<ChurchColors>(), ChurchColors.light);
      expect(
        churchMobileTheme(Brightness.dark).extension<ChurchColors>(),
        ChurchColors.dark,
      );
      expect(churchMobileTheme(Brightness.dark).brightness, Brightness.dark);
    });
  });

  testWidgets('FocusRing shows a ring only while its control has focus', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        Column(
          children: [
            FocusRing(
              child: TextButton(onPressed: () {}, child: const Text('A')),
            ),
            FocusRing(
              child: TextButton(onPressed: () {}, child: const Text('B')),
            ),
          ],
        ),
      ),
    );
    expect(ringShown(tester, 'A'), isFalse);
    expect(ringShown(tester, 'B'), isFalse);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(ringShown(tester, 'A'), isTrue);
    expect(ringShown(tester, 'B'), isFalse);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(ringShown(tester, 'A'), isFalse);
    expect(ringShown(tester, 'B'), isTrue);
  });

  testWidgets('ChurchDialog is a dialog named by its title', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      _host(
        const ChurchDialog(
          title: 'Change counter',
          content: Text('Body'),
          actions: [],
        ),
      ),
    );
    final node = tester.getSemantics(
      find.bySemanticsLabel('Change counter').first,
    );
    expect(node.role, SemanticsRole.dialog);
    expect(node.flagsCollection.namesRoute, isTrue);
    handle.dispose();
  });

  testWidgets('RadioSegments exposes a named radio group with checked state', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    var value = 'grid';
    await tester.pumpWidget(
      StatefulBuilder(
        builder: (context, setState) => _host(
          RadioSegments<String>(
            label: 'View',
            options: const [
              SegmentOption('grid', 'Grid'),
              SegmentOption('list', 'List'),
            ],
            selected: value,
            onChanged: (v) => setState(() => value = v),
          ),
        ),
      ),
    );
    final group = tester.getSemantics(find.bySemanticsLabel('View'));
    expect(group.role, SemanticsRole.radioGroup);
    SemanticsNode option(String label) =>
        tester.getSemantics(find.bySemanticsLabel(label).first);
    expect(option('Grid').flagsCollection.isChecked, CheckedState.isTrue);
    expect(option('List').flagsCollection.isChecked, CheckedState.isFalse);
    expect(option('List').flagsCollection.isInMutuallyExclusiveGroup, isTrue);
    await tester.tap(find.text('List'));
    await tester.pump();
    expect(value, 'list');
    expect(option('List').flagsCollection.isChecked, CheckedState.isTrue);
    handle.dispose();
  });

  testWidgets('NavItem is a selectable tab with a 44px target', (tester) async {
    final handle = tester.ensureSemantics();
    var taps = 0;
    await tester.pumpWidget(
      _host(
        SizedBox(
          width: 200,
          child: NavItem(
            label: 'Platform status',
            icon: Icons.monitor_heart_outlined,
            selected: true,
            onTap: () => taps++,
          ),
        ),
      ),
    );
    final node = tester.getSemantics(find.bySemanticsLabel('Platform status'));
    expect(node.role, SemanticsRole.tab);
    expect(node.flagsCollection.isSelected, Tristate.isTrue);
    expect(
      tester.getSize(find.byType(InkWell)).height,
      greaterThanOrEqualTo(ChurchGeometry.minTarget),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(taps, 1);
    handle.dispose();
  });

  testWidgets('banner and status label survive 2x text without overflow', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      _host(
        SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const StatusLabel(
                label: 'Not confirmed',
                tone: StatusTone.warning,
              ),
              RequestStateBanner(
                tone: StatusTone.danger,
                title: 'This counter changed since you loaded it',
                message: 'Your change is kept. Reload to see the latest value.',
                actions: [
                  BannerAction('Reload', () {}),
                  BannerAction('Discard', () {}),
                ],
              ),
            ],
          ),
        ),
        theme: churchMobileTheme(Brightness.light),
        textScale: 2,
      ),
    );
    expect(tester.takeException(), isNull);
    for (final e in find.byType(OutlinedButton).evaluate()) {
      expect(
        tester.getSize(find.byWidget(e.widget)).height,
        greaterThanOrEqualTo(ChurchGeometry.minTarget),
      );
    }
  });
}

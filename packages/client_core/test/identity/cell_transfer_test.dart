// Story 5.9: the Admin cells page shows a cell whose last leader left with
// a programme published ahead, and marks the handover done at the cell's
// revision. Scope loss on My cell and Plan meeting is in
// cell_youre_on_test.dart. Fakes only; the server behaviour is covered by
// supabase/tests/cells_transfer_effects_test.sql and
// tools/identity-e2e/cells-transfer.mjs.
import 'package:church_client_core/church_client_core.dart';
import 'package:church_client_core/testing.dart';
import 'package:church_contracts/church_contracts.dart';
import 'package:church_design_system/church_design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _cell = '91919191-9191-4191-8191-919191919191';

Map<String, Object?> cellData({bool pending = true}) => {
  'cell_id': _cell,
  'name': 'SYNTHETIC Shikoswe Cell',
  'broad_area': 'SYNTHETIC Kafue East',
  'signup_label': 'SYNTHETIC Shikoswe',
  'listed': true,
  'signup_revision': 2,
  'cell_state': 'active',
  'is_synthetic': true,
  'revision': 5,
  'leaders': const [],
  'assistants': const [],
  'member_count': 4,
  'handover_pending': pending,
};

Future<ClientTestHarness> pump(
  WidgetTester tester, {
  bool pending = true,
}) async {
  tester.view.physicalSize = const Size(1200, 4000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final h = ClientTestHarness();
  h.cells.admin = AccessReadOk(
    CellAdminOverview.fromJson({
      'cells': [cellData(pending: pending)],
      'requests': const [],
      'members': const [],
    }),
  );
  final router = buildClientRouter(
    initialLocation: ClientPaths.adminCells,
    shell: (_, _, child) => AccessRefresher(child: child),
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: h.overrides(),
      child: MaterialApp.router(
        theme: churchStaffTheme(),
        routerConfig: router,
      ),
    ),
  );
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  return h;
}

void main() {
  testWidgets('a pending handover is shown and marked done at the cell '
      'revision; "still no leader" is said', (tester) async {
    final h = await pump(tester);
    expect(
      tester
          .widget<StatusLabel>(find.byKey(const Key('cell-handover-$_cell')))
          .label,
      'Needs a leader: a programme is published ahead',
    );
    await tester.tap(find.byKey(const Key('cell-handover-done-$_cell')));
    await tester.pump();
    final sent = h.gateway.sent.single;
    expect(sent.wire['command'], 'cells.resolve_handover');
    expect(sent.wire['expected_revision'], 5);
    expect(sent.wire['payload'], {'cell_id': _cell});
    sent.refuse(
      ErrorCode.conflict,
      fieldErrors: {'cell_id': 'leader_required'},
    );
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(
      find.byKey(const Key('cells-notice-leaderRequired')),
      findsOneWidget,
    );
  });

  testWidgets('no handover, no label', (tester) async {
    await pump(tester, pending: false);
    expect(find.byKey(const Key('cell-handover-$_cell')), findsNothing);
  });

  test('an earlier server without the flag reads as no handover', () {
    final c = AdminCell.fromJson({...cellData()}..remove('handover_pending'));
    expect(c.handoverPending, isFalse);
  });
}

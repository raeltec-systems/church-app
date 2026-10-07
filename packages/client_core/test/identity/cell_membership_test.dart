// Story 2.6: cell setup, leader/Admin confirmation and transfer on staff web,
// and the member's own cell on mobile, with honest command states. Fakes
// only; the server behaviour is covered by
// supabase/tests/cell_membership_test.sql and tools/identity-e2e/cells.mjs.
import 'package:church_client_core/church_client_core.dart';
import 'package:church_client_core/testing.dart';
import 'package:church_contracts/church_contracts.dart';
import 'package:church_design_system/church_design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _cellX = '77777777-7777-4777-8777-777777777777';
const _cellY = '7777aaaa-7777-4777-8777-777777777777';
const _request = '88888888-8888-4888-8888-888888888888';
const _lydia = '99999999-9999-4999-8999-999999999999';

Future<ClientTestHarness> pumpAt(
  WidgetTester tester,
  String location, {
  void Function(ClientTestHarness h)? setUp,
}) async {
  tester.view.physicalSize = const Size(1200, 4000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final h = ClientTestHarness();
  setUp?.call(h);
  final router = buildClientRouter(
    initialLocation: location,
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
  await settle(tester);
  return h;
}

Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Finder byKey(String k) => find.byKey(Key(k));

Future<void> tapKey(WidgetTester tester, String key) async {
  await tester.ensureVisible(byKey(key));
  await tester.tap(byKey(key));
  await tester.pump();
}

bool enabled(WidgetTester tester, String key) {
  final w = tester.widget(byKey(key));
  return switch (w) {
    ButtonStyleButton b => b.onPressed != null,
    _ => throw StateError('not a button: $key'),
  };
}

Future<void> choose(
  WidgetTester tester,
  String dropdownKey,
  String text,
) async {
  await tester.ensureVisible(byKey(dropdownKey));
  await tester.tap(byKey(dropdownKey));
  await settle(tester);
  await tester.tap(find.text(text).last);
  await settle(tester);
}

AccessRead<CellAdminOverview> overviewWith({
  List<Map<String, Object?>> cells = const [],
  List<Map<String, Object?>> requests = const [],
  List<Map<String, Object?>> members = const [],
}) => AccessReadOk(
  CellAdminOverview.fromJson({
    'cells': cells,
    'requests': requests,
    'members': members,
  }),
);

AccessRead<LeaderQueue> leaderWith(List<Map<String, Object?>> requests) =>
    AccessReadOk(
      LeaderQueue.fromJson({
        'cells': [
          {
            'cell_id': _cellX,
            'name': 'SYNTHETIC Cell X',
            'broad_area': 'SYNTHETIC North',
            'role': 'leader',
            'members': [
              {
                'member_id': _lydia,
                'display_name': 'SYNTHETIC Lydia',
                'since': '2026-10-07T12:00:00.000000Z',
              },
            ],
            'requests': requests,
          },
        ],
      }),
    );

Map<String, Object?> leaderRequest({
  bool own = false,
  String kind = 'change',
}) => {
  'request_id': _request,
  'member_id': '66666666-6666-4666-8666-666666666666',
  'display_name': 'SYNTHETIC Ruth Mwale',
  'kind': kind,
  'origin': 'member',
  'member_revision': 3,
  'own_record': own,
  'created_at': '2026-10-07T12:00:00.000000Z',
};

void main() {
  group('wire mapping', () {
    test('the member view parses strictly', () {
      final m = MyCell.fromJson(
        myCellData(
          revision: 4,
          primary: {
            'membership_id': _request,
            'cell_id': _cellX,
            'label': 'SYNTHETIC X',
            'broad_area': 'SYNTHETIC North',
            'since': '2026-10-07T12:00:00.000000Z',
          },
          openRequest: {
            'request_id': _request,
            'kind': 'change',
            'origin': 'member',
            'choice': 'cell',
            'state': 'referred',
            'cell_id': _cellY,
            'label': 'SYNTHETIC Y',
            'created_at': '2026-10-07T12:00:00.000000Z',
          },
        ),
      );
      expect(m.revision, 4);
      expect(m.primary!.cellId, _cellX);
      expect(m.openRequest!.referred, isTrue);
      for (final bad in [
        {...myCellData(), 'revision': 0},
        {
          ...myCellData(),
          'open_request': {'request_id': _request, 'kind': 'move'},
        },
        {...myCellData(), 'primary': 'x'},
      ]) {
        expect(() => MyCell.fromJson(bad), throwsFormatException);
      }
    });

    test('the Admin overview and leader queue parse; scopes drive the nav', () {
      final o = CellAdminOverview.fromJson({
        'cells': [adminCellData()],
        'requests': [
          adminCellRequestData(requestedCellId: null, choice: 'not_sure'),
        ],
        'members': [cellMemberRowData()],
      });
      expect(o.requests.single.followUp, isTrue);
      expect(o.cell(_cellX)!.signupRevision, 1);
      expect(
        () => CellAdminOverview.fromJson({
          'cells': [
            {...adminCellData(), 'cell_state': 'gone'},
          ],
          'requests': const [],
          'members': const [],
        }),
        throwsFormatException,
      );
      expect(
        (leaderWith(
          [leaderRequest()],
        ) as AccessReadOk<LeaderQueue>).value.cells.single.requests.single.kind,
        'change',
      );
      expect(
        servesACell(
          syntheticGrants(
            scopes: const [
              ScopeGrant(scopeKind: 'cell_assistant', scopeId: _cellX),
            ],
          ),
        ),
        isTrue,
      );
      expect(servesACell(syntheticGrants(roles: const ['admin'])), isFalse);
      expect(servesACell(null), isFalse);
    });
  });

  group('staff web: Admin cells', () {
    testWidgets('adds a cell with its safe sign-up label', (tester) async {
      final h = await pumpAt(
        tester,
        ClientPaths.adminCells,
        setUp: (h) => h.cells.admin = overviewWith(),
      );
      expect(h.cells.adminCalls, 1);
      expect(enabled(tester, 'create-cell-save'), isFalse);
      await tester.enterText(byKey('create-cell-name'), ' SYNTHETIC Cell X ');
      await tester.enterText(byKey('create-cell-label'), 'SYNTHETIC X');
      await tester.enterText(byKey('create-cell-area'), 'SYNTHETIC North');
      await tester.pump();
      await tapKey(tester, 'create-cell-save');
      final sent = h.gateway.sent.single;
      expect(sent.function, 'cells_command');
      expect(sent.wire['command'], 'cells.create_cell');
      expect(sent.wire['expected_revision'], isNull);
      expect(sent.wire['payload'], {
        'name': 'SYNTHETIC Cell X',
        'signup_label': 'SYNTHETIC X',
        'broad_area': 'SYNTHETIC North',
      });
      sent.refuse(
        ErrorCode.validationFailed,
        fieldErrors: const {'name': 'invalid'},
      );
      await settle(tester);
      expect(byKey('cells-notice-invalid'), findsOneWidget);
      expect(find.textContaining('start with "SYNTHETIC "'), findsOneWidget);
    });

    testWidgets(
      'a leader is an Identity scope grant with the member\'s grant revision',
      (tester) async {
        final h = await pumpAt(
          tester,
          ClientPaths.adminCells,
          setUp: (h) => h.cells.admin = overviewWith(
            cells: [adminCellData()],
            members: [cellMemberRowData()],
          ),
        );
        expect(enabled(tester, 'assign-staff-$_cellX'), isFalse);
        await choose(tester, 'staff-member-$_cellX', 'SYNTHETIC Leader Lydia');
        await tapKey(tester, 'assign-staff-$_cellX');
        final sent = h.gateway.sent.single;
        expect(sent.function, 'identity_grant_command');
        expect(sent.wire['command'], 'identity.grant_scope');
        expect(sent.wire['expected_revision'], 3);
        expect(sent.wire['payload'], {
          'member_id': _lydia,
          'scope_kind': 'cell_leader',
          'scope_id': _cellX,
        });
        final reads = h.grants.myAccessCalls;
        sent.confirm(grantsData(memberId: _lydia), 4);
        await settle(tester);
        expect(byKey('cells-notice-staffAssigned'), findsOneWidget);
        expect(h.cells.adminCalls, 2);
        expect(h.grants.myAccessCalls, greaterThan(reads));
      },
    );

    testWidgets('removing a leader revokes the scope', (tester) async {
      final h = await pumpAt(
        tester,
        ClientPaths.adminCells,
        setUp: (h) => h.cells.admin = overviewWith(
          cells: [
            adminCellData(
              leaders: [
                {
                  'member_id': _lydia,
                  'display_name': 'SYNTHETIC Lydia',
                  'grants_revision': 5,
                },
              ],
            ),
          ],
        ),
      );
      await tapKey(tester, 'remove-cell_leader-$_cellX-$_lydia');
      final sent = h.gateway.sent.single;
      expect(sent.wire['command'], 'identity.revoke_scope');
      expect(sent.wire['expected_revision'], 5);
    });

    testWidgets('a follow-up needs the cell the Admin checked', (tester) async {
      final h = await pumpAt(
        tester,
        ClientPaths.adminCells,
        setUp: (h) => h.cells.admin = overviewWith(
          cells: [adminCellData()],
          requests: [
            adminCellRequestData(choice: 'not_sure', requestedCellId: null),
          ],
        ),
      );
      expect(byKey('admin-request-card-$_request'), findsOneWidget);
      expect(find.text('Follow-up (1)'), findsOneWidget);
      expect(enabled(tester, 'admin-confirm-$_request'), isFalse);
      await choose(tester, 'confirm-cell-$_request', 'SYNTHETIC Cell X');
      await tapKey(tester, 'admin-confirm-$_request');
      final sent = h.gateway.sent.single;
      expect(sent.wire['command'], 'cells.confirm_request');
      expect(sent.wire['expected_revision'], 2);
      expect(sent.wire['payload'], {'request_id': _request, 'cell_id': _cellX});
      sent.unknown();
      await settle(tester);
      expect(byKey('cells-notice-unconfirmed'), findsOneWidget);
      await tapKey(tester, 'cells-check-again');
      expect(h.gateway.sent, hasLength(2));
      expect(h.gateway.sent.last.wire, sent.wire);
      h.gateway.sent.last.confirm(myCellData(), 3);
      await settle(tester);
      expect(byKey('cells-notice-confirmed'), findsOneWidget);
    });

    testWidgets('the Admin\'s own record cannot be decided by them', (
      tester,
    ) async {
      await pumpAt(
        tester,
        ClientPaths.adminCells,
        setUp: (h) => h.cells.admin = overviewWith(
          cells: [adminCellData()],
          requests: [adminCellRequestData(ownRecord: true)],
        ),
      );
      expect(enabled(tester, 'admin-confirm-$_request'), isFalse);
      expect(enabled(tester, 'admin-decline-$_request'), isFalse);
    });

    testWidgets('a non-Admin sees the server\'s denial, not cells', (
      tester,
    ) async {
      await pumpAt(tester, ClientPaths.adminCells);
      expect(byKey('cells-denied-notGranted'), findsOneWidget);
      expect(byKey('create-cell'), findsNothing);
    });
  });

  group('staff web: the leader', () {
    testWidgets('confirms a member moving in with the member revision', (
      tester,
    ) async {
      final h = await pumpAt(
        tester,
        ClientPaths.cellLeader,
        setUp: (h) => h.cells.leader = leaderWith([leaderRequest()]),
      );
      expect(find.text('Moving from another cell'), findsOneWidget);
      expect(byKey('roster-$_cellX-$_lydia'), findsOneWidget);
      await tapKey(tester, 'leader-confirm-$_request');
      final sent = h.gateway.sent.single;
      expect(sent.wire['command'], 'cells.confirm_request');
      expect(sent.wire['expected_revision'], 3);
      expect(sent.wire['payload'], {'request_id': _request});
      sent.refuse(ErrorCode.forbidden);
      await settle(tester);
      expect(byKey('cells-notice-notAllowed'), findsOneWidget);
      expect(h.cells.leaderCalls, 2);
    });

    testWidgets('passes an unknown person to the church office', (
      tester,
    ) async {
      final h = await pumpAt(
        tester,
        ClientPaths.cellLeader,
        setUp: (h) =>
            h.cells.leader = leaderWith([leaderRequest(kind: 'join')]),
      );
      await tapKey(tester, 'leader-refer-$_request');
      final sent = h.gateway.sent.single;
      expect(sent.wire['command'], 'cells.decline_request');
      expect(sent.wire['payload'], {
        'request_id': _request,
        'reason': 'not_known_to_leader',
      });
      sent.confirm(
        myCellData(
          openRequest: {
            'request_id': _request,
            'kind': 'join',
            'origin': 'member',
            'choice': 'cell',
            'state': 'referred',
            'cell_id': _cellX,
            'label': 'SYNTHETIC X',
            'created_at': '2026-10-07T12:00:00.000000Z',
          },
        ),
        4,
      );
      await settle(tester);
      expect(byKey('cells-notice-referred'), findsOneWidget);
    });

    testWidgets('a leader\'s own request is not theirs to confirm', (
      tester,
    ) async {
      await pumpAt(
        tester,
        ClientPaths.cellLeader,
        setUp: (h) => h.cells.leader = leaderWith([leaderRequest(own: true)]),
      );
      expect(enabled(tester, 'leader-confirm-$_request'), isFalse);
      expect(find.text('Your own request'), findsOneWidget);
    });
  });

  group('mobile: my cell', () {
    testWidgets('asks to change cell with the option revision', (tester) async {
      final h = await pumpAt(
        tester,
        ClientPaths.myCell,
        setUp: (h) => h.cells.mine = AccessReadOk(
          MyCell.fromJson(
            myCellData(
              revision: 2,
              primary: {
                'membership_id': _request,
                'cell_id': syntheticCellOptions.first.cellId,
                'label': 'SYNTHETIC Riverside',
                'broad_area': 'SYNTHETIC North side',
                'since': '2026-10-07T12:00:00.000000Z',
              },
            ),
          ),
        ),
      );
      expect(byKey('my-cell-label'), findsOneWidget);
      // The current cell is not offered again.
      expect(
        byKey('my-cell-option-${syntheticCellOptions.first.cellId}'),
        findsNothing,
      );
      expect(enabled(tester, 'my-cell-send'), isFalse);
      final other = syntheticCellOptions[1];
      await tapKey(tester, 'my-cell-option-${other.cellId}');
      await tapKey(tester, 'my-cell-send');
      final sent = h.gateway.sent.single;
      expect(sent.wire['command'], 'cells.request_change');
      expect(sent.wire['expected_revision'], 2);
      expect(sent.wire['payload'], {
        'cell_id': other.cellId,
        'cell_revision': other.revision,
      });
      sent.refuse(
        ErrorCode.conflict,
        fieldErrors: const {'member_id': 'open_request'},
      );
      await settle(tester);
      expect(byKey('cells-notice-openRequest'), findsOneWidget);
    });

    testWidgets('an open request can be cancelled; no change form meanwhile', (
      tester,
    ) async {
      final h = await pumpAt(
        tester,
        ClientPaths.myCell,
        setUp: (h) => h.cells.mine = AccessReadOk(
          MyCell.fromJson(
            myCellData(
              revision: 3,
              openRequest: {
                'request_id': _request,
                'kind': 'join',
                'origin': 'application',
                'choice': 'not_sure',
                'state': 'pending',
                'cell_id': null,
                'label': null,
                'created_at': '2026-10-07T12:00:00.000000Z',
              },
            ),
          ),
        ),
      );
      expect(byKey('my-cell-none'), findsOneWidget);
      expect(find.text('With the church office'), findsOneWidget);
      expect(byKey('my-cell-change'), findsNothing);
      await tapKey(tester, 'my-cell-cancel');
      final sent = h.gateway.sent.single;
      expect(sent.wire['command'], 'cells.cancel_request');
      expect(sent.wire['expected_revision'], 3);
      expect(sent.wire['payload'], {'request_id': _request});
    });

    testWidgets(
      'a failed cell list shows the error and retries, not "no cells"',
      (tester) async {
        final h = await pumpAt(
          tester,
          ClientPaths.myCell,
          setUp: (h) {
            h.cells.mine = AccessReadOk(MyCell.fromJson(myCellData()));
            h.membership.options = const AccessReadFailed(unreachable: true);
          },
        );
        expect(byKey('my-cell-current'), findsOneWidget);
        expect(byKey('my-cell-options-problem'), findsOneWidget);
        expect(find.text('No connection'), findsOneWidget);
        expect(byKey('my-cell-no-options'), findsNothing);
        expect(find.text('No other cells are listed right now.'), findsNothing);
        expect(enabled(tester, 'my-cell-send'), isFalse);
        final reads = h.cells.mineCalls;
        h.membership.options = AccessReadOk(syntheticCellOptions);
        await tapKey(tester, 'my-cell-options-retry');
        await settle(tester);
        expect(h.cells.mineCalls, reads + 1);
        expect(byKey('my-cell-options-problem'), findsNothing);
        expect(
          byKey('my-cell-option-${syntheticCellOptions.first.cellId}'),
          findsOneWidget,
        );
      },
    );

    testWidgets('signing out drops the cell', (tester) async {
      final h = await pumpAt(
        tester,
        ClientPaths.myCell,
        setUp: (h) =>
            h.cells.mine = AccessReadOk(MyCell.fromJson(myCellData())),
      );
      expect(byKey('my-cell-current'), findsOneWidget);
      h.cells.mine = const AccessReadDenied(AccessDenial.signedOut);
      h.session.switchTo(null);
      await settle(tester);
      expect(byKey('my-cell-current'), findsNothing);
      expect(byKey('cells-denied-signedOut'), findsOneWidget);
    });
  });

  test('the cells port defaults to unconfigured', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    expect(c.read(cellsRepositoryProvider), isA<UnconfiguredCellsRepository>());
  });
}

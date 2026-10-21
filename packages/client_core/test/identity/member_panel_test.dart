// Members & applications → All members → a row: the member detail panel.
// Each action calls the same command as its own screen (Roles & access,
// Access reviews, Membership status, this screen's unlink); the destructive
// ones ask first, naming the member and the consequence. Fakes only; the
// server behaviour is covered by the identity SQL tests and E2Es.
import 'package:church_client_core/church_client_core.dart';
import 'package:church_client_core/testing.dart';
import 'package:church_contracts/church_contracts.dart';
import 'package:church_design_system/church_design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _grace = '11111111-1111-4111-8111-111111111111';
const _ruth = '66666666-6666-4666-8666-666666666666';

Finder byKey(String k) => find.byKey(Key(k));

Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> tapKey(WidgetTester tester, String key) async {
  await tester.ensureVisible(byKey(key));
  await tester.tap(byKey(key));
  await settle(tester);
}

/// A button's, or a role pill's, tap target.
Finder _tapTarget(String key) =>
    find.descendant(of: byKey(key), matching: find.byType(InkWell)).first;

bool enabled(WidgetTester tester, String key) {
  final w = tester.widget(byKey(key));
  if (w is ButtonStyleButton) return w.onPressed != null;
  return tester.widget<InkWell>(_tapTarget(key)).onTap != null;
}

Map<String, Object?> _searchPage(List<Map<String, Object?>> members) => {
  'members': members,
  'next': null,
};

Map<String, Object?> _grace0({int revision = 3}) => memberRecordData(
  id: _grace,
  name: 'SYNTHETIC Grace Banda',
  account: 'app_account',
  linkEligible: false,
  revision: revision,
  routes: [
    {'route_id': _grace, 'phone': '+12025550101', 'belongs_to': 'member'},
  ],
);

GrantRoster _roster({List<String> graceRoles = const ['admin']}) => GrantRoster(
  members: [
    RosterMember(
      memberId: _grace,
      displayName: 'SYNTHETIC Grace Banda',
      isSynthetic: true,
      account: AccountStanding.appAccount,
      grants: syntheticGrants(memberId: _grace, revision: 7, roles: graceRoles),
    ),
    RosterMember(
      memberId: _ruth,
      displayName: 'SYNTHETIC Ruth Mwale',
      isSynthetic: true,
      account: AccountStanding.noLogin,
      grants: syntheticGrants(memberId: _ruth, revision: 2),
    ),
  ],
  roles: const [
    RoleOption('admin', available: true),
    RoleOption('pastor', available: true),
    RoleOption('media', available: true),
    RoleOption('lead_pastor', available: false),
  ],
  next: null,
);

/// The Members screen on All members, with Grace (app account, Admin) and
/// Ruth (no login) listed and the roster read.
Future<ClientTestHarness> pumpMembers(
  WidgetTester tester, {
  void Function(ClientTestHarness h)? setUp,
}) async {
  tester.view.physicalSize = const Size(1400, 3000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final h = ClientTestHarness();
  h.review.queue = reviewQueueWith([]);
  h.review.search = AccessReadOk(
    MemberSearchPage.fromJson(_searchPage([_grace0(), memberRecordData()])),
  );
  h.grants.roster = AccessReadOk(_roster());
  setUp?.call(h);
  final router = buildClientRouter(
    initialLocation: ClientPaths.adminMembers,
    membershipRequests: true,
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
  await tester.tap(find.text('All members'));
  await settle(tester);
  return h;
}

void main() {
  testWidgets('a row opens the panel: details, roles from the roster', (
    tester,
  ) async {
    final h = await pumpMembers(tester);
    expect(byKey('member-panel'), findsNothing);
    // The Roles column reads the roster.
    expect(
      find.descendant(
        of: byKey('member-record-$_grace'),
        matching: find.text('Admin'),
      ),
      findsOneWidget,
    );
    await tapKey(tester, 'member-record-$_grace');
    expect(byKey('member-panel'), findsOneWidget);
    expect(
      find.descendant(
        of: byKey('member-panel-details'),
        matching: find.text('App account'),
      ),
      findsOneWidget,
    );
    // Held roles are toggled on for assistive technology, not only filled.
    expect(
      tester.getSemantics(_tapTarget('member-panel-role-admin')),
      containsSemantics(
        label: 'Admin',
        isButton: true,
        hasToggledState: true,
        isToggled: true,
      ),
    );
    expect(
      tester.getSemantics(_tapTarget('member-panel-role-pastor')),
      containsSemantics(
        label: 'Pastor',
        hasToggledState: true,
        isToggled: false,
      ),
    );
    expect(enabled(tester, 'member-panel-role-pastor'), isTrue);
    // Not offered by the church yet: it can't be given here.
    expect(enabled(tester, 'member-panel-role-lead_pastor'), isFalse);
    expect(byKey('member-panel-hold'), findsOneWidget);
    expect(byKey('unlink-$_grace'), findsOneWidget);
    expect(byKey('member-panel-deactivate'), findsOneWidget);
    // Opening the panel sends nothing.
    expect(h.gateway.sent, isEmpty);

    // A member without a login has nothing to hold or unlink.
    await tapKey(tester, 'member-record-$_ruth');
    expect(byKey('member-panel-hold'), findsNothing);
    expect(byKey('unlink-$_ruth'), findsNothing);
    expect(byKey('member-panel-deactivate'), findsOneWidget);
    await tapKey(tester, 'member-panel-close');
    expect(byKey('member-panel'), findsNothing);
  });

  testWidgets('giving a role sends the Roles & access grant command', (
    tester,
  ) async {
    final h = await pumpMembers(tester);
    await tapKey(tester, 'member-record-$_grace');
    await tapKey(tester, 'member-panel-role-pastor');
    // Giving is not destructive: no confirmation.
    expect(byKey('confirm-action'), findsNothing);
    final sent = h.gateway.sent.single;
    expect(sent.function, GrantCommands.function);
    expect(sent.wire['command'], GrantCommands.grantRole);
    expect(sent.wire['expected_revision'], 7);
    expect(sent.wire['payload'], {'member_id': _grace, 'role': 'pastor'});
    expect(byKey('member-panel-pending'), findsOneWidget);
    sent.confirm(
      grantsData(memberId: _grace, revision: 8, roles: ['admin', 'pastor']),
      8,
    );
    await settle(tester);
    expect(byKey('member-panel-notice'), findsOneWidget);
    expect(find.text('Granted'), findsOneWidget);
  });

  testWidgets('removing a role asks first, naming the member', (tester) async {
    final h = await pumpMembers(tester);
    await tapKey(tester, 'member-record-$_grace');
    await tapKey(tester, 'member-panel-role-admin');
    expect(
      find.text('Remove Admin from SYNTHETIC Grace Banda?'),
      findsOneWidget,
    );
    await tapKey(tester, 'confirm-cancel');
    expect(h.gateway.sent, isEmpty);

    await tapKey(tester, 'member-panel-role-admin');
    await tapKey(tester, 'confirm-action');
    final sent = h.gateway.sent.single;
    expect(sent.function, GrantCommands.function);
    expect(sent.wire['command'], GrantCommands.revokeRole);
    expect(sent.wire['payload'], {'member_id': _grace, 'role': 'admin'});
    sent.refuse(
      ErrorCode.forbidden,
      fieldErrors: const {'role': 'unsupported'},
    );
    await settle(tester);
    expect(find.text('The last Admin can\'t be removed'), findsOneWidget);
  });

  testWidgets('an access review hold asks for a reason and names the member', (
    tester,
  ) async {
    final h = await pumpMembers(tester);
    await tapKey(tester, 'member-record-$_grace');
    await tapKey(tester, 'member-panel-hold');
    expect(
      find.text('Place an access review hold on SYNTHETIC Grace Banda?'),
      findsOneWidget,
    );
    expect(
      find.textContaining('Every device of SYNTHETIC Grace Banda'),
      findsOneWidget,
    );
    // The login hold of Membership status is not offered here.
    expect(
      byKey('member-panel-hold-reason-${HoldReason.loginDisabled.wire}'),
      findsNothing,
    );
    expect(enabled(tester, 'confirm-action'), isFalse);
    await tapKey(tester, 'confirm-cancel');
    expect(h.gateway.sent, isEmpty);

    await tapKey(tester, 'member-panel-hold');
    await tapKey(tester, 'member-panel-hold-reason-security_concern');
    expect(enabled(tester, 'confirm-action'), isTrue);
    await tapKey(tester, 'confirm-action');
    final sent = h.gateway.sent.single;
    expect(sent.function, CredentialCommands.function);
    expect(sent.wire['command'], CredentialCommands.placeHold);
    expect(sent.wire['expected_revision'], 3);
    expect(sent.wire['payload'], {
      'member_id': _grace,
      'reason_code': 'security_concern',
    });
    final searches = h.review.searchCalls.length;
    h.review.search = AccessReadOk(
      MemberSearchPage.fromJson(
        _searchPage([
          {..._grace0(revision: 4), 'account': 'access_review'},
          memberRecordData(),
        ]),
      ),
    );
    sent.confirm(const {}, 4);
    await settle(tester);
    expect(find.text('Hold placed'), findsOneWidget);
    // The list is read again: the new standing and revision show.
    expect(h.review.searchCalls.length, searches + 1);
    expect(byKey('member-panel-in-review'), findsOneWidget);
    expect(byKey('member-panel-hold'), findsNothing);
  });

  testWidgets('deactivating asks first, sends the reason, keeps the outcome', (
    tester,
  ) async {
    final h = await pumpMembers(tester);
    await tapKey(tester, 'member-record-$_grace');
    await tapKey(tester, 'member-panel-deactivate');
    expect(
      find.text('Deactivate SYNTHETIC Grace Banda\'s membership?'),
      findsOneWidget,
    );
    expect(find.textContaining('their roles end'), findsOneWidget);
    expect(enabled(tester, 'confirm-action'), isFalse);
    await tapKey(tester, 'member-panel-deactivate-reason-moved_away');
    await tapKey(tester, 'confirm-action');
    final sent = h.gateway.sent.single;
    expect(sent.function, LifecycleCommands.function);
    expect(sent.wire['command'], LifecycleCommands.deactivate);
    expect(sent.wire['expected_revision'], 3);
    expect(sent.wire['payload'], {
      'member_id': _grace,
      'reason_code': 'moved_away',
    });
    h.review.search = AccessReadOk(
      MemberSearchPage.fromJson(_searchPage([memberRecordData()])),
    );
    sent.confirm(const {}, 4);
    await settle(tester);
    expect(find.text('Membership deactivated'), findsOneWidget);
    // No longer listed: the panel keeps the outcome and offers nothing.
    expect(byKey('member-record-$_grace'), findsNothing);
    expect(byKey('member-panel-gone'), findsOneWidget);
    expect(byKey('member-panel-deactivate'), findsNothing);
  });

  testWidgets('an unknown outcome is checked again with the same request', (
    tester,
  ) async {
    final h = await pumpMembers(tester);
    await tapKey(tester, 'member-record-$_grace');
    await tapKey(tester, 'member-panel-deactivate');
    await tapKey(tester, 'member-panel-deactivate-reason-church_decision');
    await tapKey(tester, 'confirm-action');
    h.gateway.sent.single.unknown();
    await settle(tester);
    expect(find.text('Not confirmed yet'), findsOneWidget);
    await tapKey(tester, 'member-panel-check-again');
    expect(h.gateway.sent, hasLength(2));
    expect(
      h.gateway.sent[1].wire['request_id'],
      h.gateway.sent[0].wire['request_id'],
    );
  });

  testWidgets('unlinking asks first, naming the member, with a reason', (
    tester,
  ) async {
    final h = await pumpMembers(tester);
    await tapKey(tester, 'member-record-$_grace');
    await tapKey(tester, 'unlink-$_grace');
    expect(
      find.text('Unlink SYNTHETIC Grace Banda\'s app account?'),
      findsOneWidget,
    );
    expect(byKey('unlink-reason-$_grace'), findsOneWidget);
    await tapKey(tester, 'confirm-cancel');
    expect(h.gateway.sent, isEmpty);
  });

  testWidgets('your own record: no hold, unlink, deactivation or new role', (
    tester,
  ) async {
    await pumpMembers(
      tester,
      setUp: (h) => h.grants.myAccess = AccessReadOk(
        syntheticGrants(memberId: _grace, roles: const ['admin']),
      ),
    );
    await tapKey(tester, 'member-record-$_grace');
    expect(byKey('member-panel-self'), findsOneWidget);
    expect(enabled(tester, 'member-panel-hold'), isFalse);
    expect(enabled(tester, 'unlink-$_grace'), isFalse);
    expect(enabled(tester, 'member-panel-deactivate'), isFalse);
    expect(enabled(tester, 'member-panel-role-pastor'), isFalse);
  });
}

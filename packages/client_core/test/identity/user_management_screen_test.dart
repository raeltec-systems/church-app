import 'package:church_client_core/church_client_core.dart';
import 'package:church_client_core/testing.dart';
import 'package:church_design_system/church_design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

/// Client/widget coverage only: fakes model responses, never evidence that
/// the new commissioning server or full management projection exists.
void main() {
  Future<ClientTestHarness> pump(
    WidgetTester tester, {
    UserManagementArea area = UserManagementArea.members,
    List<String> roles = const ['admin'],
    String? account = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
    double width = 1280,
    double textScale = 1,
    AccessRead<MemberGrants>? access,
  }) async {
    tester.view.physicalSize = Size(width, 1000);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = textScale;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final h = ClientTestHarness(account: account);
    h.grants.myAccess = access ?? AccessReadOk(syntheticGrants(roles: roles));
    h.review.queue = reviewQueueWith([]);
    h.grants.roster = const AccessReadOk(
      GrantRoster(members: [], roles: [], next: null),
    );
    final router = buildClientRouter(
      initialLocation: area.location,
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

  test('only explicit known section names are parsed', () {
    for (final area in UserManagementArea.values) {
      expect(UserManagementArea.parse(area.path), area);
      expect(Uri.parse(area.location).path, '/admin/users');
    }
    expect(
      UserManagementArea.parse('https://untrusted.invalid'),
      UserManagementArea.members,
    );
    expect(UserManagementArea.parse(null), UserManagementArea.members);
  });

  testWidgets('signed out deep link mounts no protected management screen', (
    tester,
  ) async {
    await pump(tester, account: null);
    expect(find.text('Sign in to continue'), findsOneWidget);
    expect(find.byType(MembershipReviewScreen), findsNothing);
    expect(find.byType(GrantAdminScreen), findsNothing);
    expect(find.byKey(const Key('review-sections')), findsNothing);
  });

  for (final roles in <List<String>>[
    [],
    ['media'],
    ['pastor'],
    ['media', 'pastor'],
  ]) {
    testWidgets('roles $roles do not grant user administration', (
      tester,
    ) async {
      await pump(tester, roles: roles);
      expect(find.text('Admin access required'), findsOneWidget);
      expect(find.byType(MembershipReviewScreen), findsNothing);
      expect(find.byType(RecoveryCasesScreen), findsNothing);
    });
  }

  testWidgets('network failure differs from lack of permission', (
    tester,
  ) async {
    await pump(tester, access: const AccessReadFailed(unreachable: true));
    expect(find.text('Could not check access'), findsOneWidget);
    expect(find.text('Admin access required'), findsNothing);
    expect(find.text('Check again'), findsOneWidget);
    expect(find.byType(MembershipReviewScreen), findsNothing);
  });

  testWidgets('default directory enters the real member table section', (
    tester,
  ) async {
    await pump(tester);
    final screen = tester.widget<MembershipReviewScreen>(
      find.byType(MembershipReviewScreen),
    );
    expect(screen.initialSection, MembershipReviewSection.members);
    expect(screen.showSectionSelector, isFalse);
    expect(find.byKey(const Key('review-sections')), findsNothing);
    expect(find.byKey(const Key('member-query')), findsOneWidget);
    expect(find.byKey(const Key('add-member-record')), findsOneWidget);
  });

  for (final (area, child) in <(UserManagementArea, Type)>[
    (UserManagementArea.applications, MembershipReviewScreen),
    (UserManagementArea.roles, GrantAdminScreen),
    (UserManagementArea.accessReviews, CredentialReviewScreen),
    (UserManagementArea.recoveryEmails, RecoveryEmailReviewScreen),
    (UserManagementArea.recovery, RecoveryCasesScreen),
    (UserManagementArea.membership, MembershipLifecycleScreen),
    (UserManagementArea.deletions, MemberDeletionScreen),
    (UserManagementArea.usernames, MembershipReviewScreen),
  ]) {
    testWidgets('${area.label} opens its actual existing workflow', (
      tester,
    ) async {
      await pump(tester, area: area);
      expect(find.byType(child), findsOneWidget);
      expect(find.text('Users & access'), findsOneWidget);
      expect(find.byKey(ValueKey('users-area-${area.path}')), findsOneWidget);
    });
  }

  testWidgets(
    'area selector changes the route and mounts only the selected area',
    (tester) async {
      await pump(tester);
      final selector = tester
          .widget<DropdownButtonFormField<UserManagementArea>>(
            find.byType(DropdownButtonFormField<UserManagementArea>),
          );
      selector.onChanged!(UserManagementArea.roles);
      await tester.pumpAndSettle();
      expect(find.byType(GrantAdminScreen), findsOneWidget);
      expect(find.byType(MembershipReviewScreen), findsNothing);
      final context = tester.element(find.byType(UserManagementScreen));
      expect(
        GoRouter.of(context)
            .routeInformationProvider
            .value
            .uri
            .queryParameters['view'],
        'roles',
      );
    },
  );

  testWidgets('observed revocation removes all management controls', (
    tester,
  ) async {
    final h = await pump(tester);
    expect(find.byType(MembershipReviewScreen), findsOneWidget);
    h.grants.myAccess = AccessReadOk(syntheticGrants(roles: [], revision: 2));
    final context = tester.element(find.byType(UserManagementScreen));
    final container = ProviderScope.containerOf(context, listen: false);
    await container.read(myAccessProvider.notifier).refresh();
    await tester.pumpAndSettle();
    expect(find.byType(MembershipReviewScreen), findsNothing);
    expect(
      find.byType(DropdownButtonFormField<UserManagementArea>),
      findsNothing,
    );
    expect(find.text('Admin access required'), findsOneWidget);
  });

  testWidgets('switching accounts drops the management area', (tester) async {
    final h = await pump(tester, area: UserManagementArea.roles);
    h.grants.myAccess = AccessReadOk(syntheticGrants(roles: []));
    h.session.switchTo('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb');
    await tester.pumpAndSettle();
    expect(find.byType(GrantAdminScreen), findsNothing);
    expect(find.text('Admin access required'), findsOneWidget);
  });

  testWidgets('narrow high-text-scale workspace remains usable', (
    tester,
  ) async {
    await pump(tester, width: 390, textScale: 2);
    expect(
      find.byType(DropdownButtonFormField<UserManagementArea>),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('old member route retains its applications-first navigation', (
    tester,
  ) async {
    await pump(tester);
    GoRouter.of(tester.element(find.byType(UserManagementScreen)))
        .go(ClientPaths.adminMembers);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('review-sections')), findsOneWidget);
    expect(find.text('No applications are waiting.'), findsOneWidget);
    expect(find.byType(UserManagementScreen), findsNothing);
  });
}

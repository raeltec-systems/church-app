import 'dart:io';
import 'dart:ui' as ui;

import 'package:bic_kafue_staff/app.dart';
import 'package:church_client_core/church_client_core.dart';
import 'package:church_client_core/testing.dart';
import 'package:church_design_system/church_design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const person = '66666666-6666-4666-8666-666666666666';

/// Normal widget interactions with the existing app router and fake ports.
/// Optional screenshots are rendering evidence, not hosted/API acceptance.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final captureKey = GlobalKey();
  setUpAll(() async {
    for (final (family, asset) in [
      (
        ChurchFonts.heading,
        'packages/church_design_system/fonts/Outfit-SemiBold.ttf',
      ),
      (
        ChurchFonts.body,
        'packages/church_design_system/fonts/Figtree-Regular.ttf',
      ),
      (
        ChurchFonts.mono,
        'packages/church_design_system/fonts/JetBrainsMono-Regular.ttf',
      ),
      ('MaterialIcons', 'fonts/MaterialIcons-Regular.otf'),
    ]) {
      final loader = FontLoader(family)..addFont(rootBundle.load(asset));
      await loader.load();
    }
  });

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Future<ClientTestHarness> pump(
    WidgetTester tester, {
    bool admin = false,
    bool signedIn = true,
    String location = ClientPaths.overview,
    Size size = const Size(1440, 1000),
    double textScale = 1,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = textScale;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final h = ClientTestHarness(
      account: signedIn ? 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa' : null,
    );
    h.grants.myAccess = AccessReadOk(
      syntheticGrants(roles: admin ? ['admin'] : []),
    );
    h.review.queue = reviewQueueWith([]);
    h.review.search = AccessReadOk(
      MemberSearchPage.fromJson({
        'members': [
          memberRecordData(
            id: person,
            name: 'SYNTHETIC Ruth Mwale',
            account: 'app_account',
          ),
        ],
        'next': null,
      }),
    );
    h.grants.roster = AccessReadOk(
      syntheticRoster(memberId: person, name: 'SYNTHETIC Ruth Mwale'),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: h.overrides(),
        child: RepaintBoundary(
          key: captureKey,
          child: StaffApp(initialLocation: location),
        ),
      ),
    );
    await settle(tester);
    return h;
  }

  Future<void> capture(WidgetTester tester, String name) async {
    final output = Platform.environment['CHURCH_CLIENT_QA_OUTPUT'];
    if (output == null) return;
    await tester.pump();
    final boundary =
        captureKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 1);
      try {
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await Directory(output).create(recursive: true);
        await File('$output/$name.png')
            .writeAsBytes(bytes!.buffer.asUint8List());
      } finally {
        image.dispose();
      }
    });
  }

  testWidgets(
    'signed-out staff can reach owner setup without a privileged session',
    (tester) async {
      await pump(tester, signedIn: false);
      await tester.tap(find.byKey(const Key('landing-admin-setup')));
      await settle(tester);
      expect(find.byType(AdminOnboardingScreen), findsOneWidget);
      expect(find.text('First Admin setup'), findsOneWidget);
      expect(find.byKey(const Key('admin-setup-password')), findsNothing);
      expect(
        find.byKey(const Key('nav-${ClientPaths.adminUsers}')),
        findsNothing,
      );
      await capture(tester, 'setup-desktop');
      await tester.enterText(
        find.byKey(const Key('admin-setup-invitation')),
        'SYNTHETIC unavailable fixture',
      );
      await tester.enterText(
        find.byKey(const Key('admin-setup-phone')),
        '+447700900818',
      );
      await tester.tap(find.byKey(const Key('admin-setup-check')));
      await settle(tester);
      expect(find.text('Setup unavailable'), findsOneWidget);
      expect(find.text('Setup complete'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Admin opens workspace, selects a person and grants only to that person',
    (tester) async {
      final h = await pump(tester, admin: true);
      await tester.tap(find.byKey(const Key('nav-group-People')));
      await settle(tester);
      await tester.tap(find.byKey(const Key('nav-${ClientPaths.adminUsers}')));
      await settle(tester);
      expect(find.byType(UserManagementScreen), findsOneWidget);
      await tester.tap(find.byKey(const Key('member-record-$person')));
      await settle(tester);
      expect(find.byKey(const Key('member-panel')), findsOneWidget);
      await capture(tester, 'users-selected-person');
      final role = find
          .descendant(
            of: find.byKey(const Key('member-panel-role-media')),
            matching: find.byType(InkWell),
          )
          .first;
      await tester.ensureVisible(role);
      await tester.tap(role);
      await settle(tester);
      final sent = h.gateway.sent.single;
      expect(sent.function, 'identity_grant_command');
      expect(sent.wire['command'], 'identity.grant_role');
      expect((sent.wire['payload'] as Map)['member_id'], person);
      expect((sent.wire['payload'] as Map)['role'], 'media');
      sent.confirm(grantsData(memberId: person, roles: ['media']), 2);
      await settle(tester);
      expect(find.textContaining('Media'), findsWidgets);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'ordinary member cannot see the workspace navigation or deep-linked records',
    (tester) async {
      await pump(tester, location: ClientPaths.adminUsers);
      expect(
        find.byKey(const Key('nav-${ClientPaths.adminUsers}')),
        findsNothing,
      );
      expect(find.byKey(const Key('member-record-$person')), findsNothing);
      expect(find.text('Admin access required'), findsOneWidget);
    },
  );

  testWidgets('390 by 844 setup with large text remains scrollable', (
    tester,
  ) async {
    await pump(
      tester,
      signedIn: false,
      location: ClientPaths.adminSetup,
      size: const Size(390, 844),
      textScale: 2,
    );
    await tester.ensureVisible(find.byKey(const Key('admin-setup-check')));
    expect(tester.takeException(), isNull);
    await capture(tester, 'setup-narrow-large-text');
  });

  testWidgets('390 by 844 workspace with large text retains its actions', (
    tester,
  ) async {
    await pump(
      tester,
      admin: true,
      location: ClientPaths.adminUsers,
      size: const Size(390, 844),
      textScale: 2,
    );
    expect(find.byType(UserManagementScreen), findsOneWidget);
    await tester.ensureVisible(find.byKey(const Key('add-member-record')));
    expect(tester.takeException(), isNull);
    await capture(tester, 'users-narrow-large-text');
  });
}

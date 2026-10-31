import 'dart:async';
import 'dart:convert';

import 'package:church_client_core/src/adapters/supabase_admin_onboarding_repository.dart';
import 'package:church_client_core/src/application/admin_onboarding_controllers.dart';
import 'package:church_client_core/src/domain/admin_onboarding.dart';
import 'package:church_client_core/src/presentation/admin_onboarding_screen.dart';
import 'package:church_client_core/testing.dart';
import 'package:church_design_system/church_design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const phone = '+447700900818';
const invitation = 'owner-test-invitation-not-a-credential';
const password = 'Synthetic-test-password';
const key = 'sb_publishable_fixture_not_a_real_key';
const requestId = 'a1111111-1111-4111-8111-111111111111';

Map<String, Object?> readyJson({String mode = 'new_account'}) => {
  'outcome': 'ready',
  'mode': mode,
  'privacy_notice_version': 'fixture-v1',
  'privacy_notice_text': 'SYNTHETIC privacy notice for this test only.',
  'expires_at': DateTime.now()
      .toUtc()
      .add(const Duration(hours: 1))
      .toIso8601String(),
};
AdminOnboardingReply ready({String mode = 'new_account'}) =>
    AdminOnboardingReply.fromJson(readyJson(mode: mode));

class SetupFake implements AdminOnboardingRepository {
  Future<AdminOnboardingReply>? inspection;
  Future<AdminOnboardingReply> completion = Future.value(
    const AdminOnboardingReply(AdminOnboardingOutcome.uncertain),
  );
  Future<AdminOnboardingReply> checked = Future.value(
    const AdminOnboardingReply(AdminOnboardingOutcome.completed),
  );
  int inspections = 0;
  int completions = 0;
  int checks = 0;
  String? lastRequestId;
  String? checkedRequestId;
  @override
  Future<AdminOnboardingReply> inspect({
    required AdminInvitation invitation,
    required String phoneUsername,
  }) {
    inspections++;
    return inspection ?? Future.value(ready());
  }

  @override
  Future<AdminOnboardingReply> complete({
    required AdminInvitation invitation,
    required String phoneUsername,
    required String fullName,
    required String password,
    required String privacyVersion,
    required String requestId,
  }) {
    completions++;
    lastRequestId = requestId;
    return completion;
  }

  @override
  Future<AdminOnboardingReply> status({
    required AdminInvitation invitation,
    required String phoneUsername,
    required String requestId,
  }) {
    checks++;
    checkedRequestId = requestId;
    return checked;
  }
}

ProviderContainer containerFor(SetupFake fake, {ClientTestHarness? harness}) {
  final container = ProviderContainer(
    overrides: [
      if (harness != null) ...harness.overrides(),
      adminOnboardingRepositoryProvider.overrideWithValue(fake),
    ],
  );
  container.listen(adminOnboardingProvider, (_, _) {});
  addTearDown(container.dispose);
  return container;
}

Future<void> inspect(ProviderContainer c) =>
    c.read(adminOnboardingProvider.notifier).inspect(invitation, phone);
Future<void> complete(ProviderContainer c) => c
    .read(adminOnboardingProvider.notifier)
    .complete(
      fullName: 'SYNTHETIC Grace Banda',
      password: password,
      privacyAccepted: true,
    );

void main() {
  group('commissioning response contract', () {
    test('invitation diagnostics never disclose the value', () {
      expect(
        const AdminInvitation(invitation).toString(),
        isNot(contains(invitation)),
      );
    });
    test('ready requires a mode, privacy notice and UTC expiry', () {
      expect(ready().mode, AdminEnrollmentMode.newAccount);
      for (final field in [
        'mode',
        'privacy_notice_version',
        'privacy_notice_text',
        'expires_at',
      ]) {
        final broken = readyJson()..remove(field);
        expect(
          () => AdminOnboardingReply.fromJson(broken),
          throwsFormatException,
        );
      }
    });
    test('unknown status and success without fresh sign-in are refused', () {
      for (final payload in [
        {'outcome': 'ok'},
        {'outcome': 'completed'},
        {'outcome': 'activation_pending', 'sign_in_required': false},
      ]) {
        expect(
          () => AdminOnboardingReply.fromJson(payload),
          throwsFormatException,
        );
      }
    });
    test('activation pending remains distinct from active access', () {
      final reply = AdminOnboardingReply.fromJson({
        'outcome': 'activation_pending',
        'sign_in_required': true,
      });
      expect(reply.outcome, AdminOnboardingOutcome.activationPending);
    });
  });

  group('transport', () {
    SupabaseAdminOnboardingRepository repository(
      Future<http.Response> Function(http.Request) respond,
    ) {
      final repo = SupabaseAdminOnboardingRepository(
        supabaseUrl: 'https://fixture.invalid',
        publishableKey: key,
        httpClient: MockClient(respond),
        timeout: const Duration(milliseconds: 100),
      );
      addTearDown(repo.close);
      return repo;
    }

    test('only a secure URL and publishable key are accepted', () {
      for (final url in [
        'http://remote.invalid',
        'https://name:pass@fixture.invalid',
        'https://fixture.invalid?code=secret',
        'https://fixture.invalid#secret',
      ]) {
        expect(
          () => SupabaseAdminOnboardingRepository(
            supabaseUrl: url,
            publishableKey: key,
          ),
          throwsArgumentError,
        );
      }
      expect(
        () => SupabaseAdminOnboardingRepository(
          supabaseUrl: 'https://fixture.invalid',
          publishableKey: 'not-a-publishable-key',
        ),
        throwsArgumentError,
      );
    });
    test(
      'invitation travels only in POST body; no ambient authorization',
      () async {
        final repo = repository((request) async {
          expect(request.url.query, isEmpty);
          expect(request.url.fragment, isEmpty);
          expect(request.headers['authorization'], isNull);
          expect(request.followRedirects, isFalse);
          expect(request.headers['apikey'], key);
          final body = jsonDecode(request.body) as Map;
          expect(body['action'], 'inspect');
          expect(body['invitation'], invitation);
          expect(body.containsKey('password'), isFalse);
          return http.Response(jsonEncode(readyJson()), 200);
        });
        expect(
          (await repo.inspect(
            invitation: const AdminInvitation(invitation),
            phoneUsername: phone,
          )).outcome,
          AdminOnboardingOutcome.ready,
        );
      },
    );
    test('status never resends the password', () async {
      final repo = repository((request) async {
        final body = jsonDecode(request.body) as Map;
        expect(body.keys.toSet(), {
          'version',
          'action',
          'invitation',
          'phone_username',
          'request_id',
        });
        expect(body['action'], 'status');
        return http.Response(
          jsonEncode({'outcome': 'pending', 'request_id': requestId}),
          200,
        );
      });
      expect(
        (await repo.status(
          invitation: const AdminInvitation(invitation),
          phoneUsername: phone,
          requestId: requestId,
        )).outcome,
        AdminOnboardingOutcome.pending,
      );
    });
    for (final status in [401, 403, 404, 500, 503]) {
      test(
        'HTTP $status cannot claim completed even with a success-shaped body',
        () async {
          final repo = repository(
            (_) async => http.Response(
              '{"outcome":"completed","sign_in_required":true}',
              status,
            ),
          );
          final r = await repo.complete(
            invitation: const AdminInvitation(invitation),
            phoneUsername: phone,
            fullName: 'SYNTHETIC Grace Banda',
            password: password,
            privacyVersion: 'fixture-v1',
            requestId: requestId,
          );
          expect(r.outcome, AdminOnboardingOutcome.uncertain);
        },
      );
    }
    test(
      'malformed, oversized and lost mutation answers remain uncertain',
      () async {
        for (final body in [
          'not json',
          'x' * 33000,
          '{"outcome":"new-server-state"}',
        ]) {
          final repo = repository((_) async => http.Response(body, 200));
          expect(
            (await repo.complete(
              invitation: const AdminInvitation(invitation),
              phoneUsername: phone,
              fullName: 'SYNTHETIC Grace Banda',
              password: password,
              privacyVersion: 'fixture-v1',
              requestId: requestId,
            )).outcome,
            AdminOnboardingOutcome.uncertain,
          );
        }
        final repo = repository(
          (_) async => throw http.ClientException('offline'),
        );
        expect(
          (await repo.complete(
            invitation: const AdminInvitation(invitation),
            phoneUsername: phone,
            fullName: 'SYNTHETIC Grace Banda',
            password: password,
            privacyVersion: 'fixture-v1',
            requestId: requestId,
          )).outcome,
          AdminOnboardingOutcome.uncertain,
        );
      },
    );
  });

  group('in-memory flow controller', () {
    test('reload resumes the server-correlated pending operation without a password', () async {
      final f = SetupFake()
        ..inspection = Future.value(
          const AdminOnboardingReply(
            AdminOnboardingOutcome.pending,
            requestId: requestId,
          ),
        );
      final c = containerFor(f);
      await inspect(c);
      expect(c.read(adminOnboardingProvider).phase, AdminSetupPhase.resolving);
      await complete(c);
      expect(f.completions, 0);
      await c.read(adminOnboardingProvider.notifier).checkStatus();
      expect(f.checkedRequestId, requestId);
      expect(c.read(adminOnboardingProvider).phase, AdminSetupPhase.complete);
    });
    test('returning invitation holder sees completion without signing in automatically', () async {
      final f = SetupFake()
        ..inspection = Future.value(
          const AdminOnboardingReply(AdminOnboardingOutcome.completed),
        );
      final c = containerFor(f);
      await inspect(c);
      expect(c.read(adminOnboardingProvider).phase, AdminSetupPhase.complete);
      expect(f.completions, 0);
    });
    test(
      'short multibyte passwords do not meet the character minimum',
      () async {
        final f = SetupFake();
        final c = containerFor(f);
        await inspect(c);
        await c
            .read(adminOnboardingProvider.notifier)
            .complete(
              fullName: 'SYNTHETIC Grace Banda',
              password: '????',
              privacyAccepted: true,
            );
        expect(f.completions, 0);
      },
    );
    test('no password submission before invitation validation', () async {
      final f = SetupFake();
      final c = containerFor(f);
      await complete(c);
      expect(f.completions, 0);
      await c.read(adminOnboardingProvider.notifier).inspect('', 'invalid');
      expect(f.inspections, 0);
    });
    test(
      'successful check allows one submission and status-only recovery',
      () async {
        final f = SetupFake();
        final c = containerFor(f);
        await inspect(c);
        expect(c.read(adminOnboardingProvider).phase, AdminSetupPhase.details);
        await complete(c);
        expect(
          c.read(adminOnboardingProvider).phase,
          AdminSetupPhase.resolving,
        );
        await complete(c);
        expect(f.completions, 1);
        await c.read(adminOnboardingProvider.notifier).checkStatus();
        expect(f.checkedRequestId, f.lastRequestId);
        expect(c.read(adminOnboardingProvider).phase, AdminSetupPhase.complete);
        expect(c.read(adminOnboardingProvider).invitationDetails, isNull);
        await c.read(adminOnboardingProvider.notifier).checkStatus();
        expect(f.checks, 1);
      },
    );
    test('parallel submit clicks cannot issue two mutations', () async {
      final f = SetupFake();
      final p = Completer<AdminOnboardingReply>();
      f.completion = p.future;
      final c = containerFor(f);
      await inspect(c);
      final first = complete(c);
      await complete(c);
      expect(f.completions, 1);
      p.complete(const AdminOnboardingReply(AdminOnboardingOutcome.completed));
      await first;
      expect(c.read(adminOnboardingProvider).phase, AdminSetupPhase.complete);
    });
    test(
      'late check after cancellation cannot restore an invitation',
      () async {
        final f = SetupFake();
        final p = Completer<AdminOnboardingReply>();
        f.inspection = p.future;
        final c = containerFor(f);
        final waiting = inspect(c);
        c.read(adminOnboardingProvider.notifier).reset();
        p.complete(ready());
        await waiting;
        expect(
          c.read(adminOnboardingProvider).phase,
          AdminSetupPhase.invitation,
        );
        await complete(c);
        expect(f.completions, 0);
      },
    );
    test('account switch discards pending setup results', () async {
      final f = SetupFake();
      final h = ClientTestHarness();
      final c = containerFor(f, harness: h);
      await inspect(c);
      h.session.switchTo('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb');
      await Future<void>.delayed(Duration.zero);
      expect(c.read(adminOnboardingProvider).phase, AdminSetupPhase.invitation);
      await complete(c);
      expect(f.completions, 0);
    });
    test('privacy consent and a usable password are required', () async {
      final f = SetupFake();
      final c = containerFor(f);
      await inspect(c);
      await c
          .read(adminOnboardingProvider.notifier)
          .complete(
            fullName: 'SYNTHETIC Grace Banda',
            password: password,
            privacyAccepted: false,
          );
      await c
          .read(adminOnboardingProvider.notifier)
          .complete(
            fullName: 'SYNTHETIC Grace Banda',
            password: 'short',
            privacyAccepted: true,
          );
      expect(f.completions, 0);
    });
    test('expired ready response cannot enable submission', () async {
      final f = SetupFake()
        ..inspection = Future.value(
          AdminOnboardingReply.fromJson({
            ...readyJson(),
            'expires_at': '2020-01-01T00:00:00Z',
          }),
        );
      final c = containerFor(f);
      await inspect(c);
      await complete(c);
      expect(f.completions, 0);
      expect(
        c.read(adminOnboardingProvider).outcome,
        AdminOnboardingOutcome.refused,
      );
    });
    test(
      'explicit activation pending does not claim active Admin access',
      () async {
        final f = SetupFake()
          ..completion = Future.value(
            const AdminOnboardingReply(
              AdminOnboardingOutcome.activationPending,
            ),
          );
        final c = containerFor(f);
        await inspect(c);
        await complete(c);
        expect(
          c.read(adminOnboardingProvider).outcome,
          AdminOnboardingOutcome.activationPending,
        );
      },
    );
  });

  group('setup screen', () {
    Future<void> pump(WidgetTester t, SetupFake f) async {
      await t.pumpWidget(
        ProviderScope(
          overrides: [adminOnboardingRepositoryProvider.overrideWithValue(f)],
          child: MaterialApp(
            theme: churchStaffTheme(),
            home: const AdminOnboardingScreen(),
          ),
        ),
      );
      await t.pumpAndSettle();
    }

    Future<void> enterInvitation(WidgetTester t) async {
      await t.enterText(
        find.byKey(const Key('admin-setup-invitation')),
        invitation,
      );
      await t.enterText(find.byKey(const Key('admin-setup-phone')), phone);
      await t.ensureVisible(find.byKey(const Key('admin-setup-check')));
      await t.tap(find.byKey(const Key('admin-setup-check')));
      await t.pumpAndSettle();
    }

    testWidgets('empty install fails closed, no fictitious success', (t) async {
      final f = SetupFake()
        ..inspection = Future.value(
          const AdminOnboardingReply(AdminOnboardingOutcome.unavailable),
        );
      await pump(t, f);
      await enterInvitation(t);
      expect(find.text('Setup unavailable'), findsOneWidget);
      expect(find.byKey(const Key('admin-setup-complete')), findsNothing);
    });
    testWidgets(
      'new account shows privacy and hidden password with confirmation',
      (t) async {
        await pump(t, SetupFake());
        await enterInvitation(t);
        final pw = t.widget<TextField>(
          find.byKey(const Key('admin-setup-password')),
        );
        expect(pw.obscureText, isTrue);
        expect(find.byKey(const Key('admin-setup-confirm')), findsOneWidget);
        expect(
          find.text('SYNTHETIC privacy notice for this test only.'),
          findsOneWidget,
        );
        expect(
          t
              .widget<FilledButton>(
                find.byKey(const Key('admin-setup-complete')),
              )
              .onPressed,
          isNull,
        );
      },
    );
    testWidgets('existing account asks for current password, not a reset', (
      t,
    ) async {
      final f = SetupFake()
        ..inspection = Future.value(ready(mode: 'existing_account'));
      await pump(t, f);
      await enterInvitation(t);
      expect(find.text('Current password'), findsOneWidget);
      expect(find.byKey(const Key('admin-setup-confirm')), findsNothing);
    });
    testWidgets('390px and 200 percent text have no overflow', (t) async {
      t.view.physicalSize = const Size(390, 844);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      await t.pumpWidget(
        ProviderScope(
          overrides: [
            adminOnboardingRepositoryProvider.overrideWithValue(SetupFake()),
          ],
          child: MaterialApp(
            theme: churchStaffTheme(),
            home: MediaQuery(
              data: const MediaQueryData(textScaler: TextScaler.linear(2)),
              child: const AdminOnboardingScreen(),
            ),
          ),
        ),
      );
      await t.pumpAndSettle();
      await enterInvitation(t);
      expect(t.takeException(), isNull);
    });
  });
}

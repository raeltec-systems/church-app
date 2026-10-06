// Story 2.2 client half: the session persists across reopening and token
// refresh without a password prompt, protected state stays in memory and is
// cleared on sign-out, and a session the server no longer trusts is ended on
// this device.
import 'package:church_client_core/church_client_core.dart';
import 'package:church_client_core/src/adapters/auth_session_storage.dart';
import 'package:church_client_core/testing.dart';
import 'package:church_design_system/church_design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

const _a = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';

Finder byKey(String k) => find.byKey(Key(k));

Future<ClientTestHarness> pumpAccount(
  WidgetTester tester, {
  String? account = _a,
}) async {
  final h = ClientTestHarness(account: account);
  final router = buildClientRouter(
    initialLocation: ClientPaths.account,
    shell: (_, _, child) => child,
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: h.overrides(),
      child: MaterialApp.router(
        theme: churchMobileTheme(Brightness.light),
        routerConfig: router,
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
  return h;
}

Future<void> settleShort(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// An in-memory [AuthSessionStore] that can be told to fail.
class _MemoryStore implements AuthSessionStore {
  String? value;
  bool failReads = false;
  bool failWrites = false;
  bool failDeletes = false;

  @override
  Future<String?> read() async {
    if (failReads) throw StateError('keystore unavailable');
    return value;
  }

  @override
  Future<void> write(String v) async {
    if (failWrites) throw StateError('keystore unavailable');
    value = v;
  }

  @override
  Future<void> delete() async {
    if (failDeletes) throw StateError('keystore unavailable');
    value = null;
  }
}

void main() {
  group('Auth session storage (the only device persistence)', () {
    test('persists, restores and removes the Auth session JSON', () async {
      final store = _MemoryStore();
      final storage = AuthSessionStorage(store);
      await storage.initialize();
      expect(await storage.hasAccessToken(), isFalse);
      await storage.persistSession('{"access_token":"synthetic"}');
      expect(await storage.hasAccessToken(), isTrue);
      expect(await storage.accessToken(), '{"access_token":"synthetic"}');
      await storage.removePersistedSession();
      expect(await storage.hasAccessToken(), isFalse);
      expect(store.value, isNull);
    });

    test('a storage error reads as "no session" (sign in again)', () async {
      final store = _MemoryStore()..value = '{"x":1}';
      store.failReads = true;
      final storage = AuthSessionStorage(store);
      expect(await storage.hasAccessToken(), isFalse);
      expect(await storage.accessToken(), isNull);
      store.failWrites = true;
      await storage.persistSession('{"y":2}'); // does not throw
    });

    test('a failed delete still leaves no usable session', () async {
      final store = _MemoryStore()..value = '{"x":1}';
      store.failDeletes = true;
      final storage = AuthSessionStorage(store);
      await storage.removePersistedSession();
      expect(store.value, '');
      expect(await storage.hasAccessToken(), isFalse);
    });

    test('mobile store round-trips through flutter_secure_storage', () async {
      FlutterSecureStorage.setMockInitialValues({});
      final storage = AuthSessionStorage(SecureDeviceSessionStore());
      await storage.persistSession('{"access_token":"synthetic"}');
      expect(await storage.accessToken(), '{"access_token":"synthetic"}');
      await storage.removePersistedSession();
      expect(await storage.hasAccessToken(), isFalse);
    });

    test('the web tab store is inert off the web', () async {
      const store = TabSessionStore();
      await store.write('{"x":1}');
      expect(await store.read(), isNull);
    });
  });

  group('session trust on the client', () {
    testWidgets('reopening with a restored session shows the summary with no '
        'password prompt', (tester) async {
      // A restored session is an account present at start-up.
      final h = await pumpAccount(tester);
      expect(byKey('summary-loading'), findsOneWidget);
      h.memberAccess.answer(MemberAccessGranted(syntheticMemberSummary()));
      await settleShort(tester);
      expect(byKey('member-summary'), findsOneWidget);
      expect(byKey('password-field'), findsNothing);
      expect(h.auth.sent, isEmpty, reason: 'no sign-in call');
    });

    testWidgets('a token refresh (same account) keeps the summary and its '
        'generation', (tester) async {
      final h = await pumpAccount(tester);
      h.memberAccess.answer(MemberAccessGranted(syntheticMemberSummary()));
      await settleShort(tester);
      final container = ProviderScope.containerOf(
        tester.element(byKey('member-summary')),
      );
      final generation = container.read(accountGenerationProvider);
      h.session.switchTo(_a); // tokenRefreshed: same account id
      await settleShort(tester);
      expect(container.read(accountGenerationProvider), generation);
      expect(byKey('member-summary'), findsOneWidget);
      expect(h.memberAccess.calls, 1, reason: 'no reload, no state drop');
    });

    testWidgets('sign-out clears the protected summary from memory', (
      tester,
    ) async {
      final h = await pumpAccount(tester);
      h.memberAccess.answer(MemberAccessGranted(syntheticMemberSummary()));
      await settleShort(tester);
      await tester.ensureVisible(byKey('sign-out'));
      await tester.tap(byKey('sign-out'));
      await settleShort(tester);
      expect(h.auth.signOuts, 1);
      expect(byKey('member-summary'), findsNothing);
      expect(find.text('SYNTHETIC Member One'), findsNothing);
      expect(byKey('account-changed'), findsOneWidget);
      final container = ProviderScope.containerOf(
        tester.element(byKey('account-changed')),
      );
      final s = container.read(memberSummaryControllerProvider);
      expect(
        s.result,
        isA<MemberAccessDenied>().having(
          (d) => d.denial,
          'denial',
          MemberAccessDenial.signedOut,
        ),
      );
    });

    testWidgets('an untrusted-session answer ends the session on this device '
        'and clears protected state', (tester) async {
      final h = await pumpAccount(tester);
      h.memberAccess.answer(MemberAccessGranted(syntheticMemberSummary()));
      await settleShort(tester);
      expect(byKey('member-summary'), findsOneWidget);
      // Revoked elsewhere / credential change: the next check is refused.
      await tester.ensureVisible(byKey('refresh-summary'));
      await tester.tap(byKey('refresh-summary'));
      await tester.pump();
      h.memberAccess.answer(
        const MemberAccessDenied(MemberAccessDenial.untrustedSession),
      );
      await settleShort(tester);
      expect(h.auth.signOuts, 1, reason: 'local session (and storage) ended');
      expect(h.session.currentAccountId, isNull);
      expect(byKey('session-ended'), findsOneWidget);
      expect(byKey('member-summary'), findsNothing);
      expect(find.text('SYNTHETIC Member One'), findsNothing);
      expect(byKey('go-sign-in'), findsOneWidget);
    });

    for (final denial in [
      MemberAccessDenial.reviewRequired,
      MemberAccessDenial.notLinked,
      MemberAccessDenial.unavailable,
    ]) {
      testWidgets('${denial.name} keeps the session (only the summary is '
          'withheld)', (tester) async {
        final h = await pumpAccount(tester);
        h.memberAccess.answer(MemberAccessDenied(denial));
        await settleShort(tester);
        expect(h.auth.signOuts, 0);
        expect(h.session.currentAccountId, _a);
        expect(byKey('denied-${denial.name}'), findsOneWidget);
      });
    }

    testWidgets('returning to the foreground asks the server again', (
      tester,
    ) async {
      final h = await pumpAccount(tester);
      h.memberAccess.answer(MemberAccessGranted(syntheticMemberSummary()));
      await settleShort(tester);
      expect(h.memberAccess.calls, 1);
      for (final s in [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
        AppLifecycleState.hidden,
        AppLifecycleState.inactive,
        AppLifecycleState.resumed,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(s);
      }
      await tester.pump();
      expect(h.memberAccess.calls, 2);
      h.memberAccess.answer(
        const MemberAccessDenied(MemberAccessDenial.reviewRequired),
      );
      await settleShort(tester);
      expect(byKey('denied-reviewRequired'), findsOneWidget);
      expect(byKey('member-summary'), findsNothing);
    });

    testWidgets('signed out at start-up: no request is sent', (tester) async {
      final h = await pumpAccount(tester, account: null);
      await settleShort(tester);
      expect(h.memberAccess.calls, 0);
      expect(byKey('go-sign-in'), findsOneWidget);
    });
  });
}

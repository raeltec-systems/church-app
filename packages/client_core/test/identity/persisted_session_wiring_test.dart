// Story 2.2: supabase_flutter's own session persistence path, wired to
// AuthSessionStorage exactly as composition.dart does: a sign-in and a token
// refresh write the Auth session to the store, a restart restores it without
// a sign-in call, and sign-out removes it. Auth is a scripted HTTP fake; no
// network, no real token.
import 'dart:convert';

import 'package:church_client_core/src/adapters/auth_session_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

// A syntactically valid, unsigned test JWT (not a credential).
String _testJwt(String sub, int n) {
  String b64(Object o) =>
      base64Url.encode(utf8.encode(jsonEncode(o))).replaceAll('=', '');
  return '${b64({'alg': 'none'})}.${b64({
    'sub': sub,
    'exp': 4102444800,
    'n': n,
    'amr': [
      {'method': 'password', 'timestamp': 1790000000},
    ],
    'role': 'authenticated',
  })}.x';
}

const _sub = '11111111-1111-4111-8111-111111111111';

class _MemoryStore implements AuthSessionStore {
  String? value;
  final List<String> writes = [];

  @override
  Future<String?> read() async => value;

  @override
  Future<void> write(String v) async {
    value = v;
    writes.add(v);
  }

  @override
  Future<void> delete() async => value = null;
}

class _MemoryPkce extends GotrueAsyncStorage {
  final _m = <String, String>{};
  @override
  Future<String?> getItem({required String key}) async => _m[key];
  @override
  Future<void> removeItem({required String key}) async => _m.remove(key);
  @override
  Future<void> setItem({required String key, required String value}) async =>
      _m[key] = value;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  var issued = 0;
  final calls = <String>[];
  http.Response json(http.Request r, Object body, [int status = 200]) =>
      http.Response(
        jsonEncode(body),
        status,
        headers: {'content-type': 'application/json'},
        request: r,
      );
  Map<String, Object?> session() => {
    'access_token': _testJwt(_sub, ++issued),
    'token_type': 'bearer',
    'expires_in': 3600,
    'expires_at': 4102444800,
    'refresh_token': 'test-refresh-$issued',
    'user': {
      'id': _sub,
      'aud': 'authenticated',
      'role': 'authenticated',
      'phone': '12025550101',
      'app_metadata': <String, Object?>{},
      'user_metadata': <String, Object?>{},
      'created_at': '2026-10-06T12:00:00Z',
    },
  };
  final httpClient = MockClient((r) async {
    calls.add('${r.method} ${r.url.path}?${r.url.query}');
    if (r.url.path == '/auth/v1/token') return json(r, session());
    if (r.url.path == '/auth/v1/logout') return http.Response('', 204);
    if (r.url.path == '/auth/v1/user') return json(r, session()['user']!);
    return json(r, {});
  });

  Future<SupabaseClient> start(_MemoryStore store) async {
    final s = await Supabase.initialize(
      url: 'http://localhost:54321',
      publishableKey: 'sb_publishable_test',
      httpClient: httpClient,
      debug: false,
      authOptions: FlutterAuthClientOptions(
        localStorage: AuthSessionStorage(store),
        pkceAsyncStorage: _MemoryPkce(),
        detectSessionInUri: false,
        autoRefreshToken: false,
      ),
    );
    return s.client;
  }

  Future<void> settle() => Future<void>.delayed(Duration.zero);

  test('sign-in and refresh persist the session; a restart restores it '
      'without signing in; sign-out removes it', () async {
    final store = _MemoryStore();
    var client = await start(store);
    expect(client.auth.currentSession, isNull);
    expect(store.value, isNull);

    await client.auth.signInWithPassword(phone: '+12025550101', password: 'p');
    await settle();
    final afterSignIn = store.value;
    expect(afterSignIn, isNotNull, reason: 'sign-in persisted the session');
    expect(jsonDecode(afterSignIn!)['refresh_token'], 'test-refresh-1');

    await client.auth.refreshSession();
    await settle();
    expect(
      jsonDecode(store.value!)['refresh_token'],
      'test-refresh-2',
      reason: 'the refreshed session replaced the stored one',
    );

    // Restart: a new Supabase instance over the same store.
    await Supabase.instance.dispose();
    calls.clear();
    client = await start(store);
    await settle();
    expect(client.auth.currentSession?.user.id, _sub);
    expect(
      calls.where((c) => c.contains('grant_type=password')),
      isEmpty,
      reason: 'no sign-in call on reopening',
    );

    await client.auth.signOut(scope: SignOutScope.local);
    await settle();
    expect(store.value, isNull, reason: 'sign-out removed the stored session');
    await Supabase.instance.dispose();
  });
}

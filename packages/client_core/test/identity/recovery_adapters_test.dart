// Story 2.7: the Supabase adapters of the forgotten-password route and the
// member's recovery email, against a mock HTTP server. The recovery client is
// its own Auth client (PKCE, own verifier store); its session is used for one
// password update and then signed out.
import 'dart:convert';

import 'package:church_client_core/church_client_core.dart';
import 'package:church_client_core/supabase_adapters.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase/supabase.dart';

class _MemoryStorage extends GotrueAsyncStorage {
  final Map<String, String> items = {};

  @override
  Future<String?> getItem({required String key}) async => items[key];

  @override
  Future<void> setItem({required String key, required String value}) async =>
      items[key] = value;

  @override
  Future<void> removeItem({required String key}) async => items.remove(key);
}

String _jwt(String method) {
  String b64(Object o) =>
      base64Url.encode(utf8.encode(jsonEncode(o))).replaceAll('=', '');
  return '${b64({'alg': 'none'})}.${b64({
    'sub': '11111111-1111-4111-8111-111111111111',
    'exp': 4102444800,
    'amr': [
      {'method': method, 'timestamp': 1790000000},
    ],
    'role': 'authenticated',
  })}.x';
}

Map<String, Object?> _session(String method) => {
  'access_token': _jwt(method),
  'token_type': 'bearer',
  'expires_in': 3600,
  'expires_at': 4102444800,
  'refresh_token': 'test-refresh',
  'user': {
    'id': '11111111-1111-4111-8111-111111111111',
    'aud': 'authenticated',
    'role': 'authenticated',
    'phone': '447700900281',
    'app_metadata': <String, Object?>{},
    'user_metadata': <String, Object?>{},
    'created_at': '2026-10-07T12:00:00Z',
  },
};

http.Response _json(Object body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json'},
);

void main() {
  group('SupabasePasswordRecoveryGateway', () {
    late List<http.Request> sent;
    late _MemoryStorage storage;

    SupabasePasswordRecoveryGateway gatewayWith(
      Future<http.Response> Function(http.Request) handler,
    ) {
      sent = [];
      storage = _MemoryStorage();
      return SupabasePasswordRecoveryGateway(
        supabaseUrl: 'http://localhost:54321',
        publishableKey: 'sb_publishable_test',
        redirects: AuthRedirects.mobile,
        verifierStorage: storage,
        httpClient: MockClient((r) {
          sent.add(r);
          return handler(r);
        }),
      );
    }

    test(
      'asks with PKCE and the allowlisted mobile link; neutral on refusal',
      () async {
        final g = gatewayWith(
          (_) async => _json({
            'code': 429,
            'error_code': 'over_email_send_rate_limit',
            'msg': 'wait',
          }, 429),
        );
        expect(
          await g.requestReset(' someone@example.test '),
          ResetRequestOutcome.sent,
        );
        final r = sent.single;
        expect(r.url.path, '/auth/v1/recover');
        expect(
          r.url.queryParameters['redirect_to'],
          'zm.bickafue.mobile://callback/auth/recovery',
        );
        final body = jsonDecode(r.body) as Map;
        expect(body['email'], 'someone@example.test');
        expect(body['code_challenge_method'], 's256');
        expect(body['code_challenge'], isA<String>());
        expect(storage.items.keys.single, endsWith('-code-verifier'));
      },
    );

    test('a transport failure is the only distinguished answer', () async {
      final g = gatewayWith((_) async => throw http.ClientException('down'));
      expect(
        await g.requestReset('someone@example.test'),
        ResetRequestOutcome.unreachable,
      );
    });

    test('opens the code with the kept verifier, sets the password once, signs out', () async {
      final g = gatewayWith((r) async {
        if (r.url.path == '/auth/v1/recover') return _json({});
        if (r.url.path == '/auth/v1/token') return _json(_session('recovery'));
        if (r.url.path == '/auth/v1/user') {
          return _json(_session('recovery')['user']!);
        }
        if (r.url.path == '/auth/v1/logout') return http.Response('', 204);
        return _json({'msg': 'unexpected'}, 500);
      });
      await g.requestReset('someone@example.test');
      final verifier = storage.items.values.single.split('/').first;
      expect(await g.openLink('code-123456'), RecoveryLinkOutcome.ready);
      final exchange = sent[1];
      expect(exchange.url.queryParameters['grant_type'], 'pkce');
      expect(jsonDecode(exchange.body), {
        'auth_code': 'code-123456',
        'code_verifier': verifier,
      });
      expect(storage.items, isEmpty, reason: 'the verifier is used once');

      expect(await g.setNewPassword('Synthetic-new-1'), isA<PasswordSet>());
      final update = sent[2];
      expect(update.method, 'PUT');
      expect(update.url.path, '/auth/v1/user');
      expect(jsonDecode(update.body), {'password': 'Synthetic-new-1'});
      expect(sent[3].url.path, '/auth/v1/logout');
      expect(
        sent,
        hasLength(4),
        reason: 'nothing else is called with the recovery session',
      );
      // A second attempt has no session left.
      final again = await g.setNewPassword('Synthetic-new-2');
      expect((again as PasswordNotSet).failure, SetPasswordFailure.linkExpired);
      expect(sent, hasLength(4));
    });

    test('a refused or verifier-less exchange is unusable', () async {
      final g = gatewayWith(
        (_) async => _json({
          'code': 400,
          'error_code': 'flow_state_not_found',
          'msg': 'x',
        }, 400),
      );
      expect(await g.openLink('code-123456'), RecoveryLinkOutcome.unusable);
      expect(
        sent,
        isEmpty,
        reason: 'no verifier kept on this device: nothing is sent',
      );
    });
  });

  group('SupabaseRecoveryEmailRepository', () {
    test('confirms the password on the same phone and asks Auth for the same-account email change', () async {
      final sent = <http.Request>[];
      final client = SupabaseClient(
        'http://localhost:54321',
        'sb_publishable_test',
        httpClient: MockClient((r) async {
          sent.add(r);
          if (r.url.path == '/auth/v1/token') {
            return _json(_session('password'));
          }
          if (r.url.path == '/auth/v1/user') {
            return _json(_session('password')['user']!);
          }
          return _json({'msg': 'unexpected'}, 500);
        }),
        authOptions: AuthClientOptions(
          autoRefreshToken: false,
          pkceAsyncStorage: _MemoryStorage(),
        ),
      );
      addTearDown(client.dispose);
      await client.auth.recoverSession(jsonEncode(_session('password')));
      final repo = SupabaseRecoveryEmailRepository(
        client,
        redirects: AuthRedirects.mobile,
      );

      expect(await repo.confirmPassword('Synthetic-pw'), isA<AuthSucceeded>());
      final signIn = sent.last;
      expect(signIn.url.queryParameters['grant_type'], 'password');
      final body = jsonDecode(signIn.body) as Map;
      expect(body['phone'], '+447700900281');
      expect(body['password'], 'Synthetic-pw');

      expect(
        await repo.requestVerification(' me@example.test '),
        EmailVerificationRequest.sent,
      );
      final update = sent.last;
      expect(update.method, 'PUT');
      expect(
        update.url.queryParameters['redirect_to'],
        'zm.bickafue.mobile://callback/auth/email-confirmed',
      );
      expect((jsonDecode(update.body) as Map)['email'], 'me@example.test');
    });
  });
}

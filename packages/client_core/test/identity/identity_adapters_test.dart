import 'dart:convert';

import 'package:church_client_core/church_client_core.dart';
import 'package:church_client_core/supabase_adapters.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase/supabase.dart';

// A syntactically valid, unsigned test JWT (not a credential): header.payload.x
String _testJwt(String sub) {
  String b64(Object o) =>
      base64Url.encode(utf8.encode(jsonEncode(o))).replaceAll('=', '');
  return '${b64({'alg': 'none'})}.${b64({
    'sub': sub,
    'exp': 4102444800,
    'amr': [
      {'method': 'password', 'timestamp': 1790000000},
    ],
    'role': 'authenticated',
  })}.x';
}

const _sub = '11111111-1111-4111-8111-111111111111';

Map<String, Object?> _session() => {
  'access_token': _testJwt(_sub),
  'token_type': 'bearer',
  'expires_in': 3600,
  'expires_at': 4102444800,
  'refresh_token': 'test-refresh',
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

void main() {
  late List<http.Request> sent;

  SupabaseClient clientWith(
    Future<http.Response> Function(http.Request) handler,
  ) {
    sent = [];
    final client = SupabaseClient(
      'http://localhost:54321',
      'sb_publishable_test',
      httpClient: MockClient((r) {
        sent.add(r);
        return handler(r);
      }),
      authOptions: const AuthClientOptions(autoRefreshToken: false),
    );
    addTearDown(client.dispose);
    return client;
  }

  http.Response json(http.Request r, Object body, [int status = 200]) =>
      http.Response(
        jsonEncode(body),
        status,
        headers: {'content-type': 'application/json'},
        request: r,
      );

  group('SupabaseAccountAuthGateway', () {
    test('sign-up posts phone and password to /signup only (no OTP, no SMS endpoint)', () async {
      final g = SupabaseAccountAuthGateway(
        clientWith((r) async => json(r, _session())),
      );
      final out = await g.signUp(
        phoneE164: '+12025550101',
        password: 'Synthetic-pw-1',
      );
      expect(out, isA<AuthSucceeded>().having((s) => s.accountId, 'id', _sub));
      expect(sent.single.url.path, '/auth/v1/signup');
      final body = jsonDecode(sent.single.body) as Map;
      expect(body['phone'], '+12025550101');
      expect(body['password'], 'Synthetic-pw-1');
    });

    test('sign-in uses the password grant', () async {
      final g = SupabaseAccountAuthGateway(
        clientWith((r) async => json(r, _session())),
      );
      expect(
        await g.signIn(phoneE164: '+447700900123', password: 'p'),
        isA<AuthSucceeded>(),
      );
      expect(sent.single.url.path, '/auth/v1/token');
      expect(sent.single.url.queryParameters['grant_type'], 'password');
      expect(
        sent.every(
          (r) => !r.url.path.contains('otp') && !r.url.path.contains('verify'),
        ),
        isTrue,
      );
    });

    test(
      'a sign-up without a session (confirmation on) is not a success',
      () async {
        final g = SupabaseAccountAuthGateway(
          clientWith((r) async => json(r, (_session()['user'] as Map))),
        );
        expect(
          await g.signUp(phoneE164: '+12025550101', password: 'p'),
          isA<AuthFailed>().having(
            (f) => f.failure,
            'failure',
            AuthFailure.unavailable,
          ),
        );
      },
    );

    for (final (status, code, expected) in [
      (400, 'invalid_credentials', AuthFailure.invalidCredentials),
      (422, 'user_already_exists', AuthFailure.usernameUnavailable),
      (422, 'phone_exists', AuthFailure.usernameUnavailable),
      (429, 'over_request_rate_limit', AuthFailure.rateLimited),
      (400, 'phone_provider_disabled', AuthFailure.unavailable),
    ]) {
      test('$status $code -> $expected', () async {
        final g = SupabaseAccountAuthGateway(
          clientWith(
            (r) async => json(r, {
              'code': status,
              'error_code': code,
              'msg': 'x',
            }, status),
          ),
        );
        expect(
          await g.signIn(phoneE164: '+12025550101', password: 'p'),
          isA<AuthFailed>().having((f) => f.failure, 'failure', expected),
        );
      });
    }

    test('weak password carries the server reasons', () async {
      final g = SupabaseAccountAuthGateway(
        clientWith(
          (r) async => json(r, {
            'code': 422,
            'error_code': 'weak_password',
            'msg': 'weak',
            'weak_password': {
              'reasons': ['length'],
            },
          }, 422),
        ),
      );
      final out = await g.signUp(phoneE164: '+12025550101', password: 'p');
      expect(
        out,
        isA<AuthFailed>().having(
          (f) => f.failure,
          'f',
          AuthFailure.weakPassword,
        ),
      );
      expect((out as AuthFailed).serverReasons, ['length']);
    });

    test('a transport failure is unreachable', () async {
      final g = SupabaseAccountAuthGateway(
        clientWith((r) async => throw http.ClientException('offline')),
      );
      expect(
        await g.signIn(phoneE164: '+12025550101', password: 'p'),
        isA<AuthFailed>().having(
          (f) => f.failure,
          'f',
          AuthFailure.unreachable,
        ),
      );
    });
  });

  group('SupabaseMemberAccessRepository', () {
    Future<SupabaseClient> signedIn(
      Future<http.Response> Function(http.Request) rest,
    ) async {
      final client = clientWith((r) async {
        if (r.url.path.startsWith('/auth/')) return json(r, _session());
        return rest(r);
      });
      await client.auth.signInWithPassword(
        phone: '+12025550101',
        password: 'p',
      );
      return client;
    }

    test('signed out: no request, denied signedOut', () async {
      final repo = SupabaseMemberAccessRepository(
        clientWith((r) async => json(r, {})),
      );
      final out = await repo.fetchMySummary();
      expect(
        out,
        isA<MemberAccessDenied>().having(
          (d) => d.denial,
          'd',
          MemberAccessDenial.signedOut,
        ),
      );
      expect(sent, isEmpty);
    });

    test(
      'posts to api.identity_my_member_summary and maps the summary',
      () async {
        final client = await signedIn(
          (r) async => json(r, {
            'member_id': '22222222-2222-4222-8222-222222222222',
            'display_name': 'SYNTHETIC Member One',
            'membership_state': 'approved',
            'phone_username': '+12025550101',
            'has_recovery_email': false,
            'is_synthetic': true,
          }),
        );
        final out = await SupabaseMemberAccessRepository(client)
            .fetchMySummary();
        expect(out, isA<MemberAccessGranted>());
        expect(
          (out as MemberAccessGranted).summary.displayName,
          'SYNTHETIC Member One',
        );
        final rpc = sent.last;
        expect(rpc.method, 'POST');
        expect(rpc.url.path, '/rest/v1/rpc/identity_my_member_summary');
        expect(rpc.headers['Content-Profile'], 'api');
        expect(rpc.headers['Authorization'], startsWith('Bearer '));
      },
    );

    for (final (status, message, details, expected) in [
      (403, 'forbidden', 'not_linked', MemberAccessDenial.notLinked),
      (403, 'forbidden', 'review_required', MemberAccessDenial.reviewRequired),
      (403, 'unavailable', 'unavailable', MemberAccessDenial.unavailable),
      (
        401,
        'unauthenticated',
        'untrusted_session',
        MemberAccessDenial.untrustedSession,
      ),
      (401, 'unauthenticated', 'unauthenticated', MemberAccessDenial.signedOut),
    ]) {
      test('$status $message/$details -> $expected', () async {
        final client = await signedIn(
          (r) async => json(r, {
            'code': 'PT$status',
            'message': message,
            'details': details,
            'hint': null,
          }, status),
        );
        final out = await SupabaseMemberAccessRepository(client)
            .fetchMySummary();
        expect(
          out,
          isA<MemberAccessDenied>().having((d) => d.denial, 'd', expected),
        );
      });
    }

    group('a JWT rejected by PostgREST (not an access decision)', () {
      Map<String, Object?> summary() => {
        'member_id': '22222222-2222-4222-8222-222222222222',
        'display_name': 'SYNTHETIC Member One',
        'membership_state': 'approved',
        'phone_username': '+12025550101',
        'has_recovery_email': false,
        'is_synthetic': true,
      };

      Future<SupabaseClient> scripted(
        List<http.Response Function(http.Request)> rpcs, {
        bool refreshRefused = false,
      }) async {
        var i = 0;
        final client = clientWith((r) async {
          if (r.url.path == '/auth/v1/token' &&
              r.url.queryParameters['grant_type'] == 'refresh_token' &&
              refreshRefused) {
            return json(r, {
              'code': 400,
              'error_code': 'refresh_token_not_found',
              'msg': 'Invalid Refresh Token: Refresh Token Not Found',
            }, 400);
          }
          if (r.url.path.startsWith('/auth/')) return json(r, _session());
          return rpcs[i++](r);
        });
        await client.auth.signInWithPassword(
          phone: '+12025550101',
          password: 'p',
        );
        return client;
      }

      http.Response rejected(http.Request r, String code) =>
          json(r, {'code': code, 'message': 'JWT expired'}, 401);

      bool refreshed() => sent.any(
        (r) => r.url.queryParameters['grant_type'] == 'refresh_token',
      );

      for (final code in ['PGRST301', 'PGRST303']) {
        test('$code: refresh once and retry -> granted', () async {
          final client = await scripted([
            (r) => rejected(r, code),
            (r) => json(r, summary()),
          ]);
          final out = await SupabaseMemberAccessRepository(client)
              .fetchMySummary();
          expect(out, isA<MemberAccessGranted>());
          expect(refreshed(), isTrue);
          expect(client.auth.currentSession, isNotNull);
        });
      }

      test(
        'rejected again after the refresh: a failure, session kept',
        () async {
          final client = await scripted([
            (r) => rejected(r, 'PGRST301'),
            (r) => rejected(r, 'PGRST301'),
          ]);
          final out = await SupabaseMemberAccessRepository(client)
              .fetchMySummary();
          expect(
            out,
            isA<MemberAccessFailed>().having((f) => f.unreachable, 'u', false),
          );
          expect(client.auth.currentSession, isNotNull);
        },
      );

      test('refresh refused by Auth: signed out (the SDK ended it)', () async {
        final client = await scripted([
          (r) => rejected(r, 'PGRST303'),
        ], refreshRefused: true);
        final out = await SupabaseMemberAccessRepository(client)
            .fetchMySummary();
        expect(
          out,
          isA<MemberAccessDenied>().having(
            (d) => d.denial,
            'd',
            MemberAccessDenial.signedOut,
          ),
        );
        expect(client.auth.currentSession, isNull);
      });

      test('a JWT rejection never maps to untrustedSession', () {
        for (final code in ['PGRST301', 'PGRST303']) {
          expect(memberAccessDenialFor(code, 'JWT expired', null), isNull);
        }
      });
    });

    test('a malformed summary is a failure, never data', () async {
      final client = await signedIn(
        (r) async => json(r, {'display_name': 'x'}),
      );
      final out = await SupabaseMemberAccessRepository(client).fetchMySummary();
      expect(
        out,
        isA<MemberAccessFailed>().having((f) => f.unreachable, 'u', false),
      );
    });

    test('a transport failure is unreachable', () async {
      final client = await signedIn(
        (r) async => throw http.ClientException('offline'),
      );
      final out = await SupabaseMemberAccessRepository(client).fetchMySummary();
      expect(
        out,
        isA<MemberAccessFailed>().having((f) => f.unreachable, 'u', true),
      );
    });
  });
}

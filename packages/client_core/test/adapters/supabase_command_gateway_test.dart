import 'dart:convert';

import 'package:church_client_core/church_client_core.dart';
import 'package:church_client_core/supabase_adapters.dart';
import 'package:church_contracts/church_contracts.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase/supabase.dart' hide ErrorCode;

const _rid = '00000000-0000-4000-8000-000000000001';

final _request = CommandRequest(
  command: 'fixture_counter.create',
  requestId: _rid,
  expectedRevision: const Optional.of(null),
  payload: const {'intent_key': 'synthetic-demo'},
);

void main() {
  late List<http.Request> sent;

  SupabaseCommandGateway gatewayWith(
    Future<http.Response> Function(http.Request) handler, {
    Duration timeout = const Duration(seconds: 2),
  }) {
    sent = [];
    final client = SupabaseClient(
      'http://localhost:54321',
      'sb_publishable_test',
      httpClient: MockClient((request) {
        sent.add(request);
        return handler(request);
      }),
      authOptions: const AuthClientOptions(autoRefreshToken: false),
    );
    addTearDown(client.dispose);
    return SupabaseCommandGateway(client, timeout: timeout);
  }

  http.Response json(http.Request r, Object body, [int status = 200]) =>
      http.Response(
        jsonEncode(body),
        status,
        headers: {'content-type': 'application/json'},
        request: r,
      );

  Future<CommandOutcome> send(SupabaseCommandGateway g) =>
      g.send('fixture_counter_command', _request);

  test(
    'posts the whole envelope to api.rpc with Content-Profile api',
    () async {
      final g = gatewayWith(
        (r) async => json(r, {
          'request_id': _rid,
          'data': {'id': 'x'},
          'revision': 1,
        }),
      );
      final outcome = await send(g);
      expect(outcome, isA<CommandConfirmed>());
      expect((outcome as CommandConfirmed).success.revision, 1);
      final r = sent.single;
      expect(r.method, 'POST');
      expect(r.url.path, '/rest/v1/rpc/fixture_counter_command');
      expect(r.headers['Content-Profile'], 'api');
      expect(jsonDecode(r.body), _request.toJson());
    },
  );

  test('an error envelope is a definite refusal with its fields', () async {
    final g = gatewayWith(
      (r) async => json(r, {
        'request_id': _rid,
        'code': 'conflict',
        'message': 'Conflict.',
        'field_errors': <String, String>{},
        'current_revision': 4,
      }),
    );
    final outcome = await send(g) as CommandRefused;
    expect(outcome.error.code, ErrorCode.conflict);
    expect(outcome.error.currentRevision.value, 4);
  });

  group('unknown outcome, never success', () {
    test('transport failure', () async {
      final g = gatewayWith((_) async => throw http.ClientException('reset'));
      expect(await send(g), isA<CommandUnknownOutcome>());
    });

    test('no answer within the timeout aborts the request', () async {
      final client = SupabaseClient(
        'http://localhost:54321',
        'sb_publishable_test',
        // Like a real client, abort the in-flight request when the signal fires.
        httpClient: MockClient.streaming((request, _) async {
          final trigger = (request as http.Abortable).abortTrigger;
          expect(
            trigger,
            isNotNull,
            reason: 'adapter must set an abort signal',
          );
          await trigger;
          throw http.RequestAbortedException(request.url);
        }),
        authOptions: const AuthClientOptions(autoRefreshToken: false),
      );
      addTearDown(client.dispose);
      final g = SupabaseCommandGateway(
        client,
        timeout: const Duration(milliseconds: 50),
      );
      expect(await send(g), isA<CommandUnknownOutcome>());
    });

    for (final status in [502, 503, 504]) {
      test('gateway $status with a non-PostgREST body', () async {
        final g = gatewayWith(
          (r) async =>
              http.Response('<html>bad gateway</html>', status, request: r),
        );
        expect(await send(g), isA<CommandUnknownOutcome>());
      });
    }

    test('a 200 with a non-JSON body', () async {
      final g = gatewayWith(
        (r) async => http.Response('<html>ok</html>', 200, request: r),
      );
      expect(await send(g), isA<CommandUnknownOutcome>());
    });

    test('a contract-invalid body', () async {
      final g = gatewayWith((r) async => json(r, {'ok': true}));
      expect(await send(g), isA<CommandUnknownOutcome>());
    });

    test('a success for another request id', () async {
      final g = gatewayWith(
        (r) async => json(r, {
          'request_id': '00000000-0000-4000-8000-000000000009',
          'data': null,
          'revision': 1,
        }),
      );
      expect(await send(g), isA<CommandUnknownOutcome>());
    });
  });

  group('API refusals are definite', () {
    test('no EXECUTE for a signed-out caller is unauthenticated', () async {
      final g = gatewayWith(
        (r) async => json(r, {
          'code': '42501',
          'message': 'permission denied for function fixture_counter_command',
          'details': null,
          'hint': null,
        }, 401),
      );
      final outcome = await send(g) as CommandRefused;
      expect(outcome.error.code, ErrorCode.unauthenticated);
      expect(outcome.error.requestId, _rid);
    });

    test('a JWT error is unauthenticated', () async {
      final g = gatewayWith(
        (r) async =>
            json(r, {'code': 'PGRST301', 'message': 'JWT expired'}, 401),
      );
      expect(
        (await send(g) as CommandRefused).error.code,
        ErrorCode.unauthenticated,
      );
    });

    test('an unknown function is unavailable', () async {
      final g = gatewayWith(
        (r) async => json(r, {'code': 'PGRST202', 'message': 'not found'}, 404),
      );
      expect(
        (await send(g) as CommandRefused).error.code,
        ErrorCode.unavailable,
      );
    });
  });

  group('a bare status without a PostgREST body is unknown outcome', () {
    for (final (status, body) in [
      (408, 'Request Timeout'),
      (302, ''),
      (429, 'slow down'),
      (401, '{"message":"Invalid API key"}'),
      (404, '<html>not found</html>'),
    ]) {
      test('$status', () async {
        final g = gatewayWith(
          (r) async => http.Response(body, status, request: r),
        );
        expect(await send(g), isA<CommandUnknownOutcome>());
      });
    }
  });

  test('session adapter reports no account when signed out', () async {
    final client = SupabaseClient(
      'http://localhost:54321',
      'sb_publishable_test',
      authOptions: const AuthClientOptions(autoRefreshToken: false),
    );
    addTearDown(client.dispose);
    expect(SupabaseSessionRepository(client).currentAccountId, isNull);
  });
}

import 'dart:convert';

import 'package:bic_kafue_mobile/platform_status/platform_status.dart';
import 'package:bic_kafue_mobile/platform_status/supabase_platform_status_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  late List<http.Request> sent;

  SupabasePlatformStatusRepository repoWith(
    Future<http.Response> Function(http.Request) handler,
  ) {
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
    return SupabasePlatformStatusRepository(
      client,
      timeout: const Duration(seconds: 2),
    );
  }

  http.Response json(http.Request request, Object body, [int status = 200]) =>
      http.Response(
        jsonEncode(body),
        status,
        headers: {'content-type': 'application/json'},
        request: request,
      );

  test('reads api.platform_status with the api schema profile', () async {
    final repo = repoWith(
      (r) async => json(r, [
        {
          'status': 'operational',
          'message': 'm',
          'is_synthetic': true,
          'updated_at': '2026-10-03T11:08:28+00:00',
        },
      ]),
    );

    final status = await repo.fetch();

    expect(status?.status, 'operational');
    final request = sent.single;
    expect(request.method, 'GET');
    expect(request.url.path, '/rest/v1/platform_status');
    expect(request.headers['Accept-Profile'], 'api');
  });

  test('returns null when no row is recorded', () async {
    final repo = repoWith((r) async => json(r, []));
    expect(await repo.fetch(), isNull);
  });

  test('each fetch sends a fresh request', () async {
    final repo = repoWith((r) async => json(r, []));
    await repo.fetch();
    await repo.fetch();
    expect(sent, hasLength(2));
  });

  test('a network failure is reported as unreachable', () async {
    final repo = repoWith(
      (_) async => throw http.ClientException('Connection refused'),
    );
    await expectLater(
      repo.fetch(),
      throwsA(
        isA<PlatformStatusException>()
            .having(
              (e) => e.failure,
              'failure',
              PlatformStatusFailure.unreachable,
            )
            .having(
              (e) => e.cause,
              'cause',
              isA<http.ClientException>().having(
                (c) => c.message,
                'message',
                'Connection refused',
              ),
            ),
      ),
    );
    expect(sent, hasLength(1), reason: 'no SDK auto-retry; Try again retries');
  });

  test('a request that never answers is aborted as unreachable', () async {
    final client = SupabaseClient(
      'http://localhost:54321',
      'sb_publishable_test',
      // Like a real client, abort the in-flight request when the signal fires.
      httpClient: MockClient.streaming((request, _) async {
        final trigger = (request as http.Abortable).abortTrigger;
        expect(trigger, isNotNull, reason: 'adapter must set an abort signal');
        await trigger;
        throw http.RequestAbortedException(request.url);
      }),
      authOptions: const AuthClientOptions(autoRefreshToken: false),
    );
    addTearDown(client.dispose);
    final repo = SupabasePlatformStatusRepository(
      client,
      timeout: const Duration(milliseconds: 50),
    );

    await expectLater(
      repo.fetch(),
      throwsA(
        isA<PlatformStatusException>()
            .having(
              (e) => e.failure,
              'failure',
              PlatformStatusFailure.unreachable,
            )
            .having(
              (e) => e.cause,
              'cause',
              isA<http.RequestAbortedException>(),
            ),
      ),
    );
  });

  test('a PostgREST error is reported as rejected', () async {
    final repo = repoWith(
      (r) async => json(r, {
        'code': '42501',
        'message': 'permission denied for view platform_status',
      }, 401),
    );
    await expectLater(
      repo.fetch(),
      throwsA(
        isA<PlatformStatusException>().having(
          (e) => e.failure,
          'failure',
          PlatformStatusFailure.rejected,
        ),
      ),
    );
  });
}

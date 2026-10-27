import 'dart:convert';

import 'package:church_client_core/church_client_core.dart';
import 'package:church_client_core/supabase_adapters.dart';
import 'package:church_client_core/testing.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase/supabase.dart';

void main() {
  test('signed-out sermon reads use public RPCs and strict parsing; staff reads require a session', () async {
    final sent = <http.Request>[];
    final client = SupabaseClient(
      'http://localhost:54321',
      'sb_publishable_test',
      httpClient: MockClient((request) async {
        sent.add(request);
        expect(request.method, 'POST');
        expect(request.headers['content-profile'], 'api');
        return http.Response(
          jsonEncode(
            request.url.path.endsWith('content_public_sermons')
                ? {
                    'sermons': [publicSermonData()],
                    'series': [],
                    'truncated': false,
                  }
                : {'sermon': publicSermonData()},
          ),
          200,
          headers: {'content-type': 'application/json'},
          request: request,
        );
      }),
      authOptions: const AuthClientOptions(autoRefreshToken: false),
    );
    addTearDown(client.dispose);
    final repo = SupabaseSermonsRepository(client);
    final catalog = await repo.fetchPublicSermons();
    expect(
      catalog,
      isA<AccessReadOk<PublicSermons>>(),
      reason: catalog is AccessReadFailed<PublicSermons>
          ? '${catalog.cause}'
          : null,
    );
    expect(
      await repo.fetchPublicSermon('92929292-9292-4292-8292-929292929292'),
      isA<AccessReadOk<PublicSermonRead>>(),
    );
    expect(jsonDecode(sent.last.body), {
      'sermon_id': '92929292-9292-4292-8292-929292929292',
    });
    expect(
      await repo.fetchStaffSermons(),
      isA<AccessReadDenied<StaffSermons>>(),
    );
    expect(
      await repo.fetchStaffSeries(),
      isA<AccessReadDenied<StaffSermonSeriesCatalog>>(),
    );
    expect(sent, hasLength(2));
  });
  test('unsafe or private fields in a sermon answer fail visibly', () async {
    final client = SupabaseClient(
      'http://localhost:54321',
      'sb_publishable_test',
      httpClient: MockClient(
        (request) async => http.Response(
          jsonEncode({
            'sermon': {...publicSermonData(), 'saved_by': 'private editor'},
          }),
          200,
          headers: {'content-type': 'application/json'},
          request: request,
        ),
      ),
      authOptions: const AuthClientOptions(autoRefreshToken: false),
    );
    addTearDown(client.dispose);
    expect(
      await SupabaseSermonsRepository(client)
          .fetchPublicSermon('92929292-9292-4292-8292-929292929292'),
      isA<AccessReadFailed<PublicSermonRead>>(),
    );
  });
}

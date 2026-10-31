import 'dart:convert';

import 'package:church_client_core/church_client_core.dart';
import 'package:church_client_core/supabase_adapters.dart';
import 'package:church_client_core/testing.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase/supabase.dart';

const id = '66666666-6666-4666-8666-666666666666';
const other = '77777777-7777-4777-8777-777777777777';
String b64(Object o) =>
    base64Url.encode(utf8.encode(jsonEncode(o))).replaceAll('=', '');
Map<String, Object?> session() => {
  'access_token':
      '${b64({'alg': 'none'})}.${b64({'sub': id, 'exp': 4102444800, 'role': 'authenticated'})}.x',
  'refresh_token': 'test-only-refresh',
  'token_type': 'bearer',
  'expires_in': 3600,
  'expires_at': 4102444800,
  'user': {
    'id': id,
    'aud': 'authenticated',
    'role': 'authenticated',
    'phone': '447700900818',
    'app_metadata': <String, Object?>{},
    'user_metadata': <String, Object?>{},
    'created_at': '2026-10-31T12:00:00Z',
  },
};
void main() {
  late List<http.Request> requests;
  Future<SupabaseClient> client(
    Object Function(http.Request) response, {
    int status = 200,
    bool signIn = true,
  }) async {
    requests = [];
    final c = SupabaseClient(
      'http://localhost:54321',
      'sb_publishable_test',
      httpClient: MockClient((r) async {
        if (r.url.path.startsWith('/auth/')) {
          return http.Response(
            jsonEncode(session()),
            200,
            headers: {'content-type': 'application/json'},
            request: r,
          );
        }
        requests.add(r);
        return http.Response(
          jsonEncode(response(r)),
          status,
          headers: {'content-type': 'application/json'},
          request: r,
        );
      }),
      authOptions: const AuthClientOptions(autoRefreshToken: false),
    );
    addTearDown(c.dispose);
    if (signIn) {
      await c.auth.signInWithPassword(
        phone: '+447700900818',
        password: 'test-only',
      );
    }
    return c;
  }

  test(
    'directory uses api RPC with all independent filters and exact cursor',
    () async {
      final c = await client(
        (_) => {
          'members': [managedMemberData()],
          'roles': [],
          'next': null,
        },
      );
      final r = await SupabaseUserManagementRepository(c).directory(
        const UserFilter(
          query: '  Ruth  ',
          membership: 'deactivated',
          account: 'access_review',
          role: 'media',
        ),
        after: const MemberCursor('SYNTHETIC Ruth', id),
      );
      expect(
        r,
        isA<AccessReadOk<UserDirectoryPage>>(),
        reason: r is AccessReadFailed<UserDirectoryPage>
            ? r.cause.toString()
            : null,
      );
      expect(requests.single.url.path, '/rest/v1/rpc/identity_admin_users');
      expect(requests.single.headers['content-profile'], 'api');
      expect(jsonDecode(requests.single.body), {
        'query': 'Ruth',
        'membership': 'deactivated',
        'account': 'access_review',
        'role_filter': 'media',
        'after_display_name': 'SYNTHETIC Ruth',
        'after_member_id': id,
      });
    },
  );
  test('detail refuses a server response for another person', () async {
    final c = await client(
      (_) => {'member': managedMemberData(id: other), 'own_record': false},
    );
    expect(
      await SupabaseUserManagementRepository(c).detail(id),
      isA<AccessReadFailed<UserDetail>>(),
    );
  });
  test(
    'activity uses exact timestamp and string event id without number rounding',
    () async {
      final c = await client((_) => {'events': [], 'next': null});
      await SupabaseUserManagementRepository(c).activity(
        id,
        after: const UserActivityCursor(
          '2026-10-31T14:00:00.123456Z',
          'profile',
          '9007199254740993',
        ),
      );
      expect(jsonDecode(requests.single.body), {
        'member_id': id,
        'after_at': '2026-10-31T14:00:00.123456Z',
        'after_source': 'profile',
        'after_event_id': '9007199254740993',
      });
    },
  );
  test('signed-out management reads make no network call', () async {
    final c = await client((_) => {}, signIn: false);
    expect(
      await SupabaseUserManagementRepository(c).detail(id),
      isA<AccessReadDenied<UserDetail>>(),
    );
    expect(requests, isEmpty);
  });
  test('server permission denial is not an empty directory', () async {
    final c = await client(
      (_) => {
        'code': '42501',
        'message': 'forbidden',
        'details': 'not_granted',
      },
      status: 403,
    );
    expect(
      await SupabaseUserManagementRepository(c).directory(const UserFilter()),
      isA<AccessReadDenied<UserDirectoryPage>>(),
    );
    expect(requests, hasLength(1));
  });
}

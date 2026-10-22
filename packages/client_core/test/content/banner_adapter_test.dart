// Story 6.2: the Supabase banner adapter's calls to the Edge function
// `content-assets` (upload, sync, preview) against a mock HTTP server: the
// editor's session goes as a bearer token, the picked bytes go as they are
// with the browser's declared type, and every answer maps to a typed
// outcome (refusals keep the server's field errors; no answer is
// unreachable, never success).
import 'dart:convert';
import 'dart:typed_data';

import 'package:church_client_core/church_client_core.dart';
import 'package:church_client_core/supabase_adapters.dart';
import 'package:church_client_core/testing.dart';
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

String _jwt() {
  String b64(Object o) =>
      base64Url.encode(utf8.encode(jsonEncode(o))).replaceAll('=', '');
  return '${b64({'alg': 'none'})}.${b64({
    'sub': '11111111-1111-4111-8111-111111111111',
    'exp': 4102444800,
    'amr': [
      {'method': 'password', 'timestamp': 1790000000},
    ],
    'role': 'authenticated',
  })}.x';
}

final _session = {
  'access_token': _jwt(),
  'token_type': 'bearer',
  'expires_in': 3600,
  'expires_at': 4102444800,
  'refresh_token': 'test-refresh',
  'user': {
    'id': '11111111-1111-4111-8111-111111111111',
    'aud': 'authenticated',
    'role': 'authenticated',
    'phone': '447700900501',
    'app_metadata': <String, Object?>{},
    'user_metadata': <String, Object?>{},
    'created_at': '2026-10-21T12:00:00Z',
  },
};

const _item = '82828282-8282-4282-8282-828282828282';
const _asset = '61616161-6161-4161-8161-616161616161';

Future<(SupabaseBannerRepository, List<http.Request>)> _repo(
  Future<http.Response> Function(http.Request r) answer, {
  bool signedIn = true,
}) async {
  final client = SupabaseClient(
    'http://localhost:54321',
    'sb_publishable_test',
    httpClient: MockClient((r) async {
      if (r.url.path == '/auth/v1/user') {
        return http.Response(jsonEncode(_session['user']), 200);
      }
      return http.Response('{}', 500);
    }),
    authOptions: AuthClientOptions(
      autoRefreshToken: false,
      pkceAsyncStorage: _MemoryStorage(),
    ),
  );
  addTearDown(client.dispose);
  if (signedIn) await client.auth.recoverSession(jsonEncode(_session));
  final sent = <http.Request>[];
  final repo = SupabaseBannerRepository(
    client,
    supabaseUrl: 'http://localhost:54321/',
    publishableKey: 'sb_publishable_test',
    httpClient: MockClient((r) {
      sent.add(r);
      return answer(r);
    }),
  );
  return (repo, sent);
}

PickedFile _file() => PickedFile(
  name: 'theme.png',
  declaredType: 'image/png',
  bytes: Uint8List.fromList([1, 2, 3]),
);

http.Response _json(Object body, int status) =>
    http.Response(jsonEncode(body), status);

void main() {
  test(
    'an upload sends the bytes with the session and the declared type',
    () async {
      final (repo, sent) = await _repo(
        (r) async => _json({
          'outcome': 'uploaded',
          'asset_id': _asset,
          'media_type': 'image/png',
          'byte_size': 3,
          'width': 1920,
          'height': 1080,
        }, 200),
      );
      final out = await repo.uploadImage(_item, 'banner_image', _file());
      expect(out, isA<ImageUploaded>());
      expect((out as ImageUploaded).image.assetId, _asset);
      final r = sent.single;
      expect(r.method, 'POST');
      expect(r.url.path, '/functions/v1/content-assets');
      expect(r.url.queryParameters, {
        'action': 'upload',
        'item_id': _item,
        'purpose': 'banner_image',
      });
      expect(r.headers['apikey'], 'sb_publishable_test');
      expect(r.headers['Authorization'], 'Bearer ${_session['access_token']}');
      expect(r.headers['content-type'], startsWith('image/png'));
      expect(r.bodyBytes, [1, 2, 3]);
    },
  );

  test('refusals keep the server\'s field errors', () async {
    for (final status in [413, 415, 422]) {
      final (repo, _) = await _repo(
        (r) async => _json({
          'outcome': 'refused',
          'code': 'validation_failed',
          'field_errors': {'file': 'unsupported_type'},
        }, status),
      );
      final out = await repo.uploadImage(_item, 'banner_image', _file());
      expect(out, isA<ImageUploadRefused>(), reason: '$status');
      expect((out as ImageUploadRefused).reason, 'unsupported_type');
      expect(out.code, 'validation_failed');
    }
  });

  test('denials, failures and no answer are never success', () async {
    Future<ImageUploadOutcome> upload(int status) async {
      final (repo, _) = await _repo((r) async => _json({}, status));
      return repo.uploadImage(_item, 'banner_image', _file());
    }

    expect(await upload(403), isA<ImageUploadNotAllowed>());
    expect(await upload(503), isA<ImageUploadFailed>());
    expect(
      await upload(200),
      isA<ImageUploadFailed>(),
      reason: 'an unreadable success is not a success',
    );
    final (down, _) = await _repo(
      (r) async => throw http.ClientException('down'),
    );
    final out = await down.uploadImage(_item, 'banner_image', _file());
    expect(out, isA<ImageUploadFailed>());
    expect((out as ImageUploadFailed).unreachable, isTrue);
    final (signedOut, sent) = await _repo(
      (r) async => _json({}, 200),
      signedIn: false,
    );
    expect(
      await signedOut.uploadImage(_item, 'banner_image', _file()),
      isA<ImageUploadSignedOut>(),
    );
    expect(sent, isEmpty, reason: 'nothing is sent without a session');
  });

  test('a file too large to read is refused without a call', () async {
    final (repo, sent) = await _repo((r) async => _json({}, 200));
    final out = await repo.uploadImage(
      _item,
      'banner_image',
      PickedFile(
        name: 'huge.png',
        declaredType: 'image/png',
        bytes: Uint8List(0),
        size: 40 << 20,
      ),
    );
    expect((out as ImageUploadRefused).reason, 'too_large');
    expect(sent, isEmpty);
  });

  test('sync and preview', () async {
    final (repo, sent) = await _repo((r) async {
      if (r.url.queryParameters['action'] == 'sync') {
        return _json({
          'outcome': 'synced',
          'placed': 1,
          'removed': 1,
          'waiting': 0,
          'removals_pending': 0,
        }, 200);
      }
      if (r.url.queryParameters['asset_id'] == _asset) {
        return http.Response.bytes(
          [9, 9],
          200,
          headers: {'content-type': 'image/png'},
        );
      }
      return http.Response(
        '<html>',
        200,
        headers: {'content-type': 'text/html'},
      );
    });
    final s = await repo.syncFiles();
    expect((s as FileSyncDone).placed, 1);
    expect(sent.first.method, 'POST');
    expect(await repo.previewImage(_asset), [9, 9]);
    expect(sent.last.method, 'GET');
    expect(sent.last.url.queryParameters, {
      'action': 'preview',
      'asset_id': _asset,
    });
    expect(
      await repo.previewImage('62626262-6262-4262-8262-626262626262'),
      isNull,
      reason: 'only an image is shown',
    );
    expect(
      repo.publicFileUrl('banner/$_item/r1/image.png').toString(),
      'http://localhost:54321/storage/v1/object/public/content-public/'
      'banner/$_item/r1/image.png',
    );
  });

  test(
    'only an offline-cleared public image is fetched for the cache',
    () async {
      final (repo, sent) = await _repo((r) async {
        return http.Response.bytes(
          [7, 8, 9],
          200,
          headers: {'content-type': 'image/png; charset=binary'},
        );
      });
      final banner = PublicBanner.fromJson(publicBannerData());
      expect(await repo.fetchPublicImage(banner), [7, 8, 9]);
      expect(sent.single.method, 'GET');
      expect(
        sent.single.url.path,
        contains('/storage/v1/object/public/content-public/'),
      );
      expect(sent.single.headers['apikey'], 'sb_publishable_test');
      sent.clear();

      expect(
        await repo.fetchPublicImage(
          PublicBanner.fromJson(publicBannerData(offlineAllowed: false)),
        ),
        isNull,
      );
      expect(sent, isEmpty);
    },
  );
}

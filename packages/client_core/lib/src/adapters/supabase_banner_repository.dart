import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:supabase/supabase.dart';

import '../domain/access_grants.dart';
import '../domain/content_banners.dart';
import 'supabase_api_reader.dart';

/// Supabase adapter for [BannerRepository] (story 6.2): the public banner
/// read (`api.content_public_banners`, signed-out callers too), the editors'
/// banner and rights reads, and the Edge function `content-assets` (upload,
/// sync, preview) called with the editor's live session. The server decides
/// everything; this only maps the answers. Nothing is stored here.
class SupabaseBannerRepository implements BannerRepository {
  SupabaseBannerRepository(
    this._client, {
    required String supabaseUrl,
    required String publishableKey,
    http.Client? httpClient,
    Duration timeout = const Duration(seconds: 10),
    this.uploadTimeout = const Duration(seconds: 60),
  }) : _base = supabaseUrl.replaceAll(RegExp(r'/+$'), ''),
       _key = publishableKey,
       _http = httpClient ?? http.Client(),
       _timeout = timeout,
       _reader = SupabaseApiReader(_client, timeout: timeout);

  final SupabaseClient _client;
  final String _base;
  final String _key;
  final http.Client _http;
  final Duration _timeout;
  final Duration uploadTimeout;
  final SupabaseApiReader _reader;

  Uri _function(Map<String, String> query) =>
      Uri.parse('$_base/functions/v1/content-assets')
          .replace(queryParameters: query);

  @override
  Future<AccessRead<PublicBanners>> fetchPublicBanners() => _reader.read(
    'content_public_banners',
    const {},
    PublicBanners.fromJson,
    public: true,
  );

  @override
  Future<AccessRead<StaffBanners>> fetchStaffBanners() =>
      _reader.read('content_staff_banners', const {}, StaffBanners.fromJson);

  @override
  Future<AccessRead<StaffRights>> fetchStaffRights() =>
      _reader.read('content_staff_rights', const {}, StaffRights.fromJson);

  @override
  Uri publicFileUrl(String path) => Uri.parse(
    '$_base/storage/v1/object/public/$contentPublicBucket/'
    '${path.split('/').map(Uri.encodeComponent).join('/')}',
  );

  @override
  Future<Uint8List?> fetchPublicImage(PublicBanner banner) async {
    if (!banner.offlineAllowed) return null;
    return _fetchPublicAsset(
      banner.image.path,
      banner.image.mediaType,
      maxBytes: 5 * 1024 * 1024,
    );
  }

  @override
  Future<Uint8List?> fetchPublicAsset(String path, String mediaType) =>
      _fetchPublicAsset(path, mediaType, maxBytes: 2 * 1024 * 1024);

  Future<Uint8List?> _fetchPublicAsset(
    String path,
    String mediaType, {
    required int maxBytes,
  }) async {
    if (!contentImageTypes.contains(mediaType) ||
        path.startsWith('/') ||
        path.contains('..')) {
      return null;
    }
    final abortTrigger = Completer<void>();
    void abortRequest() {
      if (!abortTrigger.isCompleted) abortTrigger.complete();
    }

    try {
      final request = http.AbortableRequest(
        'GET',
        publicFileUrl(path),
        abortTrigger: abortTrigger.future,
      )..headers.addAll({'apikey': _key, 'accept': mediaType});
      final responseFuture = _http.send(request);
      late final http.StreamedResponse response;
      try {
        response = await responseFuture.timeout(_timeout);
      } on TimeoutException {
        abortRequest();
        try {
          await responseFuture;
        } catch (_) {}
        return null;
      }
      final receivedMediaType = response.headers['content-type']
          ?.split(';')
          .first
          .trim()
          .toLowerCase();
      Future<void> abandonResponse() async {
        try {
          await response.stream.listen((_) {}).cancel();
        } catch (_) {}
        abortRequest();
      }

      if (response.statusCode != 200 ||
          receivedMediaType != mediaType ||
          (response.contentLength != null &&
              response.contentLength! > maxBytes)) {
        await abandonResponse();
        return null;
      }
      Future<Uint8List?> readBoundedBody() async {
        final bytes = BytesBuilder(copy: false);
        var length = 0;
        await for (final chunk in response.stream) {
          if (chunk.length > maxBytes - length) {
            abortRequest();
            return null;
          }
          bytes.add(chunk);
          length += chunk.length;
        }
        final result = bytes.takeBytes();
        return result.isEmpty ? null : result;
      }

      final bodyFuture = readBoundedBody();
      try {
        return await bodyFuture.timeout(_timeout);
      } on TimeoutException {
        abortRequest();
        try {
          await bodyFuture;
        } catch (_) {}
        return null;
      }
    } on http.ClientException {
      abortRequest();
      return null;
    } catch (_) {
      abortRequest();
      return null;
    }
  }

  /// One call to the Edge function with the current session; a 401 is
  /// retried once after a session refresh. Null when unreachable.
  Future<http.Response?> _call(
    String method,
    Map<String, String> query, {
    Uint8List? body,
    String? contentType,
    Duration? timeout,
  }) async {
    Future<http.Response?> once() async {
      final token = _client.auth.currentSession?.accessToken;
      if (token == null) return http.Response('', 401);
      final request = http.Request(method, _function(query))
        ..headers.addAll({
          'apikey': _key,
          'Authorization': 'Bearer $token',
          'content-type': ?contentType,
        });
      if (body != null) request.bodyBytes = body;
      try {
        final streamed = await _http.send(request).timeout(timeout ?? _timeout);
        return await http.Response.fromStream(streamed)
            .timeout(timeout ?? _timeout);
      } on TimeoutException {
        return null;
      } on http.ClientException {
        return null;
      } catch (_) {
        return null;
      }
    }

    final first = await once();
    if (first?.statusCode != 401 || _client.auth.currentSession == null) {
      return first;
    }
    try {
      await _client.auth.refreshSession();
    } catch (_) {
      return first;
    }
    return once();
  }

  static Map<String, Object?> _json(http.Response res) {
    try {
      final v = jsonDecode(res.body);
      return v is Map<String, Object?> ? v : const {};
    } on FormatException {
      return const {};
    }
  }

  static Map<String, String> _fieldErrors(Object? v) => {
    if (v is Map)
      for (final e in v.entries)
        if (e.key is String && e.value is String)
          e.key as String: e.value as String,
  };

  @override
  Future<ImageUploadOutcome> uploadImage(
    String itemId,
    String purpose,
    PickedFile file,
  ) async {
    if (file.unreadable) {
      return const ImageUploadRefused(fieldErrors: {'file': 'too_large'});
    }
    final res = await _call(
      'POST',
      {'action': 'upload', 'item_id': itemId, 'purpose': purpose},
      body: file.bytes,
      contentType: file.declaredType ?? 'application/octet-stream',
      timeout: uploadTimeout,
    );
    if (res == null) return const ImageUploadFailed(unreachable: true);
    final json = _json(res);
    switch (res.statusCode) {
      case 200:
        try {
          return ImageUploaded(UploadedImage.fromJson(json));
        } on FormatException {
          return const ImageUploadFailed(unreachable: false);
        }
      case 401:
        return const ImageUploadSignedOut();
      case 403:
        return const ImageUploadNotAllowed();
      case 400 || 404 || 409 || 413 || 415 || 422:
        return ImageUploadRefused(
          code: json['code'] is String ? json['code'] as String : null,
          fieldErrors: _fieldErrors(json['field_errors']),
        );
      default:
        return const ImageUploadFailed(unreachable: false);
    }
  }

  @override
  Future<FileSyncOutcome> syncFiles() async {
    final res = await _call('POST', const {
      'action': 'sync',
    }, timeout: uploadTimeout);
    if (res == null) return const FileSyncFailed(unreachable: true);
    switch (res.statusCode) {
      case 200:
        try {
          return FileSyncDone.fromJson(_json(res));
        } on FormatException {
          return const FileSyncFailed(unreachable: false);
        }
      case 401 || 403:
        return const FileSyncNotAllowed();
      default:
        return const FileSyncFailed(unreachable: false);
    }
  }

  @override
  Future<Uint8List?> previewImage(String assetId) async {
    final res = await _call('GET', {'action': 'preview', 'asset_id': assetId});
    if (res == null || res.statusCode != 200 || res.bodyBytes.isEmpty) {
      return null;
    }
    final type = res.headers['content-type'] ?? '';
    if (!contentImageTypes.any(type.startsWith)) return null;
    return res.bodyBytes;
  }
}

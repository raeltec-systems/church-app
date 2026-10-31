import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../domain/admin_onboarding.dart';

/// Public-client transport to the narrowly scoped commissioning function.
/// No ambient user session, server credential, persistent store or logging.
final class SupabaseAdminOnboardingRepository
    implements AdminOnboardingRepository {
  SupabaseAdminOnboardingRepository({
    required String supabaseUrl,
    required String publishableKey,
    http.Client? httpClient,
    this.timeout = const Duration(seconds: 30),
  }) : _endpoint = Uri.parse(
         '${supabaseUrl.replaceAll(RegExp(r'/+$'), '')}'
         '/functions/v1/identity-admin-onboarding',
       ),
       _key = publishableKey,
       _http = httpClient ?? http.Client() {
    final local =
        _endpoint.scheme == 'http' &&
        const {'127.0.0.1', 'localhost', '10.0.2.2'}.contains(_endpoint.host);
    if ((_endpoint.scheme != 'https' && !local) ||
        _endpoint.userInfo.isNotEmpty ||
        _endpoint.hasQuery ||
        _endpoint.hasFragment ||
        !_key.startsWith('sb_publishable_')) {
      throw ArgumentError(
        'Expected a secure endpoint and publishable client key',
      );
    }
  }

  final Uri _endpoint;
  final String _key;
  final http.Client _http;
  final Duration timeout;

  void close() => _http.close();

  Future<AdminOnboardingReply> _post(
    Map<String, Object?> body, {
    bool mutation = false,
  }) async {
    AdminOnboardingReply unknown() => AdminOnboardingReply(
      mutation
          ? AdminOnboardingOutcome.uncertain
          : AdminOnboardingOutcome.unavailable,
    );
    try {
      final deadline = DateTime.now().add(timeout);
      Duration remaining() {
        final left = deadline.difference(DateTime.now());
        if (left <= Duration.zero) {
          throw TimeoutException('Commissioning deadline');
        }
        return left;
      }

      final request = http.Request('POST', _endpoint)
        ..followRedirects = false
        ..headers.addAll({
          'apikey': _key,
          'content-type': 'application/json',
          'accept': 'application/json',
        })
        ..body = jsonEncode(body);
      final response = await _http.send(request).timeout(remaining());
      final bytes = <int>[];
      // Bounded decoding, including chunked answers without Content-Length.
      final chunks = StreamIterator<List<int>>(response.stream);
      try {
        while (await chunks.moveNext().timeout(remaining())) {
          final part = chunks.current;
          if (bytes.length + part.length > 32768) return unknown();
          bytes.addAll(part);
        }
      } finally {
        await chunks.cancel();
      }
      if (response.statusCode == 429) {
        return const AdminOnboardingReply(AdminOnboardingOutcome.rateLimited);
      }
      if (response.statusCode >= 500) return unknown();
      final reply = AdminOnboardingReply.fromJson(
        jsonDecode(utf8.decode(bytes)),
      );
      // A proxy/refusal may carry JSON that resembles success. HTTP must agree.
      if (response.statusCode != 200 &&
          !const {
            AdminOnboardingOutcome.refused,
            AdminOnboardingOutcome.passwordRejected,
            AdminOnboardingOutcome.rateLimited,
          }.contains(reply.outcome)) {
        return unknown();
      }
      return reply;
    } on TimeoutException {
      return unknown();
    } on http.ClientException {
      return unknown();
    } on FormatException {
      return unknown();
    } catch (_) {
      return unknown();
    }
  }

  @override
  Future<AdminOnboardingReply> inspect({
    required AdminInvitation invitation,
    required String phoneUsername,
  }) => _post({
    'version': 1,
    'action': 'inspect',
    'invitation': invitation.value,
    'phone_username': phoneUsername,
  });

  @override
  Future<AdminOnboardingReply> complete({
    required AdminInvitation invitation,
    required String phoneUsername,
    required String fullName,
    required String password,
    required String privacyVersion,
    required String requestId,
  }) => _post({
    'version': 1,
    'action': 'complete',
    'invitation': invitation.value,
    'phone_username': phoneUsername,
    'full_name': fullName,
    'password': password,
    'privacy_notice_version': privacyVersion,
    'privacy_accepted': true,
    'request_id': requestId,
  }, mutation: true);

  @override
  Future<AdminOnboardingReply> status({
    required AdminInvitation invitation,
    required String phoneUsername,
    required String requestId,
  }) => _post({
    'version': 1,
    'action': 'status',
    'invitation': invitation.value,
    'phone_username': phoneUsername,
    'request_id': requestId,
  });
}

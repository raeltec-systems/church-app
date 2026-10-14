import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:supabase/supabase.dart';

import '../domain/access_grants.dart';
import '../domain/assisted_recovery.dart';
import 'supabase_api_reader.dart';

/// The member device's side of staff-assisted recovery (story 2.9): the Edge
/// Function `identity-assisted-recovery`, called with the publishable key
/// only. The device has no session in recovery, and no user token is sent
/// even when one exists: the single-use grant is the only authority. The
/// secret is sent once, with the password, and never stored or logged here.
class SupabaseAssistedRecoveryGateway implements AssistedRecoveryGateway {
  SupabaseAssistedRecoveryGateway({
    required String supabaseUrl,
    required String publishableKey,
    http.Client? httpClient,
    this.timeout = const Duration(seconds: 25),
  }) : _endpoint = Uri.parse(
         '${supabaseUrl.replaceAll(RegExp(r'/+$'), '')}'
         '/functions/v1/identity-assisted-recovery',
       ),
       _key = publishableKey,
       _http = httpClient ?? http.Client();

  final Uri _endpoint;
  final String _key;
  final http.Client _http;
  final Duration timeout;

  /// The function's answer: (status, outcome map) or null when unreachable.
  Future<(int, Map<String, Object?>)?> _post(Map<String, Object?> body) async {
    try {
      final res = await _http
          .post(
            _endpoint,
            headers: {
              'apikey': _key,
              // A legacy JWT key also authorizes at the gateway; a new
              // sb_publishable_ key is sent as the apikey only.
              if (_key.startsWith('eyJ')) 'Authorization': 'Bearer $_key',
              'Content-Type': 'application/json',
            },
            body: jsonEncode(body),
          )
          .timeout(timeout);
      Object? json;
      try {
        json = jsonDecode(res.body);
      } on FormatException {
        json = null;
      }
      return (
        res.statusCode,
        json is Map<String, Object?> ? json : const <String, Object?>{},
      );
    } on TimeoutException {
      return null;
    } on http.ClientException {
      return null;
    } catch (_) {
      return null;
    }
  }

  static DateTime? _time(Object? v) =>
      v is String ? DateTime.tryParse(v) : null;

  @override
  Future<RecoveryRequestOutcome> request(
    String phoneUsername,
    String digest,
  ) async {
    final r = await _post({
      'action': 'request',
      'phone_username': phoneUsername,
      'grant_digest': digest,
    });
    if (r == null) {
      return const RecoveryRequestNotReceived(RecoveryFailure.unreachable);
    }
    final (status, json) = r;
    final code = json['request_code'];
    if (status == 200 && json['outcome'] == 'received' && code is String) {
      return RecoveryRequestReceived(code, _time(json['expires_at']));
    }
    return RecoveryRequestNotReceived(switch (json['outcome']) {
      'rate_limited' => RecoveryFailure.rateLimited,
      'refused' || 'invalid' => RecoveryFailure.refused,
      _ => RecoveryFailure.unavailable,
    });
  }

  @override
  Future<RecoveryStatusOutcome> status(String digest) async {
    final r = await _post({'action': 'status', 'grant_digest': digest});
    if (r == null) {
      return const RecoveryStatusFailed(RecoveryFailure.unreachable);
    }
    final (status, json) = r;
    if (status != 200) {
      return const RecoveryStatusFailed(RecoveryFailure.unavailable);
    }
    return RecoveryStatus(switch (json['outcome']) {
      'waiting' => RecoveryGrantState.waiting,
      'ready' => RecoveryGrantState.ready,
      _ => RecoveryGrantState.closed,
    }, _time(json['expires_at']));
  }

  @override
  Future<RedeemOutcome> redeem(
    String phoneUsername,
    GrantSecret secret,
    String password,
  ) async {
    final r = await _post({
      'action': 'redeem',
      'phone_username': phoneUsername,
      'grant_secret': secret.value,
      'password': password,
    });
    // No answer: the setup may or may not have been used.
    if (r == null) return RedeemOutcome.unreachable;
    final (status, json) = r;
    if (status == 400) return RedeemOutcome.invalid;
    return switch (json['outcome']) {
      'succeeded' => RedeemOutcome.succeeded,
      'rejected' => RedeemOutcome.rejected,
      'password_rejected' => RedeemOutcome.passwordRejected,
      'uncertain' => RedeemOutcome.uncertain,
      'rate_limited' => RedeemOutcome.rateLimited,
      _ => RedeemOutcome.unavailable,
    };
  }
}

/// Supabase adapter for the Admin read `api.identity_admin_recovery_cases`.
class SupabaseRecoveryCasesRepository implements RecoveryCasesRepository {
  SupabaseRecoveryCasesRepository(
    SupabaseClient client, {
    Duration timeout = const Duration(seconds: 10),
  }) : _reader = SupabaseApiReader(client, timeout: timeout);

  final SupabaseApiReader _reader;

  @override
  Future<AccessRead<RecoveryCases>> fetchCases() => _reader.read(
    'identity_admin_recovery_cases',
    const {},
    RecoveryCases.fromJson,
  );
}

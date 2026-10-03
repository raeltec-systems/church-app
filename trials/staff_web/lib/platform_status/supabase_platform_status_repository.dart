// Disposable Flutter Web trial (Q10): copied from apps/mobile; do not build on this.
import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

import 'platform_status.dart';

/// Supabase adapter for [PlatformStatusRepository].
///
/// Reads the allowlisted `api.platform_status` view only; it never writes.
class SupabasePlatformStatusRepository implements PlatformStatusRepository {
  SupabasePlatformStatusRepository(
    this._client, {
    this.timeout = const Duration(seconds: 10),
  });

  final SupabaseClient _client;

  /// Upper bound for the single request; on expiry the request is aborted.
  /// SDK auto-retry is off for this read: the user's Try again is the retry.
  final Duration timeout;

  @override
  Future<PlatformStatus?> fetch() async {
    final Map<String, dynamic>? row;
    try {
      row = await _client
          .schema('api')
          .from('platform_status')
          .select('status, message, is_synthetic, updated_at')
          .limit(1)
          .maybeSingle()
          .retry(enabled: false)
          .abortSignal(Future<void>.delayed(timeout));
    } on RequestAbortedException catch (e) {
      throw PlatformStatusException(PlatformStatusFailure.unreachable, e);
    } on TimeoutException catch (e) {
      throw PlatformStatusException(PlatformStatusFailure.unreachable, e);
    } on http.ClientException catch (e) {
      // Socket, DNS and browser fetch failures all surface as ClientException.
      throw PlatformStatusException(PlatformStatusFailure.unreachable, e);
    } on PostgrestException catch (e) {
      throw PlatformStatusException(PlatformStatusFailure.rejected, e);
    } catch (e) {
      throw PlatformStatusException(PlatformStatusFailure.rejected, e);
    }
    if (row == null) return null;
    try {
      return PlatformStatus.fromRow(row);
    } on FormatException catch (e) {
      throw PlatformStatusException(PlatformStatusFailure.rejected, e);
    }
  }
}

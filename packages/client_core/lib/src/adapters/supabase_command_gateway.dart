import 'dart:async';

import 'package:church_contracts/church_contracts.dart';
import 'package:http/http.dart' as http;
import 'package:supabase/supabase.dart' hide ErrorCode;

import '../domain/commands.dart';

/// Supabase adapter for [CommandGateway]: `POST /rest/v1/rpc/<function>` with
/// `Content-Profile: api` and the whole envelope as the single JSON body.
///
/// Outcome rules (architecture "Client state", story 1.4):
/// - a contract-valid error envelope, or an API refusal carrying a PostgREST
///   or Postgres error code, is definite: the command did not apply;
/// - an abort/timeout, a transport failure, a gateway status (502/503/504),
///   a non-JSON or contract-invalid body, or a mismatched request id is
///   unknown outcome: never success.
class SupabaseCommandGateway implements CommandGateway {
  SupabaseCommandGateway(
    this._client, {
    this.timeout = const Duration(seconds: 10),
  });

  final SupabaseClient _client;

  /// Upper bound for one request; on expiry the request is aborted and the
  /// outcome is unknown. No automatic retry: the user's Check again resends.
  final Duration timeout;

  @override
  Future<CommandOutcome> send(String function, CommandRequest request) async {
    final Object? body;
    try {
      body = await _client
          .schema('api')
          .rpc<dynamic>(function, params: request.toJson())
          .retry(enabled: false)
          .abortSignal(Future<void>.delayed(timeout));
    } on RequestAbortedException catch (e) {
      return CommandUnknownOutcome(e);
    } on TimeoutException catch (e) {
      return CommandUnknownOutcome(e);
    } on http.ClientException catch (e) {
      // Socket, DNS and browser fetch failures: the request may have arrived.
      return CommandUnknownOutcome(e);
    } on PostgrestException catch (e) {
      return _fromApiError(request, e);
    } catch (e) {
      return CommandUnknownOutcome(e);
    }

    final CommandResponse response;
    try {
      response = CommandResponse.fromJson(body);
    } on ContractViolation catch (e) {
      return CommandUnknownOutcome(e);
    }
    switch (response) {
      case CommandSuccess():
        if (response.requestId != request.requestId) {
          return CommandUnknownOutcome('request_id mismatch');
        }
        return CommandConfirmed(response);
      case CommandError():
        if (response.requestId != null &&
            response.requestId != request.requestId) {
          return CommandUnknownOutcome('request_id mismatch');
        }
        return CommandRefused(response);
    }
  }

  CommandOutcome _fromApiError(CommandRequest request, PostgrestException e) {
    final code = e.code ?? '';
    final status = RegExp(r'^\d{3}$').hasMatch(code) ? int.parse(code) : null;
    if (status != null) {
      // No PostgREST/Postgres code: the body did not come from PostgREST
      // (gateway page, proxy, truncated 2xx body).
      if (status == 401) return _refused(request, ErrorCode.unauthenticated);
      if (status == 403) return _refused(request, ErrorCode.forbidden);
      if (status == 429) return _refused(request, ErrorCode.rateLimited);
      if (status >= 200 && status < 300 || status >= 500) {
        return CommandUnknownOutcome(e);
      }
      return _refused(request, ErrorCode.unavailable);
    }
    // PostgREST rejected the call before running it (JWT, privileges,
    // unknown function) or Postgres aborted the transaction: nothing applied.
    if (code == '42501') {
      return _refused(
        request,
        _client.auth.currentSession == null
            ? ErrorCode.unauthenticated
            : ErrorCode.forbidden,
      );
    }
    if (code.startsWith('PGRST3')) {
      return _refused(request, ErrorCode.unauthenticated);
    }
    return _refused(request, ErrorCode.unavailable);
  }

  CommandRefused _refused(CommandRequest request, ErrorCode code) =>
      CommandRefused(
        CommandError(
          requestId: request.requestId,
          code: code,
          message: switch (code) {
            ErrorCode.unauthenticated => 'Sign in required.',
            ErrorCode.forbidden => 'Not allowed.',
            ErrorCode.rateLimited => 'Too many requests.',
            _ => 'The service is unavailable.',
          },
          fieldErrors: const {},
        ),
      );
}

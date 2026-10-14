import 'dart:async';

import 'package:church_contracts/church_contracts.dart';
import 'package:http/http.dart' as http;
import 'package:supabase/supabase.dart' hide ErrorCode;

import '../domain/commands.dart';

/// Supabase adapter for [CommandGateway]: `POST /rest/v1/rpc/<function>` with
/// `Content-Profile: api` and the whole envelope as the single JSON body.
///
/// Outcome rules (architecture "Client state", story 1.4):
/// - a contract-valid error envelope, or an API refusal whose body carries a
///   PostgREST or Postgres error code, is definite: the command did not apply;
/// - an abort/timeout, a transport failure, any bare HTTP status without a
///   PostgREST body (proxy 408, 3xx, gateway 5xx, 401 from the gateway…), a
///   non-JSON or contract-invalid body, or a mismatched request id is
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
    // Only an answer from PostgREST itself (a Postgres SQLSTATE or a PGRST
    // code in its JSON body) is definite. A bare HTTP status (proxy 408, 3xx,
    // gateway 5xx, an HTML page, a truncated 2xx body) does not say whether
    // the command ran: unknown outcome, so the same request is checked again.
    final fromPostgrest =
        RegExp(r'^PGRST\d+$').hasMatch(code) ||
        RegExp(r'^[0-9A-Z]{5}$').hasMatch(code);
    if (!fromPostgrest) return CommandUnknownOutcome(e);
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

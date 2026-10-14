// Fix after story 2.8 (fix-field-error-vocabulary.md): the REAL
// SupabaseCommandGateway parsing path on server refusals that carry
// command-specific field error codes. The bodies below are the envelopes
// app.cmd_error_envelope writes for those refusals (recorded from the local
// stack; supabase/tests/*_test.sql assert the same field errors). Before the
// fix the v1 contract's closed field-error list made the client read each of
// them as an unknown outcome; screen tests missed it because they use
// FakeCommandGateway.
import 'dart:async';
import 'dart:convert';

import 'package:church_client_core/church_client_core.dart';
import 'package:church_client_core/supabase_adapters.dart';
import 'package:church_client_core/testing.dart';
import 'package:church_contracts/church_contracts.dart';
import 'package:church_design_system/church_design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase/supabase.dart' hide ErrorCode;

const _messages = {
  'validation_failed': 'The request is not valid.',
  'forbidden': 'You are not allowed to do this.',
  'conflict': 'The item changed or this request was already used. Reload and try again.',
};

/// A recorded refusal: what the server answered, minus the request id (the
/// mock echoes the one the gateway sent, as the server does).
typedef _Recorded = ({
  String function,
  String command,
  String code,
  Map<String, String> fieldErrors,
  int? currentRevision,
});

const List<_Recorded> _recorded = [
  (
    function: 'identity_credential_command',
    command: 'identity.release_hold',
    code: 'conflict',
    fieldErrors: {'hold_id': 'password_reset_required'},
    currentRevision: null,
  ),
  (
    function: 'identity_credential_command',
    command: 'identity.approve_credential_change',
    code: 'conflict',
    fieldErrors: {'member_id': 'held'},
    currentRevision: null,
  ),
  (
    function: 'identity_credential_command',
    command: 'identity.accept_credentials',
    code: 'conflict',
    fieldErrors: {'member_id': 'password_unreviewed'},
    currentRevision: 3,
  ),
  (
    function: 'identity_credential_command',
    command: 'identity.request_credential_change',
    code: 'forbidden',
    fieldErrors: {'session': 'reauthenticate'},
    currentRevision: null,
  ),
  (
    function: 'identity_review_command',
    command: 'identity.unlink_account',
    code: 'forbidden',
    fieldErrors: {'member_id': 'last_admin'},
    currentRevision: null,
  ),
  (
    function: 'identity_review_command',
    command: 'identity.link_application',
    code: 'validation_failed',
    fieldErrors: {'member_id': 'has_grants'},
    currentRevision: null,
  ),
  (
    function: 'identity_recovery_email_command',
    command: 'identity.approve_recovery_email',
    code: 'conflict',
    fieldErrors: {'proposal_id': 'other_changes'},
    currentRevision: null,
  ),
  (
    function: 'cells_command',
    command: 'cells.request_change',
    code: 'conflict',
    fieldErrors: {'member_id': 'open_request'},
    currentRevision: 2,
  ),
  (
    function: 'cells_command',
    command: 'cells.request_change',
    code: 'validation_failed',
    fieldErrors: {'cell_id': 'current'},
    currentRevision: null,
  ),
  (
    function: 'cells_command',
    command: 'cells.confirm_request',
    code: 'conflict',
    fieldErrors: {'request_id': 'decided'},
    currentRevision: 5,
  ),
];

/// A real SupabaseCommandGateway whose HTTP client answers every RPC with
/// [answer] (echoing the sent request id); [sent] collects the requests.
SupabaseCommandGateway _gateway(
  Map<String, Object?> Function(Map<String, Object?> sent) answer, {
  List<http.Request>? sent,
}) {
  final client = SupabaseClient(
    'http://localhost:54321',
    'sb_publishable_test',
    httpClient: MockClient((request) async {
      sent?.add(request);
      final body = (jsonDecode(request.body) as Map).cast<String, Object?>();
      return http.Response(
        jsonEncode(answer(body)),
        200,
        headers: {'content-type': 'application/json'},
        request: request,
      );
    }),
    authOptions: const AuthClientOptions(autoRefreshToken: false),
  );
  addTearDown(client.dispose);
  return SupabaseCommandGateway(client);
}

/// Runs the real gateway outside a widget test's fake clock (its abort timer
/// and HTTP/JSON work are real async); the parsing path is unchanged.
class _RealZoneGateway implements CommandGateway {
  _RealZoneGateway(this._inner);
  final CommandGateway _inner;

  @override
  Future<CommandOutcome> send(String function, CommandRequest request) =>
      Zone.root.run(() => _inner.send(function, request));
}

Map<String, Object?> _envelope(
  Map<String, Object?> sent,
  String code,
  Map<String, String> fieldErrors, {
  int? currentRevision,
}) => {
  'request_id': sent['request_id'],
  'code': code,
  'message': _messages[code],
  'field_errors': fieldErrors,
  'current_revision': ?currentRevision,
};

/// Pumps frames and lets the mock HTTP answer (real async I/O, outside the
/// fake clock) arrive.
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  group('the real gateway reads command-specific field error codes', () {
    for (final r in _recorded) {
      test('${r.command}: ${r.code} ${jsonEncode(r.fieldErrors)}', () async {
        final g = _gateway(
          (sent) => _envelope(
            sent,
            r.code,
            r.fieldErrors,
            currentRevision: r.currentRevision,
          ),
        );
        final outcome = await g.send(
          r.function,
          CommandRequest(
            command: r.command,
            requestId: '00000000-0000-4000-8000-0000000000a1',
            expectedRevision: const Optional.of(1),
            payload: const {},
          ),
        );
        expect(outcome, isA<CommandRefused>());
        final error = (outcome as CommandRefused).error;
        expect(error.code.wireName, r.code);
        expect(error.message, _messages[r.code]);
        expect(error.fieldErrors, r.fieldErrors);
        expect(error.currentRevision.present, r.currentRevision != null);
      });
    }

    test('a code no client knows yet is still the top-level refusal', () async {
      final g = _gateway(
        (sent) =>
            _envelope(sent, 'conflict', {'member_id': 'some_future_reason'}),
      );
      final outcome = await g.send(
        'identity_credential_command',
        CommandRequest(
          command: 'identity.release_hold',
          requestId: '00000000-0000-4000-8000-0000000000a2',
          expectedRevision: const Optional.of(1),
          payload: const {},
        ),
      );
      expect(outcome, isA<CommandRefused>());
      final error = (outcome as CommandRefused).error;
      expect(error.code, ErrorCode.conflict);
      expect(error.message, _messages['conflict']);
      expect(error.fieldErrors, {'member_id': 'some_future_reason'});
    });

    test('a malformed field error code is still an unknown outcome', () async {
      final g = _gateway(
        (sent) => _envelope(sent, 'conflict', {'member_id': 'Not A Code'}),
      );
      final outcome = await g.send(
        'identity_credential_command',
        CommandRequest(
          command: 'identity.release_hold',
          requestId: '00000000-0000-4000-8000-0000000000a3',
          expectedRevision: const Optional.of(1),
          payload: const {},
        ),
      );
      expect(outcome, isA<CommandUnknownOutcome>());
    });
  });

  group('the Admin credential review over the real gateway', () {
    const hold = 'cdcdcdcd-cdcd-4dcd-8dcd-cdcdcdcdcdcd';

    Future<List<http.Request>> releaseHoldAnswered(
      WidgetTester tester,
      Map<String, String> fieldErrors,
    ) async {
      tester.view.physicalSize = const Size(1200, 5000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final sent = <http.Request>[];
      final h = ClientTestHarness()
        ..credentials.queue = AccessReadOk(
          CredentialQueue.fromJson(
            credentialQueueData(holds: [holdItemData(reason: 'lost_device')]),
          ),
        );
      // Created in the real zone, so it is disposed there too.
      final real = (await tester.runAsync(
        () async => _gateway(
          (body) => _envelope(body, 'conflict', fieldErrors),
          sent: sent,
        ),
      ))!;
      h.commandGateway = _RealZoneGateway(real);
      final router = buildClientRouter(
        initialLocation: ClientPaths.adminCredentialReviews,
        membershipRequests: true,
        shell: (_, _, child) => AccessRefresher(child: child),
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        ProviderScope(
          overrides: h.overrides(),
          child: MaterialApp.router(
            theme: churchMobileTheme(Brightness.light),
            routerConfig: router,
          ),
        ),
      );
      await settle(tester);
      for (final key in [
        'credential-review-hold-$hold-check-in_person',
        'credential-hold-release-$hold',
      ]) {
        await tester.ensureVisible(find.byKey(Key(key)));
        await tester.tap(find.byKey(Key(key)));
        await settle(tester);
      }
      return sent;
    }

    testWidgets('a release before the member\'s reset shows its notice', (
      tester,
    ) async {
      final sent = await releaseHoldAnswered(tester, {
        'hold_id': 'password_reset_required',
      });
      expect(
        (jsonDecode(sent.single.body) as Map)['command'],
        'identity.release_hold',
      );
      expect(
        find.byKey(const Key('credential-review-notice-passwordResetRequired')),
        findsOneWidget,
      );
    });

    testWidgets('an unknown code falls back to the notice for its code', (
      tester,
    ) async {
      await releaseHoldAnswered(tester, {'hold_id': 'some_future_reason'});
      expect(
        find.byKey(const Key('credential-review-notice-changedElsewhere')),
        findsOneWidget,
      );
    });
  });
}

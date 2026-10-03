// Calls an already-running local API through the real client adapters, with
// the publishable key only and no session. It writes nothing: the signed-out
// fixture command must come back as a definite `unauthenticated` refusal.
//
//   SUPABASE_URL=http://127.0.0.1:54321 SUPABASE_PUBLISHABLE_KEY=sb_publishable_... \
//     dart run tool/live_local_check.dart
// or, with the output of `npx supabase status -o env` saved to a file:
//   dart run tool/live_local_check.dart local.env
import 'dart:io';

import 'package:church_client_core/src/domain/commands.dart';
import 'package:church_client_core/src/domain/fixture_counter.dart';
import 'package:church_client_core/supabase_adapters.dart';
import 'package:church_contracts/church_contracts.dart';
import 'package:supabase/supabase.dart' hide ErrorCode;

Future<void> main(List<String> args) async {
  final env = {...Platform.environment};
  if (args.isNotEmpty) {
    for (final line in File(args.first).readAsLinesSync()) {
      final i = line.indexOf('=');
      if (i > 0) {
        env[line.substring(0, i)] = line.substring(i + 1).replaceAll('"', '');
      }
    }
  }
  final url = env['SUPABASE_URL'] ?? env['API_URL'];
  final key = env['SUPABASE_PUBLISHABLE_KEY'] ?? env['PUBLISHABLE_KEY'];
  if (url == null || key == null) {
    stderr.writeln('Set SUPABASE_URL and SUPABASE_PUBLISHABLE_KEY.');
    exit(2);
  }
  final client = SupabaseClient(
    url,
    key,
    postgrestOptions: const PostgrestClientOptions(schema: 'api'),
    authOptions: const AuthClientOptions(autoRefreshToken: false),
  );
  var ok = true;

  final status = await SupabasePlatformStatusRepository(client).fetch();
  stdout.writeln('platform_status: ${status?.status} / ${status?.message}');
  ok &= status != null;

  final request = CommandRequest(
    command: FixtureCounterCommands.create,
    requestId: SecureRequestIds().next(),
    expectedRevision: const Optional.of(null),
    payload: const {'intent_key': 'SYNTHETIC live check (signed out)'},
  );
  final outcome = await SupabaseCommandGateway(client)
      .send(FixtureCounterCommands.function, request);
  final description = switch (outcome) {
    CommandConfirmed() => 'CONFIRMED (unexpected)',
    CommandRefused(:final error) => 'refused: ${error.code.wireName}',
    CommandUnknownOutcome(:final cause) => 'unknown outcome: $cause',
  };
  stdout.writeln('fixture_counter.create signed out: $description');
  ok &=
      outcome is CommandRefused &&
      outcome.error.code == ErrorCode.unauthenticated;

  client.dispose();
  stdout.writeln(ok ? 'LIVE CHECK PASSED' : 'LIVE CHECK FAILED');
  exit(ok ? 0 : 1);
}

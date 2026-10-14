// Story 2.1: drives the REAL client adapters (SupabaseAccountAuthGateway and
// SupabaseMemberAccessRepository) against a running LOCAL stack whose phone
// provider is on without SMS (tools/auth-harness/local-phone-auth.mjs on).
// Publishable key only. SYNTHETIC fictional numbers only. Prints outcomes,
// never tokens or passwords.
//
//   dart run tool/live_identity_check.dart <env-file> signup <+phone> <expect>
//   dart run tool/live_identity_check.dart <env-file> signin <+phone> <expect>
//   dart run tool/live_identity_check.dart <env-file> session <+phone> granted
// <expect>: granted | not_linked. The password is read from
// LIVE_CHECK_PASSWORD so it never appears in argv.
//
// Story 2.2 `session` mode (an already linked synthetic account): token
// refresh keeps access; a simulated app restart restores the persisted
// session JSON exactly as supabase_flutter does (recoverSession) and reads
// with no password; another device's "sign out other sessions" revokes this
// one, which the adapter reports as untrustedSession; local sign-out then
// leaves the client signed out.
import 'dart:convert';
import 'dart:io';

import 'package:church_client_core/src/domain/account_auth.dart';
import 'package:church_client_core/src/domain/member_access.dart';
import 'package:church_client_core/supabase_adapters.dart';
import 'package:supabase/supabase.dart';

final _fictional = RegExp(r'^\+(120255501[0-9]{2}|447700900[0-9]{3})$');

Future<void> main(List<String> args) async {
  if (args.length != 4) {
    stderr.writeln(
      'usage: <env-file> signup|signin <+phone> granted|not_linked',
    );
    exit(2);
  }
  final env = <String, String>{};
  for (final line in File(args[0]).readAsLinesSync()) {
    final i = line.indexOf('=');
    if (i > 0) {
      env[line.substring(0, i)] = line.substring(i + 1).replaceAll('"', '');
    }
  }
  final url = env['API_URL'];
  final key = env['PUBLISHABLE_KEY'];
  final password = Platform.environment['LIVE_CHECK_PASSWORD'];
  if (url != 'http://127.0.0.1:54321' || key == null || password == null) {
    stderr.writeln(
      'LOCAL only: API_URL must be http://127.0.0.1:54321; set LIVE_CHECK_PASSWORD.',
    );
    exit(2);
  }
  final phone = args[2];
  if (!_fictional.hasMatch(phone)) {
    stderr.writeln('refusing a number outside the reserved fictional ranges');
    exit(2);
  }
  if (args[1] == 'session') {
    exit(await _sessionMode(url!, key, phone, password) ? 0 : 1);
  }
  final client = SupabaseClient(
    url!,
    key,
    postgrestOptions: const PostgrestClientOptions(schema: 'api'),
    authOptions: const AuthClientOptions(autoRefreshToken: false),
  );
  final auth = SupabaseAccountAuthGateway(client);
  final outcome = args[1] == 'signup'
      ? await auth.signUp(phoneE164: phone, password: password)
      : await auth.signIn(phoneE164: phone, password: password);
  stdout.writeln(
    '${args[1]}: ${switch (outcome) {
      AuthSucceeded() => 'session (amr=${_amr(client)})',
      AuthFailed(:final failure) => 'failed $failure',
    }}',
  );
  final read = await SupabaseMemberAccessRepository(client).fetchMySummary();
  final got = switch (read) {
    MemberAccessGranted(:final summary) =>
      'granted ${summary.displayName} ${summary.phoneUsername}',
    MemberAccessDenied(:final denial) => 'denied ${denial.name}',
    MemberAccessFailed(:final cause) => 'failed $cause',
  };
  stdout.writeln('read: $got');
  await auth.signOut();
  final after = await SupabaseMemberAccessRepository(client).fetchMySummary();
  stdout.writeln(
    'read after sign-out: ${after is MemberAccessDenied ? after.denial.name : after}',
  );
  client.dispose();
  final ok =
      outcome is AuthSucceeded &&
      (args[3] == 'granted'
          ? read is MemberAccessGranted
          : read is MemberAccessDenied &&
                read.denial == MemberAccessDenial.notLinked) &&
      after is MemberAccessDenied &&
      after.denial == MemberAccessDenial.signedOut;
  stdout.writeln(ok ? 'PASS' : 'FAIL');
  exit(ok ? 0 : 1);
}

String _amr(SupabaseClient c) {
  final token = c.auth.currentSession?.accessToken;
  if (token == null) return '?';
  final parts = token.split('.');
  final payload = String.fromCharCodes(
    Uri.parse('data:;base64,${base64Normalize(parts[1])}').data!
        .contentAsBytes(),
  );
  return RegExp(r'"method":"([a-z_]+)"')
      .allMatches(payload)
      .map((m) => m[1])
      .join(',');
}

String base64Normalize(String s) {
  final t = s.replaceAll('-', '+').replaceAll('_', '/');
  return t.padRight(t.length + (4 - t.length % 4) % 4, '=');
}

SupabaseClient _client(String url, String key) => SupabaseClient(
  url,
  key,
  postgrestOptions: const PostgrestClientOptions(schema: 'api'),
  authOptions: const AuthClientOptions(autoRefreshToken: false),
);

String _show(MemberAccessResult r) => switch (r) {
  MemberAccessGranted(:final summary) => 'granted ${summary.displayName}',
  MemberAccessDenied(:final denial) => 'denied ${denial.name}',
  MemberAccessFailed(:final cause) => 'failed $cause',
};

Future<bool> _sessionMode(
  String url,
  String key,
  String phone,
  String password,
) async {
  var ok = true;
  void line(String step, bool pass, String detail) {
    ok &= pass;
    stdout.writeln('$step: $detail ${pass ? 'ok' : 'FAIL'}');
  }

  // Device 1: sign in and read.
  final a = _client(url, key);
  final signIn = await SupabaseAccountAuthGateway(a)
      .signIn(phoneE164: phone, password: password);
  final r1 = await SupabaseMemberAccessRepository(a).fetchMySummary();
  line(
    'S1 sign-in + read',
    signIn is AuthSucceeded && r1 is MemberAccessGranted,
    '${signIn is AuthSucceeded ? 'session (amr=${_amr(a)})' : 'failed'}; ${_show(r1)}',
  );

  // Token refresh keeps the password session and access.
  final before = a.auth.currentSession?.accessToken;
  await a.auth.refreshSession();
  final r2 = await SupabaseMemberAccessRepository(a).fetchMySummary();
  line(
    'S2 token refresh',
    a.auth.currentSession?.accessToken != before &&
        _amr(a).contains('password') &&
        r2 is MemberAccessGranted,
    'new token, amr=${_amr(a)}; ${_show(r2)}',
  );

  // App restart: a new client restores the persisted session JSON (what the
  // app's AuthSessionStorage hands supabase_flutter) and reads, no password.
  final persisted = jsonEncode(a.auth.currentSession!.toJson());
  a.dispose();
  final restarted = _client(url, key);
  await restarted.auth.recoverSession(persisted);
  final r3 = await SupabaseMemberAccessRepository(restarted).fetchMySummary();
  line(
    'S3 reopen with stored session',
    r3 is MemberAccessGranted,
    'no sign-in call; ${_show(r3)}',
  );

  // Device 2 signs in and signs out every OTHER session: device 1 is revoked.
  final b = _client(url, key);
  await SupabaseAccountAuthGateway(b)
      .signIn(phoneE164: phone, password: password);
  await b.auth.signOut(scope: SignOutScope.others);
  final r4 = await SupabaseMemberAccessRepository(restarted).fetchMySummary();
  final r4b = await SupabaseMemberAccessRepository(b).fetchMySummary();
  line(
    'S4 revoked elsewhere',
    r4 is MemberAccessDenied &&
        r4.denial == MemberAccessDenial.untrustedSession &&
        r4b is MemberAccessGranted,
    'device 1: ${_show(r4)}; device 2: ${_show(r4b)}',
  );
  var refreshRefused = false;
  try {
    await restarted.auth.refreshSession();
  } on AuthException {
    refreshRefused = true;
  }
  line(
    'S5 revoked session cannot refresh',
    refreshRefused && restarted.auth.currentSession == null,
    'refresh refused=$refreshRefused, local session cleared='
        '${restarted.auth.currentSession == null}',
  );

  // Device 2 signs out locally: signed out, nothing protected is readable.
  await SupabaseAccountAuthGateway(b).signOut();
  final r5 = await SupabaseMemberAccessRepository(b).fetchMySummary();
  line(
    'S6 sign-out',
    r5 is MemberAccessDenied && r5.denial == MemberAccessDenial.signedOut,
    _show(r5),
  );
  restarted.dispose();
  b.dispose();
  stdout.writeln(ok ? 'PASS' : 'FAIL');
  return ok;
}

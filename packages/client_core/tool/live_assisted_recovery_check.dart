// Story 2.9: drives the REAL client adapters against a running LOCAL stack
// with the Edge Function identity-assisted-recovery served:
//   R1 the member's phone (SupabaseAssistedRecoveryGateway, no session) asks
//      for help: only the digest leaves the device; the code comes back;
//   R2 a staff-web Admin (SupabaseCommandGateway, SupabaseRecoveryCasesRepository)
//      opens a case and issues the setup for that code; the Admin read holds
//      no secret, digest or code;
//   R3 the phone sees `ready` and sets the chosen password once; a replay is
//      rejected;
//   R4 the old sign-in no longer works; the new password signs in
//      (SupabaseAccountAuthGateway) and the member read is granted.
//
//   dart run tool/live_assisted_recovery_check.dart <env-file> <admin-phone> <member-phone>
//
// Run through tools/identity-e2e/live-assisted-check.sh, which creates and
// links both accounts, serves the function with a fresh system credential and
// removes everything afterwards. Passwords come from LIVE_CHECK_PASSWORD and
// are generated for the new one. Prints outcomes only.
import 'dart:io';
import 'dart:math';

import 'package:church_client_core/src/domain/access_grants.dart';
import 'package:church_client_core/src/domain/account_auth.dart';
import 'package:church_client_core/src/domain/assisted_recovery.dart';
import 'package:church_client_core/src/domain/commands.dart';
import 'package:church_client_core/src/domain/member_access.dart';
import 'package:church_client_core/supabase_adapters.dart';
import 'package:church_contracts/church_contracts.dart';
import 'package:supabase/supabase.dart' hide ErrorCode;

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

Future<void> main(List<String> args) async {
  if (args.length != 3) {
    stderr.writeln('usage: <env-file> <admin-phone> <member-phone>');
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
  final adminPhone = args[1];
  final phone = args[2];
  if (url != 'http://127.0.0.1:54321' || key == null || password == null) {
    stderr.writeln('LOCAL only; set LIVE_CHECK_PASSWORD.');
    exit(2);
  }
  final fictional = RegExp(r'^\+44770090045[0-9]$');
  if (![adminPhone, phone].every(fictional.hasMatch)) {
    stderr.writeln('refusing a non-fictional phone username');
    exit(2);
  }
  SupabaseClient client() => SupabaseClient(
    url!,
    key,
    postgrestOptions: const PostgrestClientOptions(schema: 'api'),
    authOptions: AuthClientOptions(
      autoRefreshToken: false,
      pkceAsyncStorage: _MemoryStorage(),
    ),
  );
  var ok = true;
  void check(String step, bool pass, String detail) {
    ok = ok && pass;
    stdout.writeln('${pass ? 'PASS' : 'FAIL'} $step: $detail');
  }

  String access(MemberAccessResult r) => switch (r) {
    MemberAccessGranted() => 'granted',
    MemberAccessDenied(:final denial) => denial.name,
    MemberAccessFailed() => 'failed',
  };
  String outcome(CommandOutcome o) => switch (o) {
    CommandConfirmed() => 'confirmed',
    CommandRefused(:final error) => 'refused:${error.code.wireName}',
    _ => o.runtimeType.toString(),
  };

  // The member's old session (a second device, still signed in).
  final old = client();
  final oldSignIn = await SupabaseAccountAuthGateway(old)
      .signIn(phoneE164: phone, password: password);

  // R1: the phone asks for help.
  final device = SupabaseAssistedRecoveryGateway(
    supabaseUrl: url!,
    publishableKey: key,
  );
  final secret = GrantSecret.generate();
  final req = await device.request(phone, secret.digest);
  final code = req is RecoveryRequestReceived ? req.requestCode : null;
  final waiting = await device.status(secret.digest);
  check(
    'R1 the phone asks for help with the digest only',
    oldSignIn is AuthSucceeded &&
        code != null &&
        waiting is RecoveryStatus &&
        waiting.state == RecoveryGrantState.waiting,
    'request=${req.runtimeType} status=${waiting is RecoveryStatus ? waiting.state.name : 'failed'}',
  );

  // R2: the Admin opens a case and issues the setup for the code.
  final staff = client();
  await SupabaseAccountAuthGateway(staff)
      .signIn(phoneE164: adminPhone, password: password);
  final gateway = SupabaseCommandGateway(staff);
  final repo = SupabaseRecoveryCasesRepository(staff);
  final memberId = Platform.environment['LIVE_CHECK_MEMBER_ID'];
  final opened = await gateway.send(
    RecoveryCaseCommands.function,
    CommandRequest(
      command: RecoveryCaseCommands.open,
      requestId: SecureRequestIds().next(),
      expectedRevision: const Optional.of(null),
      payload: {
        'member_id': memberId,
        'identity_check': 'in_person',
        'evidence': ['photo_id'],
      },
    ),
  );
  final listed = await repo.fetchCases();
  final item = listed is AccessReadOk<RecoveryCases>
      ? listed.value.cases.where((c) => c.memberId == memberId).firstOrNull
      : null;
  final issued = item == null
      ? null
      : await gateway.send(
          RecoveryCaseCommands.function,
          CommandRequest(
            command: RecoveryCaseCommands.issue,
            requestId: SecureRequestIds().next(),
            expectedRevision: Optional.of(item.revision),
            payload: {'case_id': item.caseId, 'request_code': code},
          ),
        );
  final after = await repo.fetchCases();
  final shown = after is AccessReadOk<RecoveryCases>
      ? after.value.cases.where((c) => c.memberId == memberId).firstOrNull
      : null;
  check(
    'R2 an Admin opens a case and issues the setup for the code',
    opened is CommandConfirmed &&
        issued is CommandConfirmed &&
        shown?.grantState == 'issued',
    'open=${outcome(opened)} issue=${issued == null ? 'none' : outcome(issued)} grant=${shown?.grantState}',
  );

  // R3: the phone sets the chosen password once.
  final ready = await device.status(secret.digest);
  final r = Random.secure();
  final newPassword =
      'Synthetic-${List.generate(16, (_) => r.nextInt(36).toRadixString(36)).join()}';
  final redeemed = await device.redeem(phone, secret, newPassword);
  final replay = await device.redeem(phone, secret, '$newPassword-again');
  check(
    'R3 the member sets the password once on the phone',
    ready is RecoveryStatus &&
        ready.state == RecoveryGrantState.ready &&
        redeemed == RedeemOutcome.succeeded &&
        replay == RedeemOutcome.rejected,
    'status=${ready is RecoveryStatus ? ready.state.name : 'failed'} redeem=${redeemed.name} replay=${replay.name}',
  );

  // R4: older sessions are gone; a fresh password sign-in is granted.
  final oldRead = await SupabaseMemberAccessRepository(old).fetchMySummary();
  final oldPassword = await SupabaseAccountAuthGateway(client())
      .signIn(phoneE164: phone, password: password);
  await Future<void>.delayed(const Duration(milliseconds: 6500));
  final fresh = client();
  final signIn = await SupabaseAccountAuthGateway(fresh)
      .signIn(phoneE164: phone, password: newPassword);
  final read = await SupabaseMemberAccessRepository(fresh).fetchMySummary();
  check(
    'R4 fresh password sign-in is required and granted',
    access(oldRead) != 'granted' &&
        oldPassword is! AuthSucceeded &&
        signIn is AuthSucceeded &&
        access(read) == 'granted',
    'old_session=${access(oldRead)} old_password=${oldPassword.runtimeType} '
        'new_password=${signIn.runtimeType} read=${access(read)}',
  );
  for (final c in [old, staff, fresh]) {
    await c.dispose();
  }
  stdout.writeln(ok ? 'ALL PASS' : 'SOME CHECKS FAILED');
  exit(ok ? 0 : 1);
}

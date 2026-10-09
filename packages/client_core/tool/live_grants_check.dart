// Story 2.3: drives the REAL client adapters (SupabaseCommandGateway and
// SupabaseGrantsRepository) against a running LOCAL stack. Two clients play
// the staff web Admin and an already signed-in member session (mobile); the
// Admin grants and revokes Pastor through the 1.4 envelope, and the member
// client's next read shows each change without signing in again.
//
//   dart run tool/live_grants_check.dart <env-file> <admin-email> <member-email>
//
// The accounts are SYNTHETIC (created, linked and cleaned up by
// tools/identity-e2e/live-grants-check.sh); they sign in through their
// verified email alias (same account and predicate as phone sign-in). The
// password comes from LIVE_CHECK_PASSWORD. Publishable key only; prints
// outcomes, never tokens or passwords.
import 'dart:io';

import 'package:church_client_core/src/domain/access_grants.dart';
import 'package:church_client_core/src/domain/commands.dart';
import 'package:church_client_core/supabase_adapters.dart';
import 'package:church_contracts/church_contracts.dart';
import 'package:supabase/supabase.dart' hide ErrorCode;

Future<void> main(List<String> args) async {
  if (args.length != 3) {
    stderr.writeln('usage: <env-file> <admin-email> <member-email>');
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
    stderr.writeln('LOCAL only; set LIVE_CHECK_PASSWORD.');
    exit(2);
  }
  for (final e in args.skip(1)) {
    if (!RegExp(r'^synthetic-2-3-live-[a-z0-9-]+@example\.test$').hasMatch(e)) {
      stderr.writeln('refusing a non-synthetic email');
      exit(2);
    }
  }
  SupabaseClient client() => SupabaseClient(
    url!,
    key,
    postgrestOptions: const PostgrestClientOptions(schema: 'api'),
    authOptions: const AuthClientOptions(autoRefreshToken: false),
  );
  final staff = client();
  final mobile = client();
  await staff.auth.signInWithPassword(email: args[1], password: password);
  await mobile.auth.signInWithPassword(email: args[2], password: password);
  final mobileToken = mobile.auth.currentSession?.accessToken;

  final staffGrants = SupabaseGrantsRepository(staff);
  final mobileGrants = SupabaseGrantsRepository(mobile);
  final gateway = SupabaseCommandGateway(staff);
  final ids = SecureRequestIds();
  var ok = true;
  void report(String step, bool pass, Object detail) {
    ok = ok && pass;
    stdout.writeln('${pass ? 'PASS' : 'FAIL'} $step: $detail');
  }

  String roles(AccessRead<MemberGrants> r) => switch (r) {
    AccessReadOk(:final value) => value.roles.join(','),
    AccessReadDenied(:final denial) => 'denied:${denial.name}',
    AccessReadFailed() => 'failed',
  };

  final before = await mobileGrants.fetchMyAccess();
  report(
    'L1 member session starts without roles',
    roles(before) == '',
    roles(before),
  );

  final roster = await staffGrants.fetchRoster();
  final row = roster is AccessReadOk<GrantRoster>
      ? roster.value.members
            .where((m) => m.displayName == 'SYNTHETIC 2.3 Live Member')
            .firstOrNull
      : null;
  report(
    'L2 Admin roster (staff web adapter)',
    row != null,
    row?.account.name ?? roster.runtimeType,
  );
  if (row == null) exit(1);

  Future<CommandOutcome> send(String command, int revision) => gateway.send(
    GrantCommands.function,
    CommandRequest(
      command: command,
      requestId: ids.next(),
      expectedRevision: Optional.of(revision),
      payload: {'member_id': row.memberId, 'role': ChurchRoles.pastor},
    ),
  );

  final granted = await send(GrantCommands.grantRole, row.grants.revision);
  final grantedRevision = granted is CommandConfirmed
      ? granted.success.revision
      : null;
  report(
    'L3 grant Pastor (command gateway)',
    grantedRevision == row.grants.revision + 1,
    granted.runtimeType,
  );

  final after = await mobileGrants.fetchMyAccess();
  report(
    'L4 same member session sees Pastor at its next read',
    roles(after) == 'pastor' &&
        mobile.auth.currentSession?.accessToken == mobileToken,
    '${roles(after)}, same token: ${mobile.auth.currentSession?.accessToken == mobileToken}',
  );

  final stale = await send(GrantCommands.grantRole, row.grants.revision);
  report(
    'L5 stale revision is a conflict',
    stale is CommandRefused && stale.error.code == ErrorCode.conflict,
    stale is CommandRefused ? stale.error.code.wireName : stale.runtimeType,
  );

  final revoked = await send(GrantCommands.revokeRole, grantedRevision ?? 0);
  report('L6 revoke Pastor', revoked is CommandConfirmed, revoked.runtimeType);
  final afterRevoke = await mobileGrants.fetchMyAccess();
  report(
    'L7 member session loses Pastor at its next read',
    roles(afterRevoke) == '',
    roles(afterRevoke),
  );

  final memberRoster = await mobileGrants.fetchRoster();
  report(
    'L8 a non-Admin session cannot read the roster',
    memberRoster is AccessReadDenied<GrantRoster> &&
        memberRoster.denial == AccessDenial.notGranted,
    memberRoster is AccessReadDenied<GrantRoster>
        ? memberRoster.denial.name
        : memberRoster.runtimeType,
  );

  await staff.auth.signOut();
  await mobile.auth.signOut();
  staff.dispose();
  mobile.dispose();
  exit(ok ? 0 : 1);
}

// Story 2.4: drives the REAL client adapters (SupabaseAccountAuthGateway,
// SupabaseMembershipRepository, SupabaseCommandGateway and the access reads)
// against a running LOCAL stack with the local phone switch on: a new
// SYNTHETIC applicant signs up with phone + password only, reads the safe
// cell chooser, submits and corrects a request through the 1.4 envelope, is
// still denied member access, and a duplicate username is refused.
//
//   dart run tool/live_application_check.dart <env-file> <phone>
//
// Run through tools/identity-e2e/live-application-check.sh, which seeds the
// SYNTHETIC cells and removes everything afterwards. The password comes from
// LIVE_CHECK_PASSWORD. Publishable key only; prints outcomes, never tokens or
// passwords.
import 'dart:io';

import 'package:church_client_core/src/domain/access_grants.dart';
import 'package:church_client_core/src/domain/account_auth.dart';
import 'package:church_client_core/src/domain/commands.dart';
import 'package:church_client_core/src/domain/member_access.dart';
import 'package:church_client_core/src/domain/membership_application.dart';
import 'package:church_client_core/supabase_adapters.dart';
import 'package:church_contracts/church_contracts.dart';
import 'package:supabase/supabase.dart' hide ErrorCode;

Future<void> main(List<String> args) async {
  if (args.length != 2) {
    stderr.writeln('usage: <env-file> <phone>');
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
  final phone = args[1];
  if (url != 'http://127.0.0.1:54321' || key == null || password == null) {
    stderr.writeln('LOCAL only; set LIVE_CHECK_PASSWORD.');
    exit(2);
  }
  if (!RegExp(r'^\+120255501[0-9]{2}$').hasMatch(phone)) {
    stderr.writeln('refusing a non-fictional phone username');
    exit(2);
  }
  SupabaseClient client() => SupabaseClient(
    url!,
    key,
    postgrestOptions: const PostgrestClientOptions(schema: 'api'),
    authOptions: const AuthClientOptions(autoRefreshToken: false),
  );
  final mobile = client();
  final auth = SupabaseAccountAuthGateway(mobile);
  final membership = SupabaseMembershipRepository(mobile);
  final commands = SupabaseCommandGateway(mobile);
  var ok = true;
  void check(String step, bool pass, String detail) {
    ok = ok && pass;
    stdout.writeln('${pass ? 'PASS' : 'FAIL'} $step: $detail');
  }

  final up = await auth.signUp(phoneE164: phone, password: password);
  check('L1 phone sign-up, no email', up is AuthSucceeded, '$up');

  final options = await membership.fetchCellOptions();
  final list = options is AccessReadOk<List<CellOption>>
      ? options.value
      : const <CellOption>[];
  check(
    'L2 safe chooser',
    list.length == 3,
    list.map((o) => '${o.label} / ${o.broadArea}').join('; '),
  );

  final mine = await membership.fetchMyApplication();
  final notice = mine is AccessReadOk<MyApplication>
      ? mine.value.privacyNotice.version
      : null;
  check(
    'L3 no request yet',
    mine is AccessReadOk<MyApplication> && mine.value.application == null,
    'notice $notice',
  );

  final submitted = await commands.send(
    ApplicationCommands.function,
    CommandRequest(
      command: ApplicationCommands.submit,
      requestId: SecureRequestIds().next(),
      expectedRevision: const Optional.of(null),
      payload: {
        'full_name': 'SYNTHETIC 2.4 Live Applicant',
        'cell_choice': CellChoice.cell(
          cellId: list.first.cellId,
          cellRevision: list.first.revision,
        ).toJson(),
        'privacy_notice_version': notice,
      },
    ),
  );
  MembershipApplication? app;
  if (submitted case CommandConfirmed(:final success)) {
    app = MembershipApplication.fromJson(success.data);
  }
  check(
    'L4 submit (cell)',
    app?.churchStatus == ChurchStatus.awaitingApproval &&
        app?.cellStatus == CellStatus.requested,
    '${app?.churchStatus} / ${app?.cellStatus} rev ${app?.revision}',
  );

  final corrected = await commands.send(
    ApplicationCommands.function,
    CommandRequest(
      command: ApplicationCommands.correct,
      requestId: SecureRequestIds().next(),
      expectedRevision: Optional.of(app?.revision),
      payload: {
        'application_id': app?.applicationId,
        'full_name': 'SYNTHETIC 2.4 Live Applicant',
        'cell_choice': const CellChoice.notSure().toJson(),
      },
    ),
  );
  MembershipApplication? fixed;
  if (corrected case CommandConfirmed(:final success)) {
    fixed = MembershipApplication.fromJson(success.data);
  }
  check(
    'L5 correct (not sure)',
    fixed?.revision == 2 && fixed?.cellStatus == CellStatus.followUp,
    '${fixed?.churchStatus} / ${fixed?.cellStatus} rev ${fixed?.revision}',
  );

  final stale = await commands.send(
    ApplicationCommands.function,
    CommandRequest(
      command: ApplicationCommands.correct,
      requestId: SecureRequestIds().next(),
      expectedRevision: const Optional.of(1),
      payload: {
        'application_id': app?.applicationId,
        'full_name': 'SYNTHETIC stale',
      },
    ),
  );
  check(
    'L6 stale revision',
    stale is CommandRefused &&
        stale.error.code == ErrorCode.conflict &&
        stale.error.currentRevision.value == 2,
    stale is CommandRefused ? stale.error.code.wireName : '$stale',
  );

  final summary = await SupabaseMemberAccessRepository(mobile).fetchMySummary();
  final access = await SupabaseGrantsRepository(mobile).fetchMyAccess();
  check(
    'L7 still no member access',
    summary is MemberAccessDenied &&
        summary.denial == MemberAccessDenial.notLinked &&
        access is AccessReadDenied<MemberGrants> &&
        access.denial == AccessDenial.notLinked,
    'summary $summary, access $access',
  );

  final other = client();
  final dup = await SupabaseAccountAuthGateway(other)
      .signUp(phoneE164: phone, password: '$password-other');
  check(
    'L8 duplicate username refused',
    dup is AuthFailed && dup.failure == AuthFailure.usernameUnavailable,
    dup is AuthFailed ? dup.failure.name : '$dup',
  );

  await auth.signOut();
  exit(ok ? 0 : 1);
}

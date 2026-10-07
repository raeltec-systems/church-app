// Story 2.5: drives the REAL client adapters (SupabaseAccountAuthGateway,
// SupabaseReviewRepository, SupabaseCommandGateway, SupabaseMembershipRepository
// and SupabaseMemberAccessRepository) against a running LOCAL stack with the
// local phone switch on: a staff-web Admin reads the review queue, records an
// accountless SYNTHETIC member, finds it by search and links the applicant's
// account to it; the applicant's pre-approval session is refused, and a
// fresh sign-in reaches the same member id.
//
//   dart run tool/live_review_check.dart <env-file> <admin-phone> <applicant-phone>
//
// Run through tools/identity-e2e/live-review-check.sh, which creates and
// links the Admin and removes everything afterwards. The password comes from
// LIVE_CHECK_PASSWORD. Publishable key only; prints outcomes, never tokens or
// passwords.
import 'dart:io';

import 'package:church_client_core/src/domain/access_grants.dart';
import 'package:church_client_core/src/domain/account_auth.dart';
import 'package:church_client_core/src/domain/commands.dart';
import 'package:church_client_core/src/domain/member_access.dart';
import 'package:church_client_core/src/domain/membership_application.dart';
import 'package:church_client_core/src/domain/membership_review.dart';
import 'package:church_client_core/supabase_adapters.dart';
import 'package:church_contracts/church_contracts.dart';
import 'package:supabase/supabase.dart' hide ErrorCode;

Future<void> main(List<String> args) async {
  if (args.length != 3) {
    stderr.writeln('usage: <env-file> <admin-phone> <applicant-phone>');
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
  final fictional = RegExp(r'^\+120255501[0-9]{2}$');
  if (!fictional.hasMatch(adminPhone) || !fictional.hasMatch(phone)) {
    stderr.writeln('refusing a non-fictional phone username');
    exit(2);
  }
  SupabaseClient client() => SupabaseClient(
    url!,
    key,
    postgrestOptions: const PostgrestClientOptions(schema: 'api'),
    authOptions: const AuthClientOptions(autoRefreshToken: false),
  );
  var ok = true;
  void check(String step, bool pass, String detail) {
    ok = ok && pass;
    stdout.writeln('${pass ? 'PASS' : 'FAIL'} $step: $detail');
  }

  Future<CommandOutcome> send(
    CommandGateway g,
    String function,
    String command,
    int? expected,
    Map<String, Object?> payload,
  ) => g.send(
    function,
    CommandRequest(
      command: command,
      requestId: SecureRequestIds().next(),
      expectedRevision: Optional.of(expected),
      payload: payload,
    ),
  );

  // Staff web: the Admin signs in with phone + password.
  final staff = client();
  final adminIn = await SupabaseAccountAuthGateway(
    staff,
  ).signIn(phoneE164: adminPhone, password: password);
  final review = SupabaseReviewRepository(staff);
  final adminCommands = SupabaseCommandGateway(staff);
  check('L1 Admin signs in (phone)', adminIn is AuthSucceeded, '$adminIn');

  // Mobile: a new applicant signs up and applies.
  final mobile = client();
  final mobileAuth = SupabaseAccountAuthGateway(mobile);
  final up = await mobileAuth.signUp(phoneE164: phone, password: password);
  final applied = await send(
    SupabaseCommandGateway(mobile),
    ApplicationCommands.function,
    ApplicationCommands.submit,
    null,
    {
      'full_name': 'SYNTHETIC 2.5 Live Person',
      'cell_choice': const CellChoice.notSure().toJson(),
      'privacy_notice_version': 'draft-2026-10-07',
    },
  );
  check(
    'L2 applicant signs up and applies',
    up is AuthSucceeded && applied is CommandConfirmed,
    '$up / $applied',
  );

  final applicantQueue = await SupabaseReviewRepository(mobile).fetchQueue();
  check(
    'L3 the applicant cannot read the queue',
    applicantQueue is AccessReadDenied<ReviewQueue> &&
        applicantQueue.denial == AccessDenial.notLinked,
    '$applicantQueue',
  );

  final created = await send(
    adminCommands,
    ReviewCommands.function,
    ReviewCommands.createMember,
    null,
    {'full_name': 'SYNTHETIC 2.5 Live Person', 'consent_basis': 'in_person'},
  );
  MemberRecord? record;
  if (created case CommandConfirmed(:final success)) {
    record = MemberRecord.fromJson(success.data);
  }
  check(
    'L4 Admin records an accountless member',
    record?.account == AccountStanding.noLogin,
    '${record?.account} / ${record?.origin}',
  );

  final queue = await review.fetchQueue();
  final entry = queue is AccessReadOk<ReviewQueue>
      ? queue.value.applications
            .where((a) => a.application.fullName == 'SYNTHETIC 2.5 Live Person')
            .firstOrNull
      : null;
  final hint = entry?.candidates
      .where((c) => c.memberId == record?.memberId)
      .firstOrNull;
  final search = await review.searchMembers('Live Person');
  final found = search is AccessReadOk<MemberSearchPage>
      ? search.value.members.where((m) => m.memberId == record?.memberId).length
      : 0;
  check(
    'L5 queue shows the staff-only duplicate hint; search finds the record',
    entry != null && (hint?.signals.contains('same_name') ?? false) && found == 1,
    'signals ${hint?.signals}, found $found',
  );

  final before = await SupabaseMemberAccessRepository(mobile).fetchMySummary();
  final linked = await send(
    adminCommands,
    ReviewCommands.function,
    ReviewCommands.link,
    entry?.application.revision,
    {
      'application_id': entry?.id,
      'member_id': record?.memberId,
      'identity_check': IdentityCheck.inPerson.wire,
    },
  );
  final stale = await SupabaseMemberAccessRepository(mobile).fetchMySummary();
  check(
    'L6 link; the pre-approval session is refused',
    before is MemberAccessDenied &&
        before.denial == MemberAccessDenial.notLinked &&
        linked is CommandConfirmed &&
        stale is MemberAccessDenied &&
        stale.denial == MemberAccessDenial.untrustedSession,
    '$before / $linked / $stale',
  );

  await Future<void>.delayed(const Duration(milliseconds: 6500));
  final fresh = client();
  await SupabaseAccountAuthGateway(
    fresh,
  ).signIn(phoneE164: phone, password: password);
  final after = await SupabaseMemberAccessRepository(fresh).fetchMySummary();
  final status = await SupabaseMembershipRepository(fresh).fetchMyApplication();
  check(
    'L7 fresh sign-in reaches the same member; status approved',
    after is MemberAccessGranted &&
        after.summary.memberId == record?.memberId &&
        status is AccessReadOk<MyApplication> &&
        status.value.application?.churchStatus == ChurchStatus.approved,
    after is MemberAccessGranted ? 'same member' : '$after',
  );

  exit(ok ? 0 : 1);
}

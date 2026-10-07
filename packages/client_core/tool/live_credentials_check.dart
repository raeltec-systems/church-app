// Story 2.8: drives the REAL client adapters (SupabaseAccountAuthGateway,
// SupabaseRecoveryEmailRepository for the password re-check,
// SupabaseCredentialReviewRepository, SupabaseCommandGateway,
// SupabaseGrantsRepository and SupabaseMemberAccessRepository) against a
// running LOCAL stack with the local phone switch on:
//   C1 the member (mobile) asks for a new phone username after a password
//      re-check; the request waits for review and access is unchanged;
//   C2 a staff-web Admin approves it from the queue; the member's session is
//      revoked; the new number signs in and is granted;
//   C3 the Admin places a lost-device hold: the session is revoked; a new
//      sign-in sees only access review (the help screen's own read answers
//      `review_required` with no reason);
//   C4 the Admin releases it after an identity check; a fresh sign-in is
//      granted.
//
//   dart run tool/live_credentials_check.dart <env-file> <admin-phone> <member-phone> <new-phone>
//
// Run through tools/identity-e2e/live-credentials-check.sh, which creates and
// links both accounts and removes everything afterwards. The password comes
// from LIVE_CHECK_PASSWORD. Publishable key only; prints outcomes, never
// tokens, passwords, numbers or addresses.
import 'dart:io';

import 'package:church_client_core/src/domain/access_grants.dart';
import 'package:church_client_core/src/domain/account_auth.dart';
import 'package:church_client_core/src/domain/commands.dart';
import 'package:church_client_core/src/domain/credential_review.dart';
import 'package:church_client_core/src/domain/member_access.dart';
import 'package:church_client_core/src/domain/membership_review.dart';
import 'package:church_client_core/src/domain/password_recovery.dart';
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
  if (args.length != 4) {
    stderr.writeln(
      'usage: <env-file> <admin-phone> <member-phone> <new-phone>',
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
  final adminPhone = args[1];
  final phone = args[2];
  final newPhone = args[3];
  if (url != 'http://127.0.0.1:54321' || key == null || password == null) {
    stderr.writeln('LOCAL only; set LIVE_CHECK_PASSWORD.');
    exit(2);
  }
  final fictional = RegExp(r'^\+4477009003[45][0-9]$');
  if (![adminPhone, phone, newPhone].every(fictional.hasMatch)) {
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
  String outcome(CommandOutcome? o) => switch (o) {
    CommandConfirmed() => 'confirmed',
    CommandRefused(:final error) => 'refused:${error.code.wireName}',
    null => 'not_sent',
    _ => o.runtimeType.toString(),
  };
  Future<SupabaseClient> signedIn(String p) async {
    final c = client();
    await SupabaseAccountAuthGateway(c)
        .signIn(phoneE164: p, password: password);
    return c;
  }

  const wait = Duration(milliseconds: 6500); // the 2.2 trust-epoch margin

  // C1: the member asks for a new username (mobile).
  final mobile = await signedIn(phone);
  final mineRepo = SupabaseCredentialReviewRepository(mobile);
  final before = await mineRepo.fetchMine();
  final reauth = await SupabaseRecoveryEmailRepository(
    mobile,
    redirects: AuthRedirects.mobile,
  ).confirmPassword(password);
  final asked = await SupabaseCommandGateway(mobile).send(
    CredentialCommands.function,
    CommandRequest(
      command: CredentialCommands.request,
      requestId: SecureRequestIds().next(),
      expectedRevision: const Optional.of(null),
      payload: {'change_kind': 'phone_username', 'phone_username': newPhone},
    ),
  );
  final pending = await mineRepo.fetchMine();
  final stillGranted = await SupabaseMemberAccessRepository(mobile)
      .fetchMySummary();
  check(
    'C1 the member asks for a new username; it waits for review',
    before is AccessReadOk<MyCredentials> &&
        before.value.canRequest &&
        reauth is AuthSucceeded &&
        asked is CommandConfirmed &&
        pending is AccessReadOk<MyCredentials> &&
        pending.value.pendingChange?.state == CredentialChangeState.pending &&
        stillGranted is MemberAccessGranted,
    'password=${reauth.runtimeType} request=${outcome(asked)} '
        'pending=${pending is AccessReadOk<MyCredentials> && pending.value.pendingChange != null} '
        'access=${access(stillGranted)}',
  );

  // C2: the Admin (staff web) approves it from the queue.
  final staff = await signedIn(adminPhone);
  final queue = await SupabaseCredentialReviewRepository(staff).fetchQueue();
  final item = queue is AccessReadOk<CredentialQueue>
      ? queue.value.changes.firstOrNull
      : null;
  final approved = item == null
      ? null
      : await SupabaseCommandGateway(staff).send(
          CredentialCommands.function,
          CommandRequest(
            command: CredentialCommands.approve,
            requestId: SecureRequestIds().next(),
            expectedRevision: Optional.of(item.change.revision),
            payload: {
              'change_id': item.change.changeId,
              'identity_check': 'in_person',
            },
          ),
        );
  final revoked = await SupabaseMemberAccessRepository(mobile).fetchMySummary();
  await Future<void>.delayed(wait);
  final oldNumber = await SupabaseAccountAuthGateway(client())
      .signIn(phoneE164: phone, password: password);
  final renamed = await signedIn(newPhone);
  final s2 = await SupabaseMemberAccessRepository(renamed).fetchMySummary();
  check(
    'C2 approved and applied; the old session is revoked; the new number signs in',
    item?.phoneAvailable == true &&
        approved is CommandConfirmed &&
        revoked is MemberAccessDenied &&
        revoked.denial == MemberAccessDenial.untrustedSession &&
        oldNumber is AuthFailed &&
        s2 is MemberAccessGranted &&
        s2.summary.phoneUsername == newPhone,
    'approve=${outcome(approved)} earlier=${access(revoked)} '
        'old_number=${oldNumber.runtimeType} new_number=${access(s2)}',
  );

  // C3: a lost-device hold revokes the session; a new sign-in reaches only
  // the help screen's generic read.
  final memberId = s2 is MemberAccessGranted ? s2.summary.memberId : null;
  final search = await SupabaseReviewRepository(staff)
      .searchMembers('SYNTHETIC 2.8 Live Member');
  final record = search is AccessReadOk<MemberSearchPage>
      ? search.value.members.where((m) => m.memberId == memberId).firstOrNull
      : null;
  final held = record == null
      ? null
      : await SupabaseCommandGateway(staff).send(
          CredentialCommands.function,
          CommandRequest(
            command: CredentialCommands.placeHold,
            requestId: SecureRequestIds().next(),
            expectedRevision: Optional.of(record.revision),
            payload: {'member_id': memberId, 'reason_code': 'lost_device'},
          ),
        );
  final afterHold = await SupabaseMemberAccessRepository(renamed)
      .fetchMySummary();
  final device = await signedIn(newPhone);
  final helpRead = await SupabaseCredentialReviewRepository(device).fetchMine();
  final myAccess = await SupabaseGrantsRepository(device).fetchMyAccess();
  check(
    'C3 lost device: sessions revoked; a new sign-in sees only access review',
    held is CommandConfirmed &&
        afterHold is MemberAccessDenied &&
        afterHold.denial == MemberAccessDenial.untrustedSession &&
        helpRead is AccessReadOk<MyCredentials> &&
        helpRead.value.inReview &&
        myAccess is AccessReadDenied<MemberGrants> &&
        myAccess.denial == AccessDenial.reviewRequired,
    'hold=${outcome(held)} revoked_session=${access(afterHold)} '
        'help_read_in_review=${helpRead is AccessReadOk<MyCredentials> && helpRead.value.inReview} '
        'my_access=${myAccess is AccessReadDenied<MemberGrants> ? myAccess.denial.name : 'ok'}',
  );

  // C4: another Admin releases it after an identity check.
  final queue2 = await SupabaseCredentialReviewRepository(staff).fetchQueue();
  final hold = queue2 is AccessReadOk<CredentialQueue>
      ? queue2.value.holds.where((h) => h.memberId == memberId).firstOrNull
      : null;
  final released = hold == null
      ? null
      : await SupabaseCommandGateway(staff).send(
          CredentialCommands.function,
          CommandRequest(
            command: CredentialCommands.releaseHold,
            requestId: SecureRequestIds().next(),
            expectedRevision: Optional.of(hold.memberRevision),
            payload: {
              'member_id': hold.memberId,
              'hold_id': hold.holdId,
              'identity_check': 'established_relationship',
            },
          ),
        );
  await Future<void>.delayed(wait);
  final duringHold = await SupabaseMemberAccessRepository(device)
      .fetchMySummary();
  final fresh = await signedIn(newPhone);
  final s4 = await SupabaseMemberAccessRepository(fresh).fetchMySummary();
  check(
    'C4 released after an identity check; a fresh sign-in is granted',
    hold?.reason == HoldReason.lostDevice &&
        released is CommandConfirmed &&
        duringHold is MemberAccessDenied &&
        duringHold.denial == MemberAccessDenial.untrustedSession &&
        s4 is MemberAccessGranted,
    'release=${outcome(released)} hold_time_session=${access(duringHold)} '
        'fresh=${access(s4)}',
  );
  exit(ok ? 0 : 1);
}

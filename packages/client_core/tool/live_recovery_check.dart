// Story 2.7: drives the REAL client adapters (SupabaseAccountAuthGateway,
// SupabaseRecoveryEmailRepository, SupabaseCommandGateway,
// SupabasePasswordRecoveryGateway and SupabaseMemberAccessRepository) against
// a running LOCAL stack with the local phone switch on and Mailpit catching
// email: a member adds a recovery email to the same account and confirms it
// (the link from Mailpit), a staff-web Admin approves it, then the member
// resets the password from the mobile link through the isolated recovery
// client; the earlier session loses access and a fresh sign-in is granted.
//
//   dart run tool/live_recovery_check.dart <env-file> <admin-phone> <member-phone> <email>
//
// Run through tools/identity-e2e/live-recovery-check.sh, which creates and
// links both accounts and removes everything afterwards. The password comes
// from LIVE_CHECK_PASSWORD. Publishable key only; prints outcomes, never
// tokens, codes, links or passwords.
import 'dart:convert';
import 'dart:io';

import 'package:church_client_core/src/domain/access_grants.dart';
import 'package:church_client_core/src/domain/account_auth.dart';
import 'package:church_client_core/src/domain/commands.dart';
import 'package:church_client_core/src/domain/member_access.dart';
import 'package:church_client_core/src/domain/password_recovery.dart';
import 'package:church_client_core/src/domain/recovery_email.dart';
import 'package:church_client_core/supabase_adapters.dart';
import 'package:church_contracts/church_contracts.dart';
import 'package:http/http.dart' as http;
import 'package:supabase/supabase.dart' hide ErrorCode;

const _mailpit = 'http://127.0.0.1:54324';

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

/// The newest local verify link sent to [to] since [since] (Mailpit).
Future<String?> _link(String to, DateTime since) async {
  for (var i = 0; i < 20; i++) {
    final list = jsonDecode(
      (await http.get(
        Uri.parse(
          '$_mailpit/api/v1/search?query=${Uri.encodeQueryComponent('to:"$to"')}',
        ),
      )).body,
    ) as Map;
    final fresh =
        ((list['messages'] as List?) ?? const [])
            .cast<Map>()
            .where(
              (m) => DateTime.parse(m['Created'] as String)
                  .isAfter(since.subtract(const Duration(milliseconds: 200))),
            )
            .toList()
          ..sort(
            (a, b) =>
                (b['Created'] as String).compareTo(a['Created'] as String),
          );
    if (fresh.isNotEmpty) {
      final msg = jsonDecode(
        (await http.get(
          Uri.parse('$_mailpit/api/v1/message/${fresh.first['ID']}'),
        )).body,
      ) as Map;
      final text =
          '${msg['Text'] ?? ''}\n${(msg['HTML'] ?? '').toString().replaceAll('&amp;', '&')}';
      return RegExp(r'''http://127\.0\.0\.1:54321/auth/v1/verify\?[^\s"'<>]+''')
          .firstMatch(text)
          ?.group(0);
    }
    await Future<void>.delayed(const Duration(milliseconds: 250));
  }
  return null;
}

/// Opens a verify link like the member's browser would, without following
/// the redirect: returns the redirect target.
Future<String?> _open(String link) async {
  final client = HttpClient();
  try {
    final req = await client.getUrl(Uri.parse(link));
    req.followRedirects = false;
    final res = await req.close();
    await res.drain<void>();
    return res.headers.value('location');
  } finally {
    client.close();
  }
}

Future<void> main(List<String> args) async {
  if (args.length != 4) {
    stderr.writeln('usage: <env-file> <admin-phone> <member-phone> <email>');
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
  final email = args[3];
  if (url != 'http://127.0.0.1:54321' || key == null || password == null) {
    stderr.writeln('LOCAL only; set LIVE_CHECK_PASSWORD.');
    exit(2);
  }
  final fictional = RegExp(r'^\+44770090028[0-9]$');
  if (!fictional.hasMatch(adminPhone) ||
      !fictional.hasMatch(phone) ||
      !email.endsWith('@example.test')) {
    stderr.writeln('refusing a non-fictional phone username or address');
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

  // The member (mobile) signs in and adds the recovery email.
  final mobile = client();
  await SupabaseAccountAuthGateway(mobile)
      .signIn(phoneE164: phone, password: password);
  final emails = SupabaseRecoveryEmailRepository(
    mobile,
    redirects: AuthRedirects.mobile,
  );
  final mine0 = await emails.fetchMine();
  final confirmed = await emails.confirmPassword(password);
  final proposed = await SupabaseCommandGateway(mobile).send(
    RecoveryEmailCommands.function,
    CommandRequest(
      command: RecoveryEmailCommands.propose,
      requestId: SecureRequestIds().next(),
      expectedRevision: const Optional.of(null),
      payload: {'email': email},
    ),
  );
  final askedAt = DateTime.now().toUtc();
  final verification = await emails.requestVerification(email);
  check(
    'L1 add a recovery email to the same account',
    mine0 is AccessReadOk<MyRecoveryEmail> &&
        mine0.value.canPropose &&
        confirmed is AuthSucceeded &&
        proposed is CommandConfirmed &&
        verification == EmailVerificationRequest.sent,
    'can_propose=${mine0 is AccessReadOk<MyRecoveryEmail> && mine0.value.canPropose} '
        'password=${confirmed.runtimeType} proposal=${proposed.runtimeType} '
        'verification=${verification.name}',
  );

  final confirmLink = await _link(email, askedAt);
  final landing = confirmLink == null ? null : await _open(confirmLink);
  final landingUri = landing == null ? null : Uri.parse(landing);
  final landed = landingUri == null
      ? null
      : parseAuthLink(Uri(path: landingUri.path, query: landingUri.query));
  final mine1 = await emails.fetchMine();
  check(
    'L2 the confirmation link returns to the allowlisted app link; access waits',
    landed?.kind == AuthLinkKind.emailConfirmed &&
        mine1 is AccessReadOk<MyRecoveryEmail> &&
        mine1.value.inReview &&
        // In review the own read is generic (2.8 review fix): the pending
        // proposal without its address or `verified`. L3's approval proves
        // the address was confirmed (the server refuses an unverified one).
        mine1.value.proposal?.state == ProposalState.pending,
    'link=${landed?.kind.name} in_review=${mine1 is AccessReadOk<MyRecoveryEmail> && mine1.value.inReview}',
  );

  // The Admin (staff web) approves after an identity check.
  final staff = client();
  await SupabaseAccountAuthGateway(staff)
      .signIn(phoneE164: adminPhone, password: password);
  final queue = await SupabaseRecoveryEmailRepository(
    staff,
    redirects: AuthRedirects.web(Uri.parse('http://127.0.0.1:3000/')),
  ).fetchQueue();
  final item = queue is AccessReadOk<RecoveryEmailQueue>
      ? queue.value.items.where((i) => i.proposal.email == email).firstOrNull
      : null;
  final approved = item == null
      ? null
      : await SupabaseCommandGateway(staff).send(
          RecoveryEmailCommands.function,
          CommandRequest(
            command: RecoveryEmailCommands.approve,
            requestId: SecureRequestIds().next(),
            expectedRevision: Optional.of(item.proposal.revision),
            payload: {
              'proposal_id': item.proposal.proposalId,
              'identity_check': 'in_person',
            },
          ),
        );
  await Future<void>.delayed(const Duration(milliseconds: 6500));
  final member = client();
  await SupabaseAccountAuthGateway(member)
      .signIn(phoneE164: phone, password: password);
  final s1 = await SupabaseMemberAccessRepository(member).fetchMySummary();
  check(
    'L3 the Admin approves; a fresh sign-in is granted with the email',
    approved is CommandConfirmed &&
        s1 is MemberAccessGranted &&
        s1.summary.hasRecoveryEmail,
    'approve=${approved.runtimeType} fresh=${access(s1)}',
  );

  // Forgot password from the mobile link, through the isolated client.
  final recovery = SupabasePasswordRecoveryGateway(
    supabaseUrl: url!,
    publishableKey: key,
    redirects: AuthRedirects.mobile,
    verifierStorage: _MemoryStorage(),
  );
  final resetAt = DateTime.now().toUtc();
  final asked = await recovery.requestReset(email);
  // Another device asks for an unknown address: the same neutral answer.
  final unknown = await SupabasePasswordRecoveryGateway(
    supabaseUrl: url,
    publishableKey: key,
    redirects: AuthRedirects.mobile,
    verifierStorage: _MemoryStorage(),
  ).requestReset('nobody-2-7@example.test');
  final resetLink = await _link(email, resetAt);
  final target = resetLink == null ? null : await _open(resetLink);
  final targetUri = target == null ? null : Uri.parse(target);
  final link = targetUri == null
      ? null
      : parseAuthLink(Uri(path: targetUri.path, query: targetUri.query));
  final opened = link?.usable == true
      ? await recovery.openLink(link!.code!)
      : RecoveryLinkOutcome.unusable;
  check(
    'L4 neutral request; the mobile link opens a recovery session',
    asked == ResetRequestOutcome.sent &&
        unknown == ResetRequestOutcome.sent &&
        link?.kind == AuthLinkKind.recovery &&
        opened == RecoveryLinkOutcome.ready,
    'request=${asked.name} unknown=${unknown.name} link=${link?.kind.name} open=${opened.name}',
  );
  final newPassword = '$password-new';
  final set = await recovery.setNewPassword(newPassword);
  final old = await SupabaseMemberAccessRepository(member).fetchMySummary();
  await Future<void>.delayed(const Duration(milliseconds: 6500));
  final fresh = client();
  final oldPw = await SupabaseAccountAuthGateway(fresh)
      .signIn(phoneE164: phone, password: password);
  await SupabaseAccountAuthGateway(fresh)
      .signIn(phoneE164: phone, password: newPassword);
  final s2 = await SupabaseMemberAccessRepository(fresh).fetchMySummary();
  check(
    'L5 password set; the earlier session is refused; fresh sign-in granted',
    set is PasswordSet &&
        old is MemberAccessDenied &&
        old.denial == MemberAccessDenial.untrustedSession &&
        oldPw is AuthFailed &&
        s2 is MemberAccessGranted,
    'set=${set.runtimeType} earlier=${access(old)} '
        'old_password=${oldPw.runtimeType} fresh=${access(s2)}',
  );
  exit(ok ? 0 : 1);
}

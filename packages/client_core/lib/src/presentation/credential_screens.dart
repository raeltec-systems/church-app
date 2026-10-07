import 'package:church_design_system/church_design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../application/access_controllers.dart';
import '../application/credential_controllers.dart';
import '../application/providers.dart';
import '../domain/access_grants.dart';
import '../domain/credential_review.dart';
import '../domain/membership_review.dart' show IdentityCheck, MemberRecord;
import '../domain/phone_username.dart';
import '../domain/password_recovery.dart' show looksLikeEmail;
import '../domain/recovery_email.dart';
import 'shell_routing.dart' show ClientPaths;

/// Story 2.8 screens: the generic "Access review required" help screen (both
/// clients), the member's own sign-in details with reviewed change requests
/// (mobile), and the Admin credential review (staff web).
Widget _page(BuildContext context, String title, List<Widget> children) {
  final c = ChurchColors.of(context);
  final layout = ChurchLayout.of(context);
  return Scaffold(
    appBar: AppBar(title: Text(title)),
    body: SafeArea(
      child: SingleChildScrollView(
        padding: layout.pagePadding,
        child: Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: layout.contentMaxWidth),
            child: DefaultTextStyle.merge(
              style: layout.body.copyWith(color: c.ink),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: children,
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

const _gap = SizedBox(height: ChurchGeometry.sectionGap);

String _kindTitle(CredentialChangeKind kind) => switch (kind) {
  CredentialChangeKind.phoneUsername => 'New phone number username',
  CredentialChangeKind.recoveryEmailReplace => 'New recovery email',
  CredentialChangeKind.recoveryEmailRemove => 'Remove recovery email',
};

/// Routes that show member or staff data. While the server answers that the
/// caller's access is in review, both shells show only the help screen there.
const accessReviewGatedPaths = <String>{
  ClientPaths.account,
  ClientPaths.access,
  ClientPaths.adminGrants,
  ClientPaths.adminMembers,
  ClientPaths.adminCells,
  ClientPaths.cellLeader,
  ClientPaths.myCell,
  ClientPaths.adminRecoveryEmails,
  ClientPaths.adminCredentialReviews,
  ClientPaths.signInDetails,
};

/// Shows [AccessReviewScreen] instead of a private destination while the
/// server's current answer for this session is "access review required"
/// (a hold, a dispute, a sign-in change waiting for review). Presentation
/// only: every private read is refused by the server anyway.
class AccessReviewGate extends ConsumerWidget {
  const AccessReviewGate({super.key, required this.path, required this.child});

  final String path;
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final review = ref.watch(
      myAccessProvider.select(
        (s) => switch (s.result) {
          AccessReadDenied(:final denial) =>
            denial == AccessDenial.reviewRequired,
          _ => false,
        },
      ),
    );
    if (review && accessReviewGatedPaths.contains(path)) {
      return const AccessReviewScreen(key: Key('access-review-gate'));
    }
    return child;
  }
}

// ---------------------------------------------------------------------------
// Access review required (generic help screen, both clients)
// ---------------------------------------------------------------------------

class AccessReviewScreen extends ConsumerWidget {
  const AccessReviewScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = ChurchColors.of(context);
    final signedIn = ref.watch(accountProvider.select((a) => a.accountId));
    final s = ref.watch(myCredentialsProvider);
    final mine = s.value;
    final children = <Widget>[];
    if (signedIn == null) {
      children.addAll([
        const Text('Sign in with your phone number and password.'),
        _gap,
        Align(
          alignment: Alignment.centerLeft,
          child: FocusRing(
            child: FilledButton(
              key: const Key('access-review-sign-in'),
              onPressed: () => context.go(ClientPaths.signIn),
              child: const Text('Sign in'),
            ),
          ),
        ),
      ]);
      return _page(context, 'Access review required', children);
    }
    final notice = s.notice;
    if (notice != null) {
      children.addAll([_CredentialNoticeBanner(notice), _gap]);
    }
    if (mine != null && !mine.inReview) {
      children.add(
        RequestStateBanner(
          key: const Key('access-review-cleared'),
          tone: StatusTone.success,
          icon: Icons.lock_open_outlined,
          title: 'Your access is open',
          message: 'No church check is waiting for this account now.',
          actions: [
            BannerAction(
              'My membership',
              () => context.go(ClientPaths.account),
              key: const Key('access-review-go-account'),
              primary: true,
            ),
          ],
        ),
      );
    } else {
      final contact = mine?.churchContact;
      children.addAll([
        RequestStateBanner(
          key: const Key('access-review-required'),
          tone: StatusTone.warning,
          icon: Icons.shield_outlined,
          title: 'Access review required',
          message:
              'Your account needs a check by the church before member '
              'information can be shown here. This is a normal safety step; '
              'nothing is wrong with your device. Signing in again, resetting '
              'your password or confirming an email does not finish the '
              'check: a church staff member does, after checking who you are.',
        ),
        _gap,
        Semantics(
          header: true,
          child: Text(
            'Get help',
            style: ChurchType.cardTitle.copyWith(color: c.ink),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          contact == null
              ? 'Contact the church office, or speak to church staff after a '
                    'service. Staff never ask for your password.'
              : 'Contact the church: $contact. Staff never ask for your '
                    'password.',
          key: const Key('access-review-contact'),
        ),
      ]);
      if (mine != null) children.addAll(_currentRequest(context, ref, mine, s));
    }
    if (s.result is AccessReadFailed<MyCredentials>) {
      children.addAll([
        _gap,
        const RequestStateBanner(
          key: Key('access-review-failed'),
          tone: StatusTone.danger,
          icon: Icons.cloud_off_outlined,
          title: 'Couldn\'t check',
          message: 'We couldn\'t reach the church server. Try again.',
        ),
      ]);
    }
    children.addAll([
      _gap,
      Wrap(
        spacing: 12,
        runSpacing: 8,
        children: [
          FocusRing(
            child: OutlinedButton.icon(
              key: const Key('access-review-check-again'),
              onPressed: s.loading || s.busy
                  ? null
                  : () {
                      ref.read(myCredentialsProvider.notifier).reload();
                      ref.read(myAccessProvider.notifier).refresh();
                    },
              icon: const Icon(Icons.refresh),
              label: const Text('Check again'),
            ),
          ),
          FocusRing(
            child: OutlinedButton.icon(
              key: const Key('access-review-sign-out'),
              onPressed: () => ref.read(accountAuthGatewayProvider).signOut(),
              icon: const Icon(Icons.logout),
              label: const Text('Sign out'),
            ),
          ),
        ],
      ),
    ]);
    return _page(context, 'Access review required', children);
  }

  List<Widget> _currentRequest(
    BuildContext context,
    WidgetRef ref,
    MyCredentials mine,
    MyCredentialsState s,
  ) {
    final change = mine.pendingChange;
    final proposal = mine.pendingRecoveryEmail;
    if (change == null && proposal == null) return const [];
    return [
      _gap,
      Semantics(
        header: true,
        child: Text('Your current request', style: ChurchType.cardTitle),
      ),
      const SizedBox(height: 8),
      if (change != null)
        RequestStateBanner(
          key: const Key('access-review-pending-change'),
          tone: StatusTone.info,
          icon: Icons.hourglass_top_outlined,
          title: '${_kindTitle(change.kind)}: waiting for the church',
          message:
              change.kind == CredentialChangeKind.recoveryEmailReplace &&
                  change.verified != true
              ? 'Open the confirmation link we sent to ${change.email}. Then '
                    'the church checks it.'
              : 'The church checks who you are before it changes your '
                    'sign-in details.',
          actions: [
            BannerAction(
              'Withdraw this request',
              s.busy
                  ? null
                  : () => ref
                        .read(myCredentialsProvider.notifier)
                        .withdraw(change),
              key: const Key('access-review-withdraw-change'),
            ),
          ],
        ),
      if (proposal != null)
        RequestStateBanner(
          key: const Key('access-review-pending-email'),
          tone: StatusTone.info,
          icon: Icons.hourglass_top_outlined,
          title: 'Recovery email: waiting for the church',
          message: proposal.verified
              ? '${proposal.email} is confirmed and waits for approval.'
              : 'Open the confirmation link we sent to ${proposal.email}.',
          actions: [
            BannerAction(
              'Withdraw this email',
              s.busy
                  ? null
                  : () => ref
                        .read(myCredentialsProvider.notifier)
                        .withdrawRecoveryEmail(proposal),
              key: const Key('access-review-withdraw-email'),
            ),
          ],
        ),
    ];
  }
}

class _CredentialNoticeBanner extends ConsumerWidget {
  const _CredentialNoticeBanner(this.notice);
  final CredentialNotice notice;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final (tone, title, message) = switch (notice) {
      CredentialNotice.requested => (
        StatusTone.success,
        'Sent for church review',
        'Nothing changes until the church checks who you are and approves '
            'it. You can withdraw it until then.',
      ),
      CredentialNotice.checkInbox => (
        StatusTone.success,
        'Check your inbox',
        'Open the confirmation link sent to the new address on this device. '
            'Your member access waits until the church approves it.',
      ),
      CredentialNotice.withdrawn => (
        StatusTone.success,
        'Request withdrawn',
        'Your account is back on its approved sign-in details. If you are '
            'asked, sign in again.',
      ),
      CredentialNotice.wrongPassword => (
        StatusTone.danger,
        'Password not right',
        'Enter your current password.',
      ),
      CredentialNotice.reauthenticate => (
        StatusTone.warning,
        'Confirm your password again',
        'Your last sign-in is too old. Enter your current password again.',
      ),
      CredentialNotice.numberUnavailable => (
        StatusTone.danger,
        'This number can\'t be used',
        'It is already someone\'s sign-in username. Ask the church office '
            'if it is yours.',
      ),
      CredentialNotice.numberOutOfRange => (
        StatusTone.warning,
        'Not available yet',
        'Only test numbers can be used here for now.',
      ),
      CredentialNotice.unchanged => (
        StatusTone.info,
        'Nothing to change',
        'That is already your approved sign-in detail.',
      ),
      CredentialNotice.addressUnavailable => (
        StatusTone.danger,
        'This address can\'t be used',
        'Use another email address, or ask the church office.',
      ),
      CredentialNotice.invalid => (
        StatusTone.danger,
        'Check the form',
        'Enter the new detail in full.',
      ),
      CredentialNotice.pendingChange => (
        StatusTone.info,
        'A request is already waiting',
        'Withdraw it first, or wait for the church to decide.',
      ),
      CredentialNotice.rateLimited => (
        StatusTone.warning,
        'Too many attempts',
        'Please wait a while before trying again.',
      ),
      CredentialNotice.confirmationNotSent => (
        StatusTone.warning,
        'The confirmation was not sent',
        'Your request is recorded. Withdraw it and send it again, or ask the '
            'church office.',
      ),
      CredentialNotice.notNow => (
        StatusTone.warning,
        'Not possible right now',
        'Contact the church office.',
      ),
      CredentialNotice.signInAgain => (
        StatusTone.warning,
        'Please sign in again',
        'This sign-in is no longer valid.',
      ),
      CredentialNotice.unconfirmed => (
        StatusTone.warning,
        'Not confirmed yet',
        'We couldn\'t confirm whether the request arrived. Check again; it is '
            'sent once.',
      ),
      CredentialNotice.unreachable => (
        StatusTone.warning,
        'No connection',
        'We couldn\'t reach the church server. Try again.',
      ),
      CredentialNotice.notSent => (
        StatusTone.neutral,
        'Not sent',
        'This build has no server configured.',
      ),
    };
    return RequestStateBanner(
      key: Key('credential-notice-${notice.name}'),
      tone: tone,
      title: title,
      message: message,
      actions: [
        if (notice == CredentialNotice.unconfirmed)
          BannerAction(
            'Check again',
            () => ref.read(myCredentialsProvider.notifier).checkAgain(),
            key: const Key('credential-check-again'),
            primary: true,
          ),
        BannerAction(
          'Dismiss',
          () => ref.read(myCredentialsProvider.notifier).dismissNotice(),
          key: const Key('credential-dismiss'),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Sign-in details: reviewed change requests (mobile)
// ---------------------------------------------------------------------------

class SignInDetailsScreen extends ConsumerStatefulWidget {
  const SignInDetailsScreen({super.key});

  @override
  ConsumerState<SignInDetailsScreen> createState() =>
      _SignInDetailsScreenState();
}

class _SignInDetailsScreenState extends ConsumerState<SignInDetailsScreen> {
  final _phone = TextEditingController();
  final _email = TextEditingController();
  final _password = TextEditingController();
  CredentialChangeKind? _kind;
  String? _phoneError;
  String? _emailError;
  String? _passwordError;
  bool _show = false;

  @override
  void dispose() {
    _phone.dispose();
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  void _submit() {
    final kind = _kind;
    if (kind == null) return;
    String? phone;
    setState(() {
      _phoneError = null;
      _emailError = null;
      if (kind == CredentialChangeKind.phoneUsername) {
        final n = normalizePhoneUsername(_phone.text, defaultDialingCountry);
        phone = n.value;
        _phoneError = n.value == null
            ? 'Enter the new number with its country code, like +44 7700 900123.'
            : null;
      }
      if (kind == CredentialChangeKind.recoveryEmailReplace &&
          !looksLikeEmail(_email.text)) {
        _emailError = 'Enter an email address, like name@example.com.';
      }
      _passwordError = _password.text.isEmpty
          ? 'Enter your current password.'
          : null;
    });
    if (_phoneError != null || _emailError != null || _passwordError != null) {
      return;
    }
    final password = _password.text;
    _password.clear();
    ref
        .read(myCredentialsProvider.notifier)
        .requestChange(
          kind,
          password,
          phoneUsername: phone,
          email: _email.text.trim(),
        );
  }

  @override
  Widget build(BuildContext context) {
    final c = ChurchColors.of(context);
    final signedIn = ref.watch(accountProvider.select((a) => a.accountId));
    final s = ref.watch(myCredentialsProvider);
    final children = <Widget>[];
    if (signedIn == null) {
      children.addAll([
        const Text('Sign in to see your sign-in details.'),
        _gap,
        Align(
          alignment: Alignment.centerLeft,
          child: FocusRing(
            child: FilledButton(
              key: const Key('sign-in-details-sign-in'),
              onPressed: () => context.go(ClientPaths.signIn),
              child: const Text('Sign in'),
            ),
          ),
        ),
      ]);
      return _page(context, 'Sign-in details', children);
    }
    final notice = s.notice;
    if (notice != null) {
      children.addAll([_CredentialNoticeBanner(notice), _gap]);
    }
    final result = s.result;
    if (s.loading && result == null) {
      children.add(
        const RequestStateBanner(
          key: Key('sign-in-details-loading'),
          tone: StatusTone.info,
          busy: true,
          title: 'Loading…',
          message: 'The server checks your access every time.',
        ),
      );
    } else if (result is AccessReadDenied<MyCredentials>) {
      children.add(
        RequestStateBanner(
          key: Key('sign-in-details-denied-${result.denial.name}'),
          tone: StatusTone.warning,
          icon: Icons.lock_outline,
          title: switch (result.denial) {
            AccessDenial.untrustedSession ||
            AccessDenial.signedOut => 'Please sign in again',
            AccessDenial.notLinked => 'No member access yet',
            AccessDenial.unavailable => 'Not available yet',
            _ => 'Access review required',
          },
          message:
              'Sign-in details can be changed once the church has linked '
              'this account to your member record.',
        ),
      );
    } else if (result is AccessReadFailed<MyCredentials>) {
      children.add(
        RequestStateBanner(
          key: const Key('sign-in-details-failed'),
          tone: StatusTone.danger,
          icon: Icons.cloud_off_outlined,
          title: result.unreachable ? 'No connection' : 'Couldn\'t load',
          message: 'Nothing is shown until the server answers.',
          actions: [
            BannerAction(
              'Try again',
              () => ref.read(myCredentialsProvider.notifier).reload(),
              key: const Key('sign-in-details-retry'),
            ),
          ],
        ),
      );
    } else if (result is AccessReadOk<MyCredentials>) {
      final mine = result.value;
      children.addAll([
        Text(
          'Sign-in username: ${mine.phoneUsername}',
          key: const Key('sign-in-details-username'),
        ),
        const SizedBox(height: 4),
        Text(
          mine.recoveryEmail == null
              ? 'Recovery email: none'
              : 'Recovery email: ${mine.recoveryEmail}',
          key: const Key('sign-in-details-email'),
        ),
        const SizedBox(height: 4),
        Text(
          'Your phone number is your sign-in username; it is not checked by '
          'SMS. Changes are made by the church after checking who you are.',
          style: ChurchType.secondary.copyWith(color: c.muted),
        ),
      ]);
      final pending = mine.pendingChange;
      if (pending != null) {
        children.addAll([
          _gap,
          RequestStateBanner(
            key: const Key('sign-in-details-pending'),
            tone: StatusTone.info,
            icon: Icons.hourglass_top_outlined,
            title: '${_kindTitle(pending.kind)}: waiting for the church',
            message: switch (pending.kind) {
              CredentialChangeKind.phoneUsername =>
                'Requested: ${pending.phoneUsername}. Your current number '
                    'keeps working until the church approves it; then sign '
                    'in with the new number.',
              CredentialChangeKind.recoveryEmailReplace =>
                pending.verified == true
                    ? '${pending.email} is confirmed and waits for approval.'
                    : 'Open the confirmation link we sent to '
                          '${pending.email}.',
              CredentialChangeKind.recoveryEmailRemove =>
                'Your recovery email keeps working until the church '
                    'approves the removal.',
            },
            actions: [
              BannerAction(
                'Withdraw this request',
                s.busy
                    ? null
                    : () => ref
                          .read(myCredentialsProvider.notifier)
                          .withdraw(pending),
                key: const Key('sign-in-details-withdraw'),
              ),
            ],
          ),
        ]);
      } else if (mine.lastChange case final last?
          when last.state == CredentialChangeState.rejected) {
        children.addAll([
          _gap,
          RequestStateBanner(
            key: const Key('sign-in-details-rejected'),
            tone: StatusTone.warning,
            icon: Icons.info_outline,
            title: 'Not approved',
            message: [
              'Your last request (${_kindTitle(last.kind).toLowerCase()}) '
                  'was not approved.',
              if (last.decisionReason != null) '${last.decisionReason!.label}.',
              'Contact the church office.',
            ].join(' '),
          ),
        ]);
      }
      if (mine.canRequest) children.addAll(_form(context, mine, s.busy));
    }
    return _page(context, 'Sign-in details', children);
  }

  List<Widget> _form(BuildContext context, MyCredentials mine, bool busy) {
    final kinds = [
      CredentialChangeKind.phoneUsername,
      if (mine.recoveryEmail != null) ...[
        CredentialChangeKind.recoveryEmailReplace,
        CredentialChangeKind.recoveryEmailRemove,
      ],
    ];
    final kind = _kind;
    return [
      _gap,
      RadioGroup<CredentialChangeKind>(
        groupValue: kind,
        onChanged: (v) {
          if (busy || v == null) return;
          setState(() => _kind = v);
        },
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Semantics(
              header: true,
              child: Text('Ask for a change', style: ChurchType.cardTitle),
            ),
            for (final k in kinds)
              RadioListTile<CredentialChangeKind>(
                key: Key('change-kind-${k.wire}'),
                value: k,
                enabled: !busy,
                contentPadding: EdgeInsets.zero,
                title: Text(k.label),
              ),
          ],
        ),
      ),
      if (kind == CredentialChangeKind.phoneUsername) ...[
        const SizedBox(height: 12),
        RevealOnFocus(
          child: TextField(
            key: const Key('new-phone-username-field'),
            controller: _phone,
            readOnly: busy,
            keyboardType: TextInputType.phone,
            autofillHints: const [AutofillHints.telephoneNumber],
            decoration: InputDecoration(
              labelText: 'New phone number (with country code)',
              helperText: 'This becomes your sign-in username. No SMS is sent.',
              errorText: _phoneError,
            ),
          ),
        ),
      ],
      if (kind == CredentialChangeKind.recoveryEmailReplace) ...[
        const SizedBox(height: 12),
        RevealOnFocus(
          child: TextField(
            key: const Key('replacement-email-field'),
            controller: _email,
            readOnly: busy,
            keyboardType: TextInputType.emailAddress,
            autofillHints: const [AutofillHints.email],
            autocorrect: false,
            enableSuggestions: false,
            decoration: InputDecoration(
              labelText: 'New recovery email',
              helperText:
                  'Your current address stops working at once; your member '
                  'access waits until the church approves the new one.',
              helperMaxLines: 3,
              errorText: _emailError,
            ),
          ),
        ),
      ],
      if (kind != null) ...[
        const SizedBox(height: 12),
        RevealOnFocus(
          child: TextField(
            key: const Key('change-current-password-field'),
            controller: _password,
            readOnly: busy,
            obscureText: !_show,
            autocorrect: false,
            enableSuggestions: false,
            autofillHints: const [AutofillHints.password],
            onSubmitted: (_) => busy ? null : _submit(),
            decoration: InputDecoration(
              labelText: 'Current password',
              errorText: _passwordError,
              suffixIcon: FocusRing(
                child: IconButton(
                  key: const Key('toggle-change-password'),
                  tooltip: _show ? 'Hide password' : 'Show password',
                  icon: Icon(
                    _show
                        ? Icons.visibility_off_outlined
                        : Icons.visibility_outlined,
                  ),
                  onPressed: () => setState(() => _show = !_show),
                ),
              ),
            ),
          ),
        ),
        _gap,
        Align(
          alignment: Alignment.centerLeft,
          child: FocusRing(
            child: FilledButton(
              key: const Key('send-credential-change'),
              onPressed: busy ? null : _submit,
              child: const Text('Send for church review'),
            ),
          ),
        ),
      ],
    ];
  }
}

// ---------------------------------------------------------------------------
// Admin: credential review (staff web)
// ---------------------------------------------------------------------------

class CredentialReviewScreen extends ConsumerStatefulWidget {
  const CredentialReviewScreen({super.key});

  @override
  ConsumerState<CredentialReviewScreen> createState() =>
      _CredentialReviewScreenState();
}

class _CredentialReviewScreenState
    extends ConsumerState<CredentialReviewScreen> {
  final _checks = <String, IdentityCheck>{};
  final _reasons = <String, RecoveryEmailRejectReason>{};
  final _holdReasons = <String, HoldReason>{};
  final _query = TextEditingController();

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  Widget _checkPicker(String id, bool enabled) => RadioGroup<IdentityCheck>(
    groupValue: _checks[id],
    onChanged: (v) {
      if (!enabled || v == null) return;
      setState(() => _checks[id] = v);
    },
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Identity check', style: ChurchType.cardTitle),
        for (final k in IdentityCheck.values)
          RadioListTile<IdentityCheck>(
            key: Key('credential-review-$id-check-${k.wire}'),
            value: k,
            enabled: enabled,
            contentPadding: EdgeInsets.zero,
            title: Text(k.label),
          ),
      ],
    ),
  );

  Widget _card(BuildContext context, Key key, List<Widget> children) {
    final c = ChurchColors.of(context);
    // A Material card, so the radio tiles paint their ink on the card.
    return Material(
      key: key,
      color: c.surface,
      shape: RoundedRectangleBorder(
        side: BorderSide(color: c.line),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Padding(
        padding: const EdgeInsets.all(ChurchGeometry.cardPadding),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: children,
        ),
      ),
    );
  }

  Widget _name(BuildContext context, String name) => Semantics(
    header: true,
    child: Text(
      name,
      style: ChurchType.cardTitle.copyWith(color: ChurchColors.of(context).ink),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final c = ChurchColors.of(context);
    final s = ref.watch(credentialReviewProvider);
    final children = <Widget>[
      Text(
        'Change sign-in details, hold access or release a hold only after '
        'checking who the member is. Staff never see or set passwords.',
        style: ChurchType.secondary.copyWith(color: c.muted),
      ),
      _gap,
    ];
    final notice = s.notice;
    if (notice != null) children.addAll([_noticeBanner(notice, s), _gap]);
    final r = s.result;
    final q = s.queue;
    if (s.loading && r == null) {
      children.add(
        const RequestStateBanner(
          key: Key('credential-review-loading'),
          tone: StatusTone.info,
          busy: true,
          title: 'Loading…',
          message: 'Waiting for the server.',
        ),
      );
    } else if (r is AccessReadDenied<CredentialQueue>) {
      children.add(
        RequestStateBanner(
          key: Key('credential-review-denied-${r.denial.name}'),
          tone: StatusTone.warning,
          icon: Icons.lock_outline,
          title: 'Not available',
          message: r.denial == AccessDenial.notGranted
              ? 'Only an Admin can review sign-in details and holds.'
              : 'Sign in again, or contact the church office.',
        ),
      );
    } else if (r is AccessReadFailed<CredentialQueue>) {
      children.add(
        RequestStateBanner(
          key: const Key('credential-review-failed'),
          tone: StatusTone.danger,
          icon: Icons.cloud_off_outlined,
          title: r.unreachable ? 'No connection' : 'Couldn\'t load',
          message: 'Nothing is shown until the server answers.',
          actions: [
            BannerAction(
              'Try again',
              () => ref.read(credentialReviewProvider.notifier).reload(),
              key: const Key('credential-review-retry'),
            ),
          ],
        ),
      );
    } else if (q != null) {
      children.addAll(
        _section(
          context,
          'Requested changes',
          [for (final item in q.changes) _change(context, item, s.busy)],
          'No sign-in change is waiting.',
          'credential-review-no-changes',
        ),
      );
      children.addAll(
        _section(
          context,
          'Accounts in access review',
          [for (final item in q.reviews) _review(context, item, s.busy)],
          'No account waits for a credential review.',
          'credential-review-no-reviews',
        ),
      );
      children.addAll(
        _section(
          context,
          'Holds',
          [for (final h in q.holds) _hold(context, h, s.busy)],
          'No account is on hold.',
          'credential-review-no-holds',
        ),
      );
      children.addAll(_placeHold(context, s));
    }
    return _page(context, 'Access reviews', children);
  }

  List<Widget> _section(
    BuildContext context,
    String title,
    List<Widget> items,
    String empty,
    String emptyKey,
  ) => [
    Semantics(header: true, child: Text(title, style: ChurchType.cardTitle)),
    const SizedBox(height: 8),
    if (items.isEmpty) Text(empty, key: Key(emptyKey)),
    for (final w in items) ...[w, const SizedBox(height: 12)],
    _gap,
  ];

  Widget _change(BuildContext context, CredentialChangeItem item, bool busy) {
    final id = item.change.changeId;
    final check = _checks[id];
    final ch = item.change;
    final canApprove =
        !item.ownAccount &&
        !item.otherChanges &&
        (ch.kind != CredentialChangeKind.recoveryEmailReplace ||
            ch.verified == true) &&
        (ch.kind != CredentialChangeKind.phoneUsername ||
            item.phoneAvailable == true);
    return _card(context, Key('credential-change-$id'), [
      _name(context, item.displayName),
      const SizedBox(height: 4),
      Text('Current sign-in username: ${item.currentPhoneUsername}'),
      Text(switch (ch.kind) {
        CredentialChangeKind.phoneUsername =>
          'Requested username: ${ch.phoneUsername}',
        CredentialChangeKind.recoveryEmailReplace =>
          'Requested recovery email: ${ch.email}',
        CredentialChangeKind.recoveryEmailRemove =>
          'Requested: remove the recovery email',
      }),
      const SizedBox(height: 8),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          if (ch.kind == CredentialChangeKind.recoveryEmailReplace)
            StatusLabel(
              label: ch.verified == true
                  ? 'Confirmed by the member'
                  : 'Not confirmed yet',
              tone: ch.verified == true
                  ? StatusTone.success
                  : StatusTone.warning,
            ),
          if (ch.kind == CredentialChangeKind.phoneUsername &&
              item.phoneAvailable == false)
            const StatusLabel(
              label: 'Number held by another account',
              tone: StatusTone.danger,
            ),
          if (item.otherChanges)
            const StatusLabel(
              label: 'Other sign-in changes: not this request',
              tone: StatusTone.danger,
            ),
          if (item.isSynthetic)
            const StatusLabel(
              label: 'Synthetic test record',
              tone: StatusTone.neutral,
            ),
        ],
      ),
      if (item.ownAccount) ...[
        const SizedBox(height: 8),
        Text(
          'This is your own account: another Admin must decide.',
          key: Key('credential-change-own-$id'),
        ),
      ],
      const SizedBox(height: 12),
      _checkPicker(id, !busy && canApprove),
      RadioGroup<RecoveryEmailRejectReason>(
        groupValue: _reasons[id],
        onChanged: (v) {
          if (busy || item.ownAccount || v == null) return;
          setState(() => _reasons[id] = v);
        },
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Reason if not approved (optional)',
              style: ChurchType.cardTitle,
            ),
            for (final k in RecoveryEmailRejectReason.values)
              RadioListTile<RecoveryEmailRejectReason>(
                key: Key('credential-change-$id-reason-${k.wire}'),
                value: k,
                enabled: !busy && !item.ownAccount,
                contentPadding: EdgeInsets.zero,
                title: Text(k.label),
              ),
          ],
        ),
      ),
      const SizedBox(height: 12),
      Wrap(
        spacing: 12,
        runSpacing: 8,
        children: [
          FocusRing(
            child: FilledButton(
              key: Key('credential-change-approve-$id'),
              onPressed: busy || !canApprove || check == null
                  ? null
                  : () => ref
                        .read(credentialReviewProvider.notifier)
                        .approve(item, check),
              child: const Text('Approve and apply'),
            ),
          ),
          FocusRing(
            child: OutlinedButton(
              key: Key('credential-change-reject-$id'),
              onPressed: busy || item.ownAccount
                  ? null
                  : () => ref
                        .read(credentialReviewProvider.notifier)
                        .reject(item, reason: _reasons[id]),
              child: const Text('Don\'t approve'),
            ),
          ),
        ],
      ),
    ]);
  }

  Widget _review(BuildContext context, AccessReviewItem item, bool busy) {
    final id = 'review-${item.memberId}';
    final check = _checks[id];
    final enabled = !busy && !item.ownAccount;
    return _card(context, Key('credential-review-${item.memberId}'), [
      _name(context, item.displayName),
      const SizedBox(height: 4),
      Text('Approved username: ${item.phoneUsername}'),
      Text('Approved recovery email: ${item.recoveryEmail ?? 'none'}'),
      Text('Username now: ${item.authPhoneUsername ?? 'none'}'),
      Text(
        'Email now: ${item.authEmail ?? 'none'}'
        '${item.authEmail != null && !item.authEmailConfirmed ? ' (not confirmed)' : ''}',
      ),
      const SizedBox(height: 8),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final k in item.changeKinds)
            StatusLabel(label: 'Changed: $k', tone: StatusTone.warning),
          if (item.extraFactors)
            const StatusLabel(
              label: 'Extra sign-in factor: restore only',
              tone: StatusTone.danger,
            ),
          if (item.isSynthetic)
            const StatusLabel(
              label: 'Synthetic test record',
              tone: StatusTone.neutral,
            ),
        ],
      ),
      if (item.ownAccount) ...[
        const SizedBox(height: 8),
        const Text('This is your own account: another Admin must decide.'),
      ],
      const SizedBox(height: 12),
      _checkPicker(id, enabled),
      const SizedBox(height: 4),
      Text(
        'Restore puts the approved details back and signs out every device. '
        'Accept makes the current details the approved ones.',
        style: ChurchType.secondary.copyWith(
          color: ChurchColors.of(context).muted,
        ),
      ),
      const SizedBox(height: 12),
      Wrap(
        spacing: 12,
        runSpacing: 8,
        children: [
          FocusRing(
            child: FilledButton(
              key: Key('credential-review-restore-${item.memberId}'),
              onPressed: !enabled || check == null
                  ? null
                  : () => ref
                        .read(credentialReviewProvider.notifier)
                        .restore(item, check),
              child: const Text('Restore approved details'),
            ),
          ),
          FocusRing(
            child: OutlinedButton(
              key: Key('credential-review-accept-${item.memberId}'),
              onPressed: !enabled || check == null || item.extraFactors
                  ? null
                  : () => ref
                        .read(credentialReviewProvider.notifier)
                        .accept(item, check),
              child: const Text('Accept current details'),
            ),
          ),
        ],
      ),
    ]);
  }

  Widget _hold(BuildContext context, HoldItem hold, bool busy) {
    final id = 'hold-${hold.holdId}';
    final check = _checks[id];
    final enabled = !busy && !hold.ownMember;
    return _card(context, Key('credential-hold-${hold.holdId}'), [
      _name(context, hold.displayName),
      const SizedBox(height: 4),
      Text(hold.reason?.label ?? 'Hold (${hold.holdKind})'),
      if (hold.ownMember) ...[
        const SizedBox(height: 8),
        const Text('This is your own record: another Admin must decide.'),
      ],
      const SizedBox(height: 12),
      _checkPicker(id, enabled),
      const SizedBox(height: 12),
      FocusRing(
        child: FilledButton(
          key: Key('credential-hold-release-${hold.holdId}'),
          onPressed: !enabled || check == null
              ? null
              : () => ref
                    .read(credentialReviewProvider.notifier)
                    .releaseHold(hold, check),
          child: const Text('Release hold'),
        ),
      ),
    ]);
  }

  List<Widget> _placeHold(BuildContext context, CredentialReviewState s) {
    final found = s.search;
    return [
      Semantics(
        header: true,
        child: Text('Place a hold', style: ChurchType.cardTitle),
      ),
      const SizedBox(height: 8),
      Row(
        children: [
          Expanded(
            child: TextField(
              key: const Key('credential-hold-search-field'),
              controller: _query,
              decoration: const InputDecoration(
                labelText: 'Member name or contact number',
              ),
              onSubmitted: (v) =>
                  ref.read(credentialReviewProvider.notifier).searchMembers(v),
            ),
          ),
          const SizedBox(width: 12),
          FocusRing(
            child: OutlinedButton(
              key: const Key('credential-hold-search'),
              onPressed: s.searching
                  ? null
                  : () => ref
                        .read(credentialReviewProvider.notifier)
                        .searchMembers(_query.text),
              child: const Text('Search'),
            ),
          ),
        ],
      ),
      const SizedBox(height: 12),
      if (found is AccessReadOk<List<MemberRecord>>)
        for (final m in found.value) ...[
          _holdTarget(context, m, s.busy),
          const SizedBox(height: 12),
        ],
      if (found is AccessReadOk<List<MemberRecord>> && found.value.isEmpty)
        const Text('No member found.', key: Key('credential-hold-none')),
    ];
  }

  Widget _holdTarget(BuildContext context, MemberRecord m, bool busy) {
    final reason = _holdReasons[m.memberId];
    return _card(context, Key('credential-hold-target-${m.memberId}'), [
      _name(context, m.displayName),
      RadioGroup<HoldReason>(
        groupValue: reason,
        onChanged: (v) {
          if (busy || v == null) return;
          setState(() => _holdReasons[m.memberId] = v);
        },
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final k in HoldReason.values)
              RadioListTile<HoldReason>(
                key: Key('credential-hold-${m.memberId}-reason-${k.wire}'),
                value: k,
                enabled: !busy,
                contentPadding: EdgeInsets.zero,
                title: Text(k.label),
              ),
          ],
        ),
      ),
      FocusRing(
        child: FilledButton(
          key: Key('credential-hold-place-${m.memberId}'),
          onPressed: busy || reason == null
              ? null
              : () => ref
                    .read(credentialReviewProvider.notifier)
                    .placeHold(m.memberId, m.revision, m.displayName, reason),
          child: const Text('Place hold'),
        ),
      ),
    ]);
  }

  Widget _noticeBanner(CredentialReviewNotice notice, CredentialReviewState s) {
    final who = s.subject ?? 'the member';
    final (tone, title, message) = switch (notice) {
      CredentialReviewNotice.approved => (
        StatusTone.success,
        'Approved and applied',
        'The sign-in details of $who changed; every device signs in again.',
      ),
      CredentialReviewNotice.rejected => (
        StatusTone.info,
        'Not approved',
        '$who is told to contact the church office. Their approved details '
            'stay in force.',
      ),
      CredentialReviewNotice.holdPlaced => (
        StatusTone.success,
        'Hold placed',
        'Every device of $who now shows only the access review screen.',
      ),
      CredentialReviewNotice.holdReleased => (
        StatusTone.success,
        'Hold released',
        '$who signs in again to continue.',
      ),
      CredentialReviewNotice.restored => (
        StatusTone.success,
        'Approved details restored',
        'Every device of $who was signed out.',
      ),
      CredentialReviewNotice.accepted => (
        StatusTone.success,
        'Current details accepted',
        '$who signs in again with them.',
      ),
      CredentialReviewNotice.unverified => (
        StatusTone.warning,
        'Not confirmed',
        'The member has not opened the confirmation link yet.',
      ),
      CredentialReviewNotice.otherChanges => (
        StatusTone.danger,
        'Other sign-in changes',
        'Don\'t approve this request; then review the account below.',
      ),
      CredentialReviewNotice.taken => (
        StatusTone.danger,
        'Number in use',
        'Another account holds this number. Nothing was overwritten.',
      ),
      CredentialReviewNotice.pendingChange => (
        StatusTone.warning,
        'A request is waiting',
        'Decide the member\'s pending request first.',
      ),
      CredentialReviewNotice.unsupportedFactors => (
        StatusTone.danger,
        'Extra sign-in factor',
        'Restore the approved details instead.',
      ),
      CredentialReviewNotice.notAcceptable => (
        StatusTone.danger,
        'Can\'t accept these details',
        'The current number or email can\'t become the approved one. '
            'Restore the approved details instead.',
      ),
      CredentialReviewNotice.alreadyHeld => (
        StatusTone.info,
        'Already on hold',
        '$who already has this hold.',
      ),
      CredentialReviewNotice.restoreBlocked => (
        StatusTone.danger,
        'Can\'t restore',
        'Another account now holds the approved number or address.',
      ),
      CredentialReviewNotice.changedElsewhere => (
        StatusTone.info,
        'Changed elsewhere',
        'The record changed since you loaded it. The list was reloaded.',
      ),
      CredentialReviewNotice.selfAction => (
        StatusTone.warning,
        'Not for your own record',
        'Another Admin must decide.',
      ),
      CredentialReviewNotice.noLongerAdmin => (
        StatusTone.danger,
        'Not allowed',
        'Your account no longer holds the Admin role.',
      ),
      CredentialReviewNotice.signInAgain => (
        StatusTone.warning,
        'Please sign in again',
        'This sign-in is no longer valid.',
      ),
      CredentialReviewNotice.notAccepting => (
        StatusTone.neutral,
        'Not available here',
        'This can\'t be done in this environment yet.',
      ),
      CredentialReviewNotice.invalid => (
        StatusTone.danger,
        'Check the form',
        'Choose how you checked the member\'s identity.',
      ),
      CredentialReviewNotice.notFound => (
        StatusTone.info,
        'Not found',
        'The record no longer exists.',
      ),
      CredentialReviewNotice.refused => (
        StatusTone.danger,
        'Refused',
        'The server refused the request.',
      ),
      CredentialReviewNotice.unconfirmed => (
        StatusTone.warning,
        'Not confirmed yet',
        'We couldn\'t confirm whether the decision arrived. Check again; it '
            'is sent once.',
      ),
      CredentialReviewNotice.notSent => (
        StatusTone.neutral,
        'Not sent',
        'This build has no server configured.',
      ),
    };
    return RequestStateBanner(
      key: Key('credential-review-notice-${notice.name}'),
      tone: tone,
      title: title,
      message: message,
      actions: [
        if (notice == CredentialReviewNotice.unconfirmed)
          BannerAction(
            'Check again',
            () => ref.read(credentialReviewProvider.notifier).checkAgain(),
            key: const Key('credential-review-check-again'),
            primary: true,
          ),
        BannerAction(
          'Dismiss',
          () => ref.read(credentialReviewProvider.notifier).dismissNotice(),
          key: const Key('credential-review-dismiss'),
        ),
      ],
    );
  }
}

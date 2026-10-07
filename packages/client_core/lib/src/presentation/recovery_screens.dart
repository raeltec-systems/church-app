import 'package:church_design_system/church_design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../application/providers.dart';
import '../application/recovery_controllers.dart';
import '../domain/access_grants.dart';
import '../domain/membership_review.dart' show IdentityCheck;
import '../domain/password_recovery.dart';
import '../domain/recovery_email.dart';
import 'shell_routing.dart' show ClientPaths;

/// Story 2.7 screens: forgot password (neutral), the recovery link (set a new
/// password, nothing else), the email-confirmed landing, the member's own
/// recovery email (mobile) and the Admin approval queue (staff web).
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

const _churchHelp = RequestStateBanner(
  key: Key('recovery-church-help'),
  tone: StatusTone.info,
  icon: Icons.support_agent_outlined,
  title: 'No recovery email, or can\'t reach it?',
  message:
      'Ask the church office for help. They check who you are in person, '
      'then you set a new password yourself. Staff never see, choose or send '
      'your password, and no code is sent by SMS.',
);

// ---------------------------------------------------------------------------
// Forgot password
// ---------------------------------------------------------------------------

class ForgotPasswordScreen extends ConsumerStatefulWidget {
  const ForgotPasswordScreen({super.key});

  @override
  ConsumerState<ForgotPasswordScreen> createState() =>
      _ForgotPasswordScreenState();
}

class _ForgotPasswordScreenState extends ConsumerState<ForgotPasswordScreen> {
  final _email = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _email.dispose();
    super.dispose();
  }

  void _submit() {
    if (!looksLikeEmail(_email.text)) {
      setState(() => _error = 'Enter an email address, like name@example.com.');
      return;
    }
    setState(() => _error = null);
    ref.read(forgotPasswordProvider.notifier).request(_email.text.trim());
  }

  @override
  Widget build(BuildContext context) {
    final c = ChurchColors.of(context);
    final phase = ref.watch(forgotPasswordProvider);
    final pending = phase == ForgotPhase.pending;
    ref.listen(forgotPasswordProvider, (prev, next) {
      if (next == ForgotPhase.sent && prev != ForgotPhase.sent) {
        announce(context, 'Check your email');
      }
    });
    return _page(context, 'Forgot password', [
      Text(
        'Enter the recovery email the church approved for your account. We '
        'send a link to set a new password. Open it on this device.',
        style: ChurchType.secondary.copyWith(color: c.muted),
      ),
      _gap,
      if (phase == ForgotPhase.sent) ...[
        RequestStateBanner(
          key: const Key('reset-requested'),
          tone: StatusTone.success,
          icon: Icons.mark_email_read_outlined,
          title: 'Check your email',
          message:
              'If this is the approved recovery email of an account, a reset '
              'link is on its way. It works once, expires after an hour, and '
              'only the newest link works. Nothing arrives? Check the address '
              'or get help from the church office.',
          actions: [
            BannerAction(
              'Use another address',
              () => ref.read(forgotPasswordProvider.notifier).reset(),
              key: const Key('reset-again'),
            ),
          ],
        ),
        _gap,
      ],
      if (phase == ForgotPhase.unreachable) ...[
        const RequestStateBanner(
          key: Key('reset-unreachable'),
          tone: StatusTone.warning,
          icon: Icons.cloud_off_outlined,
          title: 'No connection',
          message:
              'We couldn\'t reach the church server, so nothing was sent. '
              'Check your connection and try again.',
        ),
        _gap,
      ],
      if (phase == ForgotPhase.notConfigured) ...[
        const RequestStateBanner(
          key: Key('reset-not-configured'),
          tone: StatusTone.neutral,
          title: 'Not available here',
          message: 'This build has no server configured, so nothing was sent.',
        ),
        _gap,
      ],
      if (pending) ...[
        const RequestStateBanner(
          key: Key('reset-pending'),
          tone: StatusTone.info,
          busy: true,
          title: 'Sending…',
          message: 'Waiting for the server.',
        ),
        _gap,
      ],
      if (phase != ForgotPhase.sent) ...[
        RevealOnFocus(
          child: TextField(
            key: const Key('reset-email-field'),
            controller: _email,
            readOnly: pending,
            keyboardType: TextInputType.emailAddress,
            autofillHints: const [AutofillHints.email],
            autocorrect: false,
            enableSuggestions: false,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => pending ? null : _submit(),
            decoration: InputDecoration(
              labelText: 'Recovery email',
              errorText: _error,
            ),
          ),
        ),
        _gap,
        FocusRing(
          child: FilledButton(
            key: const Key('send-reset-link'),
            onPressed: pending ? null : _submit,
            child: const Text('Send reset link'),
          ),
        ),
        _gap,
      ],
      _churchHelp,
      const SizedBox(height: 12),
      Align(
        alignment: Alignment.centerLeft,
        child: FocusRing(
          child: TextButton(
            key: const Key('back-to-sign-in'),
            onPressed: () => context.go(ClientPaths.signIn),
            child: const Text('Back to sign in'),
          ),
        ),
      ),
    ]);
  }
}

// ---------------------------------------------------------------------------
// The recovery link: set a new password, nothing else
// ---------------------------------------------------------------------------

class RecoveryLinkScreen extends ConsumerStatefulWidget {
  const RecoveryLinkScreen({super.key, required this.link});

  /// The allowlisted link (null: the address was not a usable link).
  final AuthLink? link;

  @override
  ConsumerState<RecoveryLinkScreen> createState() => _RecoveryLinkScreenState();
}

class _RecoveryLinkScreenState extends ConsumerState<RecoveryLinkScreen> {
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  bool _show = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    Future.microtask(() {
      if (mounted) ref.read(recoveryLinkProvider.notifier).open(widget.link);
    });
  }

  @override
  void dispose() {
    _password.dispose();
    _confirm.dispose();
    super.dispose();
  }

  void _submit() {
    final p = _password.text;
    setState(() {
      _error = p.isEmpty
          ? 'Choose a new password.'
          : p != _confirm.text
          ? 'The two passwords are not the same.'
          : null;
    });
    if (_error != null) return;
    TextInput.finishAutofillContext();
    ref.read(recoveryLinkProvider.notifier).setPassword(p);
  }

  @override
  Widget build(BuildContext context) {
    final c = ChurchColors.of(context);
    final s = ref.watch(recoveryLinkProvider);
    ref.listen(recoveryLinkProvider, (prev, next) {
      if (next.phase == RecoveryPhase.done &&
          prev?.phase != RecoveryPhase.done) {
        _password.clear();
        _confirm.clear();
        announce(context, 'Password changed. Sign in again.');
      }
    });
    final children = <Widget>[];
    switch (s.phase) {
      case RecoveryPhase.opening:
        children.add(
          const RequestStateBanner(
            key: Key('recovery-opening'),
            tone: StatusTone.info,
            busy: true,
            title: 'Checking your link…',
            message: 'Waiting for the server.',
          ),
        );
      case RecoveryPhase.unusable:
        children.addAll([
          RequestStateBanner(
            key: const Key('recovery-link-unusable'),
            tone: StatusTone.danger,
            icon: Icons.link_off_outlined,
            title: 'This link can\'t be used',
            message:
                'It may have expired, been used already, or been opened on '
                'another device than the one that asked for it. Ask for a new '
                'link, or get help from the church office.',
            actions: [
              BannerAction(
                'Ask for a new link',
                () => context.go(ClientPaths.forgotPassword),
                key: const Key('recovery-ask-again'),
                primary: true,
              ),
            ],
          ),
          _gap,
          _churchHelp,
        ]);
      case RecoveryPhase.unreachable:
        children.add(
          const RequestStateBanner(
            key: Key('recovery-unreachable'),
            tone: StatusTone.warning,
            icon: Icons.cloud_off_outlined,
            title: 'No connection',
            message:
                'We couldn\'t reach the church server. Check your connection, '
                'then open the link from your email again.',
          ),
        );
      case RecoveryPhase.done:
        children.add(
          RequestStateBanner(
            key: const Key('password-set'),
            tone: StatusTone.success,
            icon: Icons.check_circle_outline,
            title: 'Password changed',
            message:
                'Sign in with your phone number and your new password. Every '
                'earlier sign-in has ended. If the church has paused your '
                'access, it stays paused until staff resolve it.',
            actions: [
              BannerAction(
                'Sign in',
                () => context.go(ClientPaths.signIn),
                key: const Key('recovery-go-sign-in'),
                primary: true,
              ),
            ],
          ),
        );
      case RecoveryPhase.ready:
      case RecoveryPhase.saving:
        final saving = s.phase == RecoveryPhase.saving;
        children.addAll([
          Text(
            'This link lets you set a new password and nothing else. Choose '
            'one only you know; church staff will never ask for it.',
            style: ChurchType.secondary.copyWith(color: c.muted),
          ),
          _gap,
          if (s.failure == SetPasswordFailure.weakPassword) ...[
            RequestStateBanner(
              key: const Key('recovery-weak-password'),
              tone: StatusTone.danger,
              icon: Icons.error_outline,
              title: 'Choose a stronger password',
              message: [
                'The password does not meet the requirements.',
                if (s.serverReasons.isNotEmpty)
                  'Reason: ${s.serverReasons.join(', ').replaceAll('_', ' ')}.',
              ].join(' '),
            ),
            _gap,
          ],
          if (s.failure == SetPasswordFailure.unreachable ||
              s.failure == SetPasswordFailure.unavailable) ...[
            const RequestStateBanner(
              key: Key('recovery-save-failed'),
              tone: StatusTone.warning,
              icon: Icons.cloud_off_outlined,
              title: 'The password was not changed',
              message: 'Try again in a moment.',
            ),
            _gap,
          ],
          if (saving) ...[
            const RequestStateBanner(
              key: Key('recovery-saving'),
              tone: StatusTone.info,
              busy: true,
              title: 'Setting your password…',
              message: 'Waiting for the server.',
            ),
            _gap,
          ],
          AutofillGroup(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                RevealOnFocus(
                  child: TextField(
                    key: const Key('new-password-field'),
                    controller: _password,
                    readOnly: saving,
                    obscureText: !_show,
                    autocorrect: false,
                    enableSuggestions: false,
                    autofillHints: const [AutofillHints.newPassword],
                    decoration: InputDecoration(
                      labelText: 'New password',
                      errorText: _error,
                      suffixIcon: FocusRing(
                        child: IconButton(
                          key: const Key('toggle-new-password'),
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
                const SizedBox(height: 12),
                RevealOnFocus(
                  child: TextField(
                    key: const Key('confirm-password-field'),
                    controller: _confirm,
                    readOnly: saving,
                    obscureText: !_show,
                    autocorrect: false,
                    enableSuggestions: false,
                    autofillHints: const [AutofillHints.newPassword],
                    onSubmitted: (_) => saving ? null : _submit(),
                    decoration: const InputDecoration(
                      labelText: 'New password again',
                    ),
                  ),
                ),
              ],
            ),
          ),
          _gap,
          FocusRing(
            child: FilledButton(
              key: const Key('set-password'),
              onPressed: saving ? null : _submit,
              child: const Text('Set new password'),
            ),
          ),
        ]);
    }
    return _page(context, 'Set a new password', children);
  }
}

// ---------------------------------------------------------------------------
// The email-confirmed landing
// ---------------------------------------------------------------------------

/// Where the confirmation link of a new recovery email returns. The
/// confirmation already happened at the server; the code in the link is
/// never used, so this page cannot sign anyone in.
class EmailConfirmedScreen extends StatelessWidget {
  const EmailConfirmedScreen({super.key, required this.link});

  final AuthLink? link;

  @override
  Widget build(BuildContext context) {
    // Only a link carrying a code (and no error) reached the server's
    // confirmation; anything else is shown as failed.
    final failed =
        link == null || link!.errorCode != null || link!.code == null;
    return _page(context, 'Recovery email', [
      if (failed)
        const RequestStateBanner(
          key: Key('email-confirm-failed'),
          tone: StatusTone.danger,
          icon: Icons.link_off_outlined,
          title: 'This confirmation link can\'t be used',
          message:
              'It may have expired or been used already. Open Recovery email '
              'from your account to send a new one.',
        )
      else
        const RequestStateBanner(
          key: Key('email-confirmed'),
          tone: StatusTone.success,
          icon: Icons.mark_email_read_outlined,
          title: 'Email confirmed',
          message:
              'The church will check it and approve it as your recovery '
              'email. Until then your member access waits for that check; '
              'afterwards, sign in again.',
        ),
      _gap,
      Align(
        alignment: Alignment.centerLeft,
        child: FocusRing(
          child: OutlinedButton(
            key: const Key('email-confirmed-account'),
            onPressed: () => context.go(ClientPaths.account),
            child: const Text('My account'),
          ),
        ),
      ),
    ]);
  }
}

// ---------------------------------------------------------------------------
// The member's own recovery email (mobile)
// ---------------------------------------------------------------------------

class RecoveryEmailScreen extends ConsumerStatefulWidget {
  const RecoveryEmailScreen({super.key});

  @override
  ConsumerState<RecoveryEmailScreen> createState() =>
      _RecoveryEmailScreenState();
}

class _RecoveryEmailScreenState extends ConsumerState<RecoveryEmailScreen> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  String? _emailError;
  String? _passwordError;
  bool _show = false;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  void _submit() {
    setState(() {
      _emailError = looksLikeEmail(_email.text)
          ? null
          : 'Enter an email address, like name@example.com.';
      _passwordError = _password.text.isEmpty
          ? 'Enter your current password.'
          : null;
    });
    if (_emailError != null || _passwordError != null) return;
    final password = _password.text;
    _password.clear();
    ref
        .read(myRecoveryEmailProvider.notifier)
        .addEmail(_email.text.trim(), password);
  }

  @override
  Widget build(BuildContext context) {
    final c = ChurchColors.of(context);
    final signedIn = ref.watch(accountProvider.select((a) => a.accountId));
    final s = ref.watch(myRecoveryEmailProvider);
    final children = <Widget>[];
    if (signedIn == null) {
      children.addAll([
        const Text('Sign in to manage your recovery email.'),
        _gap,
        Align(
          alignment: Alignment.centerLeft,
          child: FocusRing(
            child: FilledButton(
              key: const Key('recovery-email-sign-in'),
              onPressed: () => context.go(ClientPaths.signIn),
              child: const Text('Sign in'),
            ),
          ),
        ),
      ]);
      return _page(context, 'Recovery email', children);
    }
    final notice = s.notice;
    if (notice != null) {
      children.addAll([_noticeBanner(notice), _gap]);
    }
    final result = s.result;
    if (s.loading && result == null) {
      children.add(
        const RequestStateBanner(
          key: Key('recovery-email-loading'),
          tone: StatusTone.info,
          busy: true,
          title: 'Loading…',
          message: 'The server checks your access every time.',
        ),
      );
    } else if (result is AccessReadDenied<MyRecoveryEmail>) {
      children.add(
        RequestStateBanner(
          key: Key('recovery-email-denied-${result.denial.name}'),
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
              'A recovery email can be added once the church has linked this '
              'account to your member record.',
        ),
      );
    } else if (result is AccessReadFailed<MyRecoveryEmail>) {
      children.add(
        RequestStateBanner(
          key: const Key('recovery-email-failed'),
          tone: StatusTone.danger,
          icon: Icons.cloud_off_outlined,
          title: result.unreachable ? 'No connection' : 'Couldn\'t load',
          message: 'Nothing is shown until the server answers.',
          actions: [
            BannerAction(
              'Try again',
              () => ref.read(myRecoveryEmailProvider.notifier).reload(),
              key: const Key('recovery-email-retry'),
            ),
          ],
        ),
      );
    } else if (result is AccessReadOk<MyRecoveryEmail>) {
      final mine = result.value;
      children.addAll(_stateViews(context, mine));
      if (mine.canPropose) {
        children.addAll([
          _gap,
          Text(
            'Optional. It is used only to reset your password, and only '
            'after the church approves it. Confirm your current password '
            'first.',
            style: ChurchType.secondary.copyWith(color: c.muted),
          ),
          const SizedBox(height: 12),
          RevealOnFocus(
            child: TextField(
              key: const Key('new-recovery-email-field'),
              controller: _email,
              readOnly: s.busy,
              keyboardType: TextInputType.emailAddress,
              autofillHints: const [AutofillHints.email],
              autocorrect: false,
              enableSuggestions: false,
              decoration: InputDecoration(
                labelText: 'Recovery email',
                errorText: _emailError,
              ),
            ),
          ),
          const SizedBox(height: 12),
          RevealOnFocus(
            child: TextField(
              key: const Key('current-password-field'),
              controller: _password,
              readOnly: s.busy,
              obscureText: !_show,
              autocorrect: false,
              enableSuggestions: false,
              autofillHints: const [AutofillHints.password],
              onSubmitted: (_) => s.busy ? null : _submit(),
              decoration: InputDecoration(
                labelText: 'Current password',
                errorText: _passwordError,
                suffixIcon: FocusRing(
                  child: IconButton(
                    key: const Key('toggle-current-password'),
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
                key: const Key('add-recovery-email'),
                onPressed: s.busy ? null : _submit,
                child: const Text('Add recovery email'),
              ),
            ),
          ),
        ]);
      }
    }
    return _page(context, 'Recovery email', children);
  }

  List<Widget> _stateViews(BuildContext context, MyRecoveryEmail mine) {
    final approved = mine.approvedEmail;
    final p = mine.proposal;
    if (approved != null) {
      return [
        RequestStateBanner(
          key: const Key('recovery-email-approved'),
          tone: StatusTone.success,
          icon: Icons.verified_outlined,
          title: 'Recovery email approved',
          message:
              '$approved can receive password reset links. To change or '
              'remove it, contact the church office.',
        ),
      ];
    }
    if (p != null && p.state == ProposalState.pending) {
      final busy = ref.watch(myRecoveryEmailProvider.select((s) => s.busy));
      return [
        p.verified != false
            ? RequestStateBanner(
                key: const Key('recovery-email-awaiting-approval'),
                tone: StatusTone.info,
                icon: Icons.hourglass_top_outlined,
                title: 'Waiting for church approval',
                message:
                    '${p.email ?? 'Your recovery email'} is confirmed or '
                    'waiting. Your member access waits until the church '
                    'approves it; then sign in again.',
              )
            : RequestStateBanner(
                key: const Key('recovery-email-check-inbox'),
                tone: StatusTone.info,
                icon: Icons.mark_email_unread_outlined,
                title: 'Confirm your email',
                message:
                    'Open the link we sent to ${p.email ?? 'your address'} on this device. Not '
                    'there? Add it again below to send a new link.',
              ),
        const SizedBox(height: 12),
        Align(
          alignment: Alignment.centerLeft,
          child: FocusRing(
            child: OutlinedButton(
              key: const Key('withdraw-recovery-email'),
              onPressed: busy
                  ? null
                  : () =>
                        ref.read(myRecoveryEmailProvider.notifier).withdraw(p),
              child: const Text('Withdraw this email'),
            ),
          ),
        ),
      ];
    }
    if (p != null && p.state == ProposalState.rejected) {
      return [
        RequestStateBanner(
          key: const Key('recovery-email-rejected'),
          tone: StatusTone.warning,
          icon: Icons.info_outline,
          title: 'Not approved',
          message: [
            '${p.email ?? 'The address'} was not approved as your recovery email.',
            if (p.decisionReason != null) '${p.decisionReason!.label}.',
            'Contact the church office.',
          ].join(' '),
        ),
      ];
    }
    return [
      const RequestStateBanner(
        key: Key('recovery-email-none'),
        tone: StatusTone.neutral,
        icon: Icons.alternate_email_outlined,
        title: 'No recovery email',
        message:
            'Without one, the church office helps you in person if you forget '
            'your password.',
      ),
    ];
  }

  Widget _noticeBanner(RecoveryEmailNotice notice) {
    final (tone, title, message) = switch (notice) {
      RecoveryEmailNotice.checkInbox => (
        StatusTone.success,
        'Check your inbox',
        'Open the confirmation link on this device. After that, the church '
            'checks and approves the address.',
      ),
      RecoveryEmailNotice.withdrawn => (
        StatusTone.success,
        'Email withdrawn',
        'Your account is back on its approved sign-in details. If you are '
            'asked, sign in again.',
      ),
      RecoveryEmailNotice.wrongPassword => (
        StatusTone.danger,
        'Password not right',
        'Enter your current password to add a recovery email.',
      ),
      RecoveryEmailNotice.reauthenticate => (
        StatusTone.warning,
        'Confirm your password again',
        'Your last sign-in is too old. Enter your current password again.',
      ),
      RecoveryEmailNotice.addressUnavailable => (
        StatusTone.danger,
        'This address can\'t be used',
        'Use another email address, or ask the church office.',
      ),
      RecoveryEmailNotice.invalidAddress => (
        StatusTone.danger,
        'Check the address',
        'Enter an email address, like name@example.com.',
      ),
      RecoveryEmailNotice.rateLimited => (
        StatusTone.warning,
        'Too many attempts',
        'Please wait a while before trying again.',
      ),
      RecoveryEmailNotice.confirmationNotSent => (
        StatusTone.warning,
        'The confirmation was not sent',
        'Your request is recorded. Add it again to send a new link.',
      ),
      RecoveryEmailNotice.notNow => (
        StatusTone.warning,
        'Not possible right now',
        'A recovery email can\'t be added to this account now. Contact the '
            'church office.',
      ),
      RecoveryEmailNotice.signInAgain => (
        StatusTone.warning,
        'Please sign in again',
        'This sign-in is no longer valid.',
      ),
      RecoveryEmailNotice.unconfirmed => (
        StatusTone.warning,
        'Not confirmed yet',
        'We couldn\'t confirm whether the request arrived. Check again; it '
            'is sent once.',
      ),
      RecoveryEmailNotice.unreachable => (
        StatusTone.warning,
        'No connection',
        'We couldn\'t reach the church server. Try again.',
      ),
      RecoveryEmailNotice.notSent => (
        StatusTone.neutral,
        'Not sent',
        'This build has no server configured.',
      ),
    };
    return RequestStateBanner(
      key: Key('recovery-email-notice-${notice.name}'),
      tone: tone,
      title: title,
      message: message,
      actions: [
        if (notice == RecoveryEmailNotice.unconfirmed)
          BannerAction(
            'Check again',
            () => ref.read(myRecoveryEmailProvider.notifier).checkAgain(),
            key: const Key('recovery-email-check-again'),
            primary: true,
          ),
        BannerAction(
          'Dismiss',
          () => ref.read(myRecoveryEmailProvider.notifier).dismissNotice(),
          key: const Key('recovery-email-dismiss'),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Admin: recovery email approvals (staff web)
// ---------------------------------------------------------------------------

class RecoveryEmailReviewScreen extends ConsumerStatefulWidget {
  const RecoveryEmailReviewScreen({super.key});

  @override
  ConsumerState<RecoveryEmailReviewScreen> createState() =>
      _RecoveryEmailReviewScreenState();
}

class _RecoveryEmailReviewScreenState
    extends ConsumerState<RecoveryEmailReviewScreen> {
  final _checks = <String, IdentityCheck>{};
  final _reasons = <String, RecoveryEmailRejectReason>{};

  @override
  Widget build(BuildContext context) {
    final c = ChurchColors.of(context);
    final s = ref.watch(recoveryEmailReviewProvider);
    final children = <Widget>[
      Text(
        'Approve a recovery email only after checking who the member is. '
        'Approval makes the address their password reset route; their '
        'current sign-ins end.',
        style: ChurchType.secondary.copyWith(color: c.muted),
      ),
      _gap,
    ];
    final notice = s.notice;
    if (notice != null) children.addAll([_noticeBanner(notice, s), _gap]);
    final r = s.result;
    if (s.loading && r == null) {
      children.add(
        const RequestStateBanner(
          key: Key('recovery-review-loading'),
          tone: StatusTone.info,
          busy: true,
          title: 'Loading…',
          message: 'Waiting for the server.',
        ),
      );
    } else if (r is AccessReadDenied<RecoveryEmailQueue>) {
      children.add(
        RequestStateBanner(
          key: Key('recovery-review-denied-${r.denial.name}'),
          tone: StatusTone.warning,
          icon: Icons.lock_outline,
          title: 'Not available',
          message: r.denial == AccessDenial.notGranted
              ? 'Only an Admin can approve recovery emails.'
              : 'Sign in again, or contact the church office.',
        ),
      );
    } else if (r is AccessReadFailed<RecoveryEmailQueue>) {
      children.add(
        RequestStateBanner(
          key: const Key('recovery-review-failed'),
          tone: StatusTone.danger,
          icon: Icons.cloud_off_outlined,
          title: r.unreachable ? 'No connection' : 'Couldn\'t load',
          message: 'Nothing is shown until the server answers.',
          actions: [
            BannerAction(
              'Try again',
              () => ref.read(recoveryEmailReviewProvider.notifier).reload(),
              key: const Key('recovery-review-retry'),
            ),
          ],
        ),
      );
    } else if (s.items.isEmpty) {
      children.add(
        const RequestStateBanner(
          key: Key('recovery-review-empty'),
          tone: StatusTone.neutral,
          title: 'Nothing to review',
          message: 'No recovery email is waiting for approval.',
        ),
      );
    } else {
      for (final item in s.items) {
        children.addAll([_item(context, item, s.busy), _gap]);
      }
    }
    return _page(context, 'Recovery emails', children);
  }

  Widget _item(BuildContext context, RecoveryEmailReviewItem item, bool busy) {
    final c = ChurchColors.of(context);
    final id = item.proposal.proposalId;
    final check = _checks[id];
    final canApprove =
        item.proposal.verified == true &&
        !item.otherChanges &&
        !item.ownAccount;
    // A Material card, so the radio tiles paint their ink on the card.
    return Material(
      key: Key('recovery-review-$id'),
      color: c.surface,
      shape: RoundedRectangleBorder(
        side: BorderSide(color: c.line),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Padding(
        padding: const EdgeInsets.all(ChurchGeometry.cardPadding),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Semantics(
              header: true,
              child: Text(
                item.displayName,
                style: ChurchType.cardTitle.copyWith(color: c.ink),
              ),
            ),
            const SizedBox(height: 4),
            Text('Sign-in username: ${item.phoneUsername}'),
            Text('Proposed recovery email: ${item.proposal.email ?? ''}'),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                StatusLabel(
                  label: item.proposal.verified == true
                      ? 'Confirmed by the member'
                      : 'Not confirmed yet',
                  tone: item.proposal.verified == true
                      ? StatusTone.success
                      : StatusTone.warning,
                ),
                if (item.otherChanges)
                  const StatusLabel(
                    label: 'Other sign-in changes: credential review',
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
                key: Key('recovery-review-own-$id'),
                style: ChurchType.secondary.copyWith(color: c.muted),
              ),
            ],
            const SizedBox(height: 12),
            RadioGroup<IdentityCheck>(
              groupValue: check,
              onChanged: (v) {
                if (busy || !canApprove || v == null) return;
                setState(() => _checks[id] = v);
              },
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Identity check', style: ChurchType.cardTitle),
                  for (final k in IdentityCheck.values)
                    RadioListTile<IdentityCheck>(
                      key: Key('recovery-review-$id-check-${k.wire}'),
                      value: k,
                      enabled: !busy && canApprove,
                      contentPadding: EdgeInsets.zero,
                      title: Text(k.label),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 8),
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
                      key: Key('recovery-review-$id-reason-${k.wire}'),
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
                    key: Key('recovery-review-approve-$id'),
                    onPressed: busy || !canApprove || check == null
                        ? null
                        : () => ref
                              .read(recoveryEmailReviewProvider.notifier)
                              .approve(item, check),
                    child: const Text('Approve'),
                  ),
                ),
                FocusRing(
                  child: OutlinedButton(
                    key: Key('recovery-review-reject-$id'),
                    onPressed: busy || item.ownAccount
                        ? null
                        : () => ref
                              .read(recoveryEmailReviewProvider.notifier)
                              .reject(item, reason: _reasons[id]),
                    child: const Text('Don\'t approve'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _noticeBanner(RecoveryReviewNotice notice, RecoveryReviewState s) {
    final who = s.subject ?? 'the member';
    final (tone, title, message) = switch (notice) {
      RecoveryReviewNotice.approved => (
        StatusTone.success,
        'Approved',
        'The recovery email of $who is now part of their sign-in binding.',
      ),
      RecoveryReviewNotice.rejected => (
        StatusTone.info,
        'Not approved',
        '$who is told to contact the church office. Their account is back '
            'on its approved sign-in details.',
      ),
      RecoveryReviewNotice.unverified => (
        StatusTone.warning,
        'Not confirmed',
        'The account does not hold this address confirmed. Ask the member to '
            'open the confirmation link first.',
      ),
      RecoveryReviewNotice.otherChanges => (
        StatusTone.danger,
        'Credential review needed',
        'Other sign-in details of this account changed. Handle it as an '
            'access review, not as a recovery email approval.',
      ),
      RecoveryReviewNotice.changedElsewhere => (
        StatusTone.info,
        'Changed elsewhere',
        'The request changed since you loaded it. The list was reloaded.',
      ),
      RecoveryReviewNotice.selfAction => (
        StatusTone.warning,
        'Not for your own account',
        'Another Admin must decide your own recovery email.',
      ),
      RecoveryReviewNotice.noLongerAdmin => (
        StatusTone.danger,
        'Not allowed',
        'Your account no longer holds the Admin role.',
      ),
      RecoveryReviewNotice.signInAgain => (
        StatusTone.warning,
        'Please sign in again',
        'This sign-in is no longer valid.',
      ),
      RecoveryReviewNotice.notAccepting => (
        StatusTone.neutral,
        'Not available here',
        'Recovery emails can\'t be approved in this environment yet.',
      ),
      RecoveryReviewNotice.invalid => (
        StatusTone.danger,
        'Check the form',
        'Choose how you checked the member\'s identity.',
      ),
      RecoveryReviewNotice.notFound => (
        StatusTone.info,
        'Not found',
        'The request no longer exists.',
      ),
      RecoveryReviewNotice.refused => (
        StatusTone.danger,
        'Refused',
        'The server refused the request.',
      ),
      RecoveryReviewNotice.unconfirmed => (
        StatusTone.warning,
        'Not confirmed yet',
        'We couldn\'t confirm whether the decision arrived. Check again; it '
            'is sent once.',
      ),
      RecoveryReviewNotice.notSent => (
        StatusTone.neutral,
        'Not sent',
        'This build has no server configured.',
      ),
    };
    return RequestStateBanner(
      key: Key('recovery-review-notice-${notice.name}'),
      tone: tone,
      title: title,
      message: message,
      actions: [
        if (notice == RecoveryReviewNotice.unconfirmed)
          BannerAction(
            'Check again',
            () => ref.read(recoveryEmailReviewProvider.notifier).checkAgain(),
            key: const Key('recovery-review-check-again'),
            primary: true,
          ),
        BannerAction(
          'Dismiss',
          () => ref.read(recoveryEmailReviewProvider.notifier).dismissNotice(),
          key: const Key('recovery-review-dismiss'),
        ),
      ],
    );
  }
}

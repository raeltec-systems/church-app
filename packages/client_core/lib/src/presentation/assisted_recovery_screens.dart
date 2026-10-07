import 'package:church_design_system/church_design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../application/assisted_recovery_controllers.dart';
import '../domain/access_grants.dart';
import '../domain/assisted_recovery.dart';
import '../domain/membership_review.dart' show IdentityCheck, MemberRecord;
import '../domain/phone_username.dart';
import 'shell_routing.dart' show ClientPaths;

/// Story 2.9 screens: "I need help accessing my account" on the member's
/// phone, and the Admin's recovery cases on staff web. Staff never see,
/// choose or send a password, a setup secret or its digest.
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

/// `ABCD EFGH`: easier to read aloud.
String _spacedCode(String code) =>
    code.length == 8 ? '${code.substring(0, 4)} ${code.substring(4)}' : code;

String _clock(DateTime? at) {
  if (at == null) return '';
  final l = at.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(l.hour)}:${two(l.minute)}';
}

// ---------------------------------------------------------------------------
// Member device: I need help accessing my account
// ---------------------------------------------------------------------------

class AccountHelpScreen extends ConsumerStatefulWidget {
  const AccountHelpScreen({super.key});

  @override
  ConsumerState<AccountHelpScreen> createState() => _AccountHelpScreenState();
}

class _AccountHelpScreenState extends ConsumerState<AccountHelpScreen> {
  final _phone = TextEditingController();
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  String? _phoneError;
  String? _passwordError;
  bool _show = false;

  @override
  void initState() {
    super.initState();
    final known = ref.read(accountHelpProvider).phoneUsername;
    if (known != null) _phone.text = known;
  }

  @override
  void dispose() {
    _phone.dispose();
    _password.dispose();
    _confirm.dispose();
    super.dispose();
  }

  void _start() {
    final n = normalizePhoneUsername(_phone.text, defaultDialingCountry);
    if (n.value == null) {
      setState(
        () => _phoneError = n.problem == PhoneUsernameProblem.empty
            ? 'Enter the phone number you sign in with.'
            : 'Check the number, including the country code.',
      );
      return;
    }
    setState(() => _phoneError = null);
    ref.read(accountHelpProvider.notifier).start(n.value!);
  }

  void _setPassword() {
    final problem = setupPasswordProblem(_password.text, _confirm.text);
    if (problem != null) {
      setState(() => _passwordError = problem);
      return;
    }
    final pw = _password.text;
    // The password leaves this screen once; nothing keeps it.
    _password.clear();
    _confirm.clear();
    setState(() => _passwordError = null);
    ref.read(accountHelpProvider.notifier).setPassword(pw);
  }

  (StatusTone, String, String) _notice(AccountHelpNotice n) => switch (n) {
    AccountHelpNotice.rateLimited => (
      StatusTone.warning,
      'Too many requests',
      'Please wait an hour before asking again, or ask the church office.',
    ),
    AccountHelpNotice.refused => (
      StatusTone.warning,
      'Couldn\'t start',
      'Please try again.',
    ),
    AccountHelpNotice.unavailable => (
      StatusTone.warning,
      'Not available right now',
      'Help with signing in is not available right now. Please ask the '
          'church office.',
    ),
    AccountHelpNotice.unreachable => (
      StatusTone.warning,
      'No connection',
      'We couldn\'t reach the church server. Check your connection and try '
          'again.',
    ),
    AccountHelpNotice.notConfigured => (
      StatusTone.neutral,
      'Not available here',
      'This build has no server configured.',
    ),
    AccountHelpNotice.stillWaiting => (
      StatusTone.info,
      'Not ready yet',
      'The church office has not finished. Show them the code, then check '
          'again.',
    ),
    AccountHelpNotice.closed => (
      StatusTone.warning,
      'This request has ended',
      'It expired, was used or was replaced. Start again if you still need '
          'help.',
    ),
    AccountHelpNotice.rejected => (
      StatusTone.warning,
      'This setup can\'t be used',
      'It was used, replaced or expired, or the account changed. Ask the '
          'church office to start again.',
    ),
    AccountHelpNotice.passwordRejected => (
      StatusTone.warning,
      'Password not accepted',
      'The password was not accepted, and this setup is now used. Ask the '
          'church office for a new one and choose a longer password.',
    ),
    AccountHelpNotice.uncertain => (
      StatusTone.warning,
      'We couldn\'t confirm the change',
      'Your account stays protected until the church office checks it. Ask '
          'them to finish the check; you may need a new setup.',
    ),
    AccountHelpNotice.redeemUnreachable => (
      StatusTone.warning,
      'No answer from the server',
      'We don\'t know whether your password was changed. Try signing in with '
          'the new password; if that fails, ask the church office.',
    ),
    AccountHelpNotice.invalid => (
      StatusTone.warning,
      'Check the password',
      'Use 8 to 72 characters and try again.',
    ),
  };

  @override
  Widget build(BuildContext context) {
    final c = ChurchColors.of(context);
    final s = ref.watch(accountHelpProvider);
    ref.listen(accountHelpProvider, (prev, next) {
      if (next.phase == AccountHelpPhase.succeeded &&
          prev?.phase != AccountHelpPhase.succeeded) {
        announce(context, 'Password changed');
      }
    });
    final children = <Widget>[
      Text(
        'No recovery email, or can\'t reach it? The church office checks who '
        'you are in person, then you choose a new password here on this '
        'phone. Staff never see, choose or send your password, and no code '
        'is sent by SMS.',
        style: ChurchType.secondary.copyWith(color: c.muted),
      ),
      _gap,
    ];
    final notice = s.notice;
    if (notice != null) {
      final (tone, title, message) = _notice(notice);
      children.addAll([
        RequestStateBanner(
          key: Key('help-notice-${notice.name}'),
          tone: tone,
          title: title,
          message: message,
        ),
        _gap,
      ]);
    }
    switch (s.phase) {
      case AccountHelpPhase.start:
      case AccountHelpPhase.requesting:
        final pending = s.phase == AccountHelpPhase.requesting;
        children.addAll([
          RevealOnFocus(
            child: TextField(
              key: const Key('help-phone-field'),
              controller: _phone,
              readOnly: pending,
              keyboardType: TextInputType.phone,
              autofillHints: const [AutofillHints.telephoneNumber],
              onSubmitted: (_) => pending ? null : _start(),
              decoration: InputDecoration(
                labelText: 'Phone number (your username)',
                helperText: 'Include the country code, like +260 97 123 4567.',
                errorText: _phoneError,
              ),
            ),
          ),
          _gap,
          FocusRing(
            child: FilledButton(
              key: const Key('help-start'),
              onPressed: pending ? null : _start,
              child: Text(pending ? 'Starting…' : 'Ask the church for help'),
            ),
          ),
        ]);
      case AccountHelpPhase.waiting:
      case AccountHelpPhase.checking:
        final checking = s.phase == AccountHelpPhase.checking;
        children.addAll([
          Text(
            'Show this code to the church office',
            style: ChurchType.cardTitle,
          ),
          const SizedBox(height: 8),
          Semantics(
            label: 'Request code ${s.requestCode?.split('').join(' ')}',
            child: ExcludeSemantics(
              child: SelectableText(
                _spacedCode(s.requestCode ?? ''),
                key: const Key('help-request-code'),
                style: Theme.of(context).textTheme.headlineMedium,
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            [
              'Keep this screen open. The code only finds your request; it '
                  'does not open your account.',
              if (s.expiresAt != null) 'It expires at ${_clock(s.expiresAt)}.',
            ].join(' '),
            style: ChurchType.secondary.copyWith(color: c.muted),
          ),
          _gap,
          FocusRing(
            child: FilledButton(
              key: const Key('help-check'),
              onPressed: checking
                  ? null
                  : () => ref.read(accountHelpProvider.notifier).checkStatus(),
              child: Text(
                checking ? 'Checking…' : 'The office is done: continue',
              ),
            ),
          ),
          const SizedBox(height: 12),
          _startOver(),
        ]);
      case AccountHelpPhase.ready:
      case AccountHelpPhase.setting:
        final setting = s.phase == AccountHelpPhase.setting;
        children.addAll([
          Text('Choose a new password', style: ChurchType.cardTitle),
          const SizedBox(height: 8),
          Text(
            [
              'Only you see it. It works once you sign in again on every '
                  'device.',
              if (s.expiresAt != null) 'Finish before ${_clock(s.expiresAt)}.',
            ].join(' '),
            style: ChurchType.secondary.copyWith(color: c.muted),
          ),
          _gap,
          RevealOnFocus(
            child: TextField(
              key: const Key('help-password'),
              controller: _password,
              readOnly: setting,
              obscureText: !_show,
              autocorrect: false,
              enableSuggestions: false,
              autofillHints: const [AutofillHints.newPassword],
              decoration: const InputDecoration(labelText: 'New password'),
            ),
          ),
          const SizedBox(height: 12),
          RevealOnFocus(
            child: TextField(
              key: const Key('help-password-confirm'),
              controller: _confirm,
              readOnly: setting,
              obscureText: !_show,
              autocorrect: false,
              enableSuggestions: false,
              autofillHints: const [AutofillHints.newPassword],
              onSubmitted: (_) => setting ? null : _setPassword(),
              decoration: InputDecoration(
                labelText: 'Type it again',
                errorText: _passwordError,
              ),
            ),
          ),
          CheckboxListTile(
            key: const Key('help-show-password'),
            value: _show,
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            title: const Text('Show password'),
            onChanged: (v) => setState(() => _show = v ?? false),
          ),
          _gap,
          FocusRing(
            child: FilledButton(
              key: const Key('help-set-password'),
              onPressed: setting ? null : _setPassword,
              child: Text(setting ? 'Setting…' : 'Set password'),
            ),
          ),
          const SizedBox(height: 12),
          _startOver(),
        ]);
      case AccountHelpPhase.succeeded:
        children.addAll([
          const RequestStateBanner(
            key: Key('help-succeeded'),
            tone: StatusTone.success,
            icon: Icons.check_circle_outline,
            title: 'Password changed',
            message:
                'Sign in with your phone number and the new password. Every '
                'device that was signed in has to sign in again. A church '
                'check on your account, if any, stays until the office '
                'finishes it.',
          ),
          _gap,
          FocusRing(
            child: FilledButton(
              key: const Key('help-sign-in'),
              onPressed: () {
                ref.read(accountHelpProvider.notifier).startOver();
                context.go(ClientPaths.signIn);
              },
              child: const Text('Sign in'),
            ),
          ),
        ]);
      case AccountHelpPhase.ended:
        children.add(_startOver(primary: true));
    }
    children.addAll([
      _gap,
      Align(
        alignment: Alignment.centerLeft,
        child: FocusRing(
          child: TextButton(
            key: const Key('help-back-to-sign-in'),
            onPressed: () => context.go(ClientPaths.signIn),
            child: const Text('Back to sign in'),
          ),
        ),
      ),
    ]);
    return _page(context, 'I need help accessing my account', children);
  }

  Widget _startOver({bool primary = false}) => Align(
    alignment: Alignment.centerLeft,
    child: FocusRing(
      child: primary
          ? FilledButton(
              key: const Key('help-start-over'),
              onPressed: () =>
                  ref.read(accountHelpProvider.notifier).startOver(),
              child: const Text('Start again'),
            )
          : TextButton(
              key: const Key('help-start-over'),
              onPressed: () =>
                  ref.read(accountHelpProvider.notifier).startOver(),
              child: const Text('Start again'),
            ),
    ),
  );
}

// ---------------------------------------------------------------------------
// Staff web (Admin): recovery cases
// ---------------------------------------------------------------------------

class RecoveryCasesScreen extends ConsumerStatefulWidget {
  const RecoveryCasesScreen({super.key});

  @override
  ConsumerState<RecoveryCasesScreen> createState() =>
      _RecoveryCasesScreenState();
}

class _RecoveryCasesScreenState extends ConsumerState<RecoveryCasesScreen> {
  final _query = TextEditingController();
  final _codes = <String, TextEditingController>{};
  final _checks = <String, IdentityCheck>{};
  final _cancelReasons = <String, RecoveryCancelReason>{};
  MemberRecord? _picked;
  IdentityCheck? _openCheck;
  final _evidence = <RecoveryEvidence>{};

  @override
  void dispose() {
    _query.dispose();
    for (final c in _codes.values) {
      c.dispose();
    }
    super.dispose();
  }

  TextEditingController _code(String id) =>
      _codes.putIfAbsent(id, TextEditingController.new);

  RecoveryCasesController get _ctl => ref.read(recoveryCasesProvider.notifier);

  Widget _card(BuildContext context, Key key, List<Widget> children) {
    final c = ChurchColors.of(context);
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

  Widget _checkPicker(
    String keyPrefix,
    IdentityCheck? value,
    bool enabled,
    ValueChanged<IdentityCheck> onChanged,
  ) => RadioGroup<IdentityCheck>(
    groupValue: value,
    onChanged: (v) {
      if (!enabled || v == null) return;
      onChanged(v);
    },
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Identity check', style: ChurchType.cardTitle),
        for (final k in IdentityCheck.values)
          RadioListTile<IdentityCheck>(
            key: Key('$keyPrefix-check-${k.wire}'),
            value: k,
            enabled: enabled,
            contentPadding: EdgeInsets.zero,
            title: Text(k.label),
          ),
      ],
    ),
  );

  (StatusTone, String) _noticeText(RecoveryCasesNotice n) => switch (n) {
    RecoveryCasesNotice.opened => (
      StatusTone.success,
      'Case opened. Ask the member to start "I need help accessing my '
          'account" on their phone and read you the code.',
    ),
    RecoveryCasesNotice.issued => (
      StatusTone.success,
      'Setup issued for 15 minutes. The member now chooses a password on '
          'their phone.',
    ),
    RecoveryCasesNotice.cancelled => (StatusTone.success, 'Case cancelled.'),
    RecoveryCasesNotice.reconciled => (
      StatusTone.success,
      'Reconciled: every session was signed out and the account stays held. '
          'Issue a new setup; release the hold in Access reviews after the '
          'member\'s reset.',
    ),
    RecoveryCasesNotice.notRecoverable => (
      StatusTone.warning,
      'This account can\'t be recovered now (an access review, a dispute or '
          'a changed sign-in number). Resolve that in Access reviews first.',
    ),
    RecoveryCasesNotice.openCase => (
      StatusTone.warning,
      'This member already has an open case.',
    ),
    RecoveryCasesNotice.unknownCode => (
      StatusTone.warning,
      'No waiting request has this code. Check it, or ask the member to start '
          'again.',
    ),
    RecoveryCasesNotice.codeMismatch => (
      StatusTone.danger,
      'This code belongs to a request from another phone number. Nothing was '
          'issued.',
    ),
    RecoveryCasesNotice.unresolved => (
      StatusTone.warning,
      'An earlier reset is unresolved. Reconcile it first.',
    ),
    RecoveryCasesNotice.nothingToReconcile => (
      StatusTone.info,
      'Nothing needs reconciling.',
    ),
    RecoveryCasesNotice.closed => (StatusTone.info, 'This case is closed.'),
    RecoveryCasesNotice.notLinked => (
      StatusTone.warning,
      'This member has no app account to recover.',
    ),
    RecoveryCasesNotice.changedElsewhere => (
      StatusTone.warning,
      'Changed elsewhere. The list was reloaded.',
    ),
    RecoveryCasesNotice.selfAction => (
      StatusTone.warning,
      'Another Admin must handle your own account.',
    ),
    RecoveryCasesNotice.noLongerAdmin => (
      StatusTone.danger,
      'You are no longer an Admin.',
    ),
    RecoveryCasesNotice.signInAgain => (StatusTone.warning, 'Sign in again.'),
    RecoveryCasesNotice.notAccepting => (
      StatusTone.warning,
      'Assisted recovery is not available in this environment.',
    ),
    RecoveryCasesNotice.invalid => (StatusTone.warning, 'Check the form.'),
    RecoveryCasesNotice.notFound => (StatusTone.warning, 'Not found.'),
    RecoveryCasesNotice.refused => (StatusTone.danger, 'Refused.'),
    RecoveryCasesNotice.unconfirmed => (
      StatusTone.warning,
      'No answer from the server: the result is unknown. Check again sends '
          'the same request.',
    ),
    RecoveryCasesNotice.notSent => (
      StatusTone.neutral,
      'Not sent: this build has no server configured.',
    ),
  };

  @override
  Widget build(BuildContext context) {
    final c = ChurchColors.of(context);
    final s = ref.watch(recoveryCasesProvider);
    final children = <Widget>[
      Text(
        'For members without a usable recovery email. Check who the member is '
        'in person, record what you saw, then issue a one-time setup for the '
        'code on their phone. The member chooses the password on their own '
        'phone: staff never see, choose or send a password or setup secret.',
        style: ChurchType.secondary.copyWith(color: c.muted),
      ),
      _gap,
    ];
    final notice = s.notice;
    if (notice != null) {
      final (tone, text) = _noticeText(notice);
      children.addAll([
        RequestStateBanner(
          key: Key('recovery-notice-${notice.name}'),
          tone: tone,
          title: s.subject ?? 'Account recovery',
          message: text,
          actions: [
            if (notice == RecoveryCasesNotice.unconfirmed)
              BannerAction(
                'Check again',
                () => _ctl.checkAgain(),
                key: const Key('recovery-check-again'),
              ),
          ],
        ),
        _gap,
      ]);
    }
    final r = s.result;
    final cases = s.cases;
    if (s.loading && r == null) {
      children.add(
        const RequestStateBanner(
          key: Key('recovery-loading'),
          tone: StatusTone.info,
          busy: true,
          title: 'Loading…',
          message: 'Waiting for the server.',
        ),
      );
    } else if (r is AccessReadDenied<RecoveryCases>) {
      children.add(
        RequestStateBanner(
          key: Key('recovery-denied-${r.denial.name}'),
          tone: StatusTone.warning,
          icon: Icons.lock_outline,
          title: 'Not available',
          message: r.denial == AccessDenial.notGranted
              ? 'Only an Admin can help members recover access.'
              : 'Sign in again, or contact the church office.',
        ),
      );
    } else if (r is AccessReadFailed<RecoveryCases>) {
      children.add(
        RequestStateBanner(
          key: const Key('recovery-failed'),
          tone: StatusTone.danger,
          icon: Icons.cloud_off_outlined,
          title: r.unreachable ? 'No connection' : 'Couldn\'t load',
          message: 'Nothing is shown until the server answers.',
          actions: [
            BannerAction(
              'Try again',
              () => _ctl.reload(),
              key: const Key('recovery-retry'),
            ),
          ],
        ),
      );
    } else if (cases != null) {
      if (!cases.accepting) {
        children.addAll([
          const RequestStateBanner(
            key: Key('recovery-not-accepting'),
            tone: StatusTone.neutral,
            title: 'Not open in this environment',
            message:
                'Assisted recovery waits for the church\'s approval of the '
                'recovery procedure.',
          ),
          _gap,
        ]);
      }
      final open = cases.cases.where((x) => x.isOpen).toList();
      final closed = cases.cases.where((x) => !x.isOpen).toList();
      children.addAll([
        Semantics(
          header: true,
          child: Text('Open cases', style: ChurchType.cardTitle),
        ),
        const SizedBox(height: 8),
        if (open.isEmpty)
          const Text('No open case.', key: Key('recovery-no-open')),
        for (final item in open) ...[
          _caseCard(context, item, s.busy),
          const SizedBox(height: 12),
        ],
        _gap,
        ..._openCaseForm(context, s),
        if (closed.isNotEmpty) ...[
          _gap,
          Semantics(
            header: true,
            child: Text(
              'Closed in the last 7 days',
              style: ChurchType.cardTitle,
            ),
          ),
          const SizedBox(height: 8),
          for (final item in closed) ...[
            _caseCard(context, item, s.busy),
            const SizedBox(height: 12),
          ],
        ],
      ]);
    }
    return _page(context, 'Account recovery', children);
  }

  String _grantLabel(RecoveryCaseItem item) => switch (item.grantState) {
    null => 'No setup issued yet',
    'issued' =>
      'Setup issued, waiting for the member (until '
          '${_clock(item.grantExpiresAt)})',
    'expired' => 'Setup expired',
    'consumed' => 'Setup used',
    'superseded' => 'Setup replaced or no longer valid',
    'burned' => 'Setup refused: presented with another number',
    'cancelled' => 'Setup cancelled',
    final other => 'Setup: $other',
  };

  (String, StatusTone)? _operationLabel(RecoveryCaseItem item) =>
      switch (item.operationState) {
        null => null,
        'pending' ||
        'dispatched' => ('Password change in progress', StatusTone.info),
        'succeeded' => ('Password changed by the member', StatusTone.success),
        'failed' => (
          'Password not accepted: issue a new setup',
          StatusTone.warning,
        ),
        'obsolete' => (
          'Stopped before any change: issue a new setup',
          StatusTone.warning,
        ),
        'uncertain' || 'stuck' => (
          'Not confirmed: the account is held until you reconcile',
          StatusTone.danger,
        ),
        'reconciled' => ('Reconciled', StatusTone.neutral),
        final other => (other, StatusTone.neutral),
      };

  Widget _caseCard(BuildContext context, RecoveryCaseItem item, bool busy) {
    final id = item.caseId;
    final op = _operationLabel(item);
    final canIssue =
        item.isOpen &&
        !item.ownMember &&
        item.linkProblem == null &&
        !item.needsReconciliation &&
        !item.inFlight;
    return _card(context, Key('recovery-case-$id'), [
      Semantics(
        header: true,
        child: Text(item.displayName, style: ChurchType.cardTitle),
      ),
      const SizedBox(height: 4),
      Text(
        'Checked: ${item.identityCheck.label}. '
        '${item.evidence.map((e) => e.label).join('; ')}.',
      ),
      const SizedBox(height: 8),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          StatusLabel(
            label: switch (item.caseState) {
              'open' => 'Open',
              'completed' => 'Completed: password reset',
              _ => 'Cancelled',
            },
            tone: item.isOpen ? StatusTone.info : StatusTone.neutral,
          ),
          if (item.isOpen)
            StatusLabel(label: _grantLabel(item), tone: StatusTone.neutral),
          if (op != null) StatusLabel(label: op.$1, tone: op.$2),
          if (item.held)
            const StatusLabel(
              label: 'On hold: release in Access reviews',
              tone: StatusTone.warning,
            ),
          if (item.isOpen && item.linkProblem != null)
            const StatusLabel(
              label: 'Can\'t be recovered now: see Access reviews',
              tone: StatusTone.danger,
            ),
          if (item.isSynthetic)
            const StatusLabel(
              label: 'Synthetic test record',
              tone: StatusTone.neutral,
            ),
        ],
      ),
      if (item.ownMember) ...[
        const SizedBox(height: 8),
        Text(
          'This is your own account: another Admin must handle it.',
          key: Key('recovery-own-$id'),
        ),
      ],
      if (item.isOpen && item.needsReconciliation && !item.ownMember) ...[
        const SizedBox(height: 12),
        _checkPicker(
          'recovery-$id',
          _checks[id],
          !busy,
          (v) => setState(() => _checks[id] = v),
        ),
        FocusRing(
          child: FilledButton(
            key: Key('recovery-reconcile-$id'),
            onPressed: busy || _checks[id] == null
                ? null
                : () => _ctl.reconcile(item, _checks[id]!),
            child: const Text('Reconcile: sign out every device'),
          ),
        ),
      ],
      if (canIssue) ...[
        const SizedBox(height: 12),
        RevealOnFocus(
          child: TextField(
            key: Key('recovery-code-$id'),
            controller: _code(id),
            readOnly: busy,
            autocorrect: false,
            enableSuggestions: false,
            textCapitalization: TextCapitalization.characters,
            decoration: const InputDecoration(
              labelText: 'Request code on the member\'s phone',
              helperText: '8 letters and digits, like ABCD 2345',
            ),
          ),
        ),
        const SizedBox(height: 8),
        FocusRing(
          child: FilledButton(
            key: Key('recovery-issue-$id'),
            onPressed: busy
                ? null
                : () {
                    final code = _code(id).text;
                    if (!looksLikeRequestCode(code)) return;
                    _code(id).clear();
                    _ctl.issueGrant(item, code);
                  },
            child: Text(
              item.grantState == null ? 'Issue setup' : 'Issue a new setup',
            ),
          ),
        ),
      ],
      if (item.isOpen &&
          !item.ownMember &&
          !item.needsReconciliation &&
          !item.inFlight) ...[
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            DropdownButton<RecoveryCancelReason>(
              key: Key('recovery-cancel-reason-$id'),
              value: _cancelReasons[id] ?? RecoveryCancelReason.memberWithdrew,
              items: [
                for (final r in RecoveryCancelReason.values)
                  DropdownMenuItem(value: r, child: Text(r.label)),
              ],
              onChanged: busy
                  ? null
                  : (v) => setState(() => _cancelReasons[id] = v!),
            ),
            FocusRing(
              child: OutlinedButton(
                key: Key('recovery-cancel-$id'),
                onPressed: busy
                    ? null
                    : () => _ctl.cancel(
                        item,
                        _cancelReasons[id] ??
                            RecoveryCancelReason.memberWithdrew,
                      ),
                child: const Text('Cancel case'),
              ),
            ),
          ],
        ),
      ],
    ]);
  }

  List<Widget> _openCaseForm(BuildContext context, RecoveryCasesState s) {
    final picked = _picked;
    final search = s.search;
    final canOpen =
        picked != null && _openCheck != null && _evidence.isNotEmpty && !s.busy;
    return [
      Semantics(
        header: true,
        child: Text('Open a recovery case', style: ChurchType.cardTitle),
      ),
      const SizedBox(height: 8),
      Row(
        children: [
          Expanded(
            child: RevealOnFocus(
              child: TextField(
                key: const Key('recovery-search-field'),
                controller: _query,
                onSubmitted: (_) => _ctl.searchMembers(_query.text),
                decoration: const InputDecoration(
                  labelText: 'Find a member by name or contact number',
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          FocusRing(
            child: OutlinedButton(
              key: const Key('recovery-search'),
              onPressed: s.searching
                  ? null
                  : () => _ctl.searchMembers(_query.text),
              child: const Text('Search'),
            ),
          ),
        ],
      ),
      const SizedBox(height: 8),
      if (search is AccessReadOk<List<MemberRecord>>) ...[
        if (search.value.isEmpty)
          const Text('No member found.', key: Key('recovery-search-empty')),
        RadioGroup<String>(
          groupValue: picked?.memberId,
          onChanged: (v) => setState(
            () => _picked = search.value.firstWhere((m) => m.memberId == v),
          ),
          child: Column(
            children: [
              for (final m in search.value)
                RadioListTile<String>(
                  key: Key('recovery-pick-${m.memberId}'),
                  value: m.memberId,
                  contentPadding: EdgeInsets.zero,
                  title: Text(m.displayName),
                ),
            ],
          ),
        ),
      ],
      if (picked != null) ...[
        const SizedBox(height: 8),
        _checkPicker(
          'recovery-open',
          _openCheck,
          !s.busy,
          (v) => setState(() => _openCheck = v),
        ),
        Text('What you saw', style: ChurchType.cardTitle),
        for (final e in RecoveryEvidence.values)
          CheckboxListTile(
            key: Key('recovery-evidence-${e.wire}'),
            value: _evidence.contains(e),
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            title: Text(e.label),
            onChanged: s.busy
                ? null
                : (v) => setState(
                    () => v == true ? _evidence.add(e) : _evidence.remove(e),
                  ),
          ),
        const SizedBox(height: 8),
        FocusRing(
          child: FilledButton(
            key: const Key('recovery-open'),
            onPressed: canOpen
                ? () {
                    _ctl.openCase(picked, _openCheck!, {..._evidence});
                    setState(() {
                      _picked = null;
                      _openCheck = null;
                      _evidence.clear();
                    });
                  }
                : null,
            child: Text('Open a case for ${picked.displayName}'),
          ),
        ),
      ],
    ];
  }
}

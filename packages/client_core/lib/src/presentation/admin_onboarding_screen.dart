import 'package:church_design_system/church_design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../application/admin_onboarding_controllers.dart';
import '../application/providers.dart';
import '../domain/admin_onboarding.dart';
import '../domain/phone_username.dart';

/// Invitation-only installation journey. Presence of this page never implies
/// setup is open; every state comes from the commissioning service.
class AdminOnboardingScreen extends ConsumerStatefulWidget {
  const AdminOnboardingScreen({super.key});
  @override
  ConsumerState<AdminOnboardingScreen> createState() =>
      _AdminOnboardingScreenState();
}

class _AdminOnboardingScreenState extends ConsumerState<AdminOnboardingScreen> {
  final _invitation = TextEditingController();
  final _phone = TextEditingController();
  final _name = TextEditingController();
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  bool _showPassword = false;
  bool _accepted = false;
  String? _localError;

  @override
  void dispose() {
    for (final c in [_invitation, _phone, _name, _password, _confirm]) {
      c.clear();
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _inspect() async {
    final phone = normalizePhoneUsername(_phone.text, defaultDialingCountry);
    if (phone.value == null) {
      setState(
        () => _localError = 'Enter a phone number with its country code.',
      );
      return;
    }
    setState(() {
      _localError = null;
      _accepted = false;
    });
    await ref
        .read(adminOnboardingProvider.notifier)
        .inspect(_invitation.text, phone.value!);
    if (!mounted) return;
    if (ref.read(adminOnboardingProvider).phase == AdminSetupPhase.details) {
      _invitation.clear();
    }
  }

  Future<void> _submit(AdminSetupState state) async {
    if (state.invitationDetails?.mode == AdminEnrollmentMode.newAccount &&
        _password.text != _confirm.text) {
      setState(() => _localError = 'The two passwords do not match.');
      return;
    }
    setState(() => _localError = null);
    final password = _password.text;
    // Do not keep a second plaintext copy in the form after submission.
    _password.clear();
    _confirm.clear();
    await ref
        .read(adminOnboardingProvider.notifier)
        .complete(
          fullName: _name.text,
          password: password,
          privacyAccepted: _accepted,
        );
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(accountGenerationProvider, (previous, next) {
      if (previous == next) return;
      for (final controller in [
        _invitation,
        _phone,
        _name,
        _password,
        _confirm,
      ]) {
        controller.clear();
      }
      setState(() {
        _accepted = false;
        _showPassword = false;
        _localError = null;
      });
    });
    final state = ref.watch(adminOnboardingProvider);
    final ctl = ref.read(adminOnboardingProvider.notifier);
    final layout = ChurchLayout.of(context);
    final c = ChurchColors.of(context);
    final details = state.invitationDetails;
    final isNew = details?.mode == AdminEnrollmentMode.newAccount;
    final error = _localError ?? state.validationMessage;
    final children = <Widget>[
      Text(
        'Use the private setup invitation issued by the church owner. '
        'This is not a public Admin registration form.',
        style: layout.body.copyWith(color: c.muted),
      ),
      const SizedBox(height: ChurchGeometry.sectionGap),
      if (error != null) ...[
        RequestStateBanner(
          tone: StatusTone.warning,
          key: const Key('admin-setup-validation'),
          title: 'Check your details',
          message: error,
        ),
        const SizedBox(height: 16),
      ],
      if (state.outcome case final outcome?) ...[
        _outcomeBanner(outcome),
        const SizedBox(height: 16),
      ],
    ];
    if (state.busy) {
      children.add(
        RequestStateBanner(
          key: const Key('admin-setup-busy'),
          tone: StatusTone.info,
          busy: true,
          title: state.phase == AdminSetupPhase.submitting
              ? 'Completing setup…'
              : 'Checking setup…',
          message:
              'Waiting for the server. No access is assumed until it confirms.',
        ),
      );
    } else if (state.phase == AdminSetupPhase.invitation) {
      children.addAll([
        TextField(
          key: const Key('admin-setup-invitation'),
          controller: _invitation,
          obscureText: true,
          autocorrect: false,
          enableSuggestions: false,
          decoration: const InputDecoration(
            labelText: 'Setup invitation',
            helperText: 'Paste it here, not into the address bar.',
          ),
        ),
        const SizedBox(height: 16),
        TextField(
          key: const Key('admin-setup-phone'),
          controller: _phone,
          keyboardType: TextInputType.phone,
          autofillHints: const [AutofillHints.telephoneNumber],
          decoration: const InputDecoration(
            labelText: 'Phone username',
            helperText: 'Include the country code. This does not verify phone ownership.',
          ),
        ),
        const SizedBox(height: 24),
        FocusRing(
          child: FilledButton(
            key: const Key('admin-setup-check'),
            onPressed: _inspect,
            child: const Text('Check invitation'),
          ),
        ),
      ]);
    } else if (state.phase == AdminSetupPhase.details && details != null) {
      children.addAll([
        Text(
          isNew
              ? 'Choose your own sign-in details'
              : 'Confirm your existing account',
          style: ChurchType.cardTitle.copyWith(color: c.ink),
        ),
        const SizedBox(height: 12),
        if (!isNew) ...[
          const Text(
            'Use your existing password. Setup will not reset it or claim another account.',
          ),
          const SizedBox(height: 16),
        ],
        TextField(
          key: const Key('admin-setup-name'),
          controller: _name,
          textCapitalization: TextCapitalization.words,
          maxLength: 120,
          autofillHints: const [AutofillHints.name],
          decoration: const InputDecoration(labelText: 'Full name'),
        ),
        const SizedBox(height: 16),
        TextField(
          key: const Key('admin-setup-password'),
          controller: _password,
          obscureText: !_showPassword,
          autocorrect: false,
          enableSuggestions: false,
          autofillHints: [
            isNew ? AutofillHints.newPassword : AutofillHints.password,
          ],
          decoration: InputDecoration(
            labelText: isNew ? 'New password' : 'Current password',
            helperText:
                'At least 8 characters. Only you should know this password.',
            suffixIcon: IconButton(
              key: const Key('admin-setup-password-toggle'),
              tooltip: _showPassword ? 'Hide password' : 'Show password',
              onPressed: () => setState(() => _showPassword = !_showPassword),
              icon: Icon(
                _showPassword
                    ? Icons.visibility_off_outlined
                    : Icons.visibility_outlined,
              ),
            ),
          ),
        ),
        if (isNew) ...[
          const SizedBox(height: 16),
          TextField(
            key: const Key('admin-setup-confirm'),
            controller: _confirm,
            obscureText: !_showPassword,
            autocorrect: false,
            enableSuggestions: false,
            autofillHints: const [AutofillHints.newPassword],
            decoration: const InputDecoration(labelText: 'Confirm password'),
          ),
        ],
        const SizedBox(height: 24),
        ChurchCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Privacy notice', style: ChurchType.cardTitle),
              const SizedBox(height: 8),
              SelectableText(details.privacyText!),
            ],
          ),
        ),
        CheckboxListTile(
          key: const Key('admin-setup-privacy'),
          contentPadding: EdgeInsets.zero,
          value: _accepted,
          onChanged: (v) => setState(() => _accepted = v ?? false),
          title: const Text(
            'I have read the privacy notice and agree to this setup.',
          ),
          controlAffinity: ListTileControlAffinity.leading,
        ),
        const SizedBox(height: 16),
        FocusRing(
          child: FilledButton(
            key: const Key('admin-setup-complete'),
            onPressed: _accepted ? () => _submit(state) : null,
            child: const Text('Complete Admin setup'),
          ),
        ),
        TextButton(
          onPressed: () {
            ctl.reset();
            _password.clear();
            _confirm.clear();
            setState(() {
              _accepted = false;
              _localError = null;
            });
          },
          child: const Text('Use another invitation'),
        ),
      ]);
    } else if (state.phase == AdminSetupPhase.resolving) {
      children.addAll([
        const Text(
          'Do not start another setup or change the password to retry. '
          'Check the original request. If it remains unresolved, contact the installation operator.',
        ),
        const SizedBox(height: 16),
        FocusRing(
          child: FilledButton(
            key: const Key('admin-setup-status'),
            onPressed: ctl.checkStatus,
            child: const Text('Check setup status'),
          ),
        ),
      ]);
    }
    children.addAll([
      const SizedBox(height: 24),
      TextButton(
        key: const Key('admin-setup-sign-in'),
        onPressed: state.busy ? null : () => context.go('/sign-in'),
        child: const Text('Go to sign in'),
      ),
    ]);
    return ChurchPageScaffold(
      title: 'First Admin setup',
      subtitle: 'Owner-authorised installation',
      body: SafeArea(
        child: SingleChildScrollView(
          padding: layout.pagePadding,
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
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

  Widget _outcomeBanner(AdminOnboardingOutcome outcome) {
    final (title, message, tone) = switch (outcome) {
      AdminOnboardingOutcome.completed => (
        'Setup complete',
        'Sign in with your phone username and password. '
            'Permissions will be checked again by the server.',
        StatusTone.success,
      ),
      AdminOnboardingOutcome.activationPending => (
        'Account prepared; activation pending',
        'Installation is recorded, but private access is still disabled. '
            'The owner must complete the separate activation checks.',
        StatusTone.info,
      ),
      AdminOnboardingOutcome.refused => (
        'Invitation cannot be used',
        'It may be expired, revoked, already used or not intended for this account. '
            'Ask the installation operator to check it.',
        StatusTone.warning,
      ),
      AdminOnboardingOutcome.rateLimited => (
        'Too many attempts',
        'Wait before checking again.',
        StatusTone.warning,
      ),
      AdminOnboardingOutcome.passwordRejected => (
        'Check your password',
        'The authentication service did not accept it. '
            'Enter a suitable password and try again.',
        StatusTone.warning,
      ),
      AdminOnboardingOutcome.pending || AdminOnboardingOutcome.uncertain => (
        'Setup is not yet confirmed',
        'The request may still be processing. '
            'Check its status before taking another action.',
        StatusTone.warning,
      ),
      _ => (
        'Setup unavailable',
        'The commissioning service could not confirm this request. '
            'Try again later or contact the installation operator.',
        StatusTone.warning,
      ),
    };
    return RequestStateBanner(
      key: Key('admin-setup-${outcome.name}'),
      tone: tone,
      title: title,
      message: message,
    );
  }
}

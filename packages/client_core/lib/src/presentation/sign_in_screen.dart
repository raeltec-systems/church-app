import 'package:church_design_system/church_design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../application/account_controllers.dart';
import '../domain/account_auth.dart';
import '../domain/phone_username.dart';
import 'shell_routing.dart' show ClientPaths;

/// Phone-number-and-password sign-in and account creation, shared by mobile
/// and staff web (design contract "Phone signup and sign-in"). No SMS: no
/// Send code, code entry or resend timer. Errors are generic.
class SignInScreen extends ConsumerStatefulWidget {
  const SignInScreen({
    super.key,
    this.createAccount = false,
    this.afterCreateAccount = ClientPaths.account,
  });

  /// Start in Create account mode.
  final bool createAccount;

  /// Where a new account continues (mobile: the membership request, story
  /// 2.4). A sign-in always continues to the account page.
  final String afterCreateAccount;

  @override
  ConsumerState<SignInScreen> createState() => _SignInScreenState();
}

enum _Mode { signIn, create }

class _SignInScreenState extends ConsumerState<SignInScreen> {
  late _Mode _mode = widget.createAccount ? _Mode.create : _Mode.signIn;
  DialingCountry _country = defaultDialingCountry;
  final _phone = TextEditingController();
  final _password = TextEditingController();
  bool _showPassword = false;
  String? _phoneError;
  String? _passwordError;
  bool _helpOpen = false;
  final _stateFocus = FocusNode(debugLabel: 'sign-in state');

  @override
  void dispose() {
    _phone.dispose();
    _password.dispose();
    _stateFocus.dispose();
    super.dispose();
  }

  void _submit() {
    final normalized = normalizePhoneUsername(_phone.text, _country);
    final password = _password.text;
    setState(() {
      _phoneError = switch (normalized.problem) {
        null => null,
        PhoneUsernameProblem.empty => 'Enter your phone number.',
        PhoneUsernameProblem.invalidCharacters =>
          'Use digits only, or start with + and the country code.',
        PhoneUsernameProblem.tooShort => 'This number is too short.',
        PhoneUsernameProblem.tooLong => 'This number is too long.',
        PhoneUsernameProblem.invalidCountryCode => 'Check the country code.',
      };
      _passwordError = password.isEmpty
          ? (_mode == _Mode.create
                ? 'Choose a password.'
                : 'Enter your password.')
          : null;
    });
    if (_phoneError != null || _passwordError != null) return;
    TextInput.finishAutofillContext();
    ref
        .read(signInControllerProvider.notifier)
        .submit(
          createAccount: _mode == _Mode.create,
          phoneE164: normalized.value!,
          password: password,
        );
  }

  /// Shows the exact international username before submit, so a number read
  /// with the wrong country code is visible.
  String _phonePreview() {
    final value = normalizePhoneUsername(_phone.text, _country).value;
    if (value == null) {
      return 'For example +${_country.dialCode} …, or a local number.';
    }
    final code = '+${_country.dialCode}';
    final shown = value.startsWith(code)
        ? '$code ${value.substring(code.length)}'
        : value;
    return "You'll sign in as $shown";
  }

  void _edited() {
    ref.read(signInControllerProvider.notifier).edited();
    if (_phoneError != null || _passwordError != null) {
      setState(() {
        _phoneError = null;
        _passwordError = null;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = ChurchColors.of(context);
    final layout = ChurchLayout.of(context);
    final s = ref.watch(signInControllerProvider);
    final pending = s.phase == SignInPhase.pending;
    ref.listen(signInControllerProvider, (prev, next) {
      if (next.phase == SignInPhase.succeeded &&
          prev?.phase != SignInPhase.succeeded) {
        // The password leaves memory as soon as it is no longer needed.
        _password.clear();
        ref.read(signInControllerProvider.notifier).reset();
        context.go(
          next.createdAccount ? widget.afterCreateAccount : ClientPaths.account,
        );
        return;
      }
      if (next.phase == SignInPhase.failed && next.failure != null) {
        final (title, message) = _failureText(next);
        announce(context, '$title. $message');
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _stateFocus.context != null) {
            _stateFocus.requestFocus();
          }
        });
      }
    });
    final create = _mode == _Mode.create;

    return Scaffold(
      appBar: AppBar(title: Text(create ? 'Create account' : 'Sign in')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: layout.pagePadding,
          child: Center(
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: ChurchGeometry.modalWidth),
              child: DefaultTextStyle.merge(
                style: layout.body.copyWith(color: c.ink),
                child: AutofillGroup(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      RadioSegments<_Mode>(
                        label: 'Sign in or create an account',
                        options: const [
                          SegmentOption(_Mode.signIn, 'Sign in'),
                          SegmentOption(_Mode.create, 'Create account'),
                        ],
                        selected: _mode,
                        onChanged: pending
                            ? null
                            : (m) {
                                _edited();
                                setState(() => _mode = m);
                              },
                      ),
                      const SizedBox(height: ChurchGeometry.sectionGap),
                      Text(
                        'Your phone number is your sign-in username. We never '
                        'send codes by SMS, and using a number here does not '
                        'verify that you own it.',
                        style: ChurchType.secondary.copyWith(color: c.muted),
                      ),
                      const SizedBox(height: ChurchGeometry.sectionGap),
                      if (s.phase == SignInPhase.failed &&
                          s.failure != null) ...[
                        Builder(
                          builder: (context) {
                            final (title, message) = _failureText(s);
                            return RequestStateBanner(
                              key: const Key('sign-in-failure'),
                              focusNode: _stateFocus,
                              tone:
                                  s.failure == AuthFailure.unreachable ||
                                      s.failure == AuthFailure.rateLimited
                                  ? StatusTone.warning
                                  : StatusTone.danger,
                              icon: Icons.error_outline,
                              title: title,
                              message: message,
                            );
                          },
                        ),
                        const SizedBox(height: ChurchGeometry.sectionGap),
                      ],
                      if (pending) ...[
                        RequestStateBanner(
                          key: const Key('sign-in-pending'),
                          focusNode: _stateFocus,
                          tone: StatusTone.info,
                          busy: true,
                          title: create
                              ? 'Creating your account…'
                              : 'Signing in…',
                          message: 'Waiting for the server.',
                        ),
                        const SizedBox(height: ChurchGeometry.sectionGap),
                      ],
                      DropdownButtonFormField<DialingCountry>(
                        key: const Key('country-field'),
                        initialValue: _country,
                        isExpanded: true,
                        decoration: const InputDecoration(
                          labelText: 'Country code',
                          helperText:
                              'Used when you type a local number. Numbers '
                              'starting with + work for any country.',
                          helperMaxLines: 3,
                        ),
                        items: [
                          for (final country in dialingCountries)
                            DropdownMenuItem(
                              value: country,
                              child: Text(country.label),
                            ),
                        ],
                        onChanged: pending
                            ? null
                            : (v) {
                                if (v == null) return;
                                _edited();
                                setState(() => _country = v);
                              },
                      ),
                      const SizedBox(height: 12),
                      RevealOnFocus(
                        child: TextField(
                          key: const Key('phone-field'),
                          controller: _phone,
                          readOnly: pending,
                          keyboardType: TextInputType.phone,
                          textInputAction: TextInputAction.next,
                          autofillHints: const [AutofillHints.telephoneNumber],
                          autocorrect: false,
                          enableSuggestions: false,
                          inputFormatters: [
                            FilteringTextInputFormatter.allow(
                              RegExp(r'[0-9+\-\s().]'),
                            ),
                          ],
                          onChanged: (_) {
                            _edited();
                            setState(() {}); // refresh the sign-in preview
                          },
                          decoration: InputDecoration(
                            labelText: 'Phone number (your username)',
                            helper: Text(
                              _phonePreview(),
                              key: const Key('phone-preview'),
                            ),
                            helperMaxLines: 3,
                            errorText: _phoneError,
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      RevealOnFocus(
                        child: TextField(
                          key: const Key('password-field'),
                          controller: _password,
                          readOnly: pending,
                          obscureText: !_showPassword,
                          autocorrect: false,
                          enableSuggestions: false,
                          keyboardType: TextInputType.visiblePassword,
                          textInputAction: TextInputAction.done,
                          autofillHints: [
                            create
                                ? AutofillHints.newPassword
                                : AutofillHints.password,
                          ],
                          onChanged: (_) => _edited(),
                          onSubmitted: (_) => pending ? null : _submit(),
                          decoration: InputDecoration(
                            labelText: 'Password',
                            helperText: create
                                ? 'Choose a password only you know. Church staff '
                                      'will never ask for it.'
                                : null,
                            helperMaxLines: 3,
                            errorText: _passwordError,
                            suffixIcon: FocusRing(
                              child: IconButton(
                                key: const Key('toggle-password'),
                                tooltip: _showPassword
                                    ? 'Hide password'
                                    : 'Show password',
                                icon: Icon(
                                  _showPassword
                                      ? Icons.visibility_off_outlined
                                      : Icons.visibility_outlined,
                                ),
                                onPressed: () => setState(
                                  () => _showPassword = !_showPassword,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: ChurchGeometry.sectionGap),
                      FocusRing(
                        child: FilledButton(
                          key: const Key('submit-button'),
                          onPressed: pending ? null : _submit,
                          child: Text(create ? 'Create account' : 'Sign in'),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 8,
                        children: [
                          FocusRing(
                            child: TextButton(
                              key: const Key('forgot-password'),
                              // Story 2.7: reset through the approved
                              // recovery email (neutral answer).
                              onPressed: pending
                                  ? null
                                  : () =>
                                        context.go(ClientPaths.forgotPassword),
                              child: const Text('Forgot password?'),
                            ),
                          ),
                          FocusRing(
                            child: TextButton(
                              key: const Key('church-help'),
                              onPressed: () => setState(() => _helpOpen = true),
                              child: const Text('Get church help'),
                            ),
                          ),
                        ],
                      ),
                      if (_helpOpen) ...[
                        const SizedBox(height: 12),
                        const RequestStateBanner(
                          key: Key('help-panel'),
                          tone: StatusTone.info,
                          icon: Icons.support_agent_outlined,
                          title: 'Get help from the church',
                          message:
                              'Ask the church office or your cell leader for '
                              'help with signing in. They will check who you '
                              'are in person. Staff never ask for, choose or '
                              'see your password, and no code is sent by SMS.',
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  (String, String) _failureText(SignInState s) {
    final create = s.createdAccount;
    return switch (s.failure!) {
      AuthFailure.invalidCredentials => (
        'Couldn\'t sign in',
        'The phone number or password is not right. Check both and try '
            'again, or get church help.',
      ),
      AuthFailure.usernameUnavailable => (
        'Couldn\'t create the account',
        'This phone number can\'t be used to create a new account. If you '
            'already have one, sign in instead, or get church help.',
      ),
      AuthFailure.weakPassword => (
        'Choose a stronger password',
        [
          'The password does not meet the requirements.',
          if (s.serverReasons.isNotEmpty)
            'Reason: ${s.serverReasons.join(', ').replaceAll('_', ' ')}.',
          'Use a longer password with a mix of letters and numbers.',
        ].join(' '),
      ),
      AuthFailure.rateLimited => (
        'Too many attempts',
        'Please wait a few minutes before trying again.',
      ),
      AuthFailure.unreachable => (
        'No connection',
        'We couldn\'t reach the church server. Check your connection and '
            'try again.',
      ),
      AuthFailure.unavailable => (
        create ? 'Couldn\'t create the account' : 'Couldn\'t sign in',
        'Signing in is not available right now. Please try again later or '
            'get church help.',
      ),
    };
  }
}

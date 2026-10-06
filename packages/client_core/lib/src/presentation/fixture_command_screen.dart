import 'package:church_contracts/church_contracts.dart';
import 'package:church_design_system/church_design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../application/fixture_counter_controller.dart';
import '../application/providers.dart';
import '../domain/fixture_counter.dart';

/// Exercises the synthetic 1.4 `fixture_counter` command with honest
/// pending, validation, conflict, unavailable, unknown-outcome, denied and
/// account-changed states. SYNTHETIC data only.
class FixtureCommandScreen extends ConsumerWidget {
  const FixtureCommandScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Keyed by account generation: an account change discards the form's
    // local text along with the controller's protected state.
    final generation = ref.watch(accountGenerationProvider);
    final layout = ChurchLayout.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Fixture command')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: layout.pagePadding,
          child: Center(
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: layout.contentMaxWidth),
              child: _FixtureForm(key: ValueKey('fixture-form-$generation')),
            ),
          ),
        ),
      ),
    );
  }
}

class _FixtureForm extends ConsumerStatefulWidget {
  const _FixtureForm({super.key});

  @override
  ConsumerState<_FixtureForm> createState() => _FixtureFormState();
}

class _FixtureFormState extends ConsumerState<_FixtureForm> {
  final _intentKey = TextEditingController();
  final _by = TextEditingController(text: '1');
  String? _localIntentError;
  String? _localByError;

  /// Focus target for the request-state banner: every transition moves
  /// keyboard focus to the state it reports, so focus is never lost when the
  /// triggering control is disabled or its banner action disappears.
  final _stateFocus = FocusNode(debugLabel: 'request state');
  final _accountFocus = FocusNode(debugLabel: 'account changed');
  final _intentFocus = FocusNode(debugLabel: 'intent key');

  @override
  void initState() {
    super.initState();
    // This form is rebuilt for each account generation: report the change.
    final change = ref.read(accountProvider).lastChange;
    if (change != null && change != AccountChange.signedIn) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _accountFocus.requestFocus();
        announce(context, '${_accountTitle(change)}. $_accountMessage');
      });
    }
  }

  @override
  void dispose() {
    _intentKey.dispose();
    _by.dispose();
    _stateFocus.dispose();
    _accountFocus.dispose();
    _intentFocus.dispose();
    super.dispose();
  }

  void _focusState() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _stateFocus.context != null) _stateFocus.requestFocus();
    });
  }

  FixtureCounterController get _controller =>
      ref.read(fixtureCounterControllerProvider.notifier);

  void _create() {
    final key = _intentKey.text.trim();
    setState(() {
      _localIntentError = key.isEmpty || key.length > 100
          ? 'Enter an intent key of 1 to 100 characters.'
          : null;
    });
    if (_localIntentError == null) _controller.create(key);
  }

  void _increment() {
    final by = int.tryParse(_by.text.trim());
    setState(() {
      _localByError = by == null || by == 0 || by.abs() > 1000
          ? 'Enter a whole number from -1000 to 1000, other than 0.'
          : null;
    });
    if (_localByError == null) _controller.increment(by!);
  }

  @override
  Widget build(BuildContext context) {
    final c = ChurchColors.of(context);
    final s = ref.watch(fixtureCounterControllerProvider);
    final account = ref.watch(accountProvider);
    ref.listen(fixtureCounterControllerProvider, (prev, next) {
      final spoken = _announcement(prev, next);
      if (spoken == null) return;
      announce(context, spoken);
      _focusState();
    });

    final serverFieldErrors = s.phase == FixturePhase.validation
        ? s.error?.fieldErrors ?? const <String, String>{}
        : const <String, String>{};
    final intentError =
        _localIntentError ??
        (s.lastAction == FixtureAction.create
            ? _fieldMessage('intent_key', serverFieldErrors['intent_key'])
            : null);
    final byError =
        _localByError ??
        (s.lastAction == FixtureAction.increment
            ? _fieldMessage('by', serverFieldErrors['by'])
            : null);

    return DefaultTextStyle.merge(
      style: ChurchLayout.of(context).body.copyWith(color: c.ink),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Align(
            alignment: Alignment.centerLeft,
            child: StatusLabel(
              label: 'Synthetic test command',
              tone: StatusTone.neutral,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Runs the platform test command from story 1.4. It changes only '
            'synthetic test data.',
            style: ChurchType.secondary.copyWith(color: c.muted),
          ),
          const SizedBox(height: ChurchGeometry.sectionGap),
          if (account.lastChange case final change?
              when change != AccountChange.signedIn) ...[
            RequestStateBanner(
              key: const Key('state-account-changed'),
              focusNode: _accountFocus,
              tone: StatusTone.info,
              icon: Icons.switch_account_outlined,
              title: _accountTitle(change),
              message: _accountMessage,
              actions: [
                BannerAction('Dismiss', () {
                  ref.read(accountProvider.notifier).acknowledgeChange();
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (mounted) _intentFocus.requestFocus();
                  });
                }, key: const Key('dismiss-account-change')),
              ],
            ),
            const SizedBox(height: ChurchGeometry.sectionGap),
          ],
          Text(
            account.accountId == null
                ? 'Not signed in. The server refuses commands until sign-in '
                      'is available.'
                : 'Acting as a signed-in synthetic account.',
            key: const Key('account-line'),
            style: ChurchType.secondary.copyWith(color: c.muted),
          ),
          const SizedBox(height: ChurchGeometry.sectionGap),
          _CounterCard(state: s),
          const SizedBox(height: ChurchGeometry.sectionGap),
          if (_banner(s) case final banner?) ...[
            banner,
            const SizedBox(height: ChurchGeometry.sectionGap),
          ],
          _Section(
            title: 'Create a counter',
            children: [
              RevealOnFocus(
                child: TextField(
                  key: const Key('intent-key-field'),
                  focusNode: _intentFocus,
                  controller: _intentKey,
                  readOnly: !s.canCreate,
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => s.canCreate ? _create() : null,
                  onChanged: (_) {
                    _controller.inputChanged();
                    if (_localIntentError != null) {
                      setState(() => _localIntentError = null);
                    }
                  },
                  decoration: InputDecoration(
                    labelText: 'Intent key',
                    helperText: 'Any label for this synthetic counter.',
                    errorText: intentError,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerLeft,
                child: FocusRing(
                  child: FilledButton(
                    key: const Key('create-button'),
                    onPressed: s.canCreate ? _create : null,
                    child: const Text('Create counter'),
                  ),
                ),
              ),
            ],
          ),
          if (s.counter != null) ...[
            const SizedBox(height: ChurchGeometry.sectionGap),
            _Section(
              title: 'Change the counter',
              children: [
                RevealOnFocus(
                  child: TextField(
                    key: const Key('by-field'),
                    controller: _by,
                    readOnly: !s.canIncrement,
                    keyboardType: const TextInputType.numberWithOptions(
                      signed: true,
                    ),
                    inputFormatters: [
                      FilteringTextInputFormatter.allow(RegExp(r'[-0-9]')),
                    ],
                    onSubmitted: (_) => s.canIncrement ? _increment() : null,
                    onChanged: (_) {
                      _controller.inputChanged();
                      if (_localByError != null) {
                        setState(() => _localByError = null);
                      }
                    },
                    decoration: InputDecoration(
                      labelText: 'Change by',
                      helperText:
                          'Applied to revision ${s.counter!.revision}, the '
                          'last revision the server confirmed.',
                      errorText: byError,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerLeft,
                  child: FocusRing(
                    child: FilledButton(
                      key: const Key('increment-button'),
                      onPressed: s.canIncrement ? _increment : null,
                      child: const Text('Apply change'),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget? _banner(FixtureFormState s) {
    final ctl = _controller;
    final code = s.error?.code;
    switch (s.phase) {
      case FixturePhase.idle:
        if (s.discardedUnconfirmed) {
          return RequestStateBanner(
            key: const Key('state-discarded'),
            focusNode: _stateFocus,
            tone: StatusTone.warning,
            icon: Icons.help_outline,
            title: 'Stopped checking',
            message:
                'The last change was never confirmed and may still have been '
                'applied. The counter shows only what the server confirmed.',
          );
        }
        if (s.reloaded) {
          return RequestStateBanner(
            key: const Key('state-reloaded'),
            focusNode: _stateFocus,
            tone: StatusTone.info,
            title: 'Reloaded',
            message:
                'The counter now shows the server\'s revision '
                '${s.counter?.revision}. Your entry is kept: apply it again if '
                'it still makes sense.',
          );
        }
        return null;
      case FixturePhase.pending:
        return RequestStateBanner(
          key: const Key('state-pending'),
          focusNode: _stateFocus,
          tone: StatusTone.info,
          busy: true,
          title: 'Sending…',
          message:
              'Waiting for the server to confirm. Nothing is saved until it '
              'does.',
        );
      case FixturePhase.reloading:
        return RequestStateBanner(
          key: const Key('state-reloading'),
          focusNode: _stateFocus,
          tone: StatusTone.info,
          busy: true,
          title: 'Reloading…',
          message: 'Loading the latest value from the server.',
        );
      case FixturePhase.confirmed:
        return RequestStateBanner(
          key: const Key('state-confirmed'),
          focusNode: _stateFocus,
          tone: StatusTone.success,
          icon: Icons.check_circle_outline,
          title: 'Saved',
          message: 'The server confirmed revision ${s.counter?.revision}.',
        );
      case FixturePhase.validation:
        return RequestStateBanner(
          key: const Key('state-validation'),
          focusNode: _stateFocus,
          tone: StatusTone.danger,
          icon: Icons.error_outline,
          title: 'Not saved: check your entry',
          message:
              'The server did not accept this entry. Your entry is kept; fix '
              'the highlighted field and try again.',
        );
      case FixturePhase.conflict:
        if (!s.staleRevision) {
          return RequestStateBanner(
            key: const Key('state-conflict-create'),
            focusNode: _stateFocus,
            tone: StatusTone.warning,
            icon: Icons.warning_amber_outlined,
            title: 'Not saved: this already exists',
            message:
                'This account already has a counter with this intent key. '
                'Your entry is kept; choose another intent key.',
          );
        }
        final current = s.error?.currentRevision;
        return RequestStateBanner(
          key: const Key('state-conflict'),
          focusNode: _stateFocus,
          tone: StatusTone.warning,
          icon: Icons.warning_amber_outlined,
          title: 'Not saved: the counter changed',
          message: [
            'The counter changed since revision ${s.counter?.revision}'
                '${current != null && current.present && current.value != null ? ' (the server is at revision ${current.value})' : ''}. '
                'Your change was not applied and is kept. Reload to see the '
                'latest value before applying it again.',
            if (s.reloadProblem != null) "Couldn't reload: ${s.reloadProblem}",
          ].join('\n\n'),
          actions: [
            BannerAction(
              'Reload',
              ctl.reload,
              key: const Key('reload-button'),
              primary: true,
            ),
          ],
        );
      case FixturePhase.unavailable:
        return RequestStateBanner(
          key: const Key('state-unavailable'),
          focusNode: _stateFocus,
          tone: StatusTone.danger,
          icon: Icons.cloud_off_outlined,
          title: code == ErrorCode.rateLimited
              ? 'Not saved: too many requests'
              : 'Not saved: service unavailable',
          message: s.canRetry
              ? 'The server could not run this command, so nothing changed. '
                    'Your entry is kept.'
              : 'The server could not run this command, so nothing changed. '
                    'You edited your entry: submit it to send it as a new '
                    'request.',
          actions: [
            if (s.canRetry)
              BannerAction(
                'Try again',
                ctl.retry,
                key: const Key('try-again-button'),
                primary: true,
              ),
          ],
        );
      case FixturePhase.unknownOutcome:
        return RequestStateBanner(
          key: const Key('state-unknown'),
          focusNode: _stateFocus,
          tone: StatusTone.warning,
          icon: Icons.help_outline,
          title: 'Not confirmed',
          message:
              "We couldn't confirm whether the server saved this change. "
              'Check again sends the same request, so it cannot apply twice. '
              'Your entry is locked until then.',
          actions: [
            BannerAction(
              'Check again',
              ctl.retry,
              key: const Key('check-again-button'),
              primary: true,
            ),
            BannerAction(
              'Stop checking',
              ctl.discardUnconfirmed,
              key: const Key('discard-button'),
            ),
          ],
        );
      case FixturePhase.notSent:
        return RequestStateBanner(
          key: const Key('state-not-sent'),
          focusNode: _stateFocus,
          tone: StatusTone.danger,
          icon: Icons.cloud_off_outlined,
          title: 'Not sent: no server configured',
          message: s.notSentReason ?? 'The command was not sent.',
        );
      case FixturePhase.denied:
        final (title, message) = switch (code) {
          ErrorCode.unauthenticated => (
            'Not saved: sign-in required',
            'The server needs a signed-in account for this command. Sign-in '
                'arrives with the identity work.',
          ),
          ErrorCode.forbidden => (
            'Not saved: not allowed',
            'This account is not allowed to run this command.',
          ),
          _ => (
            'Not saved: counter not found',
            'This counter was not found for this account.',
          ),
        };
        return RequestStateBanner(
          key: const Key('state-denied'),
          focusNode: _stateFocus,
          tone: StatusTone.danger,
          icon: Icons.block,
          title: title,
          message: message,
        );
    }
  }
}

/// What to announce (and where focus moves) when the form state changes;
/// null when nothing the user should hear changed.
String? _announcement(FixtureFormState? prev, FixtureFormState next) {
  if (prev != null &&
      prev.phase == next.phase &&
      prev.discardedUnconfirmed == next.discardedUnconfirmed &&
      prev.reloaded == next.reloaded) {
    return null;
  }
  return switch (next.phase) {
    FixturePhase.pending => 'Sending.',
    FixturePhase.reloading => 'Reloading.',
    FixturePhase.confirmed =>
      'Saved. Value ${next.counter?.value}, revision ${next.counter?.revision}.',
    FixturePhase.validation => 'Not saved. Check your entry.',
    FixturePhase.conflict when prev?.phase == FixturePhase.reloading =>
      "Couldn't reload. ${next.reloadProblem ?? ''}".trim(),
    FixturePhase.conflict when next.staleRevision =>
      'Not saved. The counter changed. Reload before applying again.',
    FixturePhase.conflict =>
      'Not saved. This account already has a counter with this intent key.',
    FixturePhase.unavailable => 'Not saved. Service unavailable.',
    FixturePhase.unknownOutcome => 'Not confirmed. Check again.',
    FixturePhase.denied => switch (next.error?.code) {
      ErrorCode.unauthenticated => 'Not saved. Sign-in required.',
      ErrorCode.forbidden => 'Not saved. Not allowed.',
      _ => 'Not saved. Counter not found.',
    },
    FixturePhase.notSent => 'Not sent. No server configured.',
    FixturePhase.idle when next.discardedUnconfirmed =>
      'Stopped checking. The last change may still have been applied.',
    FixturePhase.idle when next.reloaded =>
      'Reloaded. The counter is at revision ${next.counter?.revision}.',
    FixturePhase.idle => null,
  };
}

String _accountTitle(AccountChange change) => change == AccountChange.signedOut
    ? 'You were signed out'
    : 'The signed-in account changed';

const _accountMessage =
    'Information and unsent changes from the previous account were cleared '
    'from this screen.';

String? _fieldMessage(String field, String? code) {
  if (code == null) return null;
  return switch ((field, code)) {
    ('intent_key', _) => 'Enter an intent key of 1 to 100 characters.',
    ('by', 'out_of_range') => 'That would take the counter out of range.',
    ('by', _) => 'Enter a whole number from -1000 to 1000, other than 0.',
    _ => 'This value was not accepted.',
  };
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final c = ChurchColors.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(ChurchGeometry.cardPadding),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Semantics(
              header: true,
              child: Text(
                title,
                style: ChurchType.cardTitle.copyWith(color: c.ink),
              ),
            ),
            const SizedBox(height: 12),
            ...children,
          ],
        ),
      ),
    );
  }
}

class _CounterCard extends StatelessWidget {
  const _CounterCard({required this.state});

  final FixtureFormState state;

  @override
  Widget build(BuildContext context) {
    final c = ChurchColors.of(context);
    final FixtureCounter? counter = state.counter;
    if (counter == null) {
      return Text(
        'No counter in this session yet.',
        key: const Key('no-counter'),
        style: ChurchType.body.copyWith(color: c.muted),
      );
    }
    return Card(
      key: const Key('counter-card'),
      child: Padding(
        padding: const EdgeInsets.all(ChurchGeometry.cardPadding),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Semantics(
              header: true,
              child: Text(
                'Counter “${counter.intentKey}”',
                style: ChurchType.cardTitle.copyWith(color: c.ink),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Value ${counter.value}',
              key: const Key('counter-value'),
              style: ChurchType.sectionTitle.copyWith(color: c.brand),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                StatusLabel(
                  label: 'Confirmed by server · revision ${counter.revision}',
                  tone: StatusTone.success,
                ),
                if (counter.isSynthetic)
                  const StatusLabel(
                    label: 'Synthetic',
                    tone: StatusTone.neutral,
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

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
    return Scaffold(
      appBar: AppBar(title: const Text('Fixture command')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(ChurchGeometry.mobileContentPadding),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 640),
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

  @override
  void dispose() {
    _intentKey.dispose();
    _by.dispose();
    super.dispose();
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
      if (prev?.phase == next.phase) return;
      final spoken = _announcement(next);
      if (spoken != null) announce(context, spoken);
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
      style: ChurchType.body.copyWith(color: c.ink),
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
              tone: StatusTone.info,
              icon: Icons.switch_account_outlined,
              title: change == AccountChange.signedOut
                  ? 'You were signed out'
                  : 'The signed-in account changed',
              message:
                  'Information and unsent changes from the previous account '
                  'were cleared from this screen.',
              actions: [
                BannerAction(
                  'Dismiss',
                  () => ref.read(accountProvider.notifier).acknowledgeChange(),
                  key: const Key('dismiss-account-change'),
                ),
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
                  controller: _intentKey,
                  readOnly: !s.canCreate,
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => s.canCreate ? _create() : null,
                  onChanged: (_) {
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
          return const RequestStateBanner(
            key: Key('state-discarded'),
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
        return const RequestStateBanner(
          key: Key('state-pending'),
          tone: StatusTone.info,
          busy: true,
          title: 'Sending…',
          message:
              'Waiting for the server to confirm. Nothing is saved until it '
              'does.',
        );
      case FixturePhase.reloading:
        return const RequestStateBanner(
          key: Key('state-reloading'),
          tone: StatusTone.info,
          busy: true,
          title: 'Reloading…',
          message: 'Loading the latest value from the server.',
        );
      case FixturePhase.confirmed:
        return RequestStateBanner(
          key: const Key('state-confirmed'),
          tone: StatusTone.success,
          icon: Icons.check_circle_outline,
          title: 'Saved',
          message: 'The server confirmed revision ${s.counter?.revision}.',
        );
      case FixturePhase.validation:
        return const RequestStateBanner(
          key: Key('state-validation'),
          tone: StatusTone.danger,
          icon: Icons.error_outline,
          title: 'Not saved: check your entry',
          message:
              'The server did not accept this entry. Your entry is kept; fix '
              'the highlighted field and try again.',
        );
      case FixturePhase.conflict:
        if (!s.staleRevision) {
          return const RequestStateBanner(
            key: Key('state-conflict-create'),
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
          tone: StatusTone.danger,
          icon: Icons.cloud_off_outlined,
          title: code == ErrorCode.rateLimited
              ? 'Not saved: too many requests'
              : 'Not saved: service unavailable',
          message:
              'The server could not run this command, so nothing changed. '
              'Your entry is kept.',
          actions: [
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
          tone: StatusTone.danger,
          icon: Icons.block,
          title: title,
          message: message,
        );
    }
  }
}

String? _announcement(FixtureFormState s) => switch (s.phase) {
  FixturePhase.confirmed =>
    'Saved. Value ${s.counter?.value}, revision ${s.counter?.revision}.',
  FixturePhase.validation => 'Not saved. Check your entry.',
  FixturePhase.conflict => 'Not saved. The counter changed.',
  FixturePhase.unavailable => 'Not saved. Service unavailable.',
  FixturePhase.unknownOutcome => 'Not confirmed. Check again.',
  FixturePhase.denied => 'Not saved.',
  _ => null,
};

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

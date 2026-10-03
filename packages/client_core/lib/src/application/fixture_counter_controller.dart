import 'package:church_contracts/church_contracts.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/commands.dart';
import '../domain/fixture_counter.dart';
import 'providers.dart';

/// Where the fixture command form stands. Only [confirmed] follows a server
/// success envelope; nothing else implies the change was saved.
enum FixturePhase {
  idle,
  pending,
  confirmed,
  validation,
  conflict,
  reloading,
  unavailable,
  unknownOutcome,
  denied,
}

enum FixtureAction { create, increment }

/// A submitted envelope, kept so a retry resends it unchanged.
class SubmittedCommand {
  const SubmittedCommand(this.action, this.request);
  final FixtureAction action;
  final CommandRequest request;
}

/// Protected, memory-only fixture state for the current account.
class FixtureFormState {
  const FixtureFormState({
    this.counter,
    this.phase = FixturePhase.idle,
    this.submitted,
    this.error,
    this.reloadProblem,
    this.reloaded = false,
    this.lastAction,
    this.discardedUnconfirmed = false,
  });

  /// Last server-confirmed snapshot (never a guessed value).
  final FixtureCounter? counter;
  final FixturePhase phase;

  /// The last command sent; resent as-is by [FixtureCounterController.retry].
  final SubmittedCommand? submitted;
  final CommandError? error;
  final String? reloadProblem;

  /// True after a successful reload that resolved a conflict.
  final bool reloaded;

  /// The action of the last command sent (what [error] refers to).
  final FixtureAction? lastAction;

  /// True after the user stopped checking an unconfirmed command.
  final bool discardedUnconfirmed;

  /// A stale-revision conflict on the counter: applying is blocked until a
  /// successful reload. (A create conflict is a duplicate intent key.)
  bool get staleRevision =>
      phase == FixturePhase.conflict && lastAction == FixtureAction.increment;

  /// Inputs are read-only while the outcome is open: editing then would
  /// change what "Check again" resends.
  bool get inputLocked =>
      phase == FixturePhase.pending ||
      phase == FixturePhase.reloading ||
      phase == FixturePhase.unknownOutcome;

  /// Applying a change needs a confirmed counter and a settled conflict.
  bool get canIncrement => counter != null && !inputLocked && !staleRevision;

  bool get canCreate => !inputLocked;

  FixtureFormState copyWith({
    FixtureCounter? counter,
    FixturePhase? phase,
    SubmittedCommand? submitted,
    bool clearSubmitted = false,
    CommandError? error,
    bool clearError = false,
    String? reloadProblem,
    bool clearReloadProblem = false,
    bool? reloaded,
    FixtureAction? lastAction,
    bool? discardedUnconfirmed,
  }) => FixtureFormState(
    counter: counter ?? this.counter,
    phase: phase ?? this.phase,
    submitted: clearSubmitted ? null : (submitted ?? this.submitted),
    error: clearError ? null : (error ?? this.error),
    reloadProblem: clearReloadProblem
        ? null
        : (reloadProblem ?? this.reloadProblem),
    reloaded: reloaded ?? this.reloaded,
    lastAction: lastAction ?? this.lastAction,
    discardedUnconfirmed: discardedUnconfirmed ?? this.discardedUnconfirmed,
  );
}

/// Runs the 1.4 `fixture_counter` commands with honest request states.
///
/// Rebuilt (state dropped) whenever the account generation changes, and a
/// response that arrives for an older generation is discarded.
class FixtureCounterController extends Notifier<FixtureFormState> {
  int _epoch = 0;

  @override
  FixtureFormState build() {
    ref.watch(accountGenerationProvider);
    _epoch++;
    return const FixtureFormState();
  }

  Future<void> create(String intentKey) async {
    if (!state.canCreate) return;
    final request = CommandRequest(
      command: FixtureCounterCommands.create,
      requestId: ref.read(requestIdsProvider).next(),
      expectedRevision: const Optional.of(null),
      payload: {'intent_key': intentKey},
    );
    await _send(SubmittedCommand(FixtureAction.create, request));
  }

  Future<void> increment(int by) async {
    final counter = state.counter;
    if (counter == null || !state.canIncrement) return;
    final request = CommandRequest(
      command: FixtureCounterCommands.increment,
      requestId: ref.read(requestIdsProvider).next(),
      // Always the last server-confirmed revision: a conflict's
      // current_revision is never adopted without a reload.
      expectedRevision: Optional.of(counter.revision),
      payload: {'counter_id': counter.id, 'by': by},
    );
    await _send(SubmittedCommand(FixtureAction.increment, request));
  }

  /// Resends the last envelope unchanged (same request_id and body).
  Future<void> retry() async {
    final submitted = state.submitted;
    if (submitted == null) return;
    if (state.phase != FixturePhase.unknownOutcome &&
        state.phase != FixturePhase.unavailable) {
      return;
    }
    await _send(submitted);
  }

  /// Stops checking an unconfirmed command. Its outcome stays unknown.
  void discardUnconfirmed() {
    if (state.phase != FixturePhase.unknownOutcome) return;
    state = state.copyWith(
      phase: FixturePhase.idle,
      clearSubmitted: true,
      clearError: true,
      discardedUnconfirmed: true,
    );
  }

  /// Reloads the counter after a conflict. Only a successful read replaces
  /// the snapshot (and with it the expected revision).
  Future<void> reload() async {
    final counter = state.counter;
    if (counter == null || !state.staleRevision) return;
    final epoch = _epoch;
    state = state.copyWith(
      phase: FixturePhase.reloading,
      clearReloadProblem: true,
    );
    try {
      final fresh = await ref
          .read(fixtureCounterReaderProvider)
          .read(counter.id);
      if (!_current(epoch)) return;
      state = FixtureFormState(
        counter: fresh,
        reloaded: true,
        lastAction: state.lastAction,
      );
    } on FixtureReadUnavailable catch (e) {
      if (!_current(epoch)) return;
      state = state.copyWith(
        phase: FixturePhase.conflict,
        reloadProblem: e.reason,
      );
    } catch (_) {
      if (!_current(epoch)) return;
      state = state.copyWith(
        phase: FixturePhase.conflict,
        reloadProblem: "The latest value couldn't be loaded. Try again.",
      );
    }
  }

  bool _current(int epoch) => ref.mounted && epoch == _epoch;

  Future<void> _send(SubmittedCommand submitted) async {
    final epoch = _epoch;
    state = state.copyWith(
      phase: FixturePhase.pending,
      submitted: submitted,
      clearError: true,
      clearReloadProblem: true,
      reloaded: false,
      lastAction: submitted.action,
      discardedUnconfirmed: false,
    );
    final outcome = await ref
        .read(commandGatewayProvider)
        .send(FixtureCounterCommands.function, submitted.request);
    // A response for a previous account (or a disposed screen) is dropped.
    if (!_current(epoch)) return;
    state = switch (outcome) {
      CommandConfirmed(:final success) => _confirmed(success),
      CommandRefused(:final error) => _refused(error),
      CommandUnknownOutcome() => state.copyWith(
        phase: FixturePhase.unknownOutcome,
      ),
    };
  }

  FixtureFormState _confirmed(CommandSuccess success) {
    try {
      final counter = FixtureCounter.fromCommandData(
        success.data,
        success.revision,
      );
      return FixtureFormState(
        counter: counter,
        phase: FixturePhase.confirmed,
        lastAction: state.lastAction,
      );
    } on FormatException {
      // An unusable success body proves nothing: keep the outcome open.
      return state.copyWith(phase: FixturePhase.unknownOutcome);
    }
  }

  FixtureFormState _refused(CommandError error) {
    final phase = switch (error.code) {
      ErrorCode.validationFailed => FixturePhase.validation,
      ErrorCode.conflict => FixturePhase.conflict,
      ErrorCode.unavailable ||
      ErrorCode.rateLimited => FixturePhase.unavailable,
      ErrorCode.unauthenticated ||
      ErrorCode.forbidden ||
      ErrorCode.notFound => FixturePhase.denied,
    };
    return state.copyWith(
      phase: phase,
      error: error,
      // Only an unavailable command is resent unchanged; after any other
      // definite refusal the next submit is a new request.
      clearSubmitted: phase != FixturePhase.unavailable,
    );
  }
}

final fixtureCounterControllerProvider =
    NotifierProvider<FixtureCounterController, FixtureFormState>(
      FixtureCounterController.new,
    );

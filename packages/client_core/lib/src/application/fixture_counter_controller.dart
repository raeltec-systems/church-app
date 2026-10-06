import 'dart:convert';

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
  notSent,
}

enum FixtureAction { create, increment }

/// A submitted envelope, kept so a retry resends it unchanged.
class SubmittedCommand {
  const SubmittedCommand(this.action, this.request);
  final FixtureAction action;
  final CommandRequest request;

  /// The envelope without its request id: "the same input".
  String get body {
    final m = request.toJson()..remove('request_id');
    return jsonEncode(m);
  }
}

/// Protected, memory-only fixture state for the current account.
///
/// Kept while the user moves between destinations (an unconfirmed command
/// must not be forgotten and resubmitted under a new id); dropped on any
/// account change or sign-out (AD-13).
class FixtureFormState {
  const FixtureFormState({
    this.counter,
    this.phase = FixturePhase.idle,
    this.submitted,
    this.unconfirmed,
    this.error,
    this.notSentReason,
    this.reloadProblem,
    this.reloaded = false,
    this.lastAction,
    this.discardedUnconfirmed = false,
  });

  /// Last server-confirmed snapshot (never a guessed value).
  final FixtureCounter? counter;
  final FixturePhase phase;

  /// The command that [FixtureCounterController.retry] resends as-is. Set
  /// while pending, unknown or unavailable-and-unedited.
  final SubmittedCommand? submitted;

  /// A command whose outcome was never learned (the user stopped checking).
  /// The same input is resent under the same request id.
  final SubmittedCommand? unconfirmed;
  final CommandError? error;
  final String? notSentReason;
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

  /// "Try again" resends [submitted]; it disappears once the input is edited.
  bool get canRetry =>
      submitted != null &&
      (phase == FixturePhase.unavailable ||
          phase == FixturePhase.unknownOutcome);

  /// Applying a change needs a confirmed counter and a settled conflict.
  bool get canIncrement => counter != null && !inputLocked && !staleRevision;

  bool get canCreate => !inputLocked;

  FixtureFormState copyWith({
    FixtureCounter? counter,
    FixturePhase? phase,
    SubmittedCommand? submitted,
    bool clearSubmitted = false,
    SubmittedCommand? unconfirmed,
    bool clearUnconfirmed = false,
    CommandError? error,
    bool clearError = false,
    String? notSentReason,
    String? reloadProblem,
    bool clearReloadProblem = false,
    bool? reloaded,
    FixtureAction? lastAction,
    bool? discardedUnconfirmed,
  }) => FixtureFormState(
    counter: counter ?? this.counter,
    phase: phase ?? this.phase,
    submitted: clearSubmitted ? null : (submitted ?? this.submitted),
    unconfirmed: clearUnconfirmed ? null : (unconfirmed ?? this.unconfirmed),
    error: clearError ? null : (error ?? this.error),
    notSentReason: notSentReason,
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
    await _send(
      _command(
        FixtureAction.create,
        FixtureCounterCommands.create,
        const Optional.of(null),
        {'intent_key': intentKey},
      ),
    );
  }

  Future<void> increment(int by) async {
    final counter = state.counter;
    if (counter == null || !state.canIncrement) return;
    await _send(
      _command(
        FixtureAction.increment,
        FixtureCounterCommands.increment,
        // Always the last server-confirmed revision: a conflict's
        // current_revision is never adopted without a reload.
        Optional.of(counter.revision),
        {'counter_id': counter.id, 'by': by},
      ),
    );
  }

  /// One request id per submitted input: an input whose outcome was never
  /// learned is resent under its original id; any other input gets a new one.
  SubmittedCommand _command(
    FixtureAction action,
    String command,
    Optional<int> expectedRevision,
    Map<String, Object?> payload,
  ) {
    CommandRequest withId(String id) => CommandRequest(
      command: command,
      requestId: id,
      expectedRevision: expectedRevision,
      payload: payload,
    );
    final unconfirmed = state.unconfirmed;
    if (unconfirmed != null) {
      final same = SubmittedCommand(
        action,
        withId(unconfirmed.request.requestId),
      );
      if (same.body == unconfirmed.body) return same;
    }
    return SubmittedCommand(
      action,
      withId(ref.read(requestIdsProvider).next()),
    );
  }

  /// Resends the last envelope unchanged (same request_id and body).
  Future<void> retry() async {
    final submitted = state.submitted;
    if (submitted == null || !state.canRetry) return;
    await _send(submitted);
  }

  /// The user edited an input. After an `unavailable` refusal the old body is
  /// no longer what they mean, so "Try again" is withdrawn; the next submit
  /// sends the edited input as a new request.
  void inputChanged() {
    if (state.phase == FixturePhase.unavailable && state.submitted != null) {
      state = state.copyWith(clearSubmitted: true);
    }
  }

  /// Stops checking an unconfirmed command. Its outcome stays unknown, and
  /// the same input keeps its request id if it is submitted again.
  void discardUnconfirmed() {
    if (state.phase != FixturePhase.unknownOutcome) return;
    state = state.copyWith(
      phase: FixturePhase.idle,
      unconfirmed: state.submitted,
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
        unconfirmed: state.unconfirmed,
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
    // A definite outcome settles an earlier unconfirmed send of this id.
    final settled =
        outcome is! CommandUnknownOutcome &&
        state.unconfirmed?.request.requestId == submitted.request.requestId;
    final next = switch (outcome) {
      CommandConfirmed(:final success) => _confirmed(success),
      CommandRefused(:final error) => _refused(error),
      CommandNotSent(:final reason) => state.copyWith(
        phase: FixturePhase.notSent,
        notSentReason: reason,
        clearSubmitted: true,
      ),
      CommandUnknownOutcome() => state.copyWith(
        phase: FixturePhase.unknownOutcome,
      ),
    };
    state = settled && next.phase != FixturePhase.unknownOutcome
        ? next.copyWith(clearUnconfirmed: true)
        : next;
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
        unconfirmed: state.unconfirmed,
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

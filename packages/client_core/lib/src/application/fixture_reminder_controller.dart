import 'package:church_contracts/church_contracts.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/commands.dart';
import 'providers.dart';

/// One SYNTHETIC reminder source this screen knows about.
class FixtureReminderSource {
  const FixtureReminderSource({
    required this.sourceId,
    required this.revision,
    this.kind,
    this.state,
  });

  final String sourceId;
  final int revision;

  /// `fixture_due` or `fixture_reply` (null when opened from a link).
  final String? kind;

  /// `active` or `cancelled` as last answered (null when opened from a link).
  final String? state;
}

/// The SYNTHETIC test-reminder actions.
enum FixtureReminderAction { createDue, createRequest, respond, cancel }

/// What the last action got from the server.
enum FixtureReminderOutcome {
  done,

  /// The source changed first; its current revision is now used.
  changed,

  /// Already answered or cancelled.
  closed,

  /// This test reminder needs no answer (a plain due reminder).
  noAnswerNeeded,
  refused,
  unknown,
  notSent,
}

class FixtureReminderState {
  const FixtureReminderState({
    this.busy,
    this.source,
    this.lastAction,
    this.outcome,
    this.refusal,
  });

  final FixtureReminderAction? busy;
  final FixtureReminderSource? source;
  final FixtureReminderAction? lastAction;
  final FixtureReminderOutcome? outcome;

  /// The server's error code of a refusal (shown as is: SYNTHETIC tool).
  final String? refusal;
}

/// SYNTHETIC (local/staging only; the server refuses production): the
/// signed-in member creates test reminders for themself through
/// `api.fixture_reminder_command`, so the inbox, snooze and push settings can
/// be tried on a real phone without any other tool. `fixture.reminder_create`
/// makes a reminder due now; `fixture.reminder_schedule` makes a request
/// that starts in 20 hours, whose reply reminder is due now and expires at
/// the start (a 2-day snooze is then clamped); `fixture.reminder_respond`
/// answers it and `fixture.reminder_cancel` cancels either kind. The Cron
/// worker delivers the reminder within about a minute.
class FixtureReminderController extends Notifier<FixtureReminderState> {
  FixtureReminderController(this.linkedSourceId);

  /// The source a reminder's link opened (`/fixture/reminders/<id>`), if any.
  final String? linkedSourceId;
  CommandRequest? _pending;
  FixtureReminderAction? _pendingAction;

  @override
  FixtureReminderState build() {
    ref.watch(accountGenerationProvider);
    _pending = null;
    _pendingAction = null;
    final linked = linkedSourceId;
    return FixtureReminderState(
      source: linked == null
          ? null
          : FixtureReminderSource(sourceId: linked, revision: 1),
    );
  }

  Future<void> createDueNow() => _start(
    FixtureReminderAction.createDue,
    'fixture.reminder_create',
    {'due_at': _utc(DateTime.now())},
  );

  Future<void> createRequest() => _start(
    FixtureReminderAction.createRequest,
    'fixture.reminder_schedule',
    {'starts_at': _utc(DateTime.now().add(const Duration(hours: 20)))},
  );

  Future<void> respond() =>
      _onSource(FixtureReminderAction.respond, 'fixture.reminder_respond');

  Future<void> cancel() =>
      _onSource(FixtureReminderAction.cancel, 'fixture.reminder_cancel');

  /// After an unknown outcome: resends the identical request.
  Future<void> retry() async {
    if (_pending == null || state.outcome != FixtureReminderOutcome.unknown) {
      return;
    }
    await _send(_pendingAction!);
  }

  Future<void> _onSource(FixtureReminderAction action, String command) async {
    final s = state.source;
    if (s == null) return;
    await _start(action, command, {
      'source_id': s.sourceId,
    }, expected: Optional<int>.of(s.revision));
  }

  Future<void> _start(
    FixtureReminderAction action,
    String command,
    Map<String, Object?> payload, {
    Optional<int> expected = const Optional<int>.absent(),
  }) async {
    if (state.busy != null) return;
    _pending = CommandRequest(
      command: command,
      requestId: ref.read(requestIdsProvider).next(),
      expectedRevision: expected,
      payload: payload,
    );
    _pendingAction = action;
    await _send(action);
  }

  Future<void> _send(FixtureReminderAction action) async {
    final request = _pending!;
    final generation = ref.read(accountGenerationProvider);
    state = FixtureReminderState(busy: action, source: state.source);
    final outcome = await ref
        .read(commandGatewayProvider)
        .send('fixture_reminder_command', request);
    if (!ref.mounted || ref.read(accountGenerationProvider) != generation) {
      return;
    }
    var source = state.source;
    FixtureReminderOutcome result;
    String? refusal;
    switch (outcome) {
      case CommandConfirmed(:final success):
        final data = success.data;
        if (data is Map && data['source_id'] is String) {
          source = FixtureReminderSource(
            sourceId: data['source_id'] as String,
            revision: success.revision,
            kind: data['reminder_kind'] as String?,
            state: data['state'] as String?,
          );
        }
        result = FixtureReminderOutcome.done;
      case CommandRefused(:final error):
        refusal = error.code.wireName;
        final field = error.fieldErrors['source_id'];
        if (error.code == ErrorCode.conflict &&
            (field == 'cancelled' || field == 'responded')) {
          result = FixtureReminderOutcome.closed;
        } else if (error.code == ErrorCode.conflict &&
            error.currentRevision.present &&
            error.currentRevision.value != null &&
            source != null) {
          source = FixtureReminderSource(
            sourceId: source.sourceId,
            revision: error.currentRevision.value!,
            kind: source.kind,
            state: source.state,
          );
          result = FixtureReminderOutcome.changed;
        } else if (error.code == ErrorCode.validationFailed &&
            field == 'invalid' &&
            action == FixtureReminderAction.respond) {
          result = FixtureReminderOutcome.noAnswerNeeded;
        } else {
          result = FixtureReminderOutcome.refused;
        }
      case CommandUnknownOutcome():
        result = FixtureReminderOutcome.unknown;
      case CommandNotSent():
        result = FixtureReminderOutcome.notSent;
    }
    if (result != FixtureReminderOutcome.unknown) {
      _pending = null;
      _pendingAction = null;
    }
    state = FixtureReminderState(
      source: source,
      lastAction: action,
      outcome: result,
      refusal: refusal,
    );
  }
}

String _utc(DateTime at) => at.toUtc().toIso8601String();

final fixtureReminderProvider = NotifierProvider.autoDispose
    .family<FixtureReminderController, FixtureReminderState, String?>(
      FixtureReminderController.new,
    );

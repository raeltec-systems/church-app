import 'dart:convert';

import 'package:church_contracts/church_contracts.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/access_grants.dart';
import '../domain/commands.dart';
import '../domain/content_events.dart';
import 'access_controllers.dart' show noteProtectedDenial;
import 'providers.dart';

// Story 6.1: the public calendar (everyone, signed in or not) and the
// editors' Events screen on staff web. Public reads hold only the published
// projection, in memory; the editors' read and its commands are protected
// state scoped to the account generation (AD-13). The server checks every
// read and command.

/// One public read and whether it is under way.
class PublicReadState<T> {
  const PublicReadState({this.loading = false, this.result});

  final bool loading;

  /// The last answer (failures included); null before the first.
  final AccessRead<T>? result;

  T? get value => switch (result) {
    AccessReadOk<T>(:final value) => value,
    _ => null,
  };
}

/// A public read: asked on first use, on demand (reload, resume) and again
/// after an account change. Never persisted.
abstract class PublicReadController<T> extends Notifier<PublicReadState<T>> {
  int _epoch = 0;

  Future<AccessRead<T>> fetch();

  @override
  PublicReadState<T> build() {
    ref.watch(accountGenerationProvider);
    _epoch++;
    final epoch = _epoch;
    Future.microtask(() => _reload(epoch));
    return PublicReadState<T>(loading: true);
  }

  Future<void> reload() => _reload(_epoch);

  Future<void> _reload(int epoch) async {
    if (!ref.mounted || epoch != _epoch) return;
    state = PublicReadState<T>(loading: true, result: state.result);
    final r = await fetch();
    if (!ref.mounted || epoch != _epoch) return;
    state = PublicReadState<T>(result: r);
  }
}

/// `api.content_public_events`: the published, not yet ended events.
class PublicEventsController extends PublicReadController<PublicEvents> {
  @override
  Future<AccessRead<PublicEvents>> fetch() =>
      ref.read(contentRepositoryProvider).fetchPublicEvents();
}

final publicEventsProvider =
    NotifierProvider<PublicEventsController, PublicReadState<PublicEvents>>(
      PublicEventsController.new,
    );

/// `api.content_public_event`: one event (null when it is not public).
class PublicEventController extends PublicReadController<PublicEventRead> {
  PublicEventController(this.eventId);

  final String eventId;

  @override
  Future<AccessRead<PublicEventRead>> fetch() =>
      ref.read(contentRepositoryProvider).fetchPublicEvent(eventId);
}

final publicEventProvider = NotifierProvider.autoDispose
    .family<PublicEventController, PublicReadState<PublicEventRead>, String>(
      PublicEventController.new,
    );

/// What the Events screen tells the editor after an action.
enum ContentNotice {
  created,
  saved,
  published,
  withdrawn,
  archived,

  /// Changed in another tab or by someone else: reloaded.
  changedElsewhere,

  /// Nothing to publish (no saved changes).
  nothingToPublish,

  /// Withdrawn already, or never published.
  notPublished,

  /// Archived (by someone else): no further change.
  alreadyArchived,
  invalid,
  notAllowed,
  signInAgain,
  notFound,
  notAvailable,
  refused,

  /// The outcome is unknown: check again with the same request.
  unconfirmed,
  notSent,
}

/// One command in flight or just answered.
class ContentAction {
  const ContentAction({required this.request, required this.subject});

  final CommandRequest request;

  /// What was acted on (display only): the event's title.
  final String subject;

  String get command => request.command;
}

class StaffEventsState {
  const StaffEventsState({
    this.loading = false,
    this.result,
    this.pending,
    this.unconfirmed,
    this.notice,
    this.noticeAction,
    this.fieldErrors = const {},
  });

  final bool loading;
  final AccessRead<StaffEvents>? result;
  final ContentAction? pending;
  final ContentAction? unconfirmed;
  final ContentNotice? notice;
  final ContentAction? noticeAction;
  final Map<String, String> fieldErrors;

  bool get busy => pending != null;
  StaffEvents? get value => switch (result) {
    AccessReadOk<StaffEvents>(:final value) => value,
    _ => null,
  };

  StaffEventsState copyWith({
    bool? loading,
    AccessRead<StaffEvents>? result,
    ContentAction? pending,
    bool clearPending = false,
    ContentAction? unconfirmed,
    bool clearUnconfirmed = false,
    ContentNotice? notice,
    ContentAction? noticeAction,
    bool clearNotice = false,
    Map<String, String>? fieldErrors,
  }) => StaffEventsState(
    loading: loading ?? this.loading,
    result: result ?? this.result,
    pending: clearPending ? null : (pending ?? this.pending),
    unconfirmed: clearUnconfirmed ? null : (unconfirmed ?? this.unconfirmed),
    notice: clearNotice ? null : (notice ?? this.notice),
    noticeAction: clearNotice ? null : (noticeAction ?? this.noticeAction),
    fieldErrors: fieldErrors ?? this.fieldErrors,
  );
}

/// Staff web, Media, Pastor and Admin: every event and the lifecycle
/// commands (1.4 envelope) with honest request states. An event shows as
/// published only after the server confirmed it.
class StaffEventsController extends Notifier<StaffEventsState> {
  int _epoch = 0;

  @override
  StaffEventsState build() {
    ref.watch(accountGenerationProvider);
    _epoch++;
    final epoch = _epoch;
    Future.microtask(() => _reload(epoch));
    return const StaffEventsState(loading: true);
  }

  bool _current(int epoch) => ref.mounted && epoch == _epoch;

  Future<void> reload() => _reload(_epoch);

  Future<void> _reload(int epoch) async {
    if (!_current(epoch)) return;
    state = state.copyWith(loading: true);
    final r = await ref.read(contentRepositoryProvider).fetchStaffEvents();
    if (!_current(epoch)) return;
    // A denial or failure drops every event from the screen; a command still
    // in flight stays pending so it cannot be sent twice.
    state = StaffEventsState(
      result: r,
      pending: state.pending,
      unconfirmed: state.unconfirmed,
      notice: state.notice,
      noticeAction: state.noticeAction,
      fieldErrors: state.fieldErrors,
    );
    if (r is AccessReadDenied<StaffEvents>) noteProtectedDenial(ref);
  }

  void dismissNotice() =>
      state = state.copyWith(clearNotice: true, fieldErrors: const {});

  /// Field errors of a refused input no longer match what is typed.
  void clearFieldErrors() {
    if (state.fieldErrors.isNotEmpty) {
      state = state.copyWith(fieldErrors: const {});
    }
  }

  /// Resends the unconfirmed command unchanged (same request_id and body).
  Future<void> checkAgain() async {
    final u = state.unconfirmed;
    if (u == null || state.busy) return;
    await _dispatch(u);
  }

  Future<void> create(EventInput input) => _send(
    ContentCommands.createEvent,
    const Optional.of(null),
    input.toPayload(),
    input.title.trim(),
  );

  Future<void> save(StaffEvent event, EventInput input) => _send(
    ContentCommands.saveEvent,
    Optional.of(event.revision),
    input.toPayload(eventId: event.eventId),
    input.title.trim(),
  );

  Future<void> publish(StaffEvent event) =>
      _lifecycle(ContentCommands.publishEvent, event);

  Future<void> withdraw(StaffEvent event) =>
      _lifecycle(ContentCommands.withdrawEvent, event);

  Future<void> archive(StaffEvent event) =>
      _lifecycle(ContentCommands.archiveEvent, event);

  Future<void> _lifecycle(String command, StaffEvent event) => _send(
    command,
    Optional.of(event.revision),
    {'event_id': event.eventId},
    event.current.title,
  );

  Future<void> _send(
    String command,
    Optional<int> expected,
    Map<String, Object?> payload,
    String subject,
  ) async {
    if (state.busy) return;
    final u = state.unconfirmed?.request;
    // An input whose outcome was never learned is resent under its original
    // request id; anything else is a new request.
    final same =
        u != null &&
        u.command == command &&
        u.expectedRevision.value == expected.value &&
        jsonEncode(u.payload) == jsonEncode(payload);
    await _dispatch(
      ContentAction(
        request: CommandRequest(
          command: command,
          requestId: same ? u.requestId : ref.read(requestIdsProvider).next(),
          expectedRevision: expected,
          payload: payload,
        ),
        subject: subject,
      ),
    );
  }

  static ContentNotice _success(String command) => switch (command) {
    ContentCommands.createEvent => ContentNotice.created,
    ContentCommands.saveEvent => ContentNotice.saved,
    ContentCommands.publishEvent => ContentNotice.published,
    ContentCommands.withdrawEvent => ContentNotice.withdrawn,
    _ => ContentNotice.archived,
  };

  static ContentNotice _refusal(CommandError error) {
    final f = error.fieldErrors;
    return switch (error.code) {
      ErrorCode.validationFailed when f['event_id'] == 'nothing_to_publish' =>
        ContentNotice.nothingToPublish,
      ErrorCode.validationFailed when f['event_id'] == 'not_published' =>
        ContentNotice.notPublished,
      ErrorCode.validationFailed when f['event_id'] == 'archived' =>
        ContentNotice.alreadyArchived,
      ErrorCode.validationFailed => ContentNotice.invalid,
      ErrorCode.conflict => ContentNotice.changedElsewhere,
      ErrorCode.forbidden => ContentNotice.notAllowed,
      ErrorCode.unauthenticated => ContentNotice.signInAgain,
      ErrorCode.notFound => ContentNotice.notFound,
      ErrorCode.unavailable => ContentNotice.notAvailable,
      _ => ContentNotice.refused,
    };
  }

  Future<void> _dispatch(ContentAction action) async {
    final epoch = _epoch;
    state = state.copyWith(
      pending: action,
      clearNotice: true,
      fieldErrors: const {},
    );
    final outcome = await ref
        .read(commandGatewayProvider)
        .send(ContentCommands.function, action.request);
    if (!_current(epoch)) return;
    switch (outcome) {
      case CommandConfirmed():
        state = state.copyWith(
          clearPending: true,
          clearUnconfirmed: true,
          notice: _success(action.command),
          noticeAction: action,
        );
        await _reload(epoch);
      case CommandRefused(:final error):
        final notice = _refusal(error);
        state = state.copyWith(
          clearPending: true,
          clearUnconfirmed: true,
          notice: notice,
          noticeAction: action,
          fieldErrors: error.fieldErrors,
        );
        if (notice == ContentNotice.notAllowed ||
            notice == ContentNotice.signInAgain) {
          noteProtectedDenial(ref);
        }
        // A field error keeps the form as typed; anything else shows the
        // server's current events.
        if (notice != ContentNotice.invalid) await _reload(epoch);
      case CommandUnknownOutcome():
        state = state.copyWith(
          clearPending: true,
          unconfirmed: action,
          notice: ContentNotice.unconfirmed,
          noticeAction: action,
        );
      case CommandNotSent():
        state = state.copyWith(
          clearPending: true,
          notice: ContentNotice.notSent,
          noticeAction: action,
        );
    }
  }
}

final staffEventsProvider =
    NotifierProvider<StaffEventsController, StaffEventsState>(
      StaffEventsController.new,
    );

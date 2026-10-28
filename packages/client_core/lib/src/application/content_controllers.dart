import 'dart:async';
import 'dart:convert';

import 'package:church_contracts/church_contracts.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/access_grants.dart';
import '../domain/commands.dart';
import '../domain/content_banners.dart'
    show ContentPurposes, FileSyncDone, FileSyncOutcome;
import '../domain/content_events.dart';
import '../domain/public_content_cache.dart';
import 'access_controllers.dart' show noteProtectedDenial;
import 'banner_controllers.dart'
    show BannerImageUpload, ContentImageUploadController;
import 'providers.dart';

// Story 6.1: the public calendar (everyone, signed in or not) and the
// editors' Events screen on staff web. Public reads hold only the published
// projection, in memory; the editors' read and its commands are protected
// state scoped to the account generation (AD-13). The server checks every
// read and command.

/// One public read and whether it is under way.
class PublicReadState<T> {
  const PublicReadState({
    this.loading = false,
    this.result,
    this.asOf,
    this.refreshFailed,
    this.savedAt,
    this.offlineSnapshot = false,
  });

  final bool loading;

  /// The last answer (failures included); null before the first. A failed
  /// refresh keeps an earlier good answer here (see [refreshFailed]).
  final AccessRead<T>? result;

  /// When the good answer in [result] arrived.
  final DateTime? asOf;

  /// Set when the latest refresh failed while an earlier good answer is
  /// still shown: the screen says the data is from [asOf].
  final AccessReadFailed<T>? refreshFailed;

  /// When the current public list snapshot was last committed locally.
  final DateTime? savedAt;

  /// True when [result] is the allowlisted local snapshot, never a fresh read.
  final bool offlineSnapshot;

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

  bool get supportsOfflineSnapshot => false;

  Future<DateTime?> saveOfflineSnapshot(T value) async => null;

  Future<PublicContentSnapshot<T>?> readOfflineSnapshot() async => null;

  Future<void> onFreshRead(T value) async {}

  @override
  PublicReadState<T> build() {
    ref.watch(accountGenerationProvider);
    ref.listen(publicContentReconnectsProvider, (previous, next) {
      if (next.hasValue) reload();
    });
    _epoch++;
    final epoch = _epoch;
    Future.microtask(() => _reload(epoch));
    return PublicReadState<T>(loading: true);
  }

  Future<void> reload() {
    _epoch++;
    return _reload(_epoch);
  }

  Future<void> _reload(int epoch) async {
    if (!ref.mounted || epoch != _epoch) return;
    state = PublicReadState<T>(
      loading: true,
      result: state.result,
      asOf: state.asOf,
      refreshFailed: state.refreshFailed,
      savedAt: state.savedAt,
      offlineSnapshot: state.offlineSnapshot,
    );
    final r = await fetch();
    if (!ref.mounted || epoch != _epoch) return;
    if (r is AccessReadOk<T>) {
      try {
        await onFreshRead(r.value);
      } catch (_) {
        // A cache maintenance failure cannot replace a successful server read.
      }
      if (!ref.mounted || epoch != _epoch) return;
      final savedAt = supportsOfflineSnapshot
          ? await saveOfflineSnapshot(r.value)
          : null;
      if (!ref.mounted || epoch != _epoch) return;
      state = PublicReadState<T>(
        result: r,
        asOf: DateTime.now(),
        savedAt: savedAt,
      );
      return;
    }
    if (r is AccessReadFailed<T> && supportsOfflineSnapshot) {
      final snapshot = await readOfflineSnapshot();
      if (!ref.mounted || epoch != _epoch) return;
      if (snapshot != null) {
        state = PublicReadState<T>(
          result: AccessReadOk<T>(snapshot.value),
          asOf: snapshot.savedAt,
          refreshFailed: r,
          savedAt: snapshot.savedAt,
          offlineSnapshot: true,
        );
        return;
      }
    }
    // A failed refresh keeps what is on screen and says so (a denial or a
    // first failure replaces it).
    if (r is AccessReadFailed<T> && state.result is AccessReadOk<T>) {
      state = PublicReadState<T>(
        result: state.result,
        asOf: state.asOf,
        refreshFailed: r,
        savedAt: state.savedAt,
        offlineSnapshot: state.offlineSnapshot,
      );
      return;
    }
    state = PublicReadState<T>(
      result: r,
      asOf: r is AccessReadOk<T> ? DateTime.now() : null,
    );
  }
}

/// `api.content_public_events`: the published, not yet ended events.
class PublicEventsController extends PublicReadController<PublicEvents> {
  @override
  Future<AccessRead<PublicEvents>> fetch() =>
      ref.read(contentRepositoryProvider).fetchPublicEvents();

  @override
  bool get supportsOfflineSnapshot => true;

  @override
  Future<DateTime?> saveOfflineSnapshot(PublicEvents value) async {
    final eligible = PublicEvents(
      events: value.events.where((event) => event.offlineAllowed).toList(),
      truncated: value.truncated,
    );
    final outcome = await ref
        .read(publicContentCacheProvider)
        .writeRead(PublicContentCacheKeys.calendar, eligible);
    return outcome is PublicContentCacheSaved ? outcome.savedAt : null;
  }

  @override
  Future<PublicContentSnapshot<PublicEvents>?> readOfflineSnapshot() =>
      ref.read(publicContentCacheProvider).readEvents();
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

  /// Story 6.11: the organisers were changed.
  organisersSet,

  /// Story 6.11: only an Admin or one of the event's organisers changes them.
  organisersNotAllowed,

  /// Story 6.11: the list named someone who no longer edits events (or too
  /// many people).
  organisersInvalid,
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
    this.syncing = false,
    this.sync,
  });

  final bool loading;
  final AccessRead<StaffEvents>? result;
  final ContentAction? pending;
  final ContentAction? unconfirmed;
  final ContentNotice? notice;
  final ContentAction? noticeAction;
  final Map<String, String> fieldErrors;

  /// Story 6.11: a public-file sync (posters) is under way.
  final bool syncing;

  /// The last sync's outcome (null before the first).
  final FileSyncOutcome? sync;

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
    bool? syncing,
    FileSyncOutcome? sync,
  }) => StaffEventsState(
    loading: loading ?? this.loading,
    result: result ?? this.result,
    pending: clearPending ? null : (pending ?? this.pending),
    unconfirmed: clearUnconfirmed ? null : (unconfirmed ?? this.unconfirmed),
    notice: clearNotice ? null : (notice ?? this.notice),
    noticeAction: clearNotice ? null : (noticeAction ?? this.noticeAction),
    fieldErrors: fieldErrors ?? this.fieldErrors,
    syncing: syncing ?? this.syncing,
    sync: sync ?? this.sync,
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
      syncing: state.syncing,
      sync: state.sync,
    );
    if (r is AccessReadDenied<StaffEvents>) noteProtectedDenial(ref);
  }

  /// Story 6.11: asks the server to place published posters and remove
  /// withdrawn or ended ones (the Content file sync, every kind at once).
  /// The list is read again only when the sync changed something.
  Future<void> sync() => _sync(_epoch, alwaysReload: false);

  Future<void> _sync(int epoch, {required bool alwaysReload}) async {
    if (!_current(epoch) || state.syncing) return;
    state = state.copyWith(syncing: true);
    final outcome = await ref.read(bannerRepositoryProvider).syncFiles();
    if (!_current(epoch)) return;
    state = state.copyWith(syncing: false, sync: outcome);
    final changed =
        outcome is FileSyncDone && (outcome.placed > 0 || outcome.removed > 0);
    if (alwaysReload || changed) await _reload(epoch);
  }

  /// Commands after which the public files change.
  static const _syncAfter = {
    ContentCommands.publishEvent,
    ContentCommands.withdrawEvent,
    ContentCommands.archiveEvent,
  };

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

  /// Story 6.11: sets the event's whole organiser list (an Admin or one of
  /// its organisers; the server checks).
  Future<void> setOrganisers(StaffEvent event, List<String> memberIds) => _send(
    ContentCommands.setEventOrganisers,
    Optional.of(event.revision),
    {'event_id': event.eventId, 'organiser_ids': memberIds},
    event.current.title,
  );

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
    ContentCommands.setEventOrganisers => ContentNotice.organisersSet,
    _ => ContentNotice.archived,
  };

  static ContentNotice _refusal(String command, CommandError error) {
    final f = error.fieldErrors;
    return switch (error.code) {
      ErrorCode.forbidden when command == ContentCommands.setEventOrganisers =>
        ContentNotice.organisersNotAllowed,
      ErrorCode.validationFailed
          when command == ContentCommands.setEventOrganisers &&
              f.containsKey('organiser_ids') =>
        ContentNotice.organisersInvalid,
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
        if (_syncAfter.contains(action.command)) {
          await _sync(epoch, alwaysReload: true);
        } else {
          await _reload(epoch);
        }
      case CommandRefused(:final error):
        final notice = _refusal(action.command, error);
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

// ---------------------------------------------------------------------------
// Story 6.11: RSVP (members), the organisers' names and the poster upload
// ---------------------------------------------------------------------------

/// What the event's RSVP section tells the member after an answer.
enum RsvpNotice {
  going,
  cancelled,
  full,

  /// The event has started.
  closed,

  /// The event takes no RSVPs (any more).
  off,

  /// The event is no longer on the calendar.
  notPublic,
  notGoing,

  /// Only approved church members can RSVP.
  membersOnly,
  signInAgain,
  notAvailable,
  refused,

  /// The outcome is unknown: check again with the same request.
  unconfirmed,
  notSent,
}

/// The member's own RSVP to one event and the answer in flight.
class EventRsvpState {
  const EventRsvpState({
    this.loading = false,
    this.result,
    this.pending,
    this.unconfirmed,
    this.notice,
  });

  final bool loading;

  /// The member's own RSVP (null before the first answer).
  final AccessRead<MyEventRsvp>? result;
  final CommandRequest? pending;
  final CommandRequest? unconfirmed;
  final RsvpNotice? notice;

  bool get busy => pending != null;
  MyEventRsvp? get value => switch (result) {
    AccessReadOk<MyEventRsvp>(:final value) => value,
    _ => null,
  };

  EventRsvpState copyWith({
    bool? loading,
    AccessRead<MyEventRsvp>? result,
    CommandRequest? pending,
    bool clearPending = false,
    CommandRequest? unconfirmed,
    bool clearUnconfirmed = false,
    RsvpNotice? notice,
    bool clearNotice = false,
  }) => EventRsvpState(
    loading: loading ?? this.loading,
    result: result ?? this.result,
    pending: clearPending ? null : (pending ?? this.pending),
    unconfirmed: clearUnconfirmed ? null : (unconfirmed ?? this.unconfirmed),
    notice: clearNotice ? null : (notice ?? this.notice),
  );
}

/// Story 6.11, mobile: a member's RSVP to one event (read and the two member
/// commands, 1.4 envelope). Protected state, in memory only and scoped to the
/// account generation; the server decides who may answer and whether a place
/// is left. After any answer the public event (its counts) is read again.
class EventRsvpController extends Notifier<EventRsvpState> {
  EventRsvpController(this.eventId);

  final String eventId;
  int _epoch = 0;

  @override
  EventRsvpState build() {
    ref.watch(accountGenerationProvider);
    _epoch++;
    final epoch = _epoch;
    Future.microtask(() => _reload(epoch));
    return const EventRsvpState(loading: true);
  }

  bool _current(int epoch) => ref.mounted && epoch == _epoch;

  Future<void> reload() => _reload(_epoch);

  Future<void> _reload(int epoch) async {
    if (!_current(epoch)) return;
    state = state.copyWith(loading: true);
    final r = await ref
        .read(contentRepositoryProvider)
        .fetchMyEventRsvp(eventId);
    if (!_current(epoch)) return;
    state = state.copyWith(loading: false, result: r);
  }

  /// "I'm going".
  Future<void> going() => _send(ContentCommands.rsvpEvent);

  /// "Cancel RSVP": the place is free again.
  Future<void> cancel() => _send(ContentCommands.cancelRsvp);

  /// Resends the unconfirmed answer unchanged (same request_id and body).
  Future<void> checkAgain() async {
    final u = state.unconfirmed;
    if (u == null || state.busy) return;
    await _dispatch(u);
  }

  void dismissNotice() => state = state.copyWith(clearNotice: true);

  Future<void> _send(String command) async {
    if (state.busy) return;
    final u = state.unconfirmed;
    await _dispatch(
      CommandRequest(
        command: command,
        requestId: u != null && u.command == command
            ? u.requestId
            : ref.read(requestIdsProvider).next(),
        expectedRevision: const Optional.of(null),
        payload: {'event_id': eventId},
      ),
    );
  }

  static RsvpNotice _refusal(CommandError error) {
    final f = error.fieldErrors['event_id'];
    return switch (error.code) {
      ErrorCode.validationFailed when f == 'full' => RsvpNotice.full,
      ErrorCode.validationFailed when f == 'rsvp_closed' => RsvpNotice.closed,
      ErrorCode.validationFailed when f == 'rsvp_off' => RsvpNotice.off,
      ErrorCode.validationFailed when f == 'not_public' => RsvpNotice.notPublic,
      ErrorCode.validationFailed when f == 'not_going' => RsvpNotice.notGoing,
      ErrorCode.forbidden => RsvpNotice.membersOnly,
      ErrorCode.unauthenticated => RsvpNotice.signInAgain,
      ErrorCode.unavailable => RsvpNotice.notAvailable,
      _ => RsvpNotice.refused,
    };
  }

  Future<void> _dispatch(CommandRequest request) async {
    final epoch = _epoch;
    state = state.copyWith(pending: request, clearNotice: true);
    final outcome = await ref
        .read(commandGatewayProvider)
        .send(ContentCommands.function, request);
    if (!_current(epoch)) return;
    switch (outcome) {
      case CommandConfirmed():
        state = state.copyWith(
          clearPending: true,
          clearUnconfirmed: true,
          notice: request.command == ContentCommands.rsvpEvent
              ? RsvpNotice.going
              : RsvpNotice.cancelled,
        );
        await _refresh(epoch);
      case CommandRefused(:final error):
        final notice = _refusal(error);
        state = state.copyWith(
          clearPending: true,
          clearUnconfirmed: true,
          notice: notice,
        );
        if (notice == RsvpNotice.membersOnly ||
            notice == RsvpNotice.signInAgain) {
          noteProtectedDenial(ref);
        }
        await _refresh(epoch);
      case CommandUnknownOutcome():
        state = state.copyWith(
          clearPending: true,
          unconfirmed: request,
          notice: RsvpNotice.unconfirmed,
        );
      case CommandNotSent():
        state = state.copyWith(clearPending: true, notice: RsvpNotice.notSent);
    }
  }

  /// The counts changed (or another member took the last place): the public
  /// event and the member's own RSVP are read again.
  Future<void> _refresh(int epoch) async {
    if (!_current(epoch)) return;
    if (ref.exists(publicEventProvider(eventId))) {
      unawaited(ref.read(publicEventProvider(eventId).notifier).reload());
    }
    await _reload(epoch);
  }
}

final eventRsvpProvider = NotifierProvider.autoDispose
    .family<EventRsvpController, EventRsvpState, String>(
      EventRsvpController.new,
    );

/// Story 6.11, staff web: who is going to one event, for an Admin or one of
/// its organisers (anyone else is refused by the server). Asked when the
/// editor opens the list; in memory only.
final staffEventRsvpsProvider = FutureProvider.autoDispose
    .family<AccessRead<StaffEventRsvpsRead>, String>((ref, eventId) {
      ref.watch(accountGenerationProvider);
      return ref.read(contentRepositoryProvider).fetchStaffEventRsvps(eventId);
    });

/// Story 6.12, staff web: how many duties name an event, read again when the
/// event's revision moves (a publish, withdrawal or archive may flag them).
final eventDutyLinksProvider = FutureProvider.autoDispose
    .family<AccessRead<EventDutyLinks>, ({String eventId, int revision})>((
      ref,
      key,
    ) {
      ref.watch(accountGenerationProvider);
      return ref
          .read(contentRepositoryProvider)
          .fetchEventDutyLinks(key.eventId);
    });

/// Story 6.12, staff web: the published events a rota date may be linked to
/// (the public calendar's read; nothing is cached).
final linkableEventsProvider =
    FutureProvider.autoDispose<AccessRead<PublicEvents>>((ref) {
      ref.watch(accountGenerationProvider);
      return ref.read(contentRepositoryProvider).fetchPublicEvents();
    });

/// Story 6.12: the published event a duty is linked to, as the public
/// calendar shows it (`event: null` once it is no longer public).
final linkedEventProvider = FutureProvider.autoDispose
    .family<AccessRead<PublicEventRead>, String>((ref, eventId) {
      ref.watch(accountGenerationProvider);
      return ref.read(contentRepositoryProvider).fetchPublicEvent(eventId);
    });

/// Story 6.11: one saved event's poster upload (purpose `event_poster`).
/// Nothing is attached until the editor saves the draft with the uploaded
/// poster.
class EventPosterUploadController extends ContentImageUploadController {
  EventPosterUploadController(super.itemId);

  @override
  String get purpose => ContentPurposes.eventPoster;
}

final eventPosterUploadProvider = NotifierProvider.autoDispose
    .family<EventPosterUploadController, BannerImageUpload, String>(
      EventPosterUploadController.new,
    );

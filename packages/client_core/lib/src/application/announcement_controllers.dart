import 'package:church_contracts/church_contracts.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/access_grants.dart';
import '../domain/commands.dart';
import '../domain/content_announcements.dart';
import 'access_controllers.dart' show noteProtectedDenial;
import 'content_controllers.dart'
    show ContentAction, PublicReadController, PublicReadState;
import 'providers.dart';

// Story 6.13: announcements for everyone (Home, the list and one
// announcement, signed in or not) and the editors' Announcements screen on
// staff web. Public reads hold only the published projection, in memory; the
// editors' read and its commands are protected state scoped to the account
// generation (AD-13). The server checks every read and command.

/// `api.content_public_announcements`: the published announcements.
class PublicAnnouncementsController
    extends PublicReadController<PublicAnnouncements> {
  @override
  Future<AccessRead<PublicAnnouncements>> fetch() =>
      ref.read(announcementsRepositoryProvider).fetchPublicAnnouncements();
}

final publicAnnouncementsProvider =
    NotifierProvider<
      PublicAnnouncementsController,
      PublicReadState<PublicAnnouncements>
    >(PublicAnnouncementsController.new);

/// `api.content_public_announcement`: one announcement (null when it is not
/// published).
class PublicAnnouncementController
    extends PublicReadController<PublicAnnouncementRead> {
  PublicAnnouncementController(this.announcementId);

  final String announcementId;

  @override
  Future<AccessRead<PublicAnnouncementRead>> fetch() => ref
      .read(announcementsRepositoryProvider)
      .fetchPublicAnnouncement(announcementId);
}

final publicAnnouncementProvider = NotifierProvider.autoDispose
    .family<
      PublicAnnouncementController,
      PublicReadState<PublicAnnouncementRead>,
      String
    >(PublicAnnouncementController.new);

/// What the Announcements screen tells the editor after an action.
enum AnnouncementNotice {
  created,
  saved,

  /// Published without a notice.
  published,

  /// Published, and a notice queued for [StaffAnnouncementsState.notified]
  /// members.
  publishedAndNotified,
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

  /// Members were already notified of this version: nothing was published.
  alreadyNotified,

  /// More members than one notice may reach: nothing was published.
  tooManyRecipients,

  /// Notices are not available on this server yet (the church-time policy
  /// is not approved): nothing was published.
  notifyUnavailable,
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

class StaffAnnouncementsState {
  const StaffAnnouncementsState({
    this.loading = false,
    this.result,
    this.pending,
    this.unconfirmed,
    this.notice,
    this.noticeAction,
    this.notified,
    this.fieldErrors = const {},
  });

  final bool loading;
  final AccessRead<StaffAnnouncements>? result;
  final ContentAction? pending;
  final ContentAction? unconfirmed;
  final AnnouncementNotice? notice;
  final ContentAction? noticeAction;

  /// How many members the last confirmed publish queued a notice for.
  final int? notified;
  final Map<String, String> fieldErrors;

  bool get busy => pending != null;
  StaffAnnouncements? get value => switch (result) {
    AccessReadOk<StaffAnnouncements>(:final value) => value,
    _ => null,
  };

  StaffAnnouncementsState copyWith({
    bool? loading,
    AccessRead<StaffAnnouncements>? result,
    ContentAction? pending,
    bool clearPending = false,
    ContentAction? unconfirmed,
    bool clearUnconfirmed = false,
    AnnouncementNotice? notice,
    ContentAction? noticeAction,
    int? notified,
    bool clearNotice = false,
    Map<String, String>? fieldErrors,
  }) => StaffAnnouncementsState(
    loading: loading ?? this.loading,
    result: result ?? this.result,
    pending: clearPending ? null : (pending ?? this.pending),
    unconfirmed: clearUnconfirmed ? null : (unconfirmed ?? this.unconfirmed),
    notice: clearNotice ? null : (notice ?? this.notice),
    noticeAction: clearNotice ? null : (noticeAction ?? this.noticeAction),
    notified: clearNotice ? null : (notified ?? this.notified),
    fieldErrors: fieldErrors ?? this.fieldErrors,
  );
}

/// Staff web, Media, Pastor and Admin: every announcement and the lifecycle
/// commands (1.4 envelope) with honest request states. An announcement shows
/// as published, and members as notified, only after the server confirmed
/// it.
class StaffAnnouncementsController extends Notifier<StaffAnnouncementsState> {
  int _epoch = 0;

  @override
  StaffAnnouncementsState build() {
    ref.watch(accountGenerationProvider);
    _epoch++;
    final epoch = _epoch;
    Future.microtask(() => _reload(epoch));
    return const StaffAnnouncementsState(loading: true);
  }

  bool _current(int epoch) => ref.mounted && epoch == _epoch;

  Future<void> reload() => _reload(_epoch);

  Future<void> _reload(int epoch) async {
    if (!_current(epoch)) return;
    state = state.copyWith(loading: true);
    final r = await ref
        .read(announcementsRepositoryProvider)
        .fetchStaffAnnouncements();
    if (!_current(epoch)) return;
    // A denial or failure drops every announcement from the screen; a
    // command still in flight stays pending so it cannot be sent twice.
    state = StaffAnnouncementsState(
      result: r,
      pending: state.pending,
      unconfirmed: state.unconfirmed,
      notice: state.notice,
      noticeAction: state.noticeAction,
      notified: state.notified,
      fieldErrors: state.fieldErrors,
    );
    if (r is AccessReadDenied<StaffAnnouncements>) noteProtectedDenial(ref);
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

  Future<void> create(AnnouncementInput input) => _send(
    AnnouncementCommands.create,
    const Optional.of(null),
    input.toPayload(),
    input.title.trim(),
  );

  Future<void> save(StaffAnnouncement a, AnnouncementInput input) => _send(
    AnnouncementCommands.save,
    Optional.of(a.revision),
    input.toPayload(announcementId: a.announcementId),
    input.title.trim(),
  );

  /// Publishes [a]; with [notify] the server also queues the generic notice
  /// for every member it can reach now.
  Future<void> publish(StaffAnnouncement a, {required bool notify}) => _send(
    AnnouncementCommands.publish,
    Optional.of(a.revision),
    {'announcement_id': a.announcementId, 'notify': notify},
    (a.publishTarget ?? a.current).title,
  );

  Future<void> withdraw(StaffAnnouncement a) =>
      _lifecycle(AnnouncementCommands.withdraw, a);

  Future<void> archive(StaffAnnouncement a) =>
      _lifecycle(AnnouncementCommands.archive, a);

  Future<void> _lifecycle(String command, StaffAnnouncement a) => _send(
    command,
    Optional.of(a.revision),
    {'announcement_id': a.announcementId},
    a.current.title,
  );

  Future<void> _send(
    String command,
    Optional<int> expected,
    Map<String, Object?> payload,
    String subject,
  ) async {
    if (state.busy) return;
    await _dispatch(
      ContentAction(
        request: resendOrNewRequest(
          unconfirmed: state.unconfirmed?.request,
          command: command,
          expected: expected,
          payload: payload,
          ids: ref.read(requestIdsProvider),
        ),
        subject: subject,
      ),
    );
  }

  static bool _notifies(ContentAction a) =>
      a.command == AnnouncementCommands.publish &&
      a.request.payload['notify'] == true;

  static AnnouncementNotice _success(ContentAction a) => switch (a.command) {
    AnnouncementCommands.create => AnnouncementNotice.created,
    AnnouncementCommands.save => AnnouncementNotice.saved,
    AnnouncementCommands.publish when _notifies(a) =>
      AnnouncementNotice.publishedAndNotified,
    AnnouncementCommands.publish => AnnouncementNotice.published,
    AnnouncementCommands.withdraw => AnnouncementNotice.withdrawn,
    _ => AnnouncementNotice.archived,
  };

  static AnnouncementNotice _refusal(ContentAction a, CommandError error) {
    final f = error.fieldErrors;
    return switch (error.code) {
      ErrorCode.validationFailed when f['notify'] == 'already_notified' =>
        AnnouncementNotice.alreadyNotified,
      ErrorCode.validationFailed when f['notify'] == 'too_many_recipients' =>
        AnnouncementNotice.tooManyRecipients,
      ErrorCode.validationFailed
          when f['announcement_id'] == 'nothing_to_publish' =>
        AnnouncementNotice.nothingToPublish,
      ErrorCode.validationFailed when f['announcement_id'] == 'not_published' =>
        AnnouncementNotice.notPublished,
      ErrorCode.validationFailed when f['announcement_id'] == 'archived' =>
        AnnouncementNotice.alreadyArchived,
      ErrorCode.validationFailed => AnnouncementNotice.invalid,
      ErrorCode.conflict => AnnouncementNotice.changedElsewhere,
      ErrorCode.forbidden => AnnouncementNotice.notAllowed,
      ErrorCode.unauthenticated => AnnouncementNotice.signInAgain,
      ErrorCode.notFound => AnnouncementNotice.notFound,
      ErrorCode.unavailable when _notifies(a) =>
        AnnouncementNotice.notifyUnavailable,
      ErrorCode.unavailable => AnnouncementNotice.notAvailable,
      _ => AnnouncementNotice.refused,
    };
  }

  /// The `notified` count of a confirmed publish (null when absent).
  static int? _notifiedOf(Object? data) => switch (data) {
    {'notified': final int n} when n >= 0 => n,
    _ => null,
  };

  Future<void> _dispatch(ContentAction action) async {
    final epoch = _epoch;
    state = state.copyWith(
      pending: action,
      clearNotice: true,
      fieldErrors: const {},
    );
    final outcome = await ref
        .read(commandGatewayProvider)
        .send(AnnouncementCommands.function, action.request);
    if (!_current(epoch)) return;
    switch (outcome) {
      case CommandConfirmed(:final success):
        state = state.copyWith(
          clearPending: true,
          clearUnconfirmed: true,
          notice: _success(action),
          noticeAction: action,
          notified: _notifiedOf(success.data),
        );
        await _reload(epoch);
      case CommandRefused(:final error):
        final notice = _refusal(action, error);
        state = state.copyWith(
          clearPending: true,
          clearUnconfirmed: true,
          notice: notice,
          noticeAction: action,
          fieldErrors: error.fieldErrors,
        );
        if (notice == AnnouncementNotice.notAllowed ||
            notice == AnnouncementNotice.signInAgain) {
          noteProtectedDenial(ref);
        }
        // A field error keeps the form as typed; anything else shows the
        // server's current announcements.
        if (notice != AnnouncementNotice.invalid) await _reload(epoch);
      case CommandUnknownOutcome():
        state = state.copyWith(
          clearPending: true,
          unconfirmed: action,
          notice: AnnouncementNotice.unconfirmed,
          noticeAction: action,
        );
      case CommandNotSent():
        state = state.copyWith(
          clearPending: true,
          notice: AnnouncementNotice.notSent,
          noticeAction: action,
        );
    }
  }
}

final staffAnnouncementsProvider =
    NotifierProvider<StaffAnnouncementsController, StaffAnnouncementsState>(
      StaffAnnouncementsController.new,
    );

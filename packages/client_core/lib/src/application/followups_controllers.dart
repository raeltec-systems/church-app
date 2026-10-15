import 'dart:convert';

import 'package:church_contracts/church_contracts.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/access_grants.dart';
import '../domain/commands.dart';
import '../domain/followups.dart';
import 'access_controllers.dart' show noteProtectedDenial;
import 'providers.dart';

/// What a follow-ups screen tells the person after an action.
enum FollowUpNotice {
  created,
  updated,
  reassigned,

  /// Story 4.12: tasks of a member who left were handed over.
  handoverContinued,

  /// Story 4.12: nobody the app can reach may take what is left; it stays
  /// listed for handover.
  handoverNoneMoved,

  /// Changed in another tab or by someone else: reloaded.
  changedElsewhere,

  /// The task is Done or Closed: it can no longer change.
  finished,

  /// A task for that source and purpose already exists.
  taskExists,
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
class FollowUpAction {
  const FollowUpAction({required this.request, required this.subject});

  final CommandRequest request;

  /// What was acted on (display only).
  final String subject;

  String get command => request.command;
}

class FollowUpsState<T> {
  const FollowUpsState({
    this.loading = false,
    this.result,
    this.pending,
    this.unconfirmed,
    this.notice,
    this.noticeAction,
    this.fieldErrors = const {},
  });

  final bool loading;

  /// The last read (denials and failures included).
  final AccessRead<T>? result;
  final FollowUpAction? pending;
  final FollowUpAction? unconfirmed;
  final FollowUpNotice? notice;
  final FollowUpAction? noticeAction;
  final Map<String, String> fieldErrors;

  bool get busy => pending != null;
  T? get value => switch (result) {
    AccessReadOk<T>(:final value) => value,
    _ => null,
  };

  FollowUpsState<T> copyWith({
    bool? loading,
    AccessRead<T>? result,
    FollowUpAction? pending,
    bool clearPending = false,
    FollowUpAction? unconfirmed,
    bool clearUnconfirmed = false,
    FollowUpNotice? notice,
    FollowUpAction? noticeAction,
    bool clearNotice = false,
    Map<String, String>? fieldErrors,
  }) => FollowUpsState<T>(
    loading: loading ?? this.loading,
    result: result ?? this.result,
    pending: clearPending ? null : (pending ?? this.pending),
    unconfirmed: clearUnconfirmed ? null : (unconfirmed ?? this.unconfirmed),
    notice: clearNotice ? null : (notice ?? this.notice),
    noticeAction: clearNotice ? null : (noticeAction ?? this.noticeAction),
    fieldErrors: fieldErrors ?? this.fieldErrors,
  );
}

/// Story 4.6: one follow-ups read and its commands (1.4 envelope) with
/// honest request states: a change shows only once the server confirmed it;
/// an unknown outcome stays "Not sent yet" and is checked again under the
/// same request id. Protected state lives in memory only, scoped to the
/// account generation. The server rechecks live access and scope every time.
abstract class FollowUpsController<T> extends Notifier<FollowUpsState<T>> {
  int _epoch = 0;

  Future<AccessRead<T>> fetch();

  @override
  FollowUpsState<T> build() {
    ref.watch(accountGenerationProvider);
    _epoch++;
    final epoch = _epoch;
    Future.microtask(() => _reload(epoch));
    return FollowUpsState<T>(loading: true);
  }

  bool _current(int epoch) => ref.mounted && epoch == _epoch;

  Future<void> reload() => _reload(_epoch);

  Future<void> _reload(int epoch) async {
    if (!_current(epoch)) return;
    state = state.copyWith(loading: true);
    final r = await fetch();
    if (!_current(epoch)) return;
    // A denial or failure drops everything protected from the screen.
    state = FollowUpsState<T>(
      result: r,
      notice: state.notice,
      noticeAction: state.noticeAction,
      unconfirmed: state.unconfirmed,
      fieldErrors: state.fieldErrors,
    );
    if (r is AccessReadDenied<T>) noteProtectedDenial(ref);
  }

  void dismissNotice() =>
      state = state.copyWith(clearNotice: true, fieldErrors: const {});

  /// Resends the unconfirmed command unchanged (same request_id and body).
  Future<void> checkAgain() async {
    final u = state.unconfirmed;
    if (u == null || state.busy) return;
    await _dispatch(u);
  }

  Future<void> send(
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
      FollowUpAction(
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

  /// Sends [update] for [task] at the revision the reader saw.
  Future<void> update(
    FollowUpRouting task,
    FollowUpUpdate update,
    String subject,
  ) => send(
    FollowUpCommands.updateTask,
    Optional.of(task.revision),
    update.toPayload(task.taskId),
    subject,
  );

  /// Reassigns [task] to a new owner and/or supervisor.
  Future<void> reassign(
    FollowUpRouting task, {
    String? ownerMemberId,
    String? supervisorMemberId,
    required String subject,
  }) => send(FollowUpCommands.reassign, Optional.of(task.revision), {
    'task_id': task.taskId,
    'owner_member_id': ?ownerMemberId,
    'supervisor_member_id': ?supervisorMemberId,
  }, subject);

  /// After a confirmed change: other reads that show the task ask again.
  void onConfirmed() {}

  static FollowUpNotice _success(FollowUpAction action, Object? data) =>
      switch (action.command) {
        FollowUpCommands.createTask => FollowUpNotice.created,
        FollowUpCommands.reassign => FollowUpNotice.reassigned,
        // Review N11: only say "handed over" when something moved.
        FollowUpCommands.completeHandover =>
          data is Map && data['handed_over'] is int && data['handed_over'] > 0
              ? FollowUpNotice.handoverContinued
              : FollowUpNotice.handoverNoneMoved,
        _ => FollowUpNotice.updated,
      };

  static FollowUpNotice _refusal(CommandError error) {
    final f = error.fieldErrors;
    return switch (error.code) {
      ErrorCode.conflict when f['task_id'] == 'finished' =>
        FollowUpNotice.finished,
      ErrorCode.conflict when f['purpose'] == 'task_exists' =>
        FollowUpNotice.taskExists,
      ErrorCode.conflict => FollowUpNotice.changedElsewhere,
      ErrorCode.validationFailed => FollowUpNotice.invalid,
      ErrorCode.forbidden => FollowUpNotice.notAllowed,
      ErrorCode.unauthenticated => FollowUpNotice.signInAgain,
      ErrorCode.notFound => FollowUpNotice.notFound,
      ErrorCode.unavailable => FollowUpNotice.notAvailable,
      _ => FollowUpNotice.refused,
    };
  }

  Future<void> _dispatch(FollowUpAction action) async {
    final epoch = _epoch;
    state = state.copyWith(
      pending: action,
      clearNotice: true,
      fieldErrors: const {},
    );
    final outcome = await ref
        .read(commandGatewayProvider)
        .send(FollowUpCommands.function, action.request);
    if (!_current(epoch)) return;
    switch (outcome) {
      case CommandConfirmed(:final success):
        state = state.copyWith(
          clearPending: true,
          clearUnconfirmed: true,
          notice: _success(action, success.data),
          noticeAction: action,
        );
        onConfirmed();
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
        if (notice == FollowUpNotice.notAllowed ||
            notice == FollowUpNotice.signInAgain) {
          noteProtectedDenial(ref);
        }
        if (notice != FollowUpNotice.invalid) await _reload(epoch);
      case CommandUnknownOutcome():
        state = state.copyWith(
          clearPending: true,
          unconfirmed: action,
          notice: FollowUpNotice.unconfirmed,
          noticeAction: action,
        );
      case CommandNotSent():
        state = state.copyWith(
          clearPending: true,
          notice: FollowUpNotice.notSent,
          noticeAction: action,
        );
    }
  }
}

/// My follow-ups (mobile Home and list, staff web): every owner's own tasks.
class MyFollowUpsController extends FollowUpsController<MyFollowUps> {
  @override
  Future<AccessRead<MyFollowUps>> fetch() =>
      ref.read(followUpsRepositoryProvider).fetchMyTasks();
}

final myFollowUpsProvider =
    NotifierProvider<MyFollowUpsController, FollowUpsState<MyFollowUps>>(
      MyFollowUpsController.new,
    );

/// One task with its activity and private notes (owner, scope holders) or
/// routing metadata only (Admin).
class FollowUpTaskController extends FollowUpsController<FollowUpDetail> {
  FollowUpTaskController(this.taskId);

  final String taskId;

  @override
  Future<AccessRead<FollowUpDetail>> fetch() =>
      ref.read(followUpsRepositoryProvider).fetchTask(taskId);

  // The lists under this screen (My follow-ups, supervision) ask again.
  @override
  void onConfirmed() {
    ref.invalidate(myFollowUpsProvider);
    ref.invalidate(followUpSupervisionProvider);
  }
}

final followUpTaskProvider = NotifierProvider.autoDispose
    .family<FollowUpTaskController, FollowUpsState<FollowUpDetail>, String>(
      FollowUpTaskController.new,
    );

/// Staff web: the tasks in the scopes the caller holds; create SYNTHETIC
/// tasks, record updates for owners, reassign.
class FollowUpSupervisionController
    extends FollowUpsController<FollowUpSupervision> {
  @override
  Future<AccessRead<FollowUpSupervision>> fetch() =>
      ref.read(followUpsRepositoryProvider).fetchSupervision();

  Future<void> create(FollowUpDraft draft, String subject) => send(
    FollowUpCommands.createTask,
    const Optional.of(null),
    draft.toPayload(),
    subject,
  );
}

final followUpSupervisionProvider =
    NotifierProvider<
      FollowUpSupervisionController,
      FollowUpsState<FollowUpSupervision>
    >(FollowUpSupervisionController.new);

/// Staff web, Admin: routing metadata of every task and reassignment.
class FollowUpRoutingController
    extends FollowUpsController<FollowUpAdminRouting> {
  @override
  Future<AccessRead<FollowUpAdminRouting>> fetch() =>
      ref.read(followUpsRepositoryProvider).fetchAdminRouting();

  /// Story 4.12 (review B1): hands over the next 100 tasks and supervisions
  /// that wait for someone in their group (expected revision null).
  Future<void> completeHandover(FollowUpHandoverWaiting w) => send(
    FollowUpCommands.completeHandover,
    const Optional.of(null),
    {'member_id': w.memberId},
    w.displayName ?? 'a former member',
  );
}

final followUpRoutingProvider =
    NotifierProvider<
      FollowUpRoutingController,
      FollowUpsState<FollowUpAdminRouting>
    >(FollowUpRoutingController.new);

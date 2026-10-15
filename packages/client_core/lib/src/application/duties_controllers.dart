import 'package:church_contracts/church_contracts.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/access_grants.dart';
import '../domain/commands.dart';
import '../domain/duties.dart';
import '../domain/duty_calendar.dart';
import 'access_controllers.dart' show noteProtectedDenial;
import 'providers.dart';

/// What a duties screen tells the person after an action.
enum DutyNotice {
  departmentCreated,
  memberAdded,
  staffAssigned,
  staffRemoved,
  published,
  accepted,
  declined,

  /// Story 4.2: a material change: the assignee is asked again.
  revised,

  /// Story 4.2: a notes-only change: the answer stands.
  notesUpdated,

  /// Story 4.2: the duty changed after this answer was sent (a stale
  /// revision); the field errors name what changed.
  superseded,

  /// Story 4.2: the duty or position was cancelled.
  dutyCancelled,

  /// Story 4.2: the edit changed nothing.
  unchanged,

  /// Changed in another tab or by someone else: reloaded.
  changedElsewhere,

  /// Story 4.3: a rota series was generated as drafts.
  seriesCreated,

  /// Story 4.3: a draft position was planned or cleared.
  draftAssigned,

  /// Story 4.3: a published position was given to someone.
  positionGiven,

  /// Story 4.3: Publish N draft slots succeeded.
  draftsPublished,

  /// Story 4.3: a this-and-future edit succeeded.
  seriesRevised,

  /// Story 4.3: an occurrence (or this and future) was cancelled.
  occurrenceCancelled,

  /// Story 4.3: the number of draft slots changed before publishing.
  draftCountChanged,

  /// Story 4.3: the chosen answer-by time has already passed for a duty.
  leadPassed,

  /// Story 4.3: a planned person can no longer serve.
  plannedUnavailable,

  /// Story 4.3: a draft edit (no one is asked yet).
  draftUpdated,

  /// Story 4.3: only the linked-event reference changed (no notice).
  referenceUpdated,

  /// Story 4.4: the person has another duty at that time; a reason is
  /// needed to assign them anyway.
  overlapNeedsReason,

  /// The duty was already answered.
  alreadyAnswered,

  /// Story 4.8: the member reminders of a duty (or a series) were set.
  remindersSet,

  /// Story 4.9: a contact attempt was recorded (and its follow-up task
  /// opened or updated).
  contactRecorded,

  /// Story 4.9: Confirmed by leader was recorded.
  leaderConfirmed,

  /// Story 4.9: a position was cancelled (or, the last one, its duty).
  positionCancelled,

  /// Story 4.9: a declined position is reassigned, not confirmed.
  confirmDeclined,

  /// Story 4.9: the position is already confirmed (no contact needed).
  alreadyConfirmed,

  /// Story 4.9 (review S2): the leader's own duty is answered in My duties.
  ownAssignment,

  /// Story 4.10: an outcome was recorded after the duty.
  outcomeRecorded,

  /// Story 4.10: an outcome was corrected (the earlier value is kept).
  outcomeCorrected,

  /// Story 4.10: someone recorded an outcome first; correct it instead.
  outcomeAlreadyRecorded,

  /// Story 4.10: No-show needs an acceptance (declined or never answered).
  outcomeNotAccepted,

  /// Story 4.10: the duty has not started; nothing to record yet.
  outcomeNotStarted,

  /// Story 4.10: a leader never records the outcome of their own duty.
  ownOutcome,

  /// Story 4.10 (review N2): the member was erased, left the church or is
  /// under deletion; no outcome is recorded about them.
  outcomeMemberGone,

  /// Story 4.11: an owner-review mismatch was marked reviewed.
  reviewCleared,

  /// Story 4.11: someone else marked the review first (reloaded).
  reviewAlreadyCleared,

  /// Story 4.12: a member was taken out of a department (their future duties
  /// there ended and were flagged for cover).
  memberRemoved,

  /// Story 4.12 (review N4): the removal was recorded but its notices could
  /// not be planned (the church time policy was unavailable).
  memberRemovedNoNotices,

  /// Story 4.12: a department's leader handover was marked done.
  handoverResolved,

  /// Story 4.12: the handover cannot be marked done until the department has
  /// a leader or deputy the app can reach.
  leaderRequired,

  /// Story 4.5: "Can't make it anymore" was recorded.
  withdrawn,

  /// Story 4.5: several dates were accepted together.
  bulkAccepted,

  /// Story 4.5: some selected dates changed or were answered; nothing was
  /// accepted.
  bulkChanged,

  /// The duty has started: it can no longer be answered here.
  started,

  /// Story 4.2 (leader): the duty has started, so it can no longer be
  /// changed.
  dutyStarted,

  /// A department with that name exists.
  nameTaken,

  /// The person is not (or no longer) a member of the department.
  notInDepartment,
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
class DutyAction {
  const DutyAction({
    required this.function,
    required this.request,
    required this.subject,
    this.ownerKind,
  });

  final String function;
  final CommandRequest request;

  /// What was acted on (display only).
  final String subject;

  /// Story 4.11 (review S3): who owns the member's duty or duties this
  /// answer is about (null when mixed or not a member's answer), so the
  /// notice names who sees the answer.
  final DutyOwnerKind? ownerKind;

  String get command => request.command;

  /// Story 4.5: the assignments this command answers (one, or every date
  /// of a bulk acceptance).
  List<String> get assignmentIds {
    final p = request.payload;
    final one = p['assignment_id'];
    final many = p['assignments'];
    return [
      if (one is String) one,
      if (many is List)
        for (final x in many)
          if (x is Map && x['assignment_id'] is String)
            x['assignment_id'] as String,
    ];
  }

  bool touches(String assignmentId) => assignmentIds.contains(assignmentId);
}

class DutiesState<T> {
  const DutiesState({
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
  final DutyAction? pending;
  final DutyAction? unconfirmed;
  final DutyNotice? notice;
  final DutyAction? noticeAction;
  final Map<String, String> fieldErrors;

  bool get busy => pending != null;
  T? get value => switch (result) {
    AccessReadOk<T>(:final value) => value,
    _ => null,
  };

  DutiesState<T> copyWith({
    bool? loading,
    AccessRead<T>? result,
    DutyAction? pending,
    bool clearPending = false,
    DutyAction? unconfirmed,
    bool clearUnconfirmed = false,
    DutyNotice? notice,
    DutyAction? noticeAction,
    bool clearNotice = false,
    Map<String, String>? fieldErrors,
  }) => DutiesState<T>(
    loading: loading ?? this.loading,
    result: result ?? this.result,
    pending: clearPending ? null : (pending ?? this.pending),
    unconfirmed: clearUnconfirmed ? null : (unconfirmed ?? this.unconfirmed),
    notice: clearNotice ? null : (notice ?? this.notice),
    noticeAction: clearNotice ? null : (noticeAction ?? this.noticeAction),
    fieldErrors: fieldErrors ?? this.fieldErrors,
  );
}

/// Story 4.1: one duties read and its commands (1.4 envelope) with honest
/// request states: an answer shows only once the server confirmed it; an
/// unknown outcome stays "Not confirmed" and is checked again under the same
/// request id. Protected state lives in memory only, scoped to the account
/// generation. The server rechecks live access and grants every time.
abstract class DutiesController<T> extends Notifier<DutiesState<T>> {
  int _epoch = 0;

  Future<AccessRead<T>> fetch();

  @override
  DutiesState<T> build() {
    ref.watch(accountGenerationProvider);
    _epoch++;
    final epoch = _epoch;
    Future.microtask(() => _reload(epoch));
    return DutiesState<T>(loading: true);
  }

  bool _current(int epoch) => ref.mounted && epoch == _epoch;

  Future<void> reload() => _reload(_epoch);

  Future<void> _reload(int epoch) async {
    if (!_current(epoch)) return;
    state = state.copyWith(loading: true);
    final r = await fetch();
    if (!_current(epoch)) return;
    // A denial or failure drops everything protected from the screen. A
    // request still in flight stays pending, so its buttons stay disabled
    // and it cannot be sent twice. Story 4.5: an unknown outcome is let go
    // once the fresh read shows no target still waiting for that command
    // (the server did record it, or the duty changed): the server's state
    // is shown, never a stale Not sent.
    var unconfirmed = state.unconfirmed;
    var notice = state.notice;
    var noticeAction = state.noticeAction;
    if (unconfirmed != null &&
        r is AccessReadOk<T> &&
        !stillUnconfirmed(unconfirmed, r.value)) {
      unconfirmed = null;
      if (notice == DutyNotice.unconfirmed) {
        notice = null;
        noticeAction = null;
      }
    }
    state = DutiesState<T>(
      result: r,
      pending: state.pending,
      notice: notice,
      noticeAction: noticeAction,
      unconfirmed: unconfirmed,
      fieldErrors: state.fieldErrors,
    );
    if (r is AccessReadDenied<T>) noteProtectedDenial(ref);
  }

  /// Story 4.5: whether [action], whose outcome was never learned, may still
  /// be unanswered according to the fresh read [value]. By default it is
  /// kept until Check again learns the outcome.
  bool stillUnconfirmed(DutyAction action, T value) => true;

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
    String subject, {
    String function = DutyCommands.function,
    DutyOwnerKind? ownerKind,
  }) async {
    if (state.busy) return;
    // An input whose outcome was never learned is resent under its original
    // request id; anything else is a new request.
    await _dispatch(
      DutyAction(
        function: function,
        request: resendOrNewRequest(
          unconfirmed: state.unconfirmed?.request,
          command: command,
          expected: expected,
          payload: payload,
          ids: ref.read(requestIdsProvider),
        ),
        subject: subject,
        ownerKind: ownerKind,
      ),
    );
  }

  static DutyNotice _success(DutyAction action, Object? data) =>
      switch (action.command) {
        DutyCommands.createDepartment => DutyNotice.departmentCreated,
        DutyCommands.revise => switch (data) {
          {'change': 'notes'} => DutyNotice.notesUpdated,
          {'change': 'draft'} => DutyNotice.draftUpdated,
          {'change': 'reference'} => DutyNotice.referenceUpdated,
          _ => DutyNotice.revised,
        },
        DutyCommands.createSeries => DutyNotice.seriesCreated,
        DutyCommands.assignSlot =>
          data is Map && data['state'] == 'draft'
              ? DutyNotice.draftAssigned
              : DutyNotice.positionGiven,
        DutyCommands.publishDrafts => DutyNotice.draftsPublished,
        DutyCommands.reviseSeries => DutyNotice.seriesRevised,
        DutyCommands.cancelOccurrence ||
        DutyCommands.cancelSeries => DutyNotice.occurrenceCancelled,
        DutyCommands.addMember => DutyNotice.memberAdded,
        GrantCommands.grantScope => DutyNotice.staffAssigned,
        GrantCommands.revokeScope => DutyNotice.staffRemoved,
        DutyCommands.publish => DutyNotice.published,
        DutyCommands.withdrawAcceptance => DutyNotice.withdrawn,
        DutyCommands.acceptMany => DutyNotice.bulkAccepted,
        DutyCommands.setReminders => DutyNotice.remindersSet,
        DutyCoverageCommands.recordContactAttempt => DutyNotice.contactRecorded,
        DutyCoverageCommands.confirmByLeader => DutyNotice.leaderConfirmed,
        DutyCoverageCommands.cancelPosition =>
          data is Map && data['cancelled'] == 'occurrence'
              ? DutyNotice.occurrenceCancelled
              : DutyNotice.positionCancelled,
        DutyOutcomeCommands.recordOutcome => DutyNotice.outcomeRecorded,
        DutyOutcomeCommands.correctOutcome => DutyNotice.outcomeCorrected,
        DutyCommands.clearReview => DutyNotice.reviewCleared,
        DutyCommands.removeMember =>
          data is Map && data['notices_skipped'] == true
              ? DutyNotice.memberRemovedNoNotices
              : DutyNotice.memberRemoved,
        DutyCommands.resolveHandover => DutyNotice.handoverResolved,
        _ =>
          action.request.payload['response'] == DutyResponse.declined.wire
              ? DutyNotice.declined
              : DutyNotice.accepted,
      };

  static DutyNotice _refusal(CommandError error, [DutyAction? action]) {
    final f = error.fieldErrors;
    // Story 4.9: a leader's coverage command on an assignment that changed
    // (an answer, a change, a cancellation) reloads the queue; it is never
    // the member's "your answer was not recorded".
    final coverage =
        action?.command == DutyCoverageCommands.recordContactAttempt ||
        action?.command == DutyCoverageCommands.confirmByLeader;
    if (coverage && error.code == ErrorCode.conflict) {
      return switch (f['assignment_id']) {
        'declined' => DutyNotice.confirmDeclined,
        'responded' => DutyNotice.alreadyConfirmed,
        'cancelled' => DutyNotice.dutyCancelled,
        _ => DutyNotice.changedElsewhere,
      };
    }
    if (coverage && f['assignment_id'] == 'confirmed') {
      return DutyNotice.alreadyConfirmed;
    }
    if (coverage && f['assignment_id'] == 'own') {
      return DutyNotice.ownAssignment;
    }
    // Story 4.10: the outcome commands (a leader's, never the member's answer).
    final outcome =
        action?.command == DutyOutcomeCommands.recordOutcome ||
        action?.command == DutyOutcomeCommands.correctOutcome;
    if (outcome) {
      if (error.code == ErrorCode.conflict) {
        return switch (f['assignment_id']) {
          'recorded' => DutyNotice.outcomeAlreadyRecorded,
          'cancelled' => DutyNotice.dutyCancelled,
          _ => DutyNotice.changedElsewhere,
        };
      }
      if (f['assignment_id'] == 'own') return DutyNotice.ownOutcome;
      if (f['member_id'] == 'erased' || f['member_id'] == 'inactive') {
        return DutyNotice.outcomeMemberGone;
      }
      if (f['assignment_id'] == 'not_started') {
        return DutyNotice.outcomeNotStarted;
      }
      if (f['outcome'] == 'not_accepted') return DutyNotice.outcomeNotAccepted;
      if (f['outcome'] == 'unchanged') return DutyNotice.unchanged;
      if (f['assignment_id'] == 'unrecorded') {
        return DutyNotice.changedElsewhere;
      }
    }
    // Story 4.11: a review cleared (or changed) elsewhere reloads the list.
    if (action?.command == DutyCommands.clearReview &&
        error.code == ErrorCode.conflict) {
      return f['flag_id'] == 'cleared'
          ? DutyNotice.reviewAlreadyCleared
          : DutyNotice.changedElsewhere;
    }
    // Story 4.12: a department's handover without a reachable leader yet;
    // one resolved elsewhere reloads the list.
    if (action?.command == DutyCommands.resolveHandover) {
      if (error.code == ErrorCode.conflict &&
          f['department_id'] == 'leader_required') {
        return DutyNotice.leaderRequired;
      }
      if (f['department_id'] == 'no_handover') {
        return DutyNotice.changedElsewhere;
      }
    }
    return switch (error.code) {
      ErrorCode.conflict when f['assignments'] == 'changed' =>
        DutyNotice.bulkChanged,
      ErrorCode.conflict when f['assignment_id'] == 'responded' =>
        DutyNotice.alreadyAnswered,
      ErrorCode.conflict when f['assignment_id'] == 'superseded' =>
        DutyNotice.superseded,
      ErrorCode.conflict when f['assignment_id'] == 'cancelled' =>
        DutyNotice.dutyCancelled,
      ErrorCode.conflict when f['name'] == 'taken' => DutyNotice.nameTaken,
      ErrorCode.conflict when f['slot_count'] == 'changed' =>
        DutyNotice.draftCountChanged,
      ErrorCode.conflict => DutyNotice.changedElsewhere,
      ErrorCode.validationFailed when f['override_reason'] == 'required' =>
        DutyNotice.overlapNeedsReason,
      ErrorCode.validationFailed when f['assignment_id'] == 'started' =>
        DutyNotice.started,
      ErrorCode.validationFailed when f['occurrence_id'] == 'started' =>
        DutyNotice.dutyStarted,
      ErrorCode.validationFailed
          when f['occurrence_id'] == 'unchanged' ||
              f['series_id'] == 'unchanged' ||
              f['slot_id'] == 'unchanged' =>
        DutyNotice.unchanged,
      ErrorCode.validationFailed
          when f['occurrence_id'] == 'cancelled' ||
              f['from_occurrence_id'] == 'cancelled' ||
              f['slot_id'] == 'cancelled' =>
        DutyNotice.dutyCancelled,
      ErrorCode.validationFailed when f['from_occurrence_id'] == 'started' =>
        DutyNotice.dutyStarted,
      ErrorCode.validationFailed when f['deadline_before'] == 'passed' =>
        DutyNotice.leadPassed,
      ErrorCode.validationFailed when f['member_id'] == 'unavailable' =>
        DutyNotice.plannedUnavailable,
      ErrorCode.validationFailed when f['member_id'] == 'not_in_department' =>
        DutyNotice.notInDepartment,
      ErrorCode.validationFailed => DutyNotice.invalid,
      ErrorCode.forbidden => DutyNotice.notAllowed,
      ErrorCode.unauthenticated => DutyNotice.signInAgain,
      ErrorCode.notFound => DutyNotice.notFound,
      ErrorCode.unavailable => DutyNotice.notAvailable,
      _ => DutyNotice.refused,
    };
  }

  Future<void> _dispatch(DutyAction action) async {
    final epoch = _epoch;
    state = state.copyWith(
      pending: action,
      clearNotice: true,
      fieldErrors: const {},
    );
    final outcome = await ref
        .read(commandGatewayProvider)
        .send(action.function, action.request);
    if (!_current(epoch)) return;
    switch (outcome) {
      case CommandConfirmed(:final success):
        // Story 4.4: loads and overlaps changed; pickers read them again.
        ref.invalidate(dutyCandidatesProvider);
        state = state.copyWith(
          clearPending: true,
          clearUnconfirmed: true,
          notice: _success(action, success.data),
          noticeAction: action,
        );
        if (action.function == GrantCommands.function) {
          // Grants changed: navigation follows the server's new answer.
          noteProtectedDenial(ref);
        }
        await _reload(epoch);
      case CommandRefused(:final error):
        ref.invalidate(dutyCandidatesProvider);
        final notice = _refusal(error, action);
        state = state.copyWith(
          clearPending: true,
          clearUnconfirmed: true,
          notice: notice,
          noticeAction: action,
          fieldErrors: error.fieldErrors,
        );
        if (notice == DutyNotice.notAllowed ||
            notice == DutyNotice.signInAgain) {
          noteProtectedDenial(ref);
        }
        if (notice != DutyNotice.invalid) await _reload(epoch);
      case CommandUnknownOutcome():
        state = state.copyWith(
          clearPending: true,
          unconfirmed: action,
          notice: DutyNotice.unconfirmed,
          noticeAction: action,
        );
      case CommandNotSent():
        state = state.copyWith(
          clearPending: true,
          notice: DutyNotice.notSent,
          noticeAction: action,
        );
    }
  }
}

/// Staff web, Admin: departments, their leaders and deputies (Identity
/// scope grants) and members (with or without a login).
class DutyAdminController extends DutiesController<DutyAdminOverview> {
  @override
  Future<AccessRead<DutyAdminOverview>> fetch() =>
      ref.read(dutiesRepositoryProvider).fetchAdminOverview();

  Future<void> createDepartment(String name) => send(
    DutyCommands.createDepartment,
    const Optional.of(null),
    {'name': name.trim()},
    name.trim(),
  );

  Future<void> addMember(AdminDepartment department, DutyCandidate member) =>
      send(DutyCommands.addMember, Optional.of(department.revision), {
        'department_id': department.departmentId,
        'member_id': member.memberId,
      }, member.displayName);

  /// Story 4.12: takes [member] out of [department]; their future duties
  /// there end and each position is flagged for cover.
  Future<void> removeMember(
    AdminDepartment department,
    DepartmentMember member,
  ) => send(DutyCommands.removeMember, Optional.of(department.revision), {
    'department_id': department.departmentId,
    'member_id': member.memberId,
  }, member.displayName);

  /// Story 4.12: marks [department]'s leader handover done (it has a leader
  /// or deputy again).
  Future<void> resolveHandover(AdminDepartment department) => send(
    DutyCommands.resolveHandover,
    Optional.of(department.revision),
    {'department_id': department.departmentId},
    department.name,
  );

  /// Gives [member] the leader or deputy scope of [department] through the
  /// audited Identity grant command (story 2.3).
  Future<void> assignStaff(
    AdminDepartment department,
    DutyCandidate member,
    String kind,
  ) => send(
    GrantCommands.grantScope,
    Optional.of(member.grantsRevision),
    {
      'member_id': member.memberId,
      'scope_kind': kind,
      'scope_id': department.departmentId,
    },
    member.displayName,
    function: GrantCommands.function,
  );

  Future<void> removeStaff(
    AdminDepartment department,
    DepartmentStaff staff,
    String kind,
  ) => send(
    GrantCommands.revokeScope,
    Optional.of(staff.grantsRevision),
    {
      'member_id': staff.memberId,
      'scope_kind': kind,
      'scope_id': department.departmentId,
    },
    staff.displayName,
    function: GrantCommands.function,
  );
}

final dutyAdminProvider =
    NotifierProvider<DutyAdminController, DutiesState<DutyAdminOverview>>(
      DutyAdminController.new,
    );

/// Staff web, department leaders and deputies (and Admin; Pastor read only):
/// publish a duty and see each position's response.
class DutyLeaderController extends DutiesController<DutyLeaderBoard> {
  @override
  Future<AccessRead<DutyLeaderBoard>> fetch() =>
      ref.read(dutiesRepositoryProvider).fetchLeaderBoard();

  Future<void> publish(DutyDraft draft, String subject) => send(
    DutyCommands.publish,
    const Optional.of(null),
    draft.toPayload(),
    subject,
  );

  /// Story 4.2: revise a published duty at its current revision. A conflict
  /// (another manager changed it first) reloads the board.
  Future<void> revise(DutyEdit edit, String subject) => send(
    DutyCommands.revise,
    Optional.of(edit.duty.revision),
    edit.toPayload(),
    subject,
  );

  /// Story 4.8: the member reminders of [duty] ([reminders] null = the
  /// defaults). Nobody is asked again.
  Future<void> setReminders(
    LeaderDuty duty,
    List<DutyReminderSpec>? reminders,
  ) => send(DutyCommands.setReminders, Optional.of(duty.revision), {
    'occurrence_id': duty.occurrenceId,
    'reminders': DutyReminders(reminders).toWire(),
  }, duty.dutyName);

  /// Story 4.11: mark an owner-review mismatch of [duty] reviewed (the duty
  /// itself does not change).
  Future<void> clearReview(LeaderDuty duty, DutyReview review) => send(
    DutyCommands.clearReview,
    Optional.of(review.revision),
    {'flag_id': review.flagId},
    duty.dutyName,
  );
}

final dutyLeaderProvider =
    NotifierProvider<DutyLeaderController, DutiesState<DutyLeaderBoard>>(
      DutyLeaderController.new,
    );

/// Story 4.3, staff web: rota series of the departments the caller manages
/// (Pastor read only): generate drafts, plan and give positions, Publish N
/// draft slots, change this occurrence or this and future, cancel.
class DutyRotaController extends DutiesController<DutyRota> {
  @override
  Future<AccessRead<DutyRota>> fetch() =>
      ref.read(dutiesRepositoryProvider).fetchRota();

  Future<void> createSeries(SeriesDraft draft) => send(
    DutyCommands.createSeries,
    const Optional.of(null),
    draft.toPayload(),
    draft.dutyName.trim(),
  );

  /// A draft position: [memberId] is the planned person (null clears). A
  /// published position needs [lead] for the answer-by time. Story 4.4:
  /// [overrideReason] when the person has another duty at that time.
  Future<void> assignSlot(
    RotaOccurrence occurrence,
    RotaPosition position,
    String? memberId, {
    String? lead,
    String? subject,
    String? overrideReason,
  }) => send(DutyCommands.assignSlot, Optional.of(occurrence.revision), {
    'slot_id': position.slotId,
    'member_id': memberId,
    if (occurrence.state == RotaState.published && lead != null)
      'response_deadline': DutyLeads.before(
        occurrence.times.arriveBy,
        lead,
      ).toUtc().toIso8601String(),
    if (memberId != null)
      'override_reason': ?DutyOverride.clean(overrideReason),
  }, subject ?? position.label);

  /// "Publish N draft slots": N is what the leader confirmed; the server
  /// refuses when it no longer matches. Story 4.8: a null [lead] lets each
  /// date take the church's lead-time default.
  Future<void> publishDrafts(RotaSeries series, int slots, String? lead) =>
      send(DutyCommands.publishDrafts, Optional.of(series.revision), {
        'series_id': series.seriesId,
        'slot_count': slots,
        'deadline_before': ?lead,
      }, series.dutyName);

  /// Story 4.8: the member reminders of one date ([reminders] null = the
  /// defaults).
  Future<void> setReminders(
    RotaOccurrence occurrence,
    List<DutyReminderSpec>? reminders,
  ) => send(DutyCommands.setReminders, Optional.of(occurrence.revision), {
    'occurrence_id': occurrence.occurrenceId,
    'reminders': DutyReminders(reminders).toWire(),
  }, occurrence.dutyName);

  /// Story 4.8: the member reminders of [series] from [from] onwards (the
  /// series template and every later date that has not started).
  Future<void> setSeriesReminders(
    RotaSeries series,
    RotaOccurrence from,
    List<DutyReminderSpec>? reminders,
  ) => send(DutyCommands.setReminders, Optional.of(series.revision), {
    'series_id': series.seriesId,
    'from_occurrence_id': from.occurrenceId,
    'reminders': DutyReminders(reminders).toWire(),
  }, series.dutyName);

  Future<void> reviseThis(RotaEdit edit) => send(
    DutyCommands.revise,
    Optional.of(edit.occurrence.revision),
    edit.thisPayload(),
    edit.occurrence.dutyName,
  );

  Future<void> reviseFuture(RotaSeries series, RotaEdit edit) => send(
    DutyCommands.reviseSeries,
    Optional.of(series.revision),
    edit.futurePayload(series.seriesId),
    series.dutyName,
  );

  Future<void> cancelThis(RotaOccurrence occurrence) => send(
    DutyCommands.cancelOccurrence,
    Optional.of(occurrence.revision),
    {'occurrence_id': occurrence.occurrenceId},
    occurrence.dutyName,
  );

  Future<void> cancelFuture(RotaSeries series, RotaOccurrence from) => send(
    DutyCommands.cancelSeries,
    Optional.of(series.revision),
    {'series_id': series.seriesId, 'from_occurrence_id': from.occurrenceId},
    series.dutyName,
  );

  /// Story 4.11: mark an owner-review mismatch of one date reviewed.
  Future<void> clearReview(RotaOccurrence occurrence, DutyReview review) =>
      send(DutyCommands.clearReview, Optional.of(review.revision), {
        'flag_id': review.flagId,
      }, occurrence.dutyName);
}

final dutyRotaProvider =
    NotifierProvider<DutyRotaController, DutiesState<DutyRota>>(
      DutyRotaController.new,
    );

/// Mobile: the member's own duties; Accept or Can't make it, Can't make it
/// anymore (story 4.5) and accepting several listed dates together.
class MyDutiesController extends DutiesController<MyDuties> {
  @override
  Future<AccessRead<MyDuties>> fetch() =>
      ref.read(dutiesRepositoryProvider).fetchMyDuties();

  /// Story 4.5: [duty] is still in the state [action] expected (withdrawing
  /// expects an acceptance; answering and bulk acceptance expect a pending
  /// duty). Once it is not, the server's answer is what the member sees.
  static bool awaits(DutyAction action, MyDuty duty) =>
      action.touches(duty.assignmentId) &&
      duty.response ==
          (action.command == DutyCommands.withdrawAcceptance
              ? DutyResponse.accepted
              : DutyResponse.pending);

  @override
  bool stillUnconfirmed(DutyAction action, MyDuties value) =>
      value.assignments.any((d) => awaits(action, d));

  Future<void> respond(MyDuty duty, DutyResponse response, {String? note}) {
    final n = note?.trim();
    return send(
      DutyCommands.respond,
      Optional.of(duty.revision),
      {
        'assignment_id': duty.assignmentId,
        'response': response.wire,
        if (n != null && n.isNotEmpty) 'note': n,
      },
      duty.dutyName,
      ownerKind: duty.ownerKind,
    );
  }

  /// Story 4.5: "Can't make it anymore" for an accepted duty.
  Future<void> withdraw(MyDuty duty, {String? note}) {
    final n = note?.trim();
    return send(
      DutyCommands.withdrawAcceptance,
      Optional.of(duty.revision),
      {
        'assignment_id': duty.assignmentId,
        if (n != null && n.isNotEmpty) 'note': n,
      },
      duty.dutyName,
      ownerKind: duty.ownerKind,
    );
  }

  /// Story 4.5: accept the confirmed selection, all or nothing, each at the
  /// revision the member saw. The order is the list's (soonest first), so
  /// a retry of the same selection is the same request body.
  Future<void> acceptMany(List<MyDuty> duties) {
    if (duties.isEmpty || duties.length > DutyCommands.maxBulk) {
      return Future.value();
    }
    return send(
      DutyCommands.acceptMany,
      const Optional.of(null),
      {
        'assignments': [
          for (final d in duties)
            {'assignment_id': d.assignmentId, 'revision': d.revision},
        ],
      },
      duties.length == 1 ? duties.single.dutyName : '${duties.length} duties',
      ownerKind: duties.every((d) => d.ownerKind == duties.first.ownerKind)
          ? duties.first.ownerKind
          : null,
    );
  }
}

final myDutiesProvider =
    NotifierProvider<MyDutiesController, DutiesState<MyDuties>>(
      MyDutiesController.new,
    );

/// Story 4.5: the optional note a member is typing for Accept, per
/// assignment, so the list card, the detail card and the detail footer share
/// it. Memory only, dropped on an account change.
class DutyAnswerNotes extends Notifier<Map<String, String>> {
  @override
  Map<String, String> build() {
    ref.watch(accountGenerationProvider);
    return const {};
  }

  void set(String assignmentId, String text) =>
      state = {...state, assignmentId: text};

  void clear(String assignmentId) => state = {...state}..remove(assignmentId);
}

final dutyAnswerNotesProvider =
    NotifierProvider<DutyAnswerNotes, Map<String, String>>(DutyAnswerNotes.new);

/// Story 4.5: hands a duty's calendar file to the platform. Unavailable by
/// default; the mobile composition root supplies the share-sheet handoff.
final dutyCalendarExportProvider = Provider<DutyCalendarExport>(
  (ref) => const UnavailableCalendarExport(),
);

/// Story 4.4, staff web: each roster member's upcoming load and the
/// overlapping duties the caller may see, for a position or a prospective
/// one-off duty. Read again after every duties command and on an account
/// change; nothing is kept beyond the screen that shows it.
final dutyCandidatesProvider = FutureProvider.autoDispose
    .family<AccessRead<DutyCandidates>, CandidateQuery>((ref, query) {
      ref.watch(accountGenerationProvider);
      return ref.read(dutiesRepositoryProvider).fetchCandidates(query);
    });

// ---------------------------------------------------------------------------
// Story 4.9: the coverage queue
// ---------------------------------------------------------------------------

/// The queue's server-side filters (window, department, duty). Memory only,
/// reset on an account change.
class DutyCoverageQueryController extends Notifier<CoverageQuery> {
  @override
  CoverageQuery build() {
    ref.watch(accountGenerationProvider);
    return const CoverageQuery();
  }

  void set(CoverageQuery query) => state = query;
}

final dutyCoverageQueryProvider =
    NotifierProvider<DutyCoverageQueryController, CoverageQuery>(
      DutyCoverageQueryController.new,
    );

/// Story 4.9 (staff web and mobile): the scoped coverage queue and the
/// leader's essential actions: record a contact attempt, Confirmed by
/// leader, (re)assign a position, cancel a position. Every action is a
/// server-checked command; the queue is read again after each answer.
class DutyCoverageController extends DutiesController<DutyCoverage> {
  @override
  DutiesState<DutyCoverage> build() {
    ref.watch(dutyCoverageQueryProvider);
    return super.build();
  }

  @override
  Future<AccessRead<DutyCoverage>> fetch() => ref
      .read(dutyCoverageRepositoryProvider)
      .fetchCoverage(ref.read(dutyCoverageQueryProvider));

  void setQuery(CoverageQuery query) =>
      ref.read(dutyCoverageQueryProvider.notifier).set(query);

  Future<void> recordAttempt(CoveragePosition p, ContactAttemptDraft draft) {
    final a = p.assignment;
    if (a == null) return Future.value();
    return send(
      DutyCoverageCommands.recordContactAttempt,
      Optional.of(a.revision),
      draft.toPayload(a.assignmentId),
      a.name,
    );
  }

  Future<void> confirm(CoveragePosition p, LeaderConfirmationDraft draft) {
    final a = p.assignment;
    if (a == null) return Future.value();
    return send(
      DutyCoverageCommands.confirmByLeader,
      Optional.of(a.revision),
      draft.toPayload(a.assignmentId),
      a.name,
    );
  }

  /// Gives the position to [memberId] (the 4.3 command; the old assignee's
  /// reminders end and their follow-up task closes). The answer-by time is
  /// the church default; [reason] when they have an overlapping duty.
  Future<void> assign(
    CoveragePosition p,
    String memberId,
    String subject, {
    String? reason,
  }) {
    final r = reason?.trim();
    return send(DutyCommands.assignSlot, Optional.of(p.occurrenceRevision), {
      'slot_id': p.slotId,
      'member_id': memberId,
      if (r != null && r.isNotEmpty) 'override_reason': r,
    }, subject);
  }

  Future<void> cancelPosition(CoveragePosition p) => send(
    DutyCoverageCommands.cancelPosition,
    Optional.of(p.occurrenceRevision),
    {'slot_id': p.slotId},
    p.title,
  );
}

final dutyCoverageProvider =
    NotifierProvider<DutyCoverageController, DutiesState<DutyCoverage>>(
      DutyCoverageController.new,
    );

/// Story 4.9 (mobile Home): the leader's Needs attention card reads the
/// queue with the defaults (this week, every department they lead).
class LeaderAttentionController extends DutiesController<DutyCoverage> {
  @override
  Future<AccessRead<DutyCoverage>> fetch() => ref
      .read(dutyCoverageRepositoryProvider)
      .fetchCoverage(const CoverageQuery());
}

final leaderAttentionProvider =
    NotifierProvider<LeaderAttentionController, DutiesState<DutyCoverage>>(
      LeaderAttentionController.new,
    );

// ---------------------------------------------------------------------------
// Story 4.10: completion outcomes and a member's assignment history
// ---------------------------------------------------------------------------

/// The outcomes read's filters. Memory only, reset on an account change.
class DutyOutcomesQueryController extends Notifier<OutcomesQuery> {
  @override
  OutcomesQuery build() {
    ref.watch(accountGenerationProvider);
    return const OutcomesQuery();
  }

  void set(OutcomesQuery query) => state = query;
}

final dutyOutcomesQueryProvider =
    NotifierProvider<DutyOutcomesQueryController, OutcomesQuery>(
      DutyOutcomesQueryController.new,
    );

/// Story 4.10 (staff web and mobile): the started duties of the departments
/// the reader leads or deputises, and recording or correcting an outcome.
/// Nothing shows as recorded until the server answers; the list is read
/// again after each answer.
class DutyOutcomesController extends DutiesController<DutyOutcomes> {
  @override
  DutiesState<DutyOutcomes> build() {
    ref.watch(dutyOutcomesQueryProvider);
    return super.build();
  }

  @override
  Future<AccessRead<DutyOutcomes>> fetch() => ref
      .read(dutyOutcomesRepositoryProvider)
      .fetchOutcomes(ref.read(dutyOutcomesQueryProvider));

  void setQuery(OutcomesQuery query) =>
      ref.read(dutyOutcomesQueryProvider.notifier).set(query);

  /// The first outcome of [p]'s assignment, sent against its answer revision.
  Future<void> record(OutcomePosition p, OutcomeDraft draft) {
    final a = p.assignment;
    if (a == null) return Future.value();
    return send(
      DutyOutcomeCommands.recordOutcome,
      Optional.of(a.revision),
      draft.toPayload(a.assignmentId, correction: false),
      a.name,
    );
  }

  /// A correction, sent against the current outcome revision (the earlier
  /// value stays in the trail).
  Future<void> correct(OutcomePosition p, OutcomeDraft draft) {
    final a = p.assignment;
    final o = a?.outcome;
    if (a == null || o == null) return Future.value();
    return send(
      DutyOutcomeCommands.correctOutcome,
      Optional.of(o.revision),
      draft.toPayload(a.assignmentId, correction: true),
      a.name,
    );
  }
}

final dutyOutcomesProvider =
    NotifierProvider<DutyOutcomesController, DutiesState<DutyOutcomes>>(
      DutyOutcomesController.new,
    );

/// Whose history is open and which page. Memory only, reset on an account
/// change.
class MemberHistoryQueryController extends Notifier<HistoryQuery> {
  @override
  HistoryQuery build() {
    ref.watch(accountGenerationProvider);
    return const HistoryQuery();
  }

  void set(HistoryQuery query) => state = query;
}

final memberHistoryQueryProvider =
    NotifierProvider<MemberHistoryQueryController, HistoryQuery>(
      MemberHistoryQueryController.new,
    );

/// Story 4.10: one page of a member's assignment history (the reader's own,
/// or a member of a department they lead). Read only.
class MemberHistoryController extends DutiesController<MemberHistory> {
  @override
  DutiesState<MemberHistory> build() {
    ref.watch(memberHistoryQueryProvider);
    return super.build();
  }

  @override
  Future<AccessRead<MemberHistory>> fetch() => ref
      .read(dutyOutcomesRepositoryProvider)
      .fetchHistory(ref.read(memberHistoryQueryProvider));

  /// Opens [memberId]'s history (null: the reader's own) at its newest page.
  void open(String? memberId) {
    final q = ref.read(memberHistoryQueryProvider);
    if (q.memberId == memberId && q.pages.isEmpty) return;
    ref
        .read(memberHistoryQueryProvider.notifier)
        .set(HistoryQuery(memberId: memberId));
  }

  void older(HistoryCursor c) {
    final q = ref.read(memberHistoryQueryProvider);
    ref.read(memberHistoryQueryProvider.notifier).set(q.older(c));
  }

  void newer() {
    final q = ref.read(memberHistoryQueryProvider);
    ref.read(memberHistoryQueryProvider.notifier).set(q.newer());
  }
}

final memberHistoryProvider =
    NotifierProvider<MemberHistoryController, DutiesState<MemberHistory>>(
      MemberHistoryController.new,
    );

import 'dart:convert';

import 'package:church_contracts/church_contracts.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/access_grants.dart';
import '../domain/cell_meetings.dart';
import '../domain/cell_programmes.dart';
import '../domain/duties.dart';
import '../domain/cell_membership.dart';
import '../domain/commands.dart';
import '../domain/membership_application.dart';
import 'access_controllers.dart' show noteProtectedDenial;
import 'providers.dart';

/// What a cells screen tells the person after an action.
enum CellNotice {
  cellCreated,
  cellUpdated,
  staffAssigned,
  staffRemoved,
  requested,
  confirmed,

  /// A leader passed the request to the church office (Admin follow-up).
  referred,
  declined,
  cancelled,

  /// Changed in another tab or by someone else: reloaded.
  changedElsewhere,

  /// The member already has an open request.
  openRequest,

  /// That is already the member's cell.
  sameCell,

  /// Separation of duty: not for your own record.
  selfAction,
  invalid,
  notAllowed,
  signInAgain,
  notFound,
  notAvailable,
  refused,

  /// The outcome is unknown: check again with the same request.
  unconfirmed,
  notSent,

  /// Story 5.1: meetings.
  scheduleSet,
  meetingMoved,
  meetingCancelled,
  meetingReinstated,

  /// The meeting has started: it can no longer be changed.
  meetingStarted,

  /// The meeting was already cancelled (by someone else).
  alreadyCancelled,

  /// Story 5.2: the cell's reminders were saved.
  remindersSet,

  /// Story 5.3: programme drafts.
  programmeCreated,
  programmeSaved,
  programmeCancelled,

  /// The meeting is cancelled: its programme cannot be planned.
  meetingCancelledAlready,

  /// The programme is no longer a draft (cancelled elsewhere).
  programmeNotDraft,

  /// Story 5.4: published through Duties.
  programmePublished,

  /// Story 5.4: a part's Duties side was refused (an overlap, for example).
  programmePartRefused,

  /// Story 5.4: the meeting's programme is published, so the meeting is not
  /// moved or cancelled from Cell meetings.
  meetingHasProgramme,

  /// Story 5.5: the leader recorded that the person said yes directly.
  leaderConfirmed,

  /// Story 5.7: Cannot attend sent, changed or withdrawn.
  absenceSent,
  absenceChanged,
  absenceWithdrawn,

  /// Story 5.8: the meeting record (held, a correction, who led).
  meetingRecorded,
  recordCorrected,
  leadersRecorded,

  /// The meeting has not started yet: it cannot be recorded.
  meetingNotStarted,

  /// Story 5.9: a cell's handover is done, or it still has no leader.
  handoverResolved,
  leaderRequired,
}

/// One command in flight or just answered.
class CellAction {
  const CellAction({
    required this.function,
    required this.request,
    required this.subject,
  });

  final String function;
  final CommandRequest request;

  /// What was acted on (display only).
  final String subject;

  String get command => request.command;
}

class CellsState<T> {
  const CellsState({
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
  final CellAction? pending;
  final CellAction? unconfirmed;
  final CellNotice? notice;
  final CellAction? noticeAction;
  final Map<String, String> fieldErrors;

  bool get busy => pending != null;
  T? get value => switch (result) {
    AccessReadOk<T>(:final value) => value,
    _ => null,
  };

  CellsState<T> copyWith({
    bool? loading,
    AccessRead<T>? result,
    CellAction? pending,
    bool clearPending = false,
    CellAction? unconfirmed,
    bool clearUnconfirmed = false,
    CellNotice? notice,
    CellAction? noticeAction,
    bool clearNotice = false,
    Map<String, String>? fieldErrors,
  }) => CellsState<T>(
    loading: loading ?? this.loading,
    result: result ?? this.result,
    pending: clearPending ? null : (pending ?? this.pending),
    unconfirmed: clearUnconfirmed ? null : (unconfirmed ?? this.unconfirmed),
    notice: clearNotice ? null : (notice ?? this.notice),
    noticeAction: clearNotice ? null : (noticeAction ?? this.noticeAction),
    fieldErrors: fieldErrors ?? this.fieldErrors,
  );
}

/// Story 2.6: one cells read and its commands (1.4 envelope) with honest
/// request states. Protected state (AD-13) lives in memory only, scoped to
/// the account generation. The server rechecks live access and the current
/// grants on every read and command.
abstract class CellsController<T> extends Notifier<CellsState<T>> {
  int _epoch = 0;

  Future<AccessRead<T>> fetch();

  @override
  CellsState<T> build() {
    ref.watch(accountGenerationProvider);
    _epoch++;
    final epoch = _epoch;
    Future.microtask(() => _reload(epoch));
    return CellsState<T>(loading: true);
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
    // and it cannot be sent twice (story 4.14 review: the Duties rule).
    state = CellsState<T>(
      result: r,
      pending: state.pending,
      notice: state.notice,
      noticeAction: state.noticeAction,
      unconfirmed: state.unconfirmed,
      fieldErrors: state.fieldErrors,
    );
    if (r is AccessReadDenied<T>) noteProtectedDenial(ref);
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

  Future<void> send(
    String command,
    Optional<int> expected,
    Map<String, Object?> payload,
    String subject, {
    String function = CellCommands.function,
  }) async {
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
      CellAction(
        function: function,
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

  static CellNotice _success(String command, Object? data) => switch (command) {
    CellCommands.createCell => CellNotice.cellCreated,
    CellCommands.updateCell => CellNotice.cellUpdated,
    GrantCommands.grantScope => CellNotice.staffAssigned,
    GrantCommands.revokeScope => CellNotice.staffRemoved,
    CellCommands.requestChange => CellNotice.requested,
    CellCommands.confirm => CellNotice.confirmed,
    CellCommands.decline =>
      data is Map &&
              data['open_request'] is Map &&
              (data['open_request'] as Map)['state'] == 'referred'
          ? CellNotice.referred
          : CellNotice.declined,
    CellMeetingCommands.setSchedule => CellNotice.scheduleSet,
    CellMeetingCommands.move => CellNotice.meetingMoved,
    CellMeetingCommands.cancel => CellNotice.meetingCancelled,
    CellMeetingCommands.reinstate => CellNotice.meetingReinstated,
    CellMeetingCommands.setReminders => CellNotice.remindersSet,
    CellProgrammeCommands.create => CellNotice.programmeCreated,
    CellProgrammeCommands.save => CellNotice.programmeSaved,
    CellProgrammeCommands.cancel => CellNotice.programmeCancelled,
    CellProgrammeCommands.publish => CellNotice.programmePublished,
    DutyCoverageCommands.confirmByLeader => CellNotice.leaderConfirmed,
    CellAbsenceCommands.send => CellNotice.absenceSent,
    CellAbsenceCommands.change => CellNotice.absenceChanged,
    CellAbsenceCommands.withdraw => CellNotice.absenceWithdrawn,
    CellRecordCommands.recordHeld => CellNotice.meetingRecorded,
    CellRecordCommands.correctHeld => CellNotice.recordCorrected,
    CellRecordCommands.recordLeaders => CellNotice.leadersRecorded,
    CellCommands.resolveHandover => CellNotice.handoverResolved,
    _ => CellNotice.cancelled,
  };

  static CellNotice _refusal(CommandError error) {
    final f = error.fieldErrors;
    return switch (error.code) {
      ErrorCode.conflict when f['member_id'] == 'open_request' =>
        CellNotice.openRequest,
      ErrorCode.conflict when f['meeting_id'] == 'programme_published' =>
        CellNotice.meetingHasProgramme,
      ErrorCode.conflict when f['cell_id'] == 'leader_required' =>
        CellNotice.leaderRequired,
      ErrorCode.conflict when f['meeting_id'] == 'cancelled' =>
        CellNotice.alreadyCancelled,
      ErrorCode.validationFailed when f['meeting_id'] == 'started' =>
        CellNotice.meetingStarted,
      ErrorCode.validationFailed when f['meeting_id'] == 'not_started' =>
        CellNotice.meetingNotStarted,
      ErrorCode.validationFailed when f['meeting_id'] == 'cancelled' =>
        CellNotice.meetingCancelledAlready,
      ErrorCode.conflict when f['programme_id'] == 'not_draft' =>
        CellNotice.programmeNotDraft,
      ErrorCode.validationFailed
          when f.keys.any((k) => RegExp(r'^parts\.\d+\.').hasMatch(k)) =>
        CellNotice.programmePartRefused,
      ErrorCode.conflict => CellNotice.changedElsewhere,
      ErrorCode.validationFailed when f['cell_id'] == 'current' =>
        CellNotice.sameCell,
      ErrorCode.validationFailed => CellNotice.invalid,
      ErrorCode.forbidden when f['member_id'] == 'unsupported' =>
        CellNotice.selfAction,
      ErrorCode.forbidden => CellNotice.notAllowed,
      ErrorCode.unauthenticated => CellNotice.signInAgain,
      ErrorCode.notFound => CellNotice.notFound,
      ErrorCode.unavailable => CellNotice.notAvailable,
      _ => CellNotice.refused,
    };
  }

  Future<void> _dispatch(CellAction action) async {
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
        state = state.copyWith(
          clearPending: true,
          clearUnconfirmed: true,
          notice: _success(action.command, success.data),
          noticeAction: action,
        );
        if (action.function == GrantCommands.function) {
          // Grants changed: navigation follows the server's new answer.
          noteProtectedDenial(ref);
        }
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
        if (notice == CellNotice.notAllowed ||
            notice == CellNotice.signInAgain) {
          noteProtectedDenial(ref);
        }
        if (notice != CellNotice.invalid &&
            notice != CellNotice.selfAction &&
            notice != CellNotice.programmePartRefused) {
          await _reload(epoch);
        }
      case CommandUnknownOutcome():
        state = state.copyWith(
          clearPending: true,
          unconfirmed: action,
          notice: CellNotice.unconfirmed,
          noticeAction: action,
        );
      case CommandNotSent():
        state = state.copyWith(
          clearPending: true,
          notice: CellNotice.notSent,
          noticeAction: action,
        );
    }
  }
}

/// Staff web, Admin: cell setup, leaders and assistants, open requests and
/// the follow-up queue.
class CellAdminController extends CellsController<CellAdminOverview> {
  @override
  Future<AccessRead<CellAdminOverview>> fetch() =>
      ref.read(cellsRepositoryProvider).fetchAdminOverview();

  Future<void> createCell({
    required String name,
    required String signupLabel,
    required String broadArea,
  }) => send(CellCommands.createCell, const Optional.of(null), {
    'name': name.trim(),
    'signup_label': signupLabel.trim(),
    'broad_area': broadArea.trim(),
  }, name.trim());

  Future<void> setListed(AdminCell cell, bool listed) => send(
    CellCommands.updateCell,
    Optional.of(cell.revision),
    {'cell_id': cell.cellId, 'listed': listed},
    cell.name,
  );

  /// Gives [member] the leader or assistant scope of [cell] through the
  /// audited Identity grant command (story 2.3).
  Future<void> assignStaff(AdminCell cell, CellMemberRow member, String kind) =>
      send(
        GrantCommands.grantScope,
        Optional.of(member.grantsRevision),
        {
          'member_id': member.memberId,
          'scope_kind': kind,
          'scope_id': cell.cellId,
        },
        member.displayName,
        function: GrantCommands.function,
      );

  Future<void> removeStaff(AdminCell cell, CellStaff staff, String kind) =>
      send(
        GrantCommands.revokeScope,
        Optional.of(staff.grantsRevision),
        {
          'member_id': staff.memberId,
          'scope_kind': kind,
          'scope_id': cell.cellId,
        },
        staff.displayName,
        function: GrantCommands.function,
      );

  /// Confirms [request]; [cellId] is the cell the Admin checked (required
  /// for a follow-up without one).
  Future<void> confirm(AdminCellRequest request, {String? cellId}) =>
      send(CellCommands.confirm, Optional.of(request.memberRevision), {
        'request_id': request.requestId,
        if (cellId != null && cellId != request.requestedCellId)
          'cell_id': cellId,
      }, request.displayName);

  Future<void> decline(AdminCellRequest request, CellDeclineReason reason) =>
      send(CellCommands.decline, Optional.of(request.memberRevision), {
        'request_id': request.requestId,
        'reason': reason.wire,
      }, request.displayName);

  /// Story 5.9: the cell has a reachable leader or assistant again after
  /// its last one left with a programme published ahead.
  Future<void> resolveHandover(AdminCell cell) => send(
    CellCommands.resolveHandover,
    Optional.of(cell.revision),
    {'cell_id': cell.cellId},
    cell.name,
  );

  /// Opens a move/join request for [member] (for example one without a
  /// login); a leader or Admin then confirms it.
  Future<void> requestFor(CellMemberRow member, AdminCell cell) {
    final rev = cell.signupRevision;
    if (rev == null) return Future.value();
    return send(CellCommands.requestChange, Optional.of(member.cellRevision), {
      'member_id': member.memberId,
      'cell_id': cell.cellId,
      'cell_revision': rev,
    }, member.displayName);
  }
}

final cellAdminProvider =
    NotifierProvider<CellAdminController, CellsState<CellAdminOverview>>(
      CellAdminController.new,
    );

/// Staff web, cell leaders and assistants: their cells' rosters; leaders
/// confirm or refer the requests for their cell.
class CellLeaderController extends CellsController<LeaderQueue> {
  @override
  Future<AccessRead<LeaderQueue>> fetch() =>
      ref.read(cellsRepositoryProvider).fetchLeaderQueue();

  Future<void> confirm(LeaderRequest request) => send(
    CellCommands.confirm,
    Optional.of(request.memberRevision),
    {'request_id': request.requestId},
    request.displayName,
  );

  /// Passes the request to the church office (Admin follow-up).
  Future<void> refer(LeaderRequest request, CellDeclineReason reason) => send(
    CellCommands.decline,
    Optional.of(request.memberRevision),
    {'request_id': request.requestId, 'reason': reason.wire},
    request.displayName,
  );
}

final cellLeaderProvider =
    NotifierProvider<CellLeaderController, CellsState<LeaderQueue>>(
      CellLeaderController.new,
    );

/// The member's own cell with the safe chooser's options. [options] keeps
/// the chooser read as answered, so a failure is shown, never an empty list.
class MyCellView {
  const MyCellView({required this.cell, required this.options});
  final MyCell cell;
  final AccessRead<List<CellOption>> options;
}

/// Mobile: the member's confirmed cell, their open request and a change
/// request (a request moves nobody until a leader or Admin confirms it).
class MyCellController extends CellsController<MyCellView> {
  @override
  Future<AccessRead<MyCellView>> fetch() async {
    final mine = await ref.read(cellsRepositoryProvider).fetchMyCell();
    if (mine is! AccessReadOk<MyCell>) {
      return switch (mine) {
        AccessReadDenied(:final denial) => AccessReadDenied(denial),
        AccessReadFailed(:final unreachable, :final cause) => AccessReadFailed(
          unreachable: unreachable,
          cause: cause,
        ),
        AccessReadOk() => throw StateError('unreachable'),
      };
    }
    final options = await ref
        .read(membershipRepositoryProvider)
        .fetchCellOptions();
    return AccessReadOk(MyCellView(cell: mine.value, options: options));
  }

  Future<void> requestChange(MyCell cell, CellOption option) => send(
    CellCommands.requestChange,
    Optional.of(cell.revision),
    {'cell_id': option.cellId, 'cell_revision': option.revision},
    option.label,
  );

  Future<void> cancel(MyCell cell, OwnCellRequest request) => send(
    CellCommands.cancel,
    Optional.of(cell.revision),
    {'request_id': request.requestId},
    request.label ?? 'your request',
  );
}

final myCellProvider =
    NotifierProvider<MyCellController, CellsState<MyCellView>>(
      MyCellController.new,
    );

/// Story 5.1, staff web: each cell's weekly schedule (set by an Admin) and
/// its meetings, which the cell's leader or an Admin moves, cancels or
/// reinstates one at a time. Times are typed and shown in church time and
/// travel as UTC instants.
class CellMeetingsController extends CellsController<CellMeetingsBoard> {
  @override
  Future<AccessRead<CellMeetingsBoard>> fetch() =>
      ref.read(cellsRepositoryProvider).fetchMeetings();

  /// Sets [cell]'s weekly rule. [venue] null keeps the current venue; [pin]
  /// null with [clearPin] false keeps the current pin.
  Future<void> setSchedule(
    StaffMeetingCell cell, {
    required int weekday,
    required String startTime,
    required String endTime,
    String? venue,
    MeetingMapPin? pin,
    bool clearPin = false,
  }) {
    final rev = cell.cellRevision;
    if (rev == null) return Future.value();
    return send(CellMeetingCommands.setSchedule, Optional.of(rev), {
      'cell_id': cell.cellId,
      'weekday': weekday,
      'start_time': startTime.trim(),
      'end_time': endTime.trim(),
      if (venue != null && venue.trim().isNotEmpty) 'venue': venue.trim(),
      if (pin != null)
        'map_pin': {'lat': pin.lat, 'lng': pin.lng}
      else if (clearPin)
        'map_pin': null,
    }, cell.name);
  }

  /// Moves one meeting. [venue] null keeps this meeting's venue; with
  /// [regularVenue] it goes back to the schedule's venue.
  Future<void> move(
    CellMeeting meeting, {
    required DateTime startsAt,
    required DateTime endsAt,
    String? venue,
    bool regularVenue = false,
  }) => send(CellMeetingCommands.move, Optional.of(meeting.revision), {
    'meeting_id': meeting.meetingId,
    'starts_at': startsAt.toUtc().toIso8601String(),
    'ends_at': endsAt.toUtc().toIso8601String(),
    if (venue != null && venue.trim().isNotEmpty)
      'venue': venue.trim()
    else if (regularVenue)
      'venue': null,
  }, 'the meeting of ${meeting.occurrenceDate}');

  Future<void> cancel(CellMeeting meeting) => send(
    CellMeetingCommands.cancel,
    Optional.of(meeting.revision),
    {'meeting_id': meeting.meetingId},
    'the meeting of ${meeting.occurrenceDate}',
  );

  /// Story 5.2: the cell's meeting reminders, as offsets before the start
  /// (`24 hours`); null returns to the default (one day before), an empty
  /// list means none. The leader or an Admin.
  Future<void> setReminders(StaffMeetingCell cell, List<String>? befores) {
    final schedule = cell.schedule;
    if (schedule == null) return Future.value();
    return send(
      CellMeetingCommands.setReminders,
      Optional.of(schedule.remindersRevision),
      {
        'cell_id': cell.cellId,
        'reminders': befores == null
            ? null
            : [
                for (final b in befores) {'before': b},
              ],
      },
      cell.name,
    );
  }

  Future<void> reinstate(CellMeeting meeting) => send(
    CellMeetingCommands.reinstate,
    Optional.of(meeting.revision),
    {'meeting_id': meeting.meetingId},
    'the meeting of ${meeting.occurrenceDate}',
  );
}

final cellMeetingsProvider =
    NotifierProvider<CellMeetingsController, CellsState<CellMeetingsBoard>>(
      CellMeetingsController.new,
    );

/// Story 5.3, staff web: one meeting's programme draft. The cell's leader or
/// assistant creates, saves and cancels it; Pastor oversight reads it; an
/// Admin-only reader sees counts. Every save sends the whole draft at the
/// programme revision, so a change made elsewhere is a conflict, not a
/// silent overwrite.
class CellProgrammeController extends CellsController<ProgrammeRead> {
  CellProgrammeController(this.meetingId);

  final String meetingId;

  @override
  Future<AccessRead<ProgrammeRead>> fetch() =>
      ref.read(cellsRepositoryProvider).fetchProgramme(meetingId);

  Future<void> create(CellMeeting meeting) => send(
    CellProgrammeCommands.create,
    const Optional.of(null),
    {'meeting_id': meeting.meetingId},
    'the programme for ${meeting.occurrenceDate}',
  );

  /// Saves [programme]'s content as typed; empty text clears a field.
  Future<void> save(
    CellProgramme programme, {
    required String topic,
    required String scripture,
    required String studyNotes,
    required List<ProgrammePartDraft> parts,
  }) => send(CellProgrammeCommands.save, Optional.of(programme.revision), {
    'programme_id': programme.programmeId,
    'topic': _textOrNull(topic),
    'scripture': _textOrNull(scripture),
    'study_notes': _textOrNull(studyNotes),
    'parts': [for (final p in parts) p.toJson()],
  }, 'the programme');

  /// Story 5.4: publishes [programme] at its revision. [overrideReason]
  /// keeps an assignee's overlap with their other duties knowingly.
  Future<void> publish(CellProgramme programme, {String? overrideReason}) =>
      send(CellProgrammeCommands.publish, Optional.of(programme.revision), {
        'programme_id': programme.programmeId,
        if (overrideReason != null && overrideReason.trim().isNotEmpty)
          'override_reason': overrideReason.trim(),
      }, 'the programme');

  /// Story 5.5: the person said yes directly (a member without a login, or
  /// by phone): recorded through Duties as Confirmed by leader, attributed
  /// to the leader or assistant, at the assignment's revision.
  Future<void> confirmByLeader(PartDuty duty, LeaderConfirmationDraft draft) {
    final id = duty.assignmentId, rev = duty.assignmentRevision;
    if (id == null || rev == null) return Future.value();
    return send(
      DutyCoverageCommands.confirmByLeader,
      Optional.of(rev),
      draft.toPayload(id),
      'the confirmation',
      function: DutyCommands.function,
    );
  }

  /// Story 5.8: records whether the meeting was held (the first time).
  Future<void> recordHeld(CellMeeting meeting, {required bool held}) => send(
    CellRecordCommands.recordHeld,
    const Optional.of(null),
    {'meeting_id': meeting.meetingId, 'held': held},
    'the meeting record',
  );

  /// Story 5.8: corrects held / not held; the earlier value is kept.
  Future<void> correctHeld(
    CellMeeting meeting,
    MeetingRecord record, {
    required bool held,
    required String reason,
  }) => send(CellRecordCommands.correctHeld, Optional.of(record.revision), {
    'meeting_id': meeting.meetingId,
    'held': held,
    'reason': reason.trim(),
  }, 'the meeting record');

  /// Story 5.8: who actually led [parts] (a correction carries its reason).
  Future<void> recordLeaders(
    CellMeeting meeting,
    MeetingRecord record,
    List<ActualLeaderDraft> parts,
  ) => send(CellRecordCommands.recordLeaders, Optional.of(record.revision), {
    'meeting_id': meeting.meetingId,
    'parts': [for (final p in parts) p.toJson()],
  }, 'who led');

  Future<void> cancel(CellProgramme programme) => send(
    CellProgrammeCommands.cancel,
    Optional.of(programme.revision),
    {'programme_id': programme.programmeId},
    'the programme',
  );

  static String? _textOrNull(String v) => v.trim().isEmpty ? null : v.trim();
}

/// Story 5.5, mobile My cell and Home: a meeting's published programme as a
/// member of the cell reads it (with which parts are theirs).
class MemberProgrammeController extends CellsController<MeetingProgrammeRead> {
  MemberProgrammeController(this.meetingId);

  final String meetingId;

  @override
  Future<AccessRead<MeetingProgrammeRead>> fetch() =>
      ref.read(cellsRepositoryProvider).fetchMeetingProgramme(meetingId);

  /// Story 5.7: tell the cell's leaders the member cannot attend this
  /// meeting (an optional practical note). Never answers a duty.
  Future<void> sendCannotAttend(String? note) =>
      send(CellAbsenceCommands.send, const Optional.of(null), {
        'meeting_id': meetingId,
        if (note != null && note.trim().isNotEmpty) 'note': note.trim(),
      }, 'your notice');

  Future<void> changeCannotAttend(AbsenceNotice notice, String? note) =>
      send(CellAbsenceCommands.change, Optional.of(notice.revision), {
        'notice_id': notice.noticeId,
        if (note != null && note.trim().isNotEmpty) 'note': note.trim(),
      }, 'your notice');

  Future<void> withdrawCannotAttend(AbsenceNotice notice) => send(
    CellAbsenceCommands.withdraw,
    Optional.of(notice.revision),
    {'notice_id': notice.noticeId},
    'your notice',
  );
}

final memberProgrammeProvider = NotifierProvider.autoDispose
    .family<
      MemberProgrammeController,
      CellsState<MeetingProgrammeRead>,
      String
    >(MemberProgrammeController.new);

final cellProgrammeProvider = NotifierProvider.autoDispose
    .family<CellProgrammeController, CellsState<ProgrammeRead>, String>(
      CellProgrammeController.new,
    );

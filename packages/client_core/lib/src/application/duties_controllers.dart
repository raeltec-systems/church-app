import 'dart:convert';

import 'package:church_contracts/church_contracts.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/access_grants.dart';
import '../domain/commands.dart';
import '../domain/duties.dart';
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

  /// The duty was already answered.
  alreadyAnswered,

  /// The duty has started: it can no longer be answered here.
  started,

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
  });

  final String function;
  final CommandRequest request;

  /// What was acted on (display only).
  final String subject;

  String get command => request.command;
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
    // and it cannot be sent twice.
    state = DutiesState<T>(
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
      DutyAction(
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

  static DutyNotice _success(DutyAction action, Object? data) =>
      switch (action.command) {
        DutyCommands.createDepartment => DutyNotice.departmentCreated,
        DutyCommands.revise =>
          data is Map && data['change'] == 'notes'
              ? DutyNotice.notesUpdated
              : DutyNotice.revised,
        DutyCommands.addMember => DutyNotice.memberAdded,
        GrantCommands.grantScope => DutyNotice.staffAssigned,
        GrantCommands.revokeScope => DutyNotice.staffRemoved,
        DutyCommands.publish => DutyNotice.published,
        _ =>
          action.request.payload['response'] == DutyResponse.declined.wire
              ? DutyNotice.declined
              : DutyNotice.accepted,
      };

  static DutyNotice _refusal(CommandError error) {
    final f = error.fieldErrors;
    return switch (error.code) {
      ErrorCode.conflict when f['assignment_id'] == 'responded' =>
        DutyNotice.alreadyAnswered,
      ErrorCode.conflict when f['assignment_id'] == 'superseded' =>
        DutyNotice.superseded,
      ErrorCode.conflict when f['assignment_id'] == 'cancelled' =>
        DutyNotice.dutyCancelled,
      ErrorCode.conflict when f['name'] == 'taken' => DutyNotice.nameTaken,
      ErrorCode.conflict => DutyNotice.changedElsewhere,
      ErrorCode.validationFailed
          when f['assignment_id'] == 'started' ||
              f['occurrence_id'] == 'started' =>
        DutyNotice.started,
      ErrorCode.validationFailed when f['occurrence_id'] == 'unchanged' =>
        DutyNotice.unchanged,
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
        final notice = _refusal(error);
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
}

final dutyLeaderProvider =
    NotifierProvider<DutyLeaderController, DutiesState<DutyLeaderBoard>>(
      DutyLeaderController.new,
    );

/// Mobile: the member's own duties; Accept or Can't make it.
class MyDutiesController extends DutiesController<MyDuties> {
  @override
  Future<AccessRead<MyDuties>> fetch() =>
      ref.read(dutiesRepositoryProvider).fetchMyDuties();

  Future<void> respond(MyDuty duty, DutyResponse response, {String? note}) {
    final n = note?.trim();
    return send(DutyCommands.respond, Optional.of(duty.revision), {
      'assignment_id': duty.assignmentId,
      'response': response.wire,
      if (n != null && n.isNotEmpty) 'note': n,
    }, duty.dutyName);
  }
}

final myDutiesProvider =
    NotifierProvider<MyDutiesController, DutiesState<MyDuties>>(
      MyDutiesController.new,
    );

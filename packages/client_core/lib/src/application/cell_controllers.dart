import 'dart:convert';

import 'package:church_contracts/church_contracts.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/access_grants.dart';
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
    // A denial or failure drops everything protected from the screen.
    state = CellsState<T>(
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
    _ => CellNotice.cancelled,
  };

  static CellNotice _refusal(CommandError error) {
    final f = error.fieldErrors;
    return switch (error.code) {
      ErrorCode.conflict when f['member_id'] == 'open_request' =>
        CellNotice.openRequest,
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
        if (notice != CellNotice.invalid && notice != CellNotice.selfAction) {
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

/// The member's own cell with the safe chooser's options.
class MyCellView {
  const MyCellView({required this.cell, required this.options});
  final MyCell cell;
  final List<CellOption> options;
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
    return AccessReadOk(
      MyCellView(
        cell: mine.value,
        options: switch (options) {
          AccessReadOk(:final value) => value,
          _ => const [],
        },
      ),
    );
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

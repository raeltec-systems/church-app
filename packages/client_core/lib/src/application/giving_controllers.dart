import 'dart:convert';

import 'package:church_contracts/church_contracts.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/access_grants.dart';
import '../domain/church_time.dart';
import '../domain/commands.dart';
import '../domain/content_giving.dart';
import 'access_controllers.dart' show noteProtectedDenial;
import 'content_controllers.dart'
    show ContentAction, PublicReadController, PublicReadState;
import 'providers.dart';

// Story 6.3: How to give (everyone, signed in or not) and the Admins' Giving
// screen on staff web. Public reads hold only the published projection, in
// memory; the Admins' read and its commands are protected state scoped to
// the account generation (AD-13). The server checks every read and command,
// and refuses to publish a revision a different Admin has not verified.

/// `api.content_public_giving_methods`: the published methods in order.
class PublicGivingMethodsController
    extends PublicReadController<PublicGivingMethods> {
  @override
  Future<AccessRead<PublicGivingMethods>> fetch() =>
      ref.read(givingRepositoryProvider).fetchPublicGivingMethods();
}

final publicGivingMethodsProvider =
    NotifierProvider<
      PublicGivingMethodsController,
      PublicReadState<PublicGivingMethods>
    >(PublicGivingMethodsController.new);

/// `api.content_public_giving_method`: one method (null when it is not
/// published).
class PublicGivingMethodController
    extends PublicReadController<PublicGivingMethodRead> {
  PublicGivingMethodController(this.methodId);

  final String methodId;

  @override
  Future<AccessRead<PublicGivingMethodRead>> fetch() =>
      ref.read(givingRepositoryProvider).fetchPublicGivingMethod(methodId);
}

final publicGivingMethodProvider = NotifierProvider.autoDispose
    .family<
      PublicGivingMethodController,
      PublicReadState<PublicGivingMethodRead>,
      String
    >(PublicGivingMethodController.new);

/// What the Giving screen tells the Admin after an action. Every refusal
/// code of the giving commands has its own notice.
enum GivingNotice {
  created,
  saved,
  verified,
  published,
  hidden,
  archived,
  moved,

  /// The unpublished changes of a live or hidden method were dropped.
  discarded,

  /// Changed in another tab or by another Admin: reloaded.
  changedElsewhere,

  /// A save that changes nothing is refused (the form keeps its input).
  unchanged,

  /// No draft to verify (published or archived meanwhile).
  nothingToVerify,

  /// The draft was verified already (by another Admin meanwhile).
  alreadyVerified,

  /// The caller saved changes to the draft: an Admin who saved none of it
  /// must verify it.
  savedByYou,

  /// No draft to discard (published or discarded meanwhile).
  nothingToDiscard,

  /// A never-published draft cannot be discarded (archive it instead).
  neverPublished,

  /// The draft is not verified, so it cannot be published.
  notVerified,
  nothingToPublish,

  /// Hidden already, or never published.
  notPublished,
  alreadyArchived,

  /// This server takes sample methods only: the name must start `SAMPLE `.
  sampleOnly,

  /// Publishing is closed here until the owner approves real giving details.
  gateClosed,

  /// The position is no longer in the list (it changed meanwhile).
  positionOutOfRange,
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

class StaffGivingState {
  const StaffGivingState({
    this.loading = false,
    this.result,
    this.pending,
    this.unconfirmed,
    this.notice,
    this.noticeAction,
    this.fieldErrors = const {},
  });

  final bool loading;
  final AccessRead<StaffGivingMethods>? result;
  final ContentAction? pending;
  final ContentAction? unconfirmed;
  final GivingNotice? notice;
  final ContentAction? noticeAction;
  final Map<String, String> fieldErrors;

  bool get busy => pending != null;
  StaffGivingMethods? get value => switch (result) {
    AccessReadOk<StaffGivingMethods>(:final value) => value,
    _ => null,
  };

  StaffGivingState copyWith({
    bool? loading,
    AccessRead<StaffGivingMethods>? result,
    ContentAction? pending,
    bool clearPending = false,
    ContentAction? unconfirmed,
    bool clearUnconfirmed = false,
    GivingNotice? notice,
    ContentAction? noticeAction,
    bool clearNotice = false,
    Map<String, String>? fieldErrors,
  }) => StaffGivingState(
    loading: loading ?? this.loading,
    result: result ?? this.result,
    pending: clearPending ? null : (pending ?? this.pending),
    unconfirmed: clearUnconfirmed ? null : (unconfirmed ?? this.unconfirmed),
    notice: clearNotice ? null : (notice ?? this.notice),
    noticeAction: clearNotice ? null : (noticeAction ?? this.noticeAction),
    fieldErrors: fieldErrors ?? this.fieldErrors,
  );
}

/// Staff web, Admins: every giving method and its commands (1.4 envelope)
/// with honest request states. A method shows as verified or live only
/// after the server confirmed it.
class StaffGivingController extends Notifier<StaffGivingState> {
  int _epoch = 0;

  @override
  StaffGivingState build() {
    ref.watch(accountGenerationProvider);
    _epoch++;
    final epoch = _epoch;
    Future.microtask(() => _reload(epoch));
    return const StaffGivingState(loading: true);
  }

  bool _current(int epoch) => ref.mounted && epoch == _epoch;

  Future<void> reload() => _reload(_epoch);

  Future<void> _reload(int epoch) async {
    if (!_current(epoch)) return;
    state = state.copyWith(loading: true);
    final r = await ref
        .read(givingRepositoryProvider)
        .fetchStaffGivingMethods();
    if (!_current(epoch)) return;
    // A denial or failure drops every method from the screen (the staff
    // house pattern); a command in flight stays pending so it cannot be
    // sent twice.
    state = StaffGivingState(
      result: r,
      pending: state.pending,
      unconfirmed: state.unconfirmed,
      notice: state.notice,
      noticeAction: state.noticeAction,
      fieldErrors: state.fieldErrors,
    );
    if (r is AccessReadDenied<StaffGivingMethods>) noteProtectedDenial(ref);
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

  Future<void> create(GivingMethodInput input) => _send(
    GivingCommands.create,
    const Optional.of(null),
    input.toPayload(),
    input.name.trim(),
  );

  Future<void> save(StaffGivingMethod method, GivingMethodInput input) => _send(
    GivingCommands.save,
    Optional.of(method.revision),
    input.toPayload(methodId: method.methodId),
    input.name.trim(),
  );

  /// Records that the caller checked the draft's details on [testedOn] (a
  /// church date) and how.
  Future<void> verify(
    StaffGivingMethod method, {
    required DateTime testedOn,
    required String testMethod,
  }) => _send(GivingCommands.verify, Optional.of(method.revision), {
    'method_id': method.methodId,
    'tested_on': ChurchTime.ymd(testedOn),
    'test_method': testMethod.trim(),
  }, method.current.name);

  Future<void> publish(StaffGivingMethod method) =>
      _lifecycle(GivingCommands.publish, method);

  Future<void> hide(StaffGivingMethod method) =>
      _lifecycle(GivingCommands.hide, method);

  Future<void> archive(StaffGivingMethod method) =>
      _lifecycle(GivingCommands.archive, method);

  /// Moves [method] to [position] (1-based among the methods that are not
  /// archived). Applies at once; no verification (order redirects nothing).
  Future<void> move(StaffGivingMethod method, int position) => _send(
    GivingCommands.move,
    Optional.of(method.revision),
    {'method_id': method.methodId, 'position': position},
    method.current.name,
  );

  /// Drops the unpublished changes of a method that has a live revision;
  /// the live revision stays as it is.
  Future<void> discard(StaffGivingMethod method) => _send(
    GivingCommands.discard,
    Optional.of(method.revision),
    {'method_id': method.methodId},
    (method.live ?? method.draft)!.fields.name,
  );

  Future<void> _lifecycle(String command, StaffGivingMethod method) => _send(
    command,
    Optional.of(method.revision),
    {'method_id': method.methodId},
    method.current.name,
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

  static GivingNotice _success(String command) => switch (command) {
    GivingCommands.create => GivingNotice.created,
    GivingCommands.save => GivingNotice.saved,
    GivingCommands.verify => GivingNotice.verified,
    GivingCommands.publish => GivingNotice.published,
    GivingCommands.hide => GivingNotice.hidden,
    GivingCommands.move => GivingNotice.moved,
    GivingCommands.discard => GivingNotice.discarded,
    _ => GivingNotice.archived,
  };

  static GivingNotice _refusal(CommandError error) {
    final f = error.fieldErrors;
    return switch (error.code) {
      ErrorCode.validationFailed => switch (f['method_id']) {
        'unchanged' => GivingNotice.unchanged,
        'nothing_to_verify' => GivingNotice.nothingToVerify,
        'already_verified' => GivingNotice.alreadyVerified,
        'saved_by_you' => GivingNotice.savedByYou,
        'nothing_to_discard' => GivingNotice.nothingToDiscard,
        'never_published' => GivingNotice.neverPublished,
        'not_verified' => GivingNotice.notVerified,
        'nothing_to_publish' => GivingNotice.nothingToPublish,
        'not_published' => GivingNotice.notPublished,
        'archived' => GivingNotice.alreadyArchived,
        _ when f['name'] == 'sample_only' => GivingNotice.sampleOnly,
        _ when f['position'] == 'out_of_range' =>
          GivingNotice.positionOutOfRange,
        _ => GivingNotice.invalid,
      },
      ErrorCode.conflict => GivingNotice.changedElsewhere,
      ErrorCode.forbidden => GivingNotice.notAllowed,
      ErrorCode.unauthenticated => GivingNotice.signInAgain,
      ErrorCode.notFound => GivingNotice.notFound,
      ErrorCode.unavailable when f['policy'] == 'gate_closed' =>
        GivingNotice.gateClosed,
      ErrorCode.unavailable ||
      ErrorCode.rateLimited => GivingNotice.notAvailable,
    };
  }

  /// Refusals that keep the typed input on screen (nothing to reload).
  static bool _keepsInput(GivingNotice n) =>
      n == GivingNotice.invalid ||
      n == GivingNotice.sampleOnly ||
      n == GivingNotice.unchanged;

  Future<void> _dispatch(ContentAction action) async {
    final epoch = _epoch;
    state = state.copyWith(
      pending: action,
      clearNotice: true,
      fieldErrors: const {},
    );
    final outcome = await ref
        .read(commandGatewayProvider)
        .send(GivingCommands.function, action.request);
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
        if (notice == GivingNotice.notAllowed ||
            notice == GivingNotice.signInAgain) {
          noteProtectedDenial(ref);
        }
        // A field error keeps the form as typed; anything else shows the
        // server's current methods.
        if (!_keepsInput(notice)) await _reload(epoch);
      case CommandUnknownOutcome():
        state = state.copyWith(
          clearPending: true,
          unconfirmed: action,
          notice: GivingNotice.unconfirmed,
          noticeAction: action,
        );
      case CommandNotSent():
        state = state.copyWith(
          clearPending: true,
          notice: GivingNotice.notSent,
          noticeAction: action,
        );
    }
  }
}

final staffGivingProvider =
    NotifierProvider<StaffGivingController, StaffGivingState>(
      StaffGivingController.new,
    );

import 'dart:convert';

import 'package:church_contracts/church_contracts.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/access_grants.dart';
import '../domain/commands.dart';
import '../domain/membership_application.dart';
import 'access_controllers.dart' show noteProtectedDenial;
import 'providers.dart';

/// What the application screen tells the applicant after sending.
enum ApplicationNotice {
  submitted,
  corrected,

  /// The request changed elsewhere (another device): reloaded.
  changedElsewhere,

  /// This account already has an open request: reloaded.
  alreadyApplied,

  /// The chosen cell is no longer offered or changed: the list was reloaded.
  cellListChanged,

  /// The form has fields to fix.
  invalid,
  signInAgain,

  /// The server refused (for example the account is already a member).
  refused,

  /// Requests are not being accepted here (personal-data gate).
  notAccepting,

  /// The outcome is unknown: check again with the same request.
  unconfirmed,
  notSent,
}

class ApplicationState {
  const ApplicationState({
    this.loading = false,
    this.result,
    this.optionsResult,
    this.pending,
    this.unconfirmed,
    this.notice,
    this.fieldErrors = const {},
  });

  final bool loading;

  /// The last answer for the caller's own application.
  final AccessRead<MyApplication>? result;

  /// The last answer for the safe cell chooser.
  final AccessRead<List<CellOption>>? optionsResult;

  /// The command in flight.
  final CommandRequest? pending;

  /// A command whose outcome is unknown; Check again resends it unchanged.
  final CommandRequest? unconfirmed;
  final ApplicationNotice? notice;

  /// Server field errors of the last refused command (wire field names).
  final Map<String, String> fieldErrors;

  bool get busy => pending != null;

  MyApplication? get mine => switch (result) {
    AccessReadOk(:final value) => value,
    _ => null,
  };

  List<CellOption> get options => switch (optionsResult) {
    AccessReadOk(:final value) => value,
    _ => const [],
  };

  ApplicationState copyWith({
    bool? loading,
    AccessRead<MyApplication>? result,
    AccessRead<List<CellOption>>? optionsResult,
    CommandRequest? pending,
    bool clearPending = false,
    CommandRequest? unconfirmed,
    bool clearUnconfirmed = false,
    ApplicationNotice? notice,
    bool clearNotice = false,
    Map<String, String>? fieldErrors,
  }) => ApplicationState(
    loading: loading ?? this.loading,
    result: result ?? this.result,
    optionsResult: optionsResult ?? this.optionsResult,
    pending: clearPending ? null : (pending ?? this.pending),
    unconfirmed: clearUnconfirmed ? null : (unconfirmed ?? this.unconfirmed),
    notice: clearNotice ? null : (notice ?? this.notice),
    fieldErrors: fieldErrors ?? this.fieldErrors,
  );
}

/// Story 2.4: the applicant's own membership request and the cell chooser,
/// with submit and correct through the 1.4 envelope. Protected state (AD-13):
/// memory only, scoped to the account generation; late answers for an older
/// generation are dropped. Applying grants nothing; the server decides every
/// read and command.
class MembershipApplicationController extends Notifier<ApplicationState> {
  int _epoch = 0;

  @override
  ApplicationState build() {
    ref.watch(accountGenerationProvider);
    final accountId = ref.watch(accountProvider.select((s) => s.accountId));
    _epoch++;
    if (accountId == null) {
      return const ApplicationState(
        result: AccessReadDenied(AccessDenial.signedOut),
      );
    }
    final epoch = _epoch;
    Future.microtask(() => _reload(epoch));
    return const ApplicationState(loading: true);
  }

  bool _current(int epoch) => ref.mounted && epoch == _epoch;

  /// Asks the server again for the request and the chooser.
  Future<void> reload() => _reload(_epoch);

  Future<void> _reload(int epoch) async {
    if (!_current(epoch) || ref.read(accountProvider).accountId == null) return;
    state = state.copyWith(loading: true);
    final repo = ref.read(membershipRepositoryProvider);
    final (mine, options) = await (
      repo.fetchMyApplication(),
      repo.fetchCellOptions(),
    ).wait;
    if (!_current(epoch)) return;
    state = ApplicationState(
      result: mine,
      optionsResult: options,
      unconfirmed: state.unconfirmed,
      notice: state.notice,
      fieldErrors: state.fieldErrors,
    );
    if (mine is AccessReadDenied<MyApplication> &&
        mine.denial != AccessDenial.signedOut) {
      noteProtectedDenial(ref);
      if (mine.denial == AccessDenial.untrustedSession) {
        await ref.read(accountProvider.notifier).endUntrustedSession();
      }
    }
  }

  void dismissNotice() =>
      state = state.copyWith(clearNotice: true, fieldErrors: const {});

  /// Submits a new request, or corrects the open one. The payload carries
  /// only what the applicant may set: never a membership or cell status.
  ///
  /// A new request is sent only when the applicant explicitly confirmed
  /// reading the privacy notice ([noticeAccepted]) and this client has the
  /// text of the server's notice version, so nobody accepts a notice they
  /// were never shown.
  Future<void> send({
    required String fullName,
    required CellChoice choice,
    bool noticeAccepted = false,
  }) {
    final mine = state.mine;
    if (mine == null || state.busy) return Future.value();
    final existing = mine.application;
    final correcting = existing != null && existing.correctable;
    if (!correcting &&
        (!noticeAccepted ||
            !privacyNoticeTexts.containsKey(mine.privacyNotice.version))) {
      return Future.value();
    }
    final command = correcting
        ? ApplicationCommands.correct
        : ApplicationCommands.submit;
    final Optional<int> expected = correcting
        ? Optional.of(existing.revision)
        : const Optional.of(null);
    final payload = <String, Object?>{
      if (correcting) 'application_id': existing.applicationId,
      'full_name': fullName,
      'cell_choice': choice.toJson(),
      if (!correcting) 'privacy_notice_version': mine.privacyNotice.version,
    };
    // An input whose outcome was never learned is resent under its original
    // request id; anything else is a new request.
    final u = state.unconfirmed;
    final same =
        u != null &&
        u.command == command &&
        u.expectedRevision.value == expected.value &&
        jsonEncode(u.payload) == jsonEncode(payload);
    return _dispatch(
      CommandRequest(
        command: command,
        requestId: same ? u.requestId : ref.read(requestIdsProvider).next(),
        expectedRevision: expected,
        payload: payload,
      ),
    );
  }

  /// Resends the unconfirmed command unchanged (same request_id and body).
  Future<void> checkAgain() async {
    final u = state.unconfirmed;
    if (u == null || state.busy) return;
    await _dispatch(u);
  }

  Future<void> _dispatch(CommandRequest request) async {
    final epoch = _epoch;
    state = state.copyWith(
      pending: request,
      clearNotice: true,
      fieldErrors: const {},
    );
    final outcome = await ref
        .read(commandGatewayProvider)
        .send(ApplicationCommands.function, request);
    if (!_current(epoch)) return;
    final submit = request.command == ApplicationCommands.submit;
    switch (outcome) {
      case CommandConfirmed(:final success):
        final MembershipApplication app;
        try {
          app = MembershipApplication.fromJson(success.data);
        } on FormatException {
          // Applied, but the answer is unusable: show the server's state.
          state = state.copyWith(clearPending: true, clearUnconfirmed: true);
          await _reload(epoch);
          return;
        }
        final mine = state.mine;
        state = state.copyWith(
          clearPending: true,
          clearUnconfirmed: true,
          result: mine == null ? null : AccessReadOk(mine.withApplication(app)),
          notice: submit
              ? ApplicationNotice.submitted
              : ApplicationNotice.corrected,
        );
      case CommandRefused(:final error):
        final errors = error.fieldErrors;
        final notice = switch (error.code) {
          ErrorCode.validationFailed =>
            errors.keys.any((k) => k.startsWith('cell_choice.cell_'))
                ? ApplicationNotice.cellListChanged
                : ApplicationNotice.invalid,
          ErrorCode.conflict =>
            submit
                ? ApplicationNotice.alreadyApplied
                : ApplicationNotice.changedElsewhere,
          ErrorCode.notFound => ApplicationNotice.changedElsewhere,
          ErrorCode.unauthenticated => ApplicationNotice.signInAgain,
          ErrorCode.unavailable => ApplicationNotice.notAccepting,
          _ => ApplicationNotice.refused,
        };
        state = state.copyWith(
          clearPending: true,
          clearUnconfirmed: true,
          notice: notice,
          fieldErrors: errors,
        );
        if (error.code == ErrorCode.forbidden ||
            error.code == ErrorCode.unauthenticated) {
          noteProtectedDenial(ref);
        }
        if (notice != ApplicationNotice.invalid) await _reload(epoch);
      case CommandUnknownOutcome():
        state = state.copyWith(
          clearPending: true,
          unconfirmed: request,
          notice: ApplicationNotice.unconfirmed,
        );
      case CommandNotSent():
        state = state.copyWith(
          clearPending: true,
          notice: ApplicationNotice.notSent,
        );
    }
  }
}

final membershipApplicationProvider =
    NotifierProvider<MembershipApplicationController, ApplicationState>(
      MembershipApplicationController.new,
    );

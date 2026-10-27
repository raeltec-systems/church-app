import 'package:church_contracts/church_contracts.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/access_grants.dart';
import '../domain/commands.dart';
import '../domain/hymn_lists.dart';
import 'access_controllers.dart' show noteProtectedDenial;
import 'content_controllers.dart' show PublicReadController, PublicReadState;
import 'providers.dart';

// Story 6.8: favourite hymns (signed-in members, private to each member) and
// Hymns for this Sunday (public; Admin, Media and worship leaders set it on
// staff web). Everything is in memory (AD-13): favourites are protected
// state scoped to the account generation; the public list is a public read.
// The server checks every read and command.

/// The clock the Sunday window reads (Home shows the list from Saturday
/// 00:00 to Sunday 23:59 church time). Tests replace it.
final hymnClockProvider = Provider<DateTime Function()>((ref) => DateTime.now);

/// `api.content_public_sunday_hymns`: this Sunday's list.
class PublicSundayHymnsController
    extends PublicReadController<PublicSundayHymns> {
  @override
  Future<AccessRead<PublicSundayHymns>> fetch() =>
      ref.read(hymnListsRepositoryProvider).fetchPublicSundayHymns();
}

final publicSundayHymnsProvider =
    NotifierProvider<
      PublicSundayHymnsController,
      PublicReadState<PublicSundayHymns>
    >(PublicSundayHymnsController.new);

/// What saving or removing a favourite ended in.
enum FavouriteNotice {
  saved,
  removed,

  /// Saving hymns is for approved church members.
  membersOnly,
  signInAgain,
  notAvailable,
  refused,

  /// The outcome is unknown: check again with the same request.
  unconfirmed,
  notSent,
}

/// One favourite command and the item it is about.
class FavouriteAction {
  const FavouriteAction({required this.request, required this.itemId});

  final CommandRequest request;
  final String itemId;

  bool get saves => request.command == HymnListCommands.saveFavourite;
}

class HymnFavouritesState {
  const HymnFavouritesState({
    required this.signedIn,
    this.loading = false,
    this.result,
    this.pending,
    this.unconfirmed,
    this.notice,
    this.noticeAction,
  });

  /// Signed out: nothing is read or sent (a guest is asked to sign in).
  final bool signedIn;
  final bool loading;
  final AccessRead<MyHymnFavourites>? result;
  final FavouriteAction? pending;
  final FavouriteAction? unconfirmed;
  final FavouriteNotice? notice;
  final FavouriteAction? noticeAction;

  bool get busy => pending != null;
  MyHymnFavourites? get value => switch (result) {
    AccessReadOk<MyHymnFavourites>(:final value) => value,
    _ => null,
  };

  /// Saved as far as the server last said.
  bool isSaved(String itemId) => value?.contains(itemId) ?? false;

  /// Being sent now.
  bool isSending(String itemId) => pending?.itemId == itemId;

  HymnFavouritesState copyWith({
    bool? loading,
    AccessRead<MyHymnFavourites>? result,
    FavouriteAction? pending,
    bool clearPending = false,
    FavouriteAction? unconfirmed,
    bool clearUnconfirmed = false,
    FavouriteNotice? notice,
    FavouriteAction? noticeAction,
    bool clearNotice = false,
  }) => HymnFavouritesState(
    signedIn: signedIn,
    loading: loading ?? this.loading,
    result: result ?? this.result,
    pending: clearPending ? null : (pending ?? this.pending),
    unconfirmed: clearUnconfirmed ? null : (unconfirmed ?? this.unconfirmed),
    notice: clearNotice ? null : (notice ?? this.notice),
    noticeAction: clearNotice ? null : (noticeAction ?? this.noticeAction),
  );
}

/// The signed-in member's favourite hymns, read from the server when asked
/// (the hymn book and Saved hymns ask on open, so a change made on another
/// phone shows) and changed one at a time. A hymn shows as saved only after
/// the server confirmed it.
class HymnFavouritesController extends Notifier<HymnFavouritesState> {
  int _epoch = 0;

  @override
  HymnFavouritesState build() {
    ref.watch(accountGenerationProvider);
    _epoch++;
    final epoch = _epoch;
    if (ref.read(accountProvider).accountId == null) {
      return const HymnFavouritesState(signedIn: false);
    }
    Future.microtask(() => _reload(epoch));
    return const HymnFavouritesState(signedIn: true, loading: true);
  }

  bool _current(int epoch) => ref.mounted && epoch == _epoch;

  Future<void> reload() => _reload(_epoch);

  Future<void> _reload(int epoch) async {
    if (!_current(epoch) || !state.signedIn) return;
    state = state.copyWith(loading: true);
    final r = await ref.read(hymnListsRepositoryProvider).fetchMyFavourites();
    if (!_current(epoch)) return;
    // A failed refresh keeps what the server said last; a denial drops it.
    state = HymnFavouritesState(
      signedIn: true,
      result: r is AccessReadFailed<MyHymnFavourites> && state.value != null
          ? state.result
          : r,
      pending: state.pending,
      unconfirmed: state.unconfirmed,
      notice: state.notice,
      noticeAction: state.noticeAction,
    );
  }

  void dismissNotice() => state = state.copyWith(clearNotice: true);

  /// Saves [itemId] of the book [edition].
  Future<void> save(String itemId, String edition) =>
      _send(HymnListCommands.saveFavourite, itemId, edition);

  /// Removes [itemId] (a state change on the server; the row stays).
  Future<void> remove(String itemId, String edition) =>
      _send(HymnListCommands.removeFavourite, itemId, edition);

  /// Resends the unconfirmed command unchanged (same request_id and body).
  Future<void> checkAgain() async {
    final u = state.unconfirmed;
    if (u == null || state.busy) return;
    await _dispatch(u);
  }

  Future<void> _send(String command, String itemId, String edition) async {
    if (state.busy || !state.signedIn) return;
    await _dispatch(
      FavouriteAction(
        itemId: itemId,
        request: resendOrNewRequest(
          unconfirmed: state.unconfirmed?.request,
          command: command,
          expected: const Optional.of(null),
          payload: {'edition': edition, 'item': itemId},
          ids: ref.read(requestIdsProvider),
        ),
      ),
    );
  }

  static FavouriteNotice _refusal(CommandError error) => switch (error.code) {
    ErrorCode.forbidden => FavouriteNotice.membersOnly,
    ErrorCode.unauthenticated => FavouriteNotice.signInAgain,
    ErrorCode.unavailable => FavouriteNotice.notAvailable,
    _ => FavouriteNotice.refused,
  };

  Future<void> _dispatch(FavouriteAction action) async {
    final epoch = _epoch;
    state = state.copyWith(pending: action, clearNotice: true);
    final outcome = await ref
        .read(commandGatewayProvider)
        .send(HymnListCommands.function, action.request);
    if (!_current(epoch)) return;
    switch (outcome) {
      case CommandConfirmed(:final success):
        final saved = switch (success.data) {
          {'saved': final bool s} => s,
          _ => action.saves,
        };
        final edition = action.request.payload['edition']! as String;
        final now = DateTime.now().toUtc();
        state = HymnFavouritesState(
          signedIn: true,
          result: AccessReadOk(
            (state.value ?? MyHymnFavourites.empty).withItem(
              action.itemId,
              saved: saved,
              edition: edition,
              at: now,
            ),
          ),
          notice: saved ? FavouriteNotice.saved : FavouriteNotice.removed,
          noticeAction: action,
        );
        await _reload(epoch);
      case CommandRefused(:final error):
        // Removing what another phone already removed (or never saved) is
        // done: the server's list is read again.
        if (!action.saves && error.code == ErrorCode.notFound) {
          state = state.copyWith(
            clearPending: true,
            clearUnconfirmed: true,
            notice: FavouriteNotice.removed,
            noticeAction: action,
          );
          await _reload(epoch);
          return;
        }
        final notice = _refusal(error);
        state = state.copyWith(
          clearPending: true,
          clearUnconfirmed: true,
          notice: notice,
          noticeAction: action,
        );
        if (notice == FavouriteNotice.membersOnly ||
            notice == FavouriteNotice.signInAgain) {
          noteProtectedDenial(ref);
        }
        await _reload(epoch);
      case CommandUnknownOutcome():
        state = state.copyWith(
          clearPending: true,
          unconfirmed: action,
          notice: FavouriteNotice.unconfirmed,
          noticeAction: action,
        );
      case CommandNotSent():
        state = state.copyWith(
          clearPending: true,
          notice: FavouriteNotice.notSent,
          noticeAction: action,
        );
    }
  }
}

final hymnFavouritesProvider =
    NotifierProvider<HymnFavouritesController, HymnFavouritesState>(
      HymnFavouritesController.new,
    );

/// What the Sunday hymns screen tells the editor after an action.
enum SundayHymnsNotice {
  saved,
  cleared,
  granted,
  revoked,

  /// Changed in another tab or by someone else: reloaded.
  changedElsewhere,

  /// Nothing to clear (cleared already, or never set).
  notSet,

  /// The Sunday is past or too far ahead, or an item is not in the book.
  invalid,

  /// The member already holds or no longer holds the scope.
  alreadyChanged,
  notAllowed,
  signInAgain,
  notAvailable,
  refused,

  /// The outcome is unknown: check again with the same request.
  unconfirmed,
  notSent,
}

/// One command of the Sunday hymns screen: a list command or a 2.3 grant.
class SundayHymnsAction {
  const SundayHymnsAction({
    required this.function,
    required this.request,
    required this.subject,
  });

  final String function;
  final CommandRequest request;

  /// What was acted on (display only): the Sunday or the member's name.
  final String subject;

  String get command => request.command;
}

class StaffSundayHymnsState {
  const StaffSundayHymnsState({
    this.loading = false,
    this.result,
    this.pending,
    this.unconfirmed,
    this.notice,
    this.noticeAction,
    this.fieldErrors = const {},
  });

  final bool loading;
  final AccessRead<StaffSundayHymns>? result;
  final SundayHymnsAction? pending;
  final SundayHymnsAction? unconfirmed;
  final SundayHymnsNotice? notice;
  final SundayHymnsAction? noticeAction;
  final Map<String, String> fieldErrors;

  bool get busy => pending != null;
  StaffSundayHymns? get value => switch (result) {
    AccessReadOk<StaffSundayHymns>(:final value) => value,
    _ => null,
  };

  StaffSundayHymnsState copyWith({
    bool? loading,
    AccessRead<StaffSundayHymns>? result,
    SundayHymnsAction? pending,
    bool clearPending = false,
    SundayHymnsAction? unconfirmed,
    bool clearUnconfirmed = false,
    SundayHymnsNotice? notice,
    SundayHymnsAction? noticeAction,
    bool clearNotice = false,
    Map<String, String>? fieldErrors,
  }) => StaffSundayHymnsState(
    loading: loading ?? this.loading,
    result: result ?? this.result,
    pending: clearPending ? null : (pending ?? this.pending),
    unconfirmed: clearUnconfirmed ? null : (unconfirmed ?? this.unconfirmed),
    notice: clearNotice ? null : (notice ?? this.notice),
    noticeAction: clearNotice ? null : (noticeAction ?? this.noticeAction),
    fieldErrors: fieldErrors ?? this.fieldErrors,
  );
}

/// Staff web, Admin, Media and worship leaders: every Sunday's list, its
/// commands, and (Admin) the worship leaders through the 2.3 grant command,
/// with honest request states. A list shows as set only after the server
/// confirmed it.
class StaffSundayHymnsController extends Notifier<StaffSundayHymnsState> {
  int _epoch = 0;

  @override
  StaffSundayHymnsState build() {
    ref.watch(accountGenerationProvider);
    _epoch++;
    final epoch = _epoch;
    Future.microtask(() => _reload(epoch));
    return const StaffSundayHymnsState(loading: true);
  }

  bool _current(int epoch) => ref.mounted && epoch == _epoch;

  Future<void> reload() => _reload(_epoch);

  Future<void> _reload(int epoch) async {
    if (!_current(epoch)) return;
    state = state.copyWith(loading: true);
    final r = await ref
        .read(hymnListsRepositoryProvider)
        .fetchStaffSundayHymns();
    if (!_current(epoch)) return;
    state = StaffSundayHymnsState(
      result: r,
      pending: state.pending,
      unconfirmed: state.unconfirmed,
      notice: state.notice,
      noticeAction: state.noticeAction,
      fieldErrors: state.fieldErrors,
    );
    if (r is AccessReadDenied<StaffSundayHymns>) noteProtectedDenial(ref);
  }

  void dismissNotice() =>
      state = state.copyWith(clearNotice: true, fieldErrors: const {});

  /// Resends the unconfirmed command unchanged (same request_id and body).
  Future<void> checkAgain() async {
    final u = state.unconfirmed;
    if (u == null || state.busy) return;
    await _dispatch(u);
  }

  /// Sets [sunday]'s list to [items] (in order) of the book [edition].
  Future<void> setList(
    StaffSundayHymns s,
    String sunday,
    String edition,
    List<String> items,
  ) => _send(
    HymnListCommands.function,
    HymnListCommands.setSunday,
    Optional.of(s.revision),
    {
      'sunday': sunday,
      'edition': edition,
      'items': [...items],
    },
    sunday,
  );

  /// Clears [sunday]'s list.
  Future<void> clearList(StaffSundayHymns s, String sunday) => _send(
    HymnListCommands.function,
    HymnListCommands.clearSunday,
    Optional.of(s.revision),
    {'sunday': sunday},
    sunday,
  );

  /// Admin: makes [member] a worship leader (the scope on the Sunday-list
  /// record).
  Future<void> grantWorshipLeader(
    StaffSundayHymns s,
    WorshipLeaderCandidate member,
  ) => _send(
    GrantCommands.function,
    GrantCommands.grantScope,
    Optional.of(member.grantsRevision),
    {
      'member_id': member.memberId,
      'scope_kind': HymnListCommands.worshipLeaderScope,
      'scope_id': s.listId,
    },
    member.displayName,
  );

  /// Admin: removes [leader]'s worship-leader scope.
  Future<void> revokeWorshipLeader(StaffSundayHymns s, WorshipLeader leader) =>
      _send(
        GrantCommands.function,
        GrantCommands.revokeScope,
        Optional.of(leader.grantsRevision),
        {
          'member_id': leader.memberId,
          'scope_kind': HymnListCommands.worshipLeaderScope,
          'scope_id': s.listId,
        },
        leader.displayName,
      );

  Future<void> _send(
    String function,
    String command,
    Optional<int> expected,
    Map<String, Object?> payload,
    String subject,
  ) async {
    if (state.busy) return;
    await _dispatch(
      SundayHymnsAction(
        function: function,
        subject: subject,
        request: resendOrNewRequest(
          unconfirmed: state.unconfirmed?.request,
          command: command,
          expected: expected,
          payload: payload,
          ids: ref.read(requestIdsProvider),
        ),
      ),
    );
  }

  static SundayHymnsNotice _success(SundayHymnsAction a) => switch (a.command) {
    HymnListCommands.setSunday => SundayHymnsNotice.saved,
    HymnListCommands.clearSunday => SundayHymnsNotice.cleared,
    GrantCommands.grantScope => SundayHymnsNotice.granted,
    _ => SundayHymnsNotice.revoked,
  };

  static SundayHymnsNotice _refusal(SundayHymnsAction a, CommandError error) {
    final grant = a.function == GrantCommands.function;
    return switch (error.code) {
      ErrorCode.validationFailed
          when error.fieldErrors['sunday'] == 'not_set' =>
        SundayHymnsNotice.notSet,
      ErrorCode.validationFailed => SundayHymnsNotice.invalid,
      ErrorCode.conflict when grant => SundayHymnsNotice.alreadyChanged,
      ErrorCode.conflict => SundayHymnsNotice.changedElsewhere,
      ErrorCode.forbidden => SundayHymnsNotice.notAllowed,
      ErrorCode.unauthenticated => SundayHymnsNotice.signInAgain,
      ErrorCode.notFound when grant => SundayHymnsNotice.alreadyChanged,
      ErrorCode.unavailable => SundayHymnsNotice.notAvailable,
      _ => SundayHymnsNotice.refused,
    };
  }

  Future<void> _dispatch(SundayHymnsAction action) async {
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
      case CommandConfirmed():
        state = state.copyWith(
          clearPending: true,
          clearUnconfirmed: true,
          notice: _success(action),
          noticeAction: action,
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
        if (notice == SundayHymnsNotice.notAllowed ||
            notice == SundayHymnsNotice.signInAgain) {
          noteProtectedDenial(ref);
        }
        // A field error keeps the list as edited; anything else shows the
        // server's current lists.
        if (notice != SundayHymnsNotice.invalid) await _reload(epoch);
      case CommandUnknownOutcome():
        state = state.copyWith(
          clearPending: true,
          unconfirmed: action,
          notice: SundayHymnsNotice.unconfirmed,
          noticeAction: action,
        );
      case CommandNotSent():
        state = state.copyWith(
          clearPending: true,
          notice: SundayHymnsNotice.notSent,
          noticeAction: action,
        );
    }
  }
}

final staffSundayHymnsProvider =
    NotifierProvider<StaffSundayHymnsController, StaffSundayHymnsState>(
      StaffSundayHymnsController.new,
    );

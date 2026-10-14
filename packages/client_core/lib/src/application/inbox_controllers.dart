import 'dart:async';

import 'package:church_contracts/church_contracts.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/access_grants.dart';
import '../domain/commands.dart';
import '../domain/inbox.dart';
import 'access_controllers.dart';
import 'providers.dart';

/// The caller's inbox as last answered by the server for the CURRENT account
/// generation.
class InboxState {
  const InboxState({
    this.loading = false,
    this.result,
    this.olderFailed = false,
    this.refreshFailed = false,
  });

  final bool loading;
  final AccessRead<Inbox>? result;

  /// The last request for an older page got no usable answer.
  final bool olderFailed;

  /// Story 3.7: the last re-read got no usable answer; the list shown is the
  /// previous answer, kept rather than blanked.
  final bool refreshFailed;

  Inbox? get inbox => switch (result) {
    AccessReadOk(:final value) => value,
    _ => null,
  };
}

/// Story 3.1: the durable inbox on both clients. Protected state (AD-13):
/// memory only, scoped to one account generation, dropped on sign-out or an
/// account change; a late answer for an older generation is discarded. The
/// screen asks again when it opens, on **Check again** and when the app
/// returns to the foreground. The server checks the live-access predicate on
/// every read.
class InboxController extends Notifier<InboxState> {
  bool _again = false;

  /// Older pages were appended: a re-read merges its first page in front of
  /// them instead of replacing the list (story 3.7).
  bool _olderLoaded = false;

  @override
  InboxState build() {
    _again = false;
    _olderLoaded = false;
    final generation = ref.watch(accountGenerationProvider);
    final accountId = ref.watch(accountProvider.select((s) => s.accountId));
    if (accountId == null) {
      return const InboxState(result: AccessReadDenied(AccessDenial.signedOut));
    }
    Future.microtask(() => _load(generation));
    return const InboxState(loading: true);
  }

  /// Asks the server again. A request already in flight is followed by one
  /// more, so the answer always reflects a read made after this call.
  Future<void> refresh() async {
    if (state.loading) {
      _again = true;
      return;
    }
    await _load(ref.read(accountGenerationProvider));
  }

  /// Appends the next older page. Any other answer keeps what is shown and
  /// reports it; a denial is handled like a fresh read.
  Future<void> loadOlder() async {
    final current = state.inbox;
    final after = current?.next;
    if (state.loading || current == null || after == null) return;
    final generation = ref.read(accountGenerationProvider);
    state = InboxState(loading: true, result: state.result);
    final result = await ref
        .read(inboxRepositoryProvider)
        .fetchMyInbox(after: after);
    if (!ref.mounted || ref.read(accountGenerationProvider) != generation) {
      return;
    }
    switch (result) {
      case AccessReadOk(:final value):
        _olderLoaded = true;
        state = InboxState(result: AccessReadOk(current.append(value)));
      case AccessReadDenied():
        _olderLoaded = false;
        state = InboxState(result: result);
        if (result.denial == AccessDenial.untrustedSession) {
          _again = false;
          await ref.read(accountProvider.notifier).endUntrustedSession();
          return;
        } else {
          noteProtectedDenial(ref);
        }
      case AccessReadFailed():
        state = InboxState(result: state.result, olderFailed: true);
    }
    // A signal or refresh that arrived meanwhile is not lost (story 3.7).
    if (_again) {
      _again = false;
      await _load(generation);
    }
  }

  /// Story 3.7: the new first page in front of the older pages already
  /// shown (deduplicated by id); items the server dropped from the older
  /// range stay until the next full read (Check again from the top).
  Inbox _merge(Inbox shown, Inbox first) {
    if (!_olderLoaded || first.next == null || first.items.isEmpty) {
      _olderLoaded = _olderLoaded && first.next != null;
      return first;
    }
    final last = first.items.last;
    final ids = {for (final i in first.items) i.itemId};
    bool older(InboxItem i) =>
        i.deliveredAt.isBefore(last.deliveredAt) ||
        (i.deliveredAt == last.deliveredAt &&
            i.itemId.compareTo(last.itemId) < 0);
    return Inbox(
      items: List.unmodifiable([
        ...first.items,
        ...shown.items.where((i) => !ids.contains(i.itemId) && older(i)),
      ]),
      next: shown.next,
    );
  }

  Future<void> _load(int generation) async {
    if (!ref.mounted || ref.read(accountGenerationProvider) != generation) {
      _again = false;
      return;
    }
    if (ref.read(accountProvider).accountId == null) {
      _again = false;
      return;
    }
    state = InboxState(loading: true, result: state.result);
    final result = await ref.read(inboxRepositoryProvider).fetchMyInbox();
    if (!ref.mounted || ref.read(accountGenerationProvider) != generation) {
      _again = false;
      return;
    }
    final shown = state.inbox;
    switch (result) {
      case AccessReadOk(:final value):
        state = InboxState(
          result: AccessReadOk(shown == null ? value : _merge(shown, value)),
        );
      case AccessReadFailed() when shown != null:
        // Story 3.7: a failed re-read (often a background signal or poll)
        // keeps the list shown and says so; it never blanks it.
        state = InboxState(result: state.result, refreshFailed: true);
      case _:
        _olderLoaded = false;
        state = InboxState(result: result);
    }
    if (result is AccessReadDenied<Inbox>) {
      if (result.denial == AccessDenial.untrustedSession) {
        _again = false;
        // Same rule as the member summary (story 2.2): end the session here.
        await ref.read(accountProvider.notifier).endUntrustedSession();
        return;
      }
      noteProtectedDenial(ref);
    }
    if (_again) {
      _again = false;
      await _load(generation);
    }
  }
}

final inboxProvider = NotifierProvider<InboxController, InboxState>(
  InboxController.new,
);

/// One opened item as last answered by the server for the CURRENT account
/// generation (no result while the first answer is pending).
class InboxItemOpenState {
  const InboxItemOpenState({this.loading = false, this.result});

  final bool loading;
  final AccessRead<OpenedInboxItem>? result;

  OpenedInboxItem? get opened => switch (result) {
    AccessReadOk(:final value) => value,
    _ => null,
  };
}

/// Story 3.2: opening one inbox item. Every open asks the server, which
/// re-reads the item's source through its registered contract; nothing is
/// kept beyond this screen and this account generation (AD-13).
class InboxItemController extends Notifier<InboxItemOpenState> {
  InboxItemController(this.itemId);

  final String itemId;

  @override
  InboxItemOpenState build() {
    final generation = ref.watch(accountGenerationProvider);
    final accountId = ref.watch(accountProvider.select((s) => s.accountId));
    if (accountId == null) {
      return const InboxItemOpenState(
        result: AccessReadDenied(AccessDenial.signedOut),
      );
    }
    Future.microtask(() => _load(generation));
    return const InboxItemOpenState(loading: true);
  }

  /// Asks the server again (ignored while a request is in flight).
  Future<void> refresh() async {
    if (state.loading) return;
    await _load(ref.read(accountGenerationProvider));
  }

  Future<void> _load(int generation) async {
    if (!ref.mounted || ref.read(accountGenerationProvider) != generation) {
      return;
    }
    if (ref.read(accountProvider).accountId == null) return;
    state = InboxItemOpenState(loading: true, result: state.result);
    final result = await ref.read(inboxRepositoryProvider).openItem(itemId);
    if (!ref.mounted || ref.read(accountGenerationProvider) != generation) {
      return;
    }
    state = InboxItemOpenState(result: result);
    if (result is AccessReadDenied<OpenedInboxItem>) {
      if (result.denial == AccessDenial.untrustedSession) {
        await ref.read(accountProvider.notifier).endUntrustedSession();
        return;
      }
      noteProtectedDenial(ref);
    }
  }
}

final inboxItemProvider = NotifierProvider.autoDispose
    .family<InboxItemController, InboxItemOpenState, String>(
      InboxItemController.new,
    );

/// How often an open inbox asks the server again when no signal arrives
/// (Realtime unavailable, a missed signal, a blocked socket).
const inboxPollInterval = Duration(minutes: 2);

/// Story 3.7: keeps an OPEN inbox current. While watched (by the Inbox
/// screen) it listens to the server's per-account generic signal and re-reads
/// the inbox on each one (and on every (re)connect), and also re-reads every
/// [inboxPollInterval]. The signal carries nothing: the authorised read
/// decides what is shown. Dropped with the screen or the account generation.
final inboxLiveProvider = Provider.autoDispose<void>((ref) {
  final accountId = ref.watch(accountProvider.select((s) => s.accountId));
  ref.watch(accountGenerationProvider);
  if (accountId == null) return;
  void refresh() {
    if (ref.mounted) ref.read(inboxProvider.notifier).refresh();
  }

  final sub = ref
      .watch(inboxSignalsProvider)
      .changes(accountId)
      .listen((_) => refresh(), onError: (Object _) {});
  final timer = Timer.periodic(inboxPollInterval, (_) => refresh());
  ref.onDispose(() {
    timer.cancel();
    unawaited(sub.cancel());
  });
});

/// Where one snooze request stands.
enum SnoozeStatus {
  idle,
  sending,

  /// The server moved this member's reminder: see [SnoozeState.confirmed].
  confirmed,

  /// The reminder no longer needs the member (answered, changed, cancelled
  /// or no longer theirs to see): nothing was snoozed.
  outOfDate,

  /// The reminder already stopped mattering: nothing was snoozed.
  expired,

  /// Not one of the caller's items (or no longer there).
  notFound,

  /// Any other refusal (policy unavailable, access changed): nothing applied.
  refused,

  /// No answer: the snooze may or may not have applied. **Try again**
  /// resends the identical request and the server answers the stored
  /// outcome.
  unknown,

  /// This build has no server: nothing was sent.
  notSent,
}

class SnoozeState {
  const SnoozeState(this.status, {this.choice, this.confirmed});

  final SnoozeStatus status;

  /// The choice of the last request.
  final String? choice;
  final SnoozeConfirmation? confirmed;
}

/// Story 3.7: the member snoozes one of their reminders
/// (`notifications.snooze_item {item_id, choice}` on
/// `api.notifications_command`). Only the server decides: it re-checks the
/// source, applies the policy choice, clamps it to when the reminder stops
/// mattering, and replaces an earlier snooze of the same item. A snooze dies
/// on the server with a response, a cancellation or a change of its source.
class SnoozeController extends Notifier<SnoozeState> {
  SnoozeController(this.itemId);

  final String itemId;
  CommandRequest? _pending;

  @override
  SnoozeState build() {
    ref.watch(accountGenerationProvider);
    _pending = null;
    return const SnoozeState(SnoozeStatus.idle);
  }

  /// Snoozes for [choice] (one of the opened item's policy choices).
  Future<void> snooze(String choice) async {
    if (state.status == SnoozeStatus.sending) return;
    _pending = CommandRequest(
      command: 'notifications.snooze_item',
      requestId: ref.read(requestIdsProvider).next(),
      payload: {'item_id': itemId, 'choice': choice},
    );
    await _send(choice);
  }

  /// After an unknown outcome: resends the identical request.
  Future<void> retry() async {
    if (state.status != SnoozeStatus.unknown || _pending == null) return;
    await _send(state.choice);
  }

  Future<void> _send(String? choice) async {
    final request = _pending!;
    final generation = ref.read(accountGenerationProvider);
    state = SnoozeState(SnoozeStatus.sending, choice: choice);
    final outcome = await ref
        .read(commandGatewayProvider)
        .send('notifications_command', request);
    if (!ref.mounted || ref.read(accountGenerationProvider) != generation) {
      return;
    }
    switch (outcome) {
      case CommandConfirmed(:final success):
        SnoozeConfirmation? confirmed;
        try {
          confirmed = SnoozeConfirmation.fromJson(success.data);
        } on FormatException {
          confirmed = null;
        }
        if (confirmed == null) {
          // An unusable answer is not success: ask the same request again.
          state = SnoozeState(SnoozeStatus.unknown, choice: choice);
          return;
        }
        _pending = null;
        state = SnoozeState(
          SnoozeStatus.confirmed,
          choice: choice,
          confirmed: confirmed,
        );
        _reread();
      case CommandRefused(:final error):
        _pending = null;
        state = SnoozeState(switch (error.code) {
          ErrorCode.conflict => switch (error.fieldErrors['item_id']) {
            'expired' => SnoozeStatus.expired,
            _ => SnoozeStatus.outOfDate,
          },
          ErrorCode.notFound => SnoozeStatus.notFound,
          _ => SnoozeStatus.refused,
        }, choice: choice);
        if (error.code == ErrorCode.forbidden ||
            error.code == ErrorCode.unauthenticated) {
          noteProtectedDenial(ref);
        }
        _reread();
      case CommandUnknownOutcome():
        state = SnoozeState(SnoozeStatus.unknown, choice: choice);
      case CommandNotSent():
        _pending = null;
        state = SnoozeState(SnoozeStatus.notSent, choice: choice);
    }
  }

  /// The item and the list are read again: the server's answer is shown.
  void _reread() {
    unawaited(ref.read(inboxItemProvider(itemId).notifier).refresh());
    unawaited(ref.read(inboxProvider.notifier).refresh());
  }
}

final snoozeProvider = NotifierProvider.autoDispose
    .family<SnoozeController, SnoozeState, String>(SnoozeController.new);

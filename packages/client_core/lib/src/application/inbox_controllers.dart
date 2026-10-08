import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/access_grants.dart';
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
  });

  final bool loading;
  final AccessRead<Inbox>? result;

  /// The last request for an older page got no usable answer.
  final bool olderFailed;

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

  @override
  InboxState build() {
    _again = false;
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
        state = InboxState(result: AccessReadOk(current.append(value)));
      case AccessReadDenied():
        state = InboxState(result: result);
        if (result.denial == AccessDenial.untrustedSession) {
          await ref.read(accountProvider.notifier).endUntrustedSession();
        } else {
          noteProtectedDenial(ref);
        }
      case AccessReadFailed():
        state = InboxState(result: state.result, olderFailed: true);
    }
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
    state = InboxState(result: result);
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

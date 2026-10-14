import 'dart:async';

import 'package:church_contracts/church_contracts.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/access_grants.dart';
import '../domain/commands.dart';
import '../domain/notification_settings.dart';
import 'access_controllers.dart';
import 'providers.dart';

/// What the settings screen says after a change.
enum PushSettingNotice {
  /// The server saved it.
  saved,

  /// It was changed elsewhere first: the latest settings are shown.
  changedElsewhere,

  /// Refused (for example the category no longer exists): nothing changed.
  refused,

  /// No answer: it may or may not have been saved. **Try again** resends the
  /// identical request.
  unknown,

  /// This build has no server: nothing was sent.
  notSent,
}

class NotificationSettingsState {
  const NotificationSettingsState({
    this.loading = false,
    this.result,
    this.saving,
    this.notice,
    this.noticeKey,
  });

  final bool loading;
  final AccessRead<NotificationSettings>? result;

  /// The category key ([PushCategory.key]) whose change is in flight.
  final String? saving;
  final PushSettingNotice? notice;

  /// The category the [notice] is about.
  final String? noticeKey;

  NotificationSettings? get settings => switch (result) {
    AccessReadOk(:final value) => value,
    _ => null,
  };

  NotificationSettingsState copyWith({
    bool? loading,
    AccessRead<NotificationSettings>? result,
    String? saving,
    bool clearSaving = false,
    PushSettingNotice? notice,
    String? noticeKey,
    bool clearNotice = false,
  }) => NotificationSettingsState(
    loading: loading ?? this.loading,
    result: result ?? this.result,
    saving: clearSaving ? null : (saving ?? this.saving),
    notice: clearNotice ? null : (notice ?? this.notice),
    noticeKey: clearNotice ? null : (noticeKey ?? this.noticeKey),
  );
}

/// Story 3.7: the member's push settings by category
/// (`api.notifications_my_push_settings`, `notifications.set_push_category`).
/// Push off for a category stops phone notifications for it only; the inbox
/// keeps every reminder. Memory only, one account generation (AD-13).
class NotificationSettingsController
    extends Notifier<NotificationSettingsState> {
  CommandRequest? _pending;
  String? _pendingKey;

  @override
  NotificationSettingsState build() {
    _pending = null;
    _pendingKey = null;
    final generation = ref.watch(accountGenerationProvider);
    final accountId = ref.watch(accountProvider.select((s) => s.accountId));
    if (accountId == null) {
      return const NotificationSettingsState(
        result: AccessReadDenied(AccessDenial.signedOut),
      );
    }
    Future.microtask(() => _load(generation));
    return const NotificationSettingsState(loading: true);
  }

  Future<void> refresh() async {
    if (state.loading) return;
    await _load(ref.read(accountGenerationProvider));
  }

  /// Turns push for [category] on or off, at the revision shown.
  Future<void> setPush(PushCategory category, bool enabled) async {
    if (state.saving != null) return;
    _pending = CommandRequest(
      command: 'notifications.set_push_category',
      requestId: ref.read(requestIdsProvider).next(),
      expectedRevision: category.revision == null
          ? const Optional<int>.absent()
          : Optional<int>.of(category.revision!),
      payload: {
        'source_type': category.sourceType,
        'reminder_kind': category.reminderKind,
        'push_enabled': enabled,
      },
    );
    _pendingKey = category.key;
    await _send();
  }

  /// After an unknown outcome: resends the identical request.
  Future<void> retry() async {
    if (_pending == null || state.notice != PushSettingNotice.unknown) return;
    await _send();
  }

  Future<void> _send() async {
    final request = _pending!;
    final key = _pendingKey!;
    final generation = ref.read(accountGenerationProvider);
    state = state.copyWith(saving: key, clearNotice: true);
    final outcome = await ref
        .read(commandGatewayProvider)
        .send('notifications_command', request);
    if (!ref.mounted || ref.read(accountGenerationProvider) != generation) {
      return;
    }
    final notice = switch (outcome) {
      CommandConfirmed() => PushSettingNotice.saved,
      CommandRefused(:final error) =>
        error.code == ErrorCode.conflict
            ? PushSettingNotice.changedElsewhere
            : PushSettingNotice.refused,
      CommandUnknownOutcome() => PushSettingNotice.unknown,
      CommandNotSent() => PushSettingNotice.notSent,
    };
    if (notice != PushSettingNotice.unknown) {
      _pending = null;
      _pendingKey = null;
    }
    state = state.copyWith(clearSaving: true, notice: notice, noticeKey: key);
    if (outcome case CommandRefused(:final error)
        when error.code == ErrorCode.forbidden ||
            error.code == ErrorCode.unauthenticated) {
      noteProtectedDenial(ref);
    }
    if (notice != PushSettingNotice.unknown &&
        notice != PushSettingNotice.notSent) {
      await _load(generation);
    }
  }

  Future<void> _load(int generation) async {
    if (!ref.mounted || ref.read(accountGenerationProvider) != generation) {
      return;
    }
    if (ref.read(accountProvider).accountId == null) return;
    state = state.copyWith(loading: true);
    final result = await ref
        .read(notificationSettingsRepositoryProvider)
        .fetchMySettings();
    if (!ref.mounted || ref.read(accountGenerationProvider) != generation) {
      return;
    }
    state = NotificationSettingsState(
      result: result,
      saving: state.saving,
      notice: state.notice,
      noticeKey: state.noticeKey,
    );
    if (result is AccessReadDenied<NotificationSettings>) {
      if (result.denial == AccessDenial.untrustedSession) {
        await ref.read(accountProvider.notifier).endUntrustedSession();
        return;
      }
      noteProtectedDenial(ref);
    }
  }
}

final notificationSettingsProvider =
    NotifierProvider.autoDispose<
      NotificationSettingsController,
      NotificationSettingsState
    >(NotificationSettingsController.new);

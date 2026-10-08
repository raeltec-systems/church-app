/// Story 3.7: the member's notification settings by category
/// (`api.notifications_my_push_settings`, story 3.5) and the per-account
/// inbox refresh signal. Free of widgets and SDKs.
library;

import 'access_grants.dart';

/// Push on or off for one reminder category (a registered reminder kind).
/// Turning push off never removes in-app items: the inbox keeps them.
class PushCategory {
  const PushCategory({
    required this.sourceType,
    required this.reminderKind,
    required this.title,
    required this.pushEnabled,
    this.revision,
  });

  factory PushCategory.fromJson(Object? json) {
    if (json is! Map ||
        json['source_type'] is! String ||
        json['reminder_kind'] is! String ||
        json['title'] is! String ||
        json['push_enabled'] is! bool ||
        (json['revision'] != null && json['revision'] is! int)) {
      throw const FormatException('unexpected push category');
    }
    return PushCategory(
      sourceType: json['source_type'] as String,
      reminderKind: json['reminder_kind'] as String,
      title: json['title'] as String,
      pushEnabled: json['push_enabled'] as bool,
      revision: json['revision'] as int?,
    );
  }

  final String sourceType;
  final String reminderKind;

  /// The generic title its source owner registered.
  final String title;
  final bool pushEnabled;

  /// The setting's revision, or null while no setting exists (push is on).
  final int? revision;

  String get key => '$sourceType/$reminderKind';
}

/// The caller's categories and how many of their devices can receive push.
class NotificationSettings {
  const NotificationSettings({required this.categories, this.liveDevices = 0});

  factory NotificationSettings.fromJson(Object? json) {
    if (json is! Map || json['categories'] is! List) {
      throw const FormatException('unexpected notification settings');
    }
    final devices = json['devices'];
    if (devices != null && devices is! List) {
      throw const FormatException('unexpected devices');
    }
    var live = 0;
    for (final d in (devices as List?) ?? const []) {
      if (d is! Map) throw const FormatException('unexpected device');
      if (d['retired'] != true) live++;
    }
    return NotificationSettings(
      categories: List.unmodifiable(
        (json['categories'] as List).map(PushCategory.fromJson),
      ),
      liveDevices: live,
    );
  }

  final List<PushCategory> categories;

  /// Devices (phones) registered for push on this account, never their
  /// tokens.
  final int liveDevices;
}

/// Application port for the settings read. Never throws.
abstract interface class NotificationSettingsRepository {
  Future<AccessRead<NotificationSettings>> fetchMySettings();
}

class UnconfiguredNotificationSettingsRepository
    implements NotificationSettingsRepository {
  const UnconfiguredNotificationSettingsRepository();

  @override
  Future<AccessRead<NotificationSettings>> fetchMySettings() async =>
      const AccessReadDenied(AccessDenial.unavailable);
}

/// Story 3.7: the server's per-account "your inbox changed" signal. It
/// carries nothing (no id, text or source type): a listener re-reads the
/// inbox through the authorised read. A signal may be missed; the inbox also
/// re-reads when it opens, on resume, on pull-to-refresh and by polling.
abstract interface class InboxSignals {
  /// Emits once per signal for [accountId]'s own channel, and once each time
  /// the channel (re)connects, since a signal may have been missed while it
  /// was down. Cancel the subscription to leave the channel.
  Stream<void> changes(String accountId);
}

/// No signals (tests, unconfigured builds): polling and re-reads only.
class NoInboxSignals implements InboxSignals {
  const NoInboxSignals();

  @override
  Stream<void> changes(String accountId) => const Stream.empty();
}

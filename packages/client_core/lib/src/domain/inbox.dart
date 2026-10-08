/// Story 3.1: the signed-in member's durable inbox, as the server reports it
/// (`api.notifications_my_inbox`). An item is a pointer only: its reminder
/// kind and times, never a source id, revision or private text. Free of
/// widgets and SDKs.
library;

import 'access_grants.dart';

/// One delivered reminder.
class InboxItem {
  const InboxItem({
    required this.itemId,
    required this.reminderKind,
    required this.dueAt,
    required this.deliveredAt,
  });

  /// Maps the wire object; throws [FormatException] on any unexpected shape.
  factory InboxItem.fromJson(Object? json) {
    if (json is! Map ||
        json['item_id'] is! String ||
        json['reminder_kind'] is! String ||
        json['due_at'] is! String ||
        json['delivered_at'] is! String) {
      throw const FormatException('unexpected inbox item');
    }
    final due = DateTime.tryParse(json['due_at'] as String);
    final delivered = DateTime.tryParse(json['delivered_at'] as String);
    if (due == null || !due.isUtc || delivered == null || !delivered.isUtc) {
      throw const FormatException('inbox times must be UTC instants');
    }
    return InboxItem(
      itemId: json['item_id'] as String,
      reminderKind: json['reminder_kind'] as String,
      dueAt: due,
      deliveredAt: delivered,
    );
  }

  final String itemId;

  /// The registered reminder kind (wire name).
  final String reminderKind;
  final DateTime dueAt;
  final DateTime deliveredAt;

  /// A generic label for the kind. Registered generic text arrives with the
  /// source contracts (epic 3, entry 2); until then an unknown kind is a
  /// plain "Reminder".
  String get title => switch (reminderKind) {
    'fixture_due' => 'SYNTHETIC test reminder',
    _ => 'Reminder',
  };
}

/// The keyset position after which the next (older) page starts.
class InboxCursor {
  const InboxCursor({
    required this.afterDeliveredAt,
    required this.afterItemId,
  });

  factory InboxCursor.fromJson(Object? json) {
    if (json is! Map ||
        json['after_delivered_at'] is! String ||
        json['after_item_id'] is! String) {
      throw const FormatException('unexpected inbox cursor');
    }
    return InboxCursor(
      afterDeliveredAt: json['after_delivered_at'] as String,
      afterItemId: json['after_item_id'] as String,
    );
  }

  /// The server's exact wire instant (microseconds kept).
  final String afterDeliveredAt;
  final String afterItemId;

  Map<String, Object?> toParams() => {
    'after_delivered_at': afterDeliveredAt,
    'after_item_id': afterItemId,
  };
}

/// One page of the caller's items (at most 50), newest first, and the
/// cursor of the next older page (null on the last page).
class Inbox {
  const Inbox({required this.items, this.next});

  factory Inbox.fromJson(Object? json) {
    if (json is! Map || json['items'] is! List) {
      throw const FormatException('unexpected inbox');
    }
    final next = json['next'];
    return Inbox(
      items: List.unmodifiable((json['items'] as List).map(InboxItem.fromJson)),
      next: next == null ? null : InboxCursor.fromJson(next),
    );
  }

  final List<InboxItem> items;
  final InboxCursor? next;

  /// This page followed by an older one.
  Inbox append(Inbox older) => Inbox(
    items: List.unmodifiable([...items, ...older.items]),
    next: older.next,
  );
}

/// Application port for the inbox read. Never throws; a fresh request every
/// call.
abstract interface class InboxRepository {
  /// The caller's own inbox (`api.notifications_my_inbox`): the newest
  /// page, or the page after [after].
  Future<AccessRead<Inbox>> fetchMyInbox({InboxCursor? after});
}

/// A build without backend configuration: nothing to show.
class UnconfiguredInboxRepository implements InboxRepository {
  const UnconfiguredInboxRepository();

  @override
  Future<AccessRead<Inbox>> fetchMyInbox({InboxCursor? after}) async =>
      const AccessReadDenied(AccessDenial.unavailable);
}

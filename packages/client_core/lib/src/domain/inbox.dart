/// Story 3.1: the signed-in member's durable inbox, as the server reports it
/// (`api.notifications_my_inbox`). An item is a pointer only: its reminder
/// kind, the generic text its source owner registered (story 3.2) and times,
/// never a source id, revision or private text. Opening an item
/// (`api.notifications_open_item`, story 3.2) re-reads the source on the
/// server. Free of widgets and SDKs.
library;

import 'access_grants.dart';

/// One delivered reminder.
class InboxItem {
  const InboxItem({
    required this.itemId,
    required this.reminderKind,
    required this.dueAt,
    required this.deliveredAt,
    this.registeredTitle,
    this.body,
  });

  /// Maps the wire object; throws [FormatException] on any unexpected shape.
  factory InboxItem.fromJson(Object? json) {
    if (json is! Map ||
        json['item_id'] is! String ||
        json['reminder_kind'] is! String ||
        json['due_at'] is! String ||
        json['delivered_at'] is! String ||
        (json['title'] != null && json['title'] is! String) ||
        (json['body'] != null && json['body'] is! String)) {
      throw const FormatException('unexpected inbox item');
    }
    return InboxItem(
      itemId: json['item_id'] as String,
      reminderKind: json['reminder_kind'] as String,
      dueAt: _utc(json['due_at']),
      deliveredAt: _utc(json['delivered_at']),
      registeredTitle: json['title'] as String?,
      body: json['body'] as String?,
    );
  }

  final String itemId;

  /// The registered reminder kind (wire name).
  final String reminderKind;
  final DateTime dueAt;
  final DateTime deliveredAt;

  /// The generic title its source owner registered (story 3.2), if any.
  final String? registeredTitle;

  /// The generic body its source owner registered (story 3.2), if any.
  final String? body;

  /// The registered title; a plain label for a server that sends none.
  String get title =>
      registeredTitle ??
      switch (reminderKind) {
        'fixture_due' => 'SYNTHETIC test reminder',
        _ => 'Reminder',
      };
}

DateTime _utc(Object? wire) {
  final at = wire is String ? DateTime.tryParse(wire) : null;
  if (at == null || !at.isUtc) {
    throw const FormatException('inbox times must be UTC instants');
  }
  return at;
}

/// What opening an item found when the server re-read its source just now.
enum InboxItemState {
  /// The source is current, still needs the member, and the member may still
  /// see it: the item carries the authorised [OpenedInboxItem.target].
  current,

  /// The source changed, was cancelled or expired, or the member may no
  /// longer see it. The server says no more than that, on purpose.
  superseded,

  /// Not one of the caller's items (or no longer there).
  notFound,
}

/// Story 3.2: one item as `api.notifications_open_item` answered it.
class OpenedInboxItem {
  const OpenedInboxItem._(this.state, this.item, this.target);

  const OpenedInboxItem.notFound()
    : this._(InboxItemState.notFound, null, null);

  /// Maps the wire object; throws [FormatException] on any unexpected shape,
  /// including a target on anything but a current item, or a target that is
  /// not an in-app path.
  factory OpenedInboxItem.fromJson(Object? json) {
    if (json is! Map) throw const FormatException('unexpected opened item');
    switch (json['state']) {
      case 'not_found':
        if (json.length != 1) {
          throw const FormatException('unexpected opened item');
        }
        return const OpenedInboxItem.notFound();
      case 'current':
        final target = json['target'];
        if (target is! String || !isInAppPath(target)) {
          throw const FormatException('a current item needs an in-app target');
        }
        return OpenedInboxItem._(
          InboxItemState.current,
          InboxItem.fromJson(json),
          target,
        );
      case 'superseded':
        if (json['target'] != null) {
          throw const FormatException('a superseded item has no target');
        }
        return OpenedInboxItem._(
          InboxItemState.superseded,
          InboxItem.fromJson(json),
          null,
        );
      default:
        throw const FormatException('unexpected opened item state');
    }
  }

  final InboxItemState state;

  /// The item's generic text and times (null when not found).
  final InboxItem? item;

  /// The authorised in-app route of the source (current items only).
  final String? target;
}

/// A relative in-app path: lower-case segments only, no scheme, host, query
/// or fragment (the shape the server registers, story 3.2).
bool isInAppPath(String path) =>
    RegExp(r'^(/[a-z0-9][a-z0-9_-]*)+$').hasMatch(path) && path.length <= 200;

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

  /// Opens one of the caller's items (`api.notifications_open_item`): the
  /// server re-reads its source now (story 3.2).
  Future<AccessRead<OpenedInboxItem>> openItem(String itemId);
}

/// A build without backend configuration: nothing to show.
class UnconfiguredInboxRepository implements InboxRepository {
  const UnconfiguredInboxRepository();

  @override
  Future<AccessRead<Inbox>> fetchMyInbox({InboxCursor? after}) async =>
      const AccessReadDenied(AccessDenial.unavailable);

  @override
  Future<AccessRead<OpenedInboxItem>> openItem(String itemId) async =>
      const AccessReadDenied(AccessDenial.unavailable);
}

/// Epic 6 entry 19: the signed-in member's own duties and cell meetings laid
/// over the public Calendar. Two separate reads feed it: the 4.5 My duties
/// read (`api.duties_my_duties`, unchanged) and a new bounded Cells read
/// (`api.cells_my_meetings`: the member's own confirmed cell's meetings for
/// the next 31 days, dates, times and cancelled state, no venue). The
/// Calendar itself (Content) reads neither module's data on the server; the
/// overlay is composed here, on the member's phone, and is never cached.
/// Free of widgets and SDKs.
library;

import 'access_grants.dart';
import 'duties.dart';

T _req<T>(Map json, String key) {
  final v = json[key];
  if (v is! T) throw FormatException('unexpected $key');
  return v;
}

Map _map(Object? json, String what) {
  if (json is! Map) throw FormatException('$what is not an object');
  return json;
}

DateTime _instant(Map json, String key) {
  final v = _req<String>(json, key);
  // Contract v1 instants are UTC with `Z`; an offset is refused.
  final at = v.endsWith('Z') ? DateTime.tryParse(v) : null;
  if (at == null || !at.isUtc) throw FormatException('unexpected $key');
  return at;
}

/// How far ahead the overlays reach: the Cells read's window (31 days), so
/// both overlays cover the same month.
const calendarOverlayWindow = Duration(days: 31);

/// One meeting of the member's own cell on the overlay.
class OverlayMeeting {
  const OverlayMeeting({
    required this.meetingId,
    required this.occurrenceDate,
    required this.startsAt,
    required this.endsAt,
    required this.cancelled,
    required this.moved,
  });

  factory OverlayMeeting.fromJson(Object? json) {
    final m = _map(json, 'meeting');
    final state = _req<String>(m, 'state');
    if (state != 'scheduled' && state != 'moved' && state != 'cancelled') {
      throw FormatException('unexpected meeting state $state');
    }
    final date = _req<String>(m, 'occurrence_date');
    if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(date)) {
      throw const FormatException('unexpected occurrence_date');
    }
    final startsAt = _instant(m, 'starts_at');
    final endsAt = _instant(m, 'ends_at');
    if (!endsAt.isAfter(startsAt)) {
      throw const FormatException('unexpected ends_at');
    }
    return OverlayMeeting(
      meetingId: _req<String>(m, 'meeting_id'),
      occurrenceDate: date,
      startsAt: startsAt,
      endsAt: endsAt,
      cancelled: state == 'cancelled',
      moved: state == 'moved',
    );
  }

  final String meetingId;

  /// The nominal church date (`YYYY-MM-DD`).
  final String occurrenceDate;
  final DateTime startsAt;
  final DateTime endsAt;
  final bool cancelled;

  /// Moved from its usual time this once.
  final bool moved;
}

/// `api.cells_my_meetings`: the member's own cell's meetings in the window.
/// [cellId] is null when the member has no confirmed cell or the cell has no
/// schedule (then [meetings] is empty).
class MyCellMeetingsWindow {
  const MyCellMeetingsWindow({
    required this.cellId,
    required this.from,
    required this.until,
    required this.meetings,
  });

  factory MyCellMeetingsWindow.fromJson(Object? json) {
    final m = _map(json, 'my meetings');
    final cell = m['cell_id'];
    if (cell != null && cell is! String) {
      throw const FormatException('unexpected cell_id');
    }
    final meetings = List<OverlayMeeting>.unmodifiable(
      _req<List>(m, 'meetings').map(OverlayMeeting.fromJson),
    );
    if (cell == null && meetings.isNotEmpty) {
      throw const FormatException('unexpected meetings');
    }
    return MyCellMeetingsWindow(
      cellId: cell as String?,
      from: _instant(m, 'from'),
      until: _instant(m, 'until'),
      meetings: meetings,
    );
  }

  final String? cellId;
  final DateTime from;
  final DateTime until;
  final List<OverlayMeeting> meetings;
}

/// The member's own cell meetings (`api.cells_my_meetings`).
abstract interface class CellCalendarRepository {
  Future<AccessRead<MyCellMeetingsWindow>> fetchMyMeetings();
}

class UnconfiguredCellCalendarRepository implements CellCalendarRepository {
  const UnconfiguredCellCalendarRepository();

  @override
  Future<AccessRead<MyCellMeetingsWindow>> fetchMyMeetings() async =>
      const AccessReadDenied(AccessDenial.unavailable);
}

/// Which overlay an item belongs to.
enum CalendarOverlayKind { duty, cell }

/// One of the member's own items on the Calendar: a duty (opens its duty
/// detail) or a cell meeting (opens My cell).
class CalendarOverlayItem {
  const CalendarOverlayItem({
    required this.kind,
    required this.id,
    required this.title,
    required this.startsAt,
    this.endsAt,
    this.reportingAt,
    this.place,
    this.dueOnly = false,
    this.cancelled = false,
    this.moved = false,
  });

  final CalendarOverlayKind kind;

  /// The assignment id (duty) or the meeting id (cell).
  final String id;
  final String title;

  /// Where the item sits on the Calendar: the duty's start (a "done by"
  /// assignment: its due moment) or the meeting's start.
  final DateTime startsAt;
  final DateTime? endsAt;

  /// A duty's report time, when earlier than its start.
  final DateTime? reportingAt;

  /// A duty's location (cell meetings carry no venue here).
  final String? place;

  /// A "done by" special assignment: shown as due on its date, never a time.
  final bool dueOnly;

  /// A cancelled cell meeting (still listed, marked).
  final bool cancelled;

  /// A cell meeting moved from its usual time.
  final bool moved;
}

/// The overlay items for [now], soonest first: with [duties] the member's
/// current duties (waiting for an answer or accepted; not declined, not
/// ended) that start within [window]; with [cell] their cell's meetings in
/// the Cells read's window. Either may be null (that overlay is off or not
/// loaded).
List<CalendarOverlayItem> calendarOverlayItems({
  required DateTime now,
  MyDuties? duties,
  MyCellMeetingsWindow? cell,
  Duration window = calendarOverlayWindow,
}) {
  final until = now.add(window);
  final items = <CalendarOverlayItem>[
    if (duties != null)
      for (final d in duties.assignments)
        if ((d.response == DutyResponse.pending ||
                d.response == DutyResponse.accepted) &&
            (d.times.endsAt ?? d.times.startsAt).isAfter(now) &&
            d.times.startsAt.isBefore(until))
          CalendarOverlayItem(
            kind: CalendarOverlayKind.duty,
            id: d.assignmentId,
            title: d.title,
            startsAt: d.times.startsAt,
            endsAt: d.times.endsAt,
            reportingAt: d.times.reportingAt,
            place: d.location,
            dueOnly: d.times.isDue,
          ),
    if (cell != null)
      for (final m in cell.meetings)
        CalendarOverlayItem(
          kind: CalendarOverlayKind.cell,
          id: m.meetingId,
          title: 'Cell meeting',
          startsAt: m.startsAt,
          endsAt: m.endsAt,
          cancelled: m.cancelled,
          moved: m.moved,
        ),
  ];
  items.sort((a, b) {
    final t = a.startsAt.compareTo(b.startsAt);
    if (t != 0) return t;
    final k = a.kind.index.compareTo(b.kind.index);
    return k != 0 ? k : a.id.compareTo(b.id);
  });
  return List.unmodifiable(items);
}

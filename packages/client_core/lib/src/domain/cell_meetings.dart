/// Story 5.1: a cell's weekly meetings as the server reports them. The
/// schedule, the stable meeting ids, the exceptions and who may see the venue
/// are all decided by the server; these reads are presentation only. Times
/// travel as UTC instants and are shown in church time. Free of widgets and
/// SDKs.
library;

T _req<T>(Map json, String key) {
  final v = json[key];
  if (v is! T) throw FormatException('unexpected $key');
  return v;
}

T? _opt<T>(Map json, String key) {
  final v = json[key];
  if (v == null) return null;
  if (v is! T) throw FormatException('unexpected $key');
  return v;
}

Map _map(Object? json, String what) {
  if (json is! Map) throw FormatException('$what is not an object');
  return json;
}

DateTime _instant(Map json, String key) {
  final v = _req<String>(json, key);
  // Contract v1 instants are UTC with `Z`; an offset is refused, not converted.
  final at = v.endsWith('Z') ? DateTime.tryParse(v) : null;
  if (at == null || !at.isUtc) throw FormatException('unexpected $key');
  return at;
}

final _hhmm = RegExp(r'^([01][0-9]|2[0-3]):[0-5][0-9]$');
final _ymd = RegExp(r'^\d{4}-\d{2}-\d{2}$');

String _clock(Map json, String key) {
  final v = _req<String>(json, key);
  if (!_hhmm.hasMatch(v)) throw FormatException('unexpected $key');
  return v;
}

String _date(Map json, String key) {
  final v = _req<String>(json, key);
  if (!_ymd.hasMatch(v)) throw FormatException('unexpected $key');
  return v;
}

/// The cells meeting command names (1.4 envelope, `cells_command`).
abstract final class CellMeetingCommands {
  static const setSchedule = 'cells.set_schedule';
  static const move = 'cells.move_meeting';
  static const cancel = 'cells.cancel_meeting';
  static const reinstate = 'cells.reinstate_meeting';

  /// Story 5.2: the cell's meeting reminders (leader or Admin).
  static const setReminders = 'cells.set_meeting_reminders';
}

/// Story 5.2: the reminder offsets a leader can choose from (3.3 durations,
/// before the start; at most 3, at most 7 days).
const meetingReminderChoices = [
  '1 hour',
  '2 hours',
  '24 hours',
  '2 days',
  '7 days',
];

/// "24 hours" reads "1 day before", "2 hours" "2 hours before".
String reminderLabel(String before) => switch (before) {
  '24 hours' => '1 day before',
  '1 hour' => '1 hour before',
  _ => '$before before',
};

/// Story 5.2: a member the leader should tell directly about a meeting (no
/// app access right now). Shown to the cell's leader and assistant only.
class MeetingContactNeed {
  const MeetingContactNeed({required this.memberId, required this.displayName});

  factory MeetingContactNeed.fromJson(Object? json) {
    final m = _map(json, 'contact need');
    return MeetingContactNeed(
      memberId: _req<String>(m, 'member_id'),
      displayName: _req<String>(m, 'display_name'),
    );
  }

  final String memberId;
  final String displayName;
}

/// ISO weekday (1 = Monday) names for the schedule.
const meetingWeekdays = [
  'Monday',
  'Tuesday',
  'Wednesday',
  'Thursday',
  'Friday',
  'Saturday',
  'Sunday',
];

String weekdayName(int isoWeekday) => meetingWeekdays[isoWeekday - 1];

enum MeetingState {
  scheduled('scheduled'),
  moved('moved'),
  cancelled('cancelled');

  const MeetingState(this.wire);
  final String wire;

  static MeetingState fromWire(Object? v) {
    for (final s in values) {
      if (s.wire == v) return s;
    }
    throw FormatException('unexpected meeting state $v');
  }
}

/// A map pin (cell-private, like the venue).
class MeetingMapPin {
  const MeetingMapPin({required this.lat, required this.lng});

  factory MeetingMapPin.fromJson(Object? json) {
    final m = _map(json, 'map pin');
    final lat = _req<num>(m, 'lat'), lng = _req<num>(m, 'lng');
    if (lat.abs() > 90 || lng.abs() > 180) {
      throw const FormatException('unexpected map pin');
    }
    return MeetingMapPin(lat: lat.toDouble(), lng: lng.toDouble());
  }

  final double lat;
  final double lng;

  /// `-15.77123, 28.18456`: what a member can paste into a maps app.
  String get text => '${lat.toStringAsFixed(5)}, ${lng.toStringAsFixed(5)}';
}

/// One meeting with its stable id. [venue] and [mapPin] are null unless the
/// caller has the cell's private access (leader, assistant or member).
class CellMeeting {
  const CellMeeting({
    required this.meetingId,
    required this.cellId,
    required this.occurrenceDate,
    required this.state,
    required this.startsAt,
    required this.endsAt,
    required this.nominalStartsAt,
    required this.nominalEndsAt,
    required this.venueMoved,
    required this.revision,
    this.venue,
    this.mapPin,
    this.contactNeeds = const [],
  });

  factory CellMeeting.fromJson(Object? json) {
    final m = _map(json, 'meeting');
    final revision = _req<int>(m, 'revision');
    if (revision < 1) throw const FormatException('unexpected revision');
    return CellMeeting(
      meetingId: _req<String>(m, 'meeting_id'),
      cellId: _req<String>(m, 'cell_id'),
      occurrenceDate: _date(m, 'occurrence_date'),
      state: MeetingState.fromWire(m['state']),
      startsAt: _instant(m, 'starts_at'),
      endsAt: _instant(m, 'ends_at'),
      nominalStartsAt: _instant(m, 'nominal_starts_at'),
      nominalEndsAt: _instant(m, 'nominal_ends_at'),
      venueMoved: _req<bool>(m, 'venue_moved'),
      revision: revision,
      venue: _opt<String>(m, 'venue'),
      mapPin: m['map_pin'] == null
          ? null
          : MeetingMapPin.fromJson(m['map_pin']),
      // Story 5.2: on the staff read only (empty elsewhere).
      contactNeeds: m['contact_needs'] == null
          ? const []
          : List.unmodifiable(
              _req<List>(m, 'contact_needs').map(MeetingContactNeed.fromJson),
            ),
    );
  }

  final String meetingId;
  final String cellId;

  /// The nominal church-local date (the occurrence key), `YYYY-MM-DD`.
  final String occurrenceDate;
  final MeetingState state;
  final DateTime startsAt;
  final DateTime endsAt;
  final DateTime nominalStartsAt;
  final DateTime nominalEndsAt;

  /// This meeting alone meets somewhere else.
  final bool venueMoved;

  /// expected_revision of the meeting commands.
  final int revision;
  final String? venue;
  final MeetingMapPin? mapPin;

  /// Story 5.2: members to tell directly about this meeting.
  final List<MeetingContactNeed> contactNeeds;

  bool get moved => state == MeetingState.moved;
  bool get cancelled => state == MeetingState.cancelled;
}

/// A cell's weekly rule as staff see it. [venue] and [mapPin] are null for
/// an Admin without the cell's access ([venueSet] still says it is set).
class MeetingSchedule {
  const MeetingSchedule({
    required this.weekday,
    required this.startTime,
    required this.endTime,
    required this.fromDate,
    required this.zone,
    required this.venueSet,
    required this.pinSet,
    this.venue,
    this.mapPin,
    this.reminders = const ['24 hours'],
    this.remindersDefault = true,
    this.remindersRevision = 1,
  });

  factory MeetingSchedule.fromJson(Object? json) {
    final m = _map(json, 'schedule');
    final weekday = _req<int>(m, 'weekday');
    if (weekday < 1 || weekday > 7) throw const FormatException('weekday');
    // Story 5.2 (absent from 5.1 servers: the default).
    final reminders = m['reminders'] == null
        ? const ['24 hours']
        : List<String>.unmodifiable(
            _req<List>(
              m,
              'reminders',
            ).map((r) => _req<String>(_map(r, 'reminder'), 'before')),
          );
    return MeetingSchedule(
      reminders: reminders,
      remindersDefault: _opt<bool>(m, 'reminders_default') ?? true,
      remindersRevision: _opt<int>(m, 'reminders_revision') ?? 1,
      weekday: weekday,
      startTime: _clock(m, 'start_time'),
      endTime: _clock(m, 'end_time'),
      fromDate: _date(m, 'from_date'),
      zone: _req<String>(m, 'zone'),
      venueSet: _req<bool>(m, 'venue_set'),
      pinSet: _req<bool>(m, 'pin_set'),
      venue: _opt<String>(m, 'venue'),
      mapPin: m['map_pin'] == null
          ? null
          : MeetingMapPin.fromJson(m['map_pin']),
    );
  }

  /// ISO weekday, 1 = Monday.
  final int weekday;

  /// Church-local `HH:MM`.
  final String startTime;
  final String endTime;
  final String fromDate;
  final String zone;
  final bool venueSet;
  final bool pinSet;
  final String? venue;
  final MeetingMapPin? mapPin;

  /// Story 5.2: the cell's reminder offsets before the start (`24 hours`).
  final List<String> reminders;

  /// No offsets chosen: the default (one day before).
  final bool remindersDefault;

  /// expected_revision of cells.set_meeting_reminders.
  final int remindersRevision;

  String get summary => '${weekdayName(weekday)}s, $startTime-$endTime';

  String get remindersText => reminders.isEmpty
      ? 'No reminders'
      : reminders.map(reminderLabel).join(', ');
}

enum MeetingRole { leader, assistant, admin }

/// One cell on the staff meetings screen.
class StaffMeetingCell {
  const StaffMeetingCell({
    required this.cellId,
    required this.name,
    required this.isSynthetic,
    required this.role,
    required this.canChange,
    required this.canSetSchedule,
    required this.meetings,
    this.cellRevision,
    this.schedule,
    this.recent = const [],
  });

  factory StaffMeetingCell.fromJson(Object? json) {
    final m = _map(json, 'meeting cell');
    final canSet = _req<bool>(m, 'can_set_schedule');
    final cellRevision = _opt<int>(m, 'cell_revision');
    if (canSet && cellRevision == null) {
      throw const FormatException('unexpected cell_revision');
    }
    return StaffMeetingCell(
      cellId: _req<String>(m, 'cell_id'),
      name: _req<String>(m, 'name'),
      isSynthetic: _req<bool>(m, 'is_synthetic'),
      role: switch (m['role']) {
        'leader' => MeetingRole.leader,
        'assistant' => MeetingRole.assistant,
        'admin' => MeetingRole.admin,
        _ => throw const FormatException('unexpected role'),
      },
      canChange: _req<bool>(m, 'can_change'),
      canSetSchedule: canSet,
      cellRevision: cellRevision,
      schedule: m['schedule'] == null
          ? null
          : MeetingSchedule.fromJson(m['schedule']),
      meetings: List.unmodifiable(
        _req<List>(m, 'meetings').map(CellMeeting.fromJson),
      ),
      // Story 5.8 (absent from 5.7 servers).
      recent: List.unmodifiable(
        (_opt<List>(m, 'recent') ?? const []).map(RecentMeeting.fromJson),
      ),
    );
  }

  final String cellId;
  final String name;
  final bool isSynthetic;

  /// The caller's role for this cell (`admin`: Admin without a cell scope).
  final MeetingRole role;

  /// May move, cancel and reinstate meetings (the leader, or an Admin).
  final bool canChange;

  /// May set the weekly schedule (Admin).
  final bool canSetSchedule;

  /// expected_revision of cells.set_schedule (Admin only).
  final int? cellRevision;
  final MeetingSchedule? schedule;
  final List<CellMeeting> meetings;

  /// Story 5.8: meetings that started in the last four weeks, newest first.
  final List<RecentMeeting> recent;
}

/// Story 5.8: what is known of a meeting afterwards. Not recorded is its
/// own state: it is never read as held, or as not held.
enum MeetingStatus {
  scheduled('scheduled'),
  held('held'),
  notHeld('not_held'),
  unrecorded('unrecorded'),
  cancelled('cancelled');

  const MeetingStatus(this.wire);
  final String wire;

  /// Null for a status this build does not know (a later server's).
  static MeetingStatus? tryParse(Object? v) {
    for (final s in MeetingStatus.values) {
      if (s.wire == v) return s;
    }
    return null;
  }
}

/// Story 5.8: a meeting of the last four weeks and its status.
class RecentMeeting {
  const RecentMeeting({required this.meeting, this.status});

  factory RecentMeeting.fromJson(Object? json) {
    final m = _map(json, 'recent meeting');
    return RecentMeeting(
      meeting: CellMeeting.fromJson(m),
      status: MeetingStatus.tryParse(m['status']),
    );
  }

  final CellMeeting meeting;

  /// Null when this build does not know the server's status.
  final MeetingStatus? status;
}

/// `api.cells_meetings`.
class CellMeetingsBoard {
  const CellMeetingsBoard({required this.cells});

  factory CellMeetingsBoard.fromJson(Object? json) {
    final m = _map(json, 'meetings board');
    return CellMeetingsBoard(
      cells: List.unmodifiable(
        _req<List>(m, 'cells').map(StaffMeetingCell.fromJson),
      ),
    );
  }

  final List<StaffMeetingCell> cells;
}

/// A cancelled meeting before the next one (My cell).
class CancelledMeeting {
  const CancelledMeeting({
    required this.meetingId,
    required this.occurrenceDate,
    required this.nominalStartsAt,
  });

  factory CancelledMeeting.fromJson(Object? json) {
    final m = _map(json, 'cancelled meeting');
    return CancelledMeeting(
      meetingId: _req<String>(m, 'meeting_id'),
      occurrenceDate: _date(m, 'occurrence_date'),
      nominalStartsAt: _instant(m, 'nominal_starts_at'),
    );
  }

  final String meetingId;
  final String occurrenceDate;
  final DateTime nominalStartsAt;
}

/// `meetings` of `api.cells_my_cell`: the member's own cell's next meeting
/// (with the private venue) and the cancelled meetings before it.
class MyCellMeetings {
  const MyCellMeetings({required this.cancelled, this.next});

  factory MyCellMeetings.fromJson(Object? json) {
    final m = _map(json, 'my cell meetings');
    return MyCellMeetings(
      next: m['next'] == null ? null : CellMeeting.fromJson(m['next']),
      cancelled: List.unmodifiable(
        _req<List>(m, 'cancelled').map(CancelledMeeting.fromJson),
      ),
    );
  }

  final CellMeeting? next;
  final List<CancelledMeeting> cancelled;
}

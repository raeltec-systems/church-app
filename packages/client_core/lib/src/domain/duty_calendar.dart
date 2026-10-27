/// Story 4.5: Add to calendar for one of the member's duties. The app builds
/// a standard iCalendar (RFC 5545) event and hands it to the phone (the share
/// sheet on mobile). The exported entry is a copy: it does not update when
/// the duty changes, which every screen that offers it says. Instructions and
/// notes are never exported (a calendar may sync to other services). Free of
/// widgets and SDKs.
library;

import 'church_time.dart';
import 'duties.dart';
import 'icalendar_text.dart';

abstract final class DutyCalendar {
  /// When a duty has no end time, the exported event lasts this long (the
  /// same assumption as the 4.4 busy time).
  static const defaultLength = Duration(hours: 2);

  /// What every Add to calendar offer says.
  static const staleCaveat =
      'The calendar entry is a copy: it does not change if the duty changes '
      'or is cancelled. My duties in this app always shows the current '
      'version.';

  /// A file name for [duty]'s event (`duty-2099-01-04.ics`, church date).
  static String fileName(MyDuty duty) {
    final w = ChurchTime.wall(duty.times.arriveBy);
    String two(int v) => v.toString().padLeft(2, '0');
    return 'duty-${w.year.toString().padLeft(4, '0')}-${two(w.month)}-'
        '${two(w.day)}.ics';
  }

  /// The event's UID: the occurrence and its position (slot), so it stays
  /// the same when a material change replaces the assignment. A server
  /// before 4.5 sends no slot id; the assignment id stands in.
  static String uid(MyDuty duty) =>
      'duty-${duty.occurrenceId}-${duty.slotId ?? duty.assignmentId}'
      '@bickafue.app';

  /// The iCalendar text of [duty] (CRLF lines, folded at 75 octets). [now]
  /// is the export time (DTSTAMP).
  static String ics(MyDuty duty, {required DateTime now}) {
    final start = duty.times.arriveBy;
    final end = duty.times.endsAt ?? duty.times.startsAt.add(defaultLength);
    // Special assignments: a due date is an all-day entry on that date (it
    // has no time), titled "Due: ...".
    final due = duty.times.dueOn;
    final description = [
      // Story 4.11: a cell programme part names no department.
      if (duty.departmentName case final d?)
        'Department: $d.'
      else if (duty.isSpecial)
        due == null
            ? 'Special assignment.'
            : 'Special assignment, ${DutySpecial.dueText(due).toLowerCase()}.'
      else
        'Cell programme part.',
      if (duty.times.reportingAt != null)
        'Report by ${_wallClock(duty.times.reportingAt!)}, starts '
            '${_wallClock(duty.times.startsAt)} (church time).',
      'This entry is a copy and does not update if the duty changes or is '
          'cancelled. Open BICC Kafue, My duties, for the current version.',
    ].join(' ');
    final lines = [
      'BEGIN:VCALENDAR',
      'VERSION:2.0',
      'PRODID:-//BICC Kafue//Duties//EN',
      'CALSCALE:GREGORIAN',
      'METHOD:PUBLISH',
      'BEGIN:VEVENT',
      'UID:${uid(duty)}',
      // A later export of a changed duty replaces the earlier copy in
      // calendars that honour SEQUENCE (the slot revision only grows).
      'SEQUENCE:${duty.slotRevision}',
      'DTSTAMP:${_utc(now)}',
      if (due != null) ...[
        'DTSTART;VALUE=DATE:${_date(due)}',
        'DTEND;VALUE=DATE:${_date(due.add(const Duration(days: 1)))}',
        'SUMMARY:${_text('Due: ${duty.title}')}',
      ] else ...[
        'DTSTART:${_utc(start)}',
        'DTEND:${_utc(end.isAfter(start) ? end : start.add(defaultLength))}',
        'SUMMARY:${_text(duty.title)}',
      ],
      if (duty.location case final l?) 'LOCATION:${_text(l)}',
      'DESCRIPTION:${_text(description)}',
      'END:VEVENT',
      'END:VCALENDAR',
    ];
    return ICalendarText.document(lines);
  }

  static String _wallClock(DateTime at) {
    final w = ChurchTime.wall(at);
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(w.hour)}:${two(w.minute)}';
  }

  // Story 6.11: the text rules are shared with the event export
  // (icalendar_text.dart); this export's bytes are unchanged.
  static String _date(DateTime d) => ICalendarText.date(d);
  static String _utc(DateTime at) => ICalendarText.utc(at);
  static String _text(String v) => ICalendarText.text(v);
}

/// What handing a calendar file to the phone did. Only the platform's answer
/// governs the wording; nothing claims the event was added to a calendar.
enum CalendarHandoff {
  /// The person chose a target in the share sheet.
  shared,

  /// The person closed the share sheet without choosing.
  dismissed,

  /// The file was handed over; the platform does not say what happened.
  handedOver,

  /// This build has no calendar handoff.
  unavailable,

  /// The handoff failed.
  failed,
}

/// Where the share sheet should point from (the Add to calendar button, in
/// global logical pixels). iPad shows the share sheet as a popover anchored
/// here; phones ignore it.
class ShareOrigin {
  const ShareOrigin(this.left, this.top, this.width, this.height);
  final double left;
  final double top;
  final double width;
  final double height;
}

/// Application port: hands an `.ics` file to the platform. Never throws.
abstract interface class DutyCalendarExport {
  Future<CalendarHandoff> export({
    required String fileName,
    required String ics,
    ShareOrigin? origin,
  });
}

/// The default when a build has no handoff (staff web, tests).
class UnavailableCalendarExport implements DutyCalendarExport {
  const UnavailableCalendarExport();

  @override
  Future<CalendarHandoff> export({
    required String fileName,
    required String ics,
    ShareOrigin? origin,
  }) async => CalendarHandoff.unavailable;
}

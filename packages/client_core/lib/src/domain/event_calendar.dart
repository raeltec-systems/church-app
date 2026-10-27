/// Story 6.11: Add to calendar for a published event. The app builds a
/// standard iCalendar (RFC 5545) event with the 4.5 rules (icalendar_text.dart)
/// and hands it to the phone through the same handoff as a duty
/// (`DutyCalendarExport`). Both endpoints of a multi-day event are kept. The
/// exported entry is a copy: it does not update when the event changes or is
/// cancelled, which every screen that offers it says. Free of widgets and
/// SDKs.
library;

import 'church_time.dart';
import 'content_events.dart';
import 'icalendar_text.dart';

abstract final class EventCalendar {
  /// What every event Add to calendar offer says.
  static const staleCaveat =
      'The calendar entry is a copy: it does not change if the event changes '
      'or is cancelled. The Calendar in this app always shows the current '
      'version.';

  /// A file name for [event]'s entry (`event-2099-10-10.ics`, the church
  /// date of the start).
  static String fileName(PublicEvent event) {
    final w = ChurchTime.wall(event.startsAt);
    String two(int v) => v.toString().padLeft(2, '0');
    return 'event-${w.year.toString().padLeft(4, '0')}-${two(w.month)}-'
        '${two(w.day)}.ics';
  }

  /// The entry's UID: the event, so a later export replaces the earlier copy
  /// in calendars that honour it.
  static String uid(PublicEvent event) => 'event-${event.eventId}@bickafue.app';

  /// The iCalendar text of [event] (CRLF lines, folded at 75 octets). [now]
  /// is the export time (DTSTAMP).
  static String ics(PublicEvent event, {required DateTime now}) {
    final description =
        '${event.description}\n\nThis entry is a copy and does not update if '
        'the event changes or is cancelled. Open BICC Kafue, Calendar, for the '
        'current version.';
    return ICalendarText.document([
      'BEGIN:VCALENDAR',
      'VERSION:2.0',
      'PRODID:-//BICC Kafue//Events//EN',
      'CALSCALE:GREGORIAN',
      'METHOD:PUBLISH',
      'BEGIN:VEVENT',
      'UID:${uid(event)}',
      // A later publication replaces the earlier copy in calendars that
      // honour SEQUENCE (the publication revision only grows).
      'SEQUENCE:${event.publicationRevision}',
      'DTSTAMP:${ICalendarText.utc(now)}',
      'DTSTART:${ICalendarText.utc(event.startsAt)}',
      'DTEND:${ICalendarText.utc(event.endsAt)}',
      'SUMMARY:${ICalendarText.text(event.title)}',
      'LOCATION:${ICalendarText.text(event.location)}',
      'DESCRIPTION:${ICalendarText.text(description)}',
      'END:VEVENT',
      'END:VCALENDAR',
    ]);
  }
}

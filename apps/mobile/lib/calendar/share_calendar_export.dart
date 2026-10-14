// Story 4.5: Add to calendar on the phone. The duty's iCalendar file is handed
// to the platform share sheet (share_plus), where the member picks their
// calendar app. The wording follows the platform's answer only: the app never
// claims the event was added, and every screen says the copy does not update
// after a change. share_plus writes the file to the app's temporary directory
// (the OS clears it); no other copy is kept.
import 'dart:convert';

import 'package:church_client_core/church_client_core.dart'
    show CalendarHandoff, DutyCalendarExport;
import 'package:share_plus/share_plus.dart';

class ShareCalendarExport implements DutyCalendarExport {
  const ShareCalendarExport();

  @override
  Future<CalendarHandoff> export({
    required String fileName,
    required String ics,
  }) async {
    try {
      final result = await SharePlus.instance.share(
        ShareParams(
          files: [
            XFile.fromData(
              utf8.encode(ics),
              mimeType: 'text/calendar',
              name: fileName,
            ),
          ],
          fileNameOverrides: [fileName],
          subject: 'Duty',
        ),
      );
      return switch (result.status) {
        ShareResultStatus.success => CalendarHandoff.shared,
        ShareResultStatus.dismissed => CalendarHandoff.dismissed,
        ShareResultStatus.unavailable => CalendarHandoff.handedOver,
      };
    } catch (_) {
      return CalendarHandoff.failed;
    }
  }
}

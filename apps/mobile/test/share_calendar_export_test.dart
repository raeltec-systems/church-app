// Story 4.5: the share-sheet handoff of a duty's calendar file. The platform
// channels are mocked: the file reaches the share sheet as text/calendar
// under its church-date name, and only the platform's answer decides the
// wording (never "added to your calendar").
import 'dart:io';

import 'package:bic_kafue_mobile/calendar/share_calendar_export.dart';
import 'package:church_client_core/church_client_core.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const share = MethodChannel('dev.fluttercommunity.plus/share');
  const paths = MethodChannel('plugins.flutter.io/path_provider');
  late Directory temp;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('duty-calendar-test');
    messenger.setMockMethodCallHandler(paths, (call) async => temp.path);
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(paths, null);
    messenger.setMockMethodCallHandler(share, null);
    temp.deleteSync(recursive: true);
  });

  const ics = 'BEGIN:VCALENDAR\r\nEND:VCALENDAR\r\n';

  Future<(CalendarHandoff, Map?)> run(Object? Function() answer) async {
    Map? args;
    messenger.setMockMethodCallHandler(share, (call) async {
      args = call.arguments as Map?;
      final a = answer();
      if (a is Exception) throw a;
      return a;
    });
    final r = await const ShareCalendarExport().export(
      fileName: 'duty-2099-01-04.ics',
      ics: ics,
    );
    return (r, args);
  }

  test('the file goes to the share sheet as text/calendar', () async {
    final (r, args) = await run(() => 'com.example.calendar');
    expect(r, CalendarHandoff.shared);
    final paths = (args!['paths'] as List).cast<String>();
    expect(paths.single, endsWith('/duty-2099-01-04.ics'));
    expect(File(paths.single).readAsStringSync(), ics);
    expect(args['mimeTypes'], ['text/calendar']);
  });

  test('a closed sheet, an unknown answer and a failure say so', () async {
    expect((await run(() => '')).$1, CalendarHandoff.dismissed);
    expect(
      (await run(() => 'dev.fluttercommunity.plus/share/unavailable')).$1,
      CalendarHandoff.handedOver,
    );
    expect(
      (await run(() => PlatformException(code: 'x'))).$1,
      CalendarHandoff.failed,
    );
  });
}

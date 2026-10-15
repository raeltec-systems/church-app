// Story 4.9: Call and Message hand only a tel: / sms: link with a labelled
// route's E.164 number to the platform; the app never sends anything, and the
// platform's answer alone decides what the leader reads.
import 'package:bic_kafue_mobile/contact/url_contact_launcher.dart';
import 'package:church_client_core/church_client_core.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('tel: and sms: links for an E.164 number', () async {
    final opened = <Uri>[];
    final launcher = UrlContactLauncher(
      open: (uri) async {
        opened.add(uri);
        return true;
      },
    );
    expect(await launcher.call('+447700900798'), ContactLaunch.opened);
    expect(await launcher.message('+447700900798'), ContactLaunch.opened);
    expect(opened.map((u) => u.toString()), [
      'tel:+447700900798',
      'sms:+447700900798',
    ]);
  });

  test(
    'anything else is never handed over; a refusal or error says so',
    () async {
      final opened = <Uri>[];
      final launcher = UrlContactLauncher(
        open: (uri) async {
          opened.add(uri);
          return false;
        },
      );
      expect(await launcher.call('0977 000 000'), ContactLaunch.failed);
      expect(await launcher.call('+447700900798;evil'), ContactLaunch.failed);
      expect(opened, isEmpty);
      expect(await launcher.call('+447700900798'), ContactLaunch.failed);
      final throwing = UrlContactLauncher(open: (_) => throw StateError('x'));
      expect(await throwing.message('+447700900798'), ContactLaunch.failed);
    },
  );
}

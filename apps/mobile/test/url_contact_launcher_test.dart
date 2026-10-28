// Story 4.9: Call and Message hand only a tel: / sms: link with a labelled
// route's E.164 number to the platform; the app never sends anything, and the
// platform's answer alone decides what the leader reads.
import 'package:bic_kafue_mobile/contact/url_contact_launcher.dart';
import 'package:church_client_core/church_client_core.dart';
import 'package:flutter/foundation.dart';
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

  test(
    'Android giving handoff sends only a valid USSD tel link externally',
    () async {
      final opened = <Uri>[];
      final launcher = UrlGivingDiallerLauncher(
        platform: TargetPlatform.android,
        isWeb: false,
        opener: (uri) async {
          opened.add(uri);
          return true;
        },
      );

      expect(launcher.supported, isTrue);
      expect(await launcher.open('*115#'), isTrue);
      expect(opened.map((uri) => uri.toString()), ['tel:*115%23']);
    },
  );

  test(
    'unsupported platforms and invalid or failed dialler links stay manual',
    () async {
      final opened = <Uri>[];
      final unsupported = UrlGivingDiallerLauncher(
        platform: TargetPlatform.iOS,
        opener: (uri) async {
          opened.add(uri);
          return true;
        },
      );
      expect(unsupported.supported, isFalse);
      expect(await unsupported.open('*115#'), isFalse);
      final web = UrlGivingDiallerLauncher(
        platform: TargetPlatform.android,
        isWeb: true,
        opener: (uri) async {
          opened.add(uri);
          return true;
        },
      );
      expect(web.supported, isFalse);

      final android = UrlGivingDiallerLauncher(
        platform: TargetPlatform.android,
        opener: (uri) async {
          opened.add(uri);
          return false;
        },
      );
      expect(await android.open('115'), isFalse);
      expect(await android.open('*115#;evil'), isFalse);
      expect(await android.open('*115#'), isFalse);
      expect(opened.map((uri) => uri.toString()), ['tel:*115%23']);
    },
  );
}

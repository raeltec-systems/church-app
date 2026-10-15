// Story 4.9: Call and Message on a labelled contact route hand a tel: / sms:
// link to the browser, which opens the computer's (or phone's) calling or
// messaging app when one is set up. The app never places a call or sends a
// message itself, and records nothing: the leader records the attempt.
import 'package:church_client_core/church_client_core.dart'
    show ContactLaunch, ContactLauncher;
import 'package:url_launcher/url_launcher.dart';

/// Opens [uri] outside the app; true when the platform accepted it.
typedef UrlOpener = Future<bool> Function(Uri uri);

Future<bool> _openExternally(Uri uri) =>
    launchUrl(uri, mode: LaunchMode.externalApplication);

class UrlContactLauncher implements ContactLauncher {
  const UrlContactLauncher({this.open = _openExternally});

  final UrlOpener open;

  /// Only an E.164 number (the server's labelled routes) is ever handed over.
  static final _e164 = RegExp(r'^\+[1-9][0-9]{7,14}$');

  @override
  Future<ContactLaunch> call(String phone) => _launch('tel', phone);

  @override
  Future<ContactLaunch> message(String phone) => _launch('sms', phone);

  Future<ContactLaunch> _launch(String scheme, String phone) async {
    if (!_e164.hasMatch(phone)) return ContactLaunch.failed;
    try {
      return await open(Uri(scheme: scheme, path: phone))
          ? ContactLaunch.opened
          : ContactLaunch.failed;
    } catch (_) {
      return ContactLaunch.failed;
    }
  }
}

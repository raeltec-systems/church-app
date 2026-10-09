// Staff web: the browser page address. GoTrue puts the link's query before
// the hash route (`/?code=…#/auth/recovery`), so the one-time code is read
// from here and then removed from the address bar and history.
import 'package:web/web.dart' as web;

Uri? currentPageAddress() => Uri.tryParse(web.window.location.href);

void dropPageQuery() {
  final l = web.window.location;
  if (l.search.isEmpty) return;
  web.window.history.replaceState(null, '', '${l.pathname}${l.hash}');
}

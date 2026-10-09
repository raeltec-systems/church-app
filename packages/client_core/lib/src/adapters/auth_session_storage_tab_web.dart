// Staff web: the Auth session lives in this browser tab's sessionStorage
// (survives reload, ends with the tab). See auth_session_storage.dart.
import 'package:web/web.dart' as web;

String? readTabSession(String key) => web.window.sessionStorage.getItem(key);

void writeTabSession(String key, String value) =>
    web.window.sessionStorage.setItem(key, value);

void deleteTabSession(String key) => web.window.sessionStorage.removeItem(key);

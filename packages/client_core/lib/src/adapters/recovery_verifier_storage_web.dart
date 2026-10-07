// Staff web: the recovery PKCE verifier in localStorage (see
// recovery_verifier_storage.dart).
import 'package:web/web.dart' as web;

String? readItem(String key) => web.window.localStorage.getItem(key);

void writeItem(String key, String value) =>
    web.window.localStorage.setItem(key, value);

void deleteItem(String key) => web.window.localStorage.removeItem(key);

// Story 2.7: where the isolated recovery client keeps its one-time PKCE code
// verifier between asking for a reset link and opening it. It holds nothing
// else (no session: the recovery session lives in memory only), and the
// verifier is removed when the link is opened or the request is replaced.
//
// - Mobile: platform-secured storage under its own key prefix (never the app
//   session's key).
// - Staff web: the browser's localStorage under its own prefix, because the
//   email link opens in a new tab (the app session stays in the tab store).
// Any storage error reads as "no verifier": the link is then unusable and
// the member asks for a new one (fail closed).
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:supabase/supabase.dart' show GotrueAsyncStorage;

import 'recovery_verifier_storage_stub.dart'
    if (dart.library.js_interop) 'recovery_verifier_storage_web.dart'
    as browser;

const recoveryVerifierKeyPrefix = 'bic-kafue.recovery.';

class RecoveryVerifierStorage extends GotrueAsyncStorage {
  RecoveryVerifierStorage({FlutterSecureStorage? secure})
    : _secure =
          secure ??
          const FlutterSecureStorage(
            iOptions: IOSOptions(
              accessibility: KeychainAccessibility.first_unlock_this_device,
              synchronizable: false,
            ),
          );

  final FlutterSecureStorage _secure;

  String _key(String key) => '$recoveryVerifierKeyPrefix$key';

  @override
  Future<String?> getItem({required String key}) async {
    try {
      return kIsWeb
          ? browser.readItem(_key(key))
          : await _secure.read(key: _key(key));
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> setItem({required String key, required String value}) async {
    try {
      if (kIsWeb) {
        browser.writeItem(_key(key), value);
      } else {
        await _secure.write(key: _key(key), value: value);
      }
    } catch (_) {
      // Not kept: the link will be unusable and a new one can be requested.
    }
  }

  @override
  Future<void> removeItem({required String key}) async {
    try {
      if (kIsWeb) {
        browser.deleteItem(_key(key));
      } else {
        await _secure.delete(key: _key(key));
      }
    } catch (_) {}
  }
}

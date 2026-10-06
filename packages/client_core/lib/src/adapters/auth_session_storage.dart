// Story 2.2: the ONLY place in this package that persists anything on the
// device, and it persists ONLY the Supabase Auth session (tokens and the Auth
// user) so that reopening the app keeps a valid session without a password
// prompt (I2). Protected domain records never come here: they stay in memory,
// scoped to the account generation (AD-13). The server re-checks the session
// on every protected request, so a stored session that was revoked, expired,
// or opened before a credential change is refused there and then cleared.
//
// Policy:
// - Mobile (Android/iOS): platform-secured storage (Android Keystore-backed
//   encryption, iOS Keychain with "after first unlock, this device only", not
//   synced or migrated to another device).
// - Staff web: per-tab `sessionStorage`: a reload or reopening within the tab
//   keeps the session; closing the tab ends it. Never `localStorage` (shared
//   by all tabs and kept indefinitely).
// Any storage error reads as "no stored session" (sign in again): fail closed.
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show LocalStorage;

import 'auth_session_storage_tab_stub.dart'
    if (dart.library.js_interop) 'auth_session_storage_tab_web.dart'
    as tab;

/// The key under which the Auth session JSON is kept.
const authSessionStorageKey = 'bic-kafue.auth-session.v1';

/// A single-value store for the Auth session JSON.
abstract interface class AuthSessionStore {
  Future<String?> read();
  Future<void> write(String value);
  Future<void> delete();
}

/// Mobile: Keystore/Keychain through `flutter_secure_storage`.
class SecureDeviceSessionStore implements AuthSessionStore {
  SecureDeviceSessionStore([FlutterSecureStorage? storage])
    : _storage =
          storage ??
          const FlutterSecureStorage(
            iOptions: IOSOptions(
              accessibility: KeychainAccessibility.first_unlock_this_device,
              synchronizable: false,
            ),
          );

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read() => _storage.read(key: authSessionStorageKey);

  @override
  Future<void> write(String value) =>
      _storage.write(key: authSessionStorageKey, value: value);

  @override
  Future<void> delete() => _storage.delete(key: authSessionStorageKey);
}

/// Staff web: the browser tab's `sessionStorage`.
class TabSessionStore implements AuthSessionStore {
  const TabSessionStore();

  @override
  Future<String?> read() async => tab.readTabSession(authSessionStorageKey);

  @override
  Future<void> write(String value) async =>
      tab.writeTabSession(authSessionStorageKey, value);

  @override
  Future<void> delete() async => tab.deleteTabSession(authSessionStorageKey);
}

/// supabase_flutter's session persistence over an [AuthSessionStore].
class AuthSessionStorage extends LocalStorage {
  const AuthSessionStorage(this._store);

  /// The store for the running platform (see the policy above).
  factory AuthSessionStorage.forPlatform() => AuthSessionStorage(
    kIsWeb ? const TabSessionStore() : SecureDeviceSessionStore(),
  );

  final AuthSessionStore _store;

  @override
  Future<void> initialize() async {}

  Future<String?> _read() async {
    try {
      final v = await _store.read();
      return (v == null || v.isEmpty) ? null : v;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<bool> hasAccessToken() async => await _read() != null;

  /// The persisted session JSON (supabase_flutter's naming).
  @override
  Future<String?> accessToken() => _read();

  @override
  Future<void> persistSession(String persistSessionString) async {
    try {
      await _store.write(persistSessionString);
    } catch (_) {
      // Not persisted: the next start asks for the password (fail closed).
    }
  }

  @override
  Future<void> removePersistedSession() async {
    try {
      await _store.delete();
    } catch (_) {
      // Best effort: overwrite so no usable session remains.
      try {
        await _store.write('');
      } catch (_) {}
    }
  }
}

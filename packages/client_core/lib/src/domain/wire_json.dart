/// Story 4.14: the wire-JSON readers Duties and Follow-ups share (they had
/// identical private copies since 4.1 and 4.6). Each throws a
/// [FormatException] naming the key, so a malformed server answer is a
/// failed read, never a guessed value. Internal: not exported from the
/// package. Free of widgets and SDKs.
library;

import 'access_grants.dart';

/// A required value of type [T] at [key].
T wireReq<T>(Map json, String key) {
  final v = json[key];
  if (v is! T) throw FormatException('unexpected $key');
  return v;
}

/// An optional value of type [T] at [key] (null when absent or null).
T? wireOpt<T>(Map json, String key) {
  final v = json[key];
  if (v == null) return null;
  if (v is! T) throw FormatException('unexpected $key');
  return v;
}

/// [json] as an object; [what] names it in the error.
Map wireMap(Object? json, String what) {
  if (json is! Map) throw FormatException('$what is not an object');
  return json;
}

/// A required UTC instant (ISO 8601 with a zone) at [key].
DateTime wireInstant(Map json, String key) {
  final v = wireReq<String>(json, key);
  final t = DateTime.tryParse(v);
  if (t == null || !t.isUtc) throw FormatException('unexpected $key');
  return t;
}

/// An optional UTC instant at [key].
DateTime? wireOptInstant(Map json, String key) =>
    json[key] == null ? null : wireInstant(json, key);

/// A required revision (an integer from 1) at [key].
int wireRevision(Map json, [String key = 'revision']) {
  final r = wireReq<int>(json, key);
  if (r < 1) throw FormatException('unexpected $key');
  return r;
}

/// Entry 6.16: a required, non-blank string at [key] (the Content kinds had
/// identical private copies since 6.1).
String wireText(Map json, String key) {
  final v = wireReq<String>(json, key);
  if (v.trim().isEmpty) throw FormatException('unexpected $key');
  return v;
}

/// An optional string at [key]: absent or null is null; blank is refused.
String? wireOptText(Map json, String key) {
  final v = wireOpt<String>(json, key);
  if (v != null && v.trim().isEmpty) throw FormatException('unexpected $key');
  return v;
}

/// A required positive integer at [key].
int wirePositive(Map json, String key) {
  final v = wireReq<int>(json, key);
  if (v < 1) throw FormatException('unexpected $key');
  return v;
}

/// The capacity a Content editor reads a staff catalog in (`admin`,
/// `pastor` or `media`).
String wireEditorCapacity(Map json) {
  final capacity = wireReq<String>(json, 'capacity');
  if (!const [
    ChurchRoles.admin,
    ChurchRoles.pastor,
    ChurchRoles.media,
  ].contains(capacity)) {
    throw const FormatException('unexpected capacity');
  }
  return capacity;
}

/// How a listed member's account stands (`app_account`, `no_login`,
/// `access_review`).
AccountStanding wireAccount(Object? v) => switch (v) {
  'app_account' => AccountStanding.appAccount,
  'no_login' => AccountStanding.noLogin,
  'access_review' => AccountStanding.accessReview,
  _ => throw const FormatException('unexpected account'),
};

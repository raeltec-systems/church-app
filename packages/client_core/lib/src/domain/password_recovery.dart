/// Forgotten password through the approved recovery email, and the member's
/// own recovery email (story 2.7, AD-20). Free of widgets and SDKs.
///
/// No SMS anywhere. A reset link works only for the recovery email the
/// church approved for the same account (the server refuses any other), and
/// the session it opens can only set a new password: it never reads member
/// data, and a fresh password sign-in follows.
library;

/// The two Auth email links the apps accept. Nothing else in an incoming
/// link is read: only these paths, and only `code` and error parameters.
enum AuthLinkKind {
  /// A forgotten-password link: open it, then set a new password.
  recovery('/auth/recovery'),

  /// The confirmation of a newly added recovery email. The app never uses
  /// the code it carries (the confirmation already happened at the server).
  emailConfirmed('/auth/email-confirmed');

  const AuthLinkKind(this.path);

  /// The in-app route path (and the path under the mobile link's host).
  final String path;

  static AuthLinkKind? forPath(String path) {
    for (final k in values) {
      if (k.path == path) return k;
    }
    return null;
  }
}

/// An incoming Auth email link after the allowlist check.
class AuthLink {
  const AuthLink(this.kind, {this.code, this.errorCode});

  final AuthLinkKind kind;

  /// The one-time PKCE authorisation code (useless without the verifier this
  /// device kept when it asked for the link).
  final String? code;

  /// GoTrue's error code (for example `otp_expired`); shown only as "this
  /// link can't be used".
  final String? errorCode;

  bool get usable => code != null && errorCode == null;
}

final _codeShape = RegExp(r'^[A-Za-z0-9-]{8,128}$');
final _errorShape = RegExp(r'^[a-z_]{1,64}$');

/// Reads an incoming link. [route] is the in-app location the platform gave
/// the router (mobile deep link: path and query; staff web: the hash route);
/// [page] is the browser page address on the web, where GoTrue puts the
/// query before the hash route. Returns null for any path that is not an
/// allowlisted Auth link; a malformed code is treated as no code.
AuthLink? parseAuthLink(Uri route, {Uri? page}) {
  final kind = AuthLinkKind.forPath(route.path);
  if (kind == null) return null;
  String? pick(String name) {
    final v = route.queryParameters[name] ?? page?.queryParameters[name];
    return (v == null || v.isEmpty) ? null : v;
  }

  final rawCode = pick('code');
  final rawError = pick('error_code') ?? pick('error');
  return AuthLink(
    kind,
    code: rawCode != null && _codeShape.hasMatch(rawCode) ? rawCode : null,
    errorCode: rawError == null
        ? null
        : (_errorShape.hasMatch(rawError) ? rawError : 'invalid'),
  );
}

/// Where Auth email links lead back to (each must be on the Auth redirect
/// allowlist; GoTrue sends anything else to the site URL).
class AuthRedirects {
  const AuthRedirects({required this.recovery, required this.emailConfirmed});

  /// Mobile: the app's own URL scheme. With PKCE, a link opened by another
  /// app is useless without the verifier this app holds.
  static final mobile = AuthRedirects(
    recovery: Uri.parse('zm.bickafue.mobile://callback/auth/recovery'),
    emailConfirmed: Uri.parse(
      'zm.bickafue.mobile://callback/auth/email-confirmed',
    ),
  );

  /// Staff web: the page's own origin with the hash route.
  factory AuthRedirects.web(Uri page) {
    final origin = '${page.scheme}://${page.authority}';
    return AuthRedirects(
      recovery: Uri.parse('$origin/#${AuthLinkKind.recovery.path}'),
      emailConfirmed: Uri.parse('$origin/#${AuthLinkKind.emailConfirmed.path}'),
    );
  }

  final Uri recovery;
  final Uri emailConfirmed;
}

/// A plain email address (ASCII; the server applies the same rule).
final _emailShape = RegExp(
  r"^[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$",
);

bool looksLikeEmail(String value) {
  final v = value.trim();
  return v.length >= 6 && v.length <= 254 && _emailShape.hasMatch(v);
}

/// Forgot password: the answer never says whether an account or address
/// exists. Only a transport failure is distinguished.
enum ResetRequestOutcome { sent, unreachable, notConfigured }

enum RecoveryLinkOutcome {
  /// The link opened a recovery session: a new password can be set.
  ready,

  /// Expired, used, not for an approved recovery email, opened on another
  /// device, or otherwise refused. One answer for all.
  unusable,
  unreachable,
}

enum SetPasswordFailure { weakPassword, linkExpired, unreachable, unavailable }

sealed class SetPasswordOutcome {
  const SetPasswordOutcome();
}

class PasswordSet extends SetPasswordOutcome {
  const PasswordSet();
}

class PasswordNotSet extends SetPasswordOutcome {
  const PasswordNotSet(this.failure, {this.serverReasons = const []});
  final SetPasswordFailure failure;
  final List<String> serverReasons;
}

/// The isolated recovery route. Its session is never the app's own session:
/// it is held in memory only, used once to set the password, then ended.
abstract interface class PasswordRecoveryGateway {
  /// Asks for a reset link to [email] (the link returns to this device).
  Future<ResetRequestOutcome> requestReset(String email);

  /// Opens a recovery link's code with the verifier this device kept.
  Future<RecoveryLinkOutcome> openLink(String code);

  /// Sets the new password with the open recovery session, then ends it.
  Future<SetPasswordOutcome> setNewPassword(String password);

  /// Ends any open recovery session without setting a password.
  Future<void> discard();
}

class UnconfiguredPasswordRecoveryGateway implements PasswordRecoveryGateway {
  const UnconfiguredPasswordRecoveryGateway();

  @override
  Future<ResetRequestOutcome> requestReset(String email) async =>
      ResetRequestOutcome.notConfigured;

  @override
  Future<RecoveryLinkOutcome> openLink(String code) async =>
      RecoveryLinkOutcome.unusable;

  @override
  Future<SetPasswordOutcome> setNewPassword(String password) async =>
      const PasswordNotSet(SetPasswordFailure.unavailable);

  @override
  Future<void> discard() async {}
}

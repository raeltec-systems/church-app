// Story 2.13: the member summary now reads through SupabaseApiReader. This pins
// the summary's denial mapping to the table it had before the refactor.
import 'package:church_client_core/church_client_core.dart';
import 'package:church_client_core/supabase_adapters.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('every AccessDenial maps to the summary denial it had before', () {
    const expected = {
      AccessDenial.signedOut: MemberAccessDenial.signedOut,
      AccessDenial.untrustedSession: MemberAccessDenial.untrustedSession,
      AccessDenial.notLinked: MemberAccessDenial.notLinked,
      AccessDenial.reviewRequired: MemberAccessDenial.reviewRequired,
      AccessDenial.notGranted: MemberAccessDenial.reviewRequired,
      AccessDenial.unavailable: MemberAccessDenial.unavailable,
    };
    expect(expected.keys.toSet(), AccessDenial.values.toSet());
    for (final MapEntry(:key, :value) in expected.entries) {
      expect(memberAccessDenialOf(key), value, reason: '$key');
    }
  });

  test('server answers map exactly as the pre-2.13 summary table', () {
    // (code, message, details) -> the summary's own mapping before 2.13.
    const cases = <(String?, String, Object?, MemberAccessDenial?)>[
      ('42501', 'permission denied', null, MemberAccessDenial.signedOut),
      ('PGRST301', 'JWT expired', null, null),
      ('PGRST303', 'JWT invalid', null, null),
      (
        'PT401',
        'unauthenticated',
        'unauthenticated',
        MemberAccessDenial.signedOut,
      ),
      (
        'PT401',
        'unauthenticated',
        'untrusted_session',
        MemberAccessDenial.untrustedSession,
      ),
      ('PT401', 'unauthenticated', null, MemberAccessDenial.untrustedSession),
      ('PT403', 'forbidden', 'not_linked', MemberAccessDenial.notLinked),
      ('PT403', 'forbidden', 'not_granted', MemberAccessDenial.reviewRequired),
      (
        'PT403',
        'forbidden',
        'review_required',
        MemberAccessDenial.reviewRequired,
      ),
      ('PT403', 'forbidden', null, MemberAccessDenial.reviewRequired),
      ('PT403', 'unavailable', 'unavailable', MemberAccessDenial.unavailable),
      ('PT500', 'something else', null, null),
      (null, '', null, null),
    ];
    for (final (code, message, details, want) in cases) {
      expect(
        memberAccessDenialFor(code, message, details),
        want,
        reason: '$code $message $details',
      );
    }
  });

  test('isJwtRejection is still exported and unchanged', () {
    expect(isJwtRejection('PGRST301'), isTrue);
    expect(isJwtRejection('PGRST303'), isTrue);
    expect(isJwtRejection('PGRST302'), isFalse);
    expect(isJwtRejection(null), isFalse);
  });
}

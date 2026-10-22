import 'package:supabase/supabase.dart';

import '../domain/access_grants.dart';
import '../domain/content_giving.dart';
import 'supabase_api_reader.dart';

/// Supabase adapter for [GivingRepository] (story 6.3): the public giving
/// reads (`api.content_public_giving_methods`,
/// `api.content_public_giving_method`), which answer signed-out callers too,
/// and the Admins' read (`api.content_staff_giving_methods`), which the
/// server checks against the caller's live access and roles on every call.
/// This adapter only maps the answer.
class SupabaseGivingRepository implements GivingRepository {
  SupabaseGivingRepository(
    SupabaseClient client, {
    Duration timeout = const Duration(seconds: 10),
  }) : _reader = SupabaseApiReader(client, timeout: timeout);

  final SupabaseApiReader _reader;

  @override
  Future<AccessRead<PublicGivingMethods>> fetchPublicGivingMethods() =>
      _reader.read(
        'content_public_giving_methods',
        const {},
        PublicGivingMethods.fromJson,
        public: true,
      );

  @override
  Future<AccessRead<PublicGivingMethodRead>> fetchPublicGivingMethod(
    String methodId,
  ) => _reader.read(
    'content_public_giving_method',
    {'method_id': methodId},
    PublicGivingMethodRead.fromJson,
    public: true,
  );

  @override
  Future<AccessRead<StaffGivingMethods>> fetchStaffGivingMethods() =>
      _reader.read(
        'content_staff_giving_methods',
        const {},
        StaffGivingMethods.fromJson,
      );
}

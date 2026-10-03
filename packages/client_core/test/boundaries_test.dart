@TestOn('vm')
library;

import 'dart:io';

import 'package:church_client_core/church_client_core.dart';
import 'package:church_contracts/church_contracts.dart';
import 'package:flutter_test/flutter_test.dart';

/// Imports that only `lib/src/adapters/` may use (AD-16: presentation and
/// application call ports; adapters alone depend on the SDK).
final _sdkImport = RegExp(
  r'''import\s+['"]package:(supabase|supabase_flutter|gotrue|postgrest|realtime_client|storage_client|functions_client|http)/''',
);

/// Client persistence APIs that protected state must never reach (AD-13).
final _persistence = RegExp(
  r'''package:(shared_preferences|hive|hive_flutter|sqflite|drift|isar|path_provider|flutter_secure_storage)/|dart:html|localStorage|sessionStorage|indexedDB|IndexedDB''',
);

Iterable<File> _dart(String dir) =>
    Directory(dir)
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'));

void main() {
  test('only adapters import Supabase or http', () {
    final offenders = [
      for (final layer in ['domain', 'application', 'presentation'])
        for (final f in _dart('lib/src/$layer'))
          if (_sdkImport.hasMatch(f.readAsStringSync())) f.path,
      for (final f in [
        File('lib/church_client_core.dart'),
        File('lib/testing.dart'),
      ])
        if (_sdkImport.hasMatch(f.readAsStringSync())) f.path,
    ];
    expect(offenders, isEmpty);
  });

  test('no client persistence API anywhere in the package', () {
    final offenders = [
      for (final f in _dart('lib'))
        if (_persistence.hasMatch(f.readAsStringSync())) f.path,
    ];
    expect(offenders, isEmpty);
  });

  test(
    'secure request ids are canonical lowercase UUID v4 and contract-valid',
    () {
      final ids = SecureRequestIds();
      final seen = <String>{};
      for (var i = 0; i < 200; i++) {
        final id = ids.next();
        expect(
          id,
          matches(
            RegExp(
              r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
            ),
          ),
        );
        seen.add(id);
        final envelope = CommandRequest(
          command: 'fixture_counter.create',
          requestId: id,
          expectedRevision: const Optional.of(null),
          payload: const {'intent_key': 'k'},
        ).toJson();
        expect(check(ContractKind.commandRequest, envelope).valid, isTrue);
      }
      expect(seen, hasLength(200));
    },
  );
}

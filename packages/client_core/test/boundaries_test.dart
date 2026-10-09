@TestOn('vm')
library;

import 'dart:io';

import 'package:church_client_core/church_client_core.dart';
import 'package:church_client_core/testing.dart';
import 'package:church_contracts/church_contracts.dart';
import 'package:flutter_test/flutter_test.dart';

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
  /// Files allowed to reach the SDKs and adapters: the adapters themselves,
  /// their barrel and the composition root.
  bool exempt(String path) =>
      path.startsWith('lib/src/adapters/') ||
      path == 'lib/supabase_adapters.dart' ||
      path == 'lib/composition.dart';

  // Lifecycle events are server-only (contracts runbook): additive event
  // names stay contract v1 only while no client parses them. A client-visible
  // consumer needs a new contract version first.
  test('no client or app code consumes lifecycle events', () {
    final consumer = RegExp(
      r'LifecycleEvent|lifecycleEventNames|ContractKind\.lifecycleEvent|lifecycle_event',
    );
    final offenders = <String>[];
    for (final dir in [
      'lib',
      '../../apps/mobile/lib',
      '../../apps/staff/lib',
    ]) {
      for (final f in _dart(dir)) {
        if (consumer.hasMatch(f.readAsStringSync())) offenders.add(f.path);
      }
    }
    expect(offenders, isEmpty);
  });

  test('only adapters and the composition root reach Supabase or adapters', () {
    final offenders = <String, List<String>>{};
    for (final f in _dart('lib')) {
      final path = f.path.replaceAll(r'\\', '/');
      if (exempt(path)) continue;
      final v = boundaryViolations(path, f.readAsStringSync());
      if (v.isNotEmpty) offenders[path] = v;
    }
    expect(offenders, isEmpty);
  });

  group('the boundary check catches', () {
    for (final (path, source) in [
      (
        'lib/src/presentation/x.dart',
        "import '../adapters/supabase_command_gateway.dart';",
      ),
      ('lib/src/application/x.dart', "import './../adapters/a.dart';"),
      ('lib/church_client_core.dart', "export 'src/adapters/a.dart';"),
      ('lib/church_client_core.dart', "export 'supabase_adapters.dart';"),
      (
        'lib/src/domain/x.dart',
        "import 'package:church_client_core/supabase_adapters.dart';",
      ),
      (
        'lib/src/presentation/x.dart',
        "import 'package:church_client_core/src/adapters/a.dart' show A;",
      ),
      (
        'lib/main.dart',
        "import 'package:church_client_core/composition.dart';",
      ),
      (
        'lib/app.dart',
        "import 'package:supabase_flutter/supabase_flutter.dart';",
      ),
      ('lib/app.dart', 'import "package:http/http.dart" as http;'),
    ]) {
      test('$path: $source', () {
        expect(boundaryViolations(path, source), isNotEmpty);
      });
    }

    test('but not ordinary imports', () {
      expect(
        boundaryViolations(
          'lib/src/presentation/x.dart',
          "import '../application/providers.dart';\n"
              "import 'package:church_client_core/church_client_core.dart';\n"
              "import 'package:flutter/material.dart';",
        ),
        isEmpty,
      );
    });
  });

  // Story 2.2: the Auth session (tokens) persists in platform-secured
  // storage through exactly these adapter files. Nothing else persists, and
  // they import no domain type, so no protected record can reach storage.
  const authSessionStorageFiles = {
    'lib/src/adapters/auth_session_storage.dart',
    'lib/src/adapters/auth_session_storage_tab_web.dart',
  };

  // Story 2.7: the isolated recovery client's one-time PKCE verifier store.
  const recoveryVerifierFiles = {
    'lib/src/adapters/recovery_verifier_storage.dart',
    'lib/src/adapters/recovery_verifier_storage_web.dart',
  };

  test('no client persistence API anywhere else in the package', () {
    final offenders = [
      for (final f in _dart('lib'))
        if (!authSessionStorageFiles.contains(f.path.replaceAll(r'\\', '/')) &&
            !recoveryVerifierFiles.contains(f.path.replaceAll(r'\\', '/')) &&
            f.path.replaceAll(r'\\', '/') != 'lib/composition.dart' &&
            _persistence.hasMatch(f.readAsStringSync()))
          f.path,
    ];
    expect(offenders, isEmpty);
  });

  test('the Auth session storage adapters hold no domain or app state', () {
    for (final path in authSessionStorageFiles) {
      final source = File(path).readAsStringSync();
      expect(source, isNot(contains('/domain/')), reason: path);
      expect(source, isNot(contains('/application/')), reason: path);
      expect(source, isNot(contains('localStorage.')), reason: path);
    }
    // The composition root names the SDK's `localStorage:` option once, to
    // hand it that adapter; nothing else there persists.
    final composition = File('lib/composition.dart').readAsStringSync();
    expect(_persistence.allMatches(composition).map((m) => m[0]).toList(), [
      'localStorage',
    ]);
    expect(
      composition,
      contains('localStorage: AuthSessionStorage.forPlatform()'),
    );
  });

  test('the recovery verifier store holds only the PKCE verifier', () {
    for (final path in recoveryVerifierFiles) {
      final source = File(path).readAsStringSync();
      expect(source, isNot(contains('/domain/')), reason: path);
      expect(source, isNot(contains('/application/')), reason: path);
      expect(source, isNot(contains('sessionStorage')), reason: path);
    }
    final store = File(recoveryVerifierFiles.first).readAsStringSync();
    expect(
      store,
      contains("recoveryVerifierKeyPrefix = 'bic-kafue.recovery.'"),
    );
    expect(store, isNot(contains('authSessionStorageKey')));
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

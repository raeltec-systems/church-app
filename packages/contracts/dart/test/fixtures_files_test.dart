// VM only: the embedded fixtures used by the cross-platform tests equal the files on disk.
@TestOn('vm')
library;

import 'package:test/test.dart';

import '../tool/embed_fixtures.dart' as embed;

void main() {
  test('test/fixtures.g.dart is up to date with packages/contracts/fixtures/v1', () {
    expect(embed.readFile('test/fixtures.g.dart'), embed.render(),
        reason: 'run `dart run tool/embed_fixtures.dart` in packages/contracts/dart');
  });
}

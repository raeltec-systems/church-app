/// Test doubles for the client ports, shared by the package and app tests.
/// Not for production composition roots.
library;

import 'dart:async';

import 'package:church_contracts/church_contracts.dart';

import 'src/domain/commands.dart';
import 'src/domain/fixture_counter.dart';
import 'src/domain/session.dart';

/// One command the fake gateway received; complete it to answer.
class SentCommand {
  SentCommand(this.function, this.request);
  final String function;
  final CommandRequest request;
  final Completer<CommandOutcome> _answer = Completer<CommandOutcome>();
  Future<CommandOutcome> get _future => _answer.future;

  /// The exact wire body that was sent.
  Map<String, Object?> get wire => request.toJson();

  void confirm(Object? data, int revision) => _answer.complete(
    CommandConfirmed(
      CommandSuccess(
        requestId: request.requestId,
        data: data,
        revision: revision,
      ),
    ),
  );

  void refuse(
    ErrorCode code, {
    Map<String, String> fieldErrors = const {},
    Optional<int> currentRevision = const Optional.absent(),
  }) => _answer.complete(
    CommandRefused(
      CommandError(
        requestId: request.requestId,
        code: code,
        message: code.wireName,
        fieldErrors: fieldErrors,
        currentRevision: currentRevision,
      ),
    ),
  );

  void unknown() => _answer.complete(const CommandUnknownOutcome('test'));
}

/// [CommandGateway] whose every call waits for the test to answer it.
class FakeCommandGateway implements CommandGateway {
  final List<SentCommand> sent = [];

  @override
  Future<CommandOutcome> send(String function, CommandRequest request) {
    final c = SentCommand(function, request);
    sent.add(c);
    return c._future;
  }
}

/// [SessionRepository] the test switches between accounts.
class FakeSession implements SessionRepository {
  FakeSession([this._current]);
  String? _current;
  final _changes = StreamController<String?>.broadcast();

  void switchTo(String? accountId) {
    _current = accountId;
    _changes.add(accountId);
  }

  @override
  String? get currentAccountId => _current;

  @override
  Stream<String?> get accountChanges => _changes.stream;
}

/// [FixtureCounterReader] answered by the test; null = unavailable.
class FakeFixtureReader implements FixtureCounterReader {
  FixtureCounter? next;
  int calls = 0;

  @override
  Future<FixtureCounter> read(String counterId) async {
    calls++;
    final n = next;
    if (n == null) throw const FixtureReadUnavailable('test: no read endpoint');
    return n;
  }
}

/// Deterministic request ids: `00000000-0000-4000-8000-00000000000N`.
class SequentialRequestIds implements RequestIds {
  int _n = 0;
  @override
  String next() {
    _n++;
    return '00000000-0000-4000-8000-${_n.toString().padLeft(12, '0')}';
  }
}

/// `data` of a synthetic fixture counter success envelope.
Map<String, Object?> fixtureCounterData({
  String id = '11111111-1111-4111-8111-111111111111',
  String intentKey = 'synthetic-demo',
  int value = 0,
}) => {
  'id': id,
  'intent_key': intentKey,
  'value': value,
  'is_synthetic': true,
  'updated_at': '2026-10-03T12:00:00Z',
};

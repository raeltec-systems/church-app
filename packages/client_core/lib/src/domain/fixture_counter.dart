/// The synthetic 1.4 `fixture_counter` aggregate, as the clients see it.
library;

/// `api.fixture_counter_command` command names (story 1.4).
abstract final class FixtureCounterCommands {
  static const function = 'fixture_counter_command';
  static const create = 'fixture_counter.create';
  static const increment = 'fixture_counter.increment';
}

/// A server-confirmed counter snapshot. SYNTHETIC test data only.
class FixtureCounter {
  const FixtureCounter({
    required this.id,
    required this.intentKey,
    required this.value,
    required this.revision,
    required this.isSynthetic,
    required this.updatedAt,
  });

  /// Maps a success envelope's `data` and `revision`.
  ///
  /// Throws [FormatException] for an unexpected shape, so a bad payload is
  /// never shown as confirmed data.
  factory FixtureCounter.fromCommandData(Object? data, int revision) {
    if (data is! Map) throw const FormatException('fixture_counter data');
    final id = data['id'];
    final intentKey = data['intent_key'];
    final value = data['value'];
    final isSynthetic = data['is_synthetic'];
    final updatedAt = data['updated_at'];
    if (id is! String ||
        intentKey is! String ||
        value is! num ||
        value != value.truncate() ||
        isSynthetic is! bool ||
        updatedAt is! String) {
      throw const FormatException('fixture_counter data');
    }
    return FixtureCounter(
      id: id,
      intentKey: intentKey,
      value: value.toInt(),
      revision: revision,
      isSynthetic: isSynthetic,
      updatedAt: DateTime.parse(updatedAt).toUtc(),
    );
  }

  final String id;
  final String intentKey;
  final int value;
  final int revision;
  final bool isSynthetic;
  final DateTime updatedAt;
}

/// Thrown by a [FixtureCounterReader] that cannot read the current state.
class FixtureReadUnavailable implements Exception {
  const FixtureReadUnavailable(this.reason);
  final String reason;
  @override
  String toString() => 'FixtureReadUnavailable($reason)';
}

/// Reads a counter's current server state for conflict reconciliation.
abstract interface class FixtureCounterReader {
  /// Returns the current state, or throws [FixtureReadUnavailable].
  Future<FixtureCounter> read(String counterId);
}

/// The 1.4 fixture has no read endpoint (1.4 decision: success and conflict
/// envelopes carry the revision). Reload is therefore honestly unavailable
/// until a read view exists.
class NoFixtureCounterReadEndpoint implements FixtureCounterReader {
  const NoFixtureCounterReadEndpoint();

  @override
  Future<FixtureCounter> read(String counterId) async =>
      throw const FixtureReadUnavailable(
        'Reading counters is not available yet, so the latest value '
        "can't be loaded.",
      );
}

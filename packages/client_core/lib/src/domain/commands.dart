/// Command ports over the shared wire contract. Free of widgets and SDKs.
library;

import 'dart:math';

import 'package:church_contracts/church_contracts.dart';

/// What the client knows after sending one command envelope.
sealed class CommandOutcome {
  const CommandOutcome();
}

/// The server confirmed the command with a success envelope.
final class CommandConfirmed extends CommandOutcome {
  const CommandConfirmed(this.success);
  final CommandSuccess success;
}

/// The server answered with an error envelope (or the API refused the call
/// outright): a definite outcome; the command did not apply.
final class CommandRefused extends CommandOutcome {
  const CommandRefused(this.error);
  final CommandError error;
}

/// The command may or may not have applied: the request timed out, the
/// connection failed, a gateway failed, or the answer was unusable.
///
/// Never treat this as success. Resend the identical request (same
/// `request_id`, same body) to learn the stored outcome.
final class CommandUnknownOutcome extends CommandOutcome {
  const CommandUnknownOutcome([this.cause]);
  final Object? cause;
}

/// The command was never sent (for example, the build has no server
/// configured). Definite: nothing applied, and retrying cannot help.
final class CommandNotSent extends CommandOutcome {
  const CommandNotSent(this.reason);
  final String reason;
}

/// Application port that sends one versioned command envelope to an `api`
/// command function.
abstract interface class CommandGateway {
  /// Sends [request] to the `api` function [function]. Never throws for
  /// transport or server failures: they are mapped to a [CommandOutcome].
  Future<CommandOutcome> send(String function, CommandRequest request);
}

/// Source of caller-generated request ids (lowercase canonical UUID v4).
abstract interface class RequestIds {
  String next();
}

/// [RequestIds] backed by a cryptographically secure generator.
class SecureRequestIds implements RequestIds {
  SecureRequestIds([Random? random]) : _random = random ?? Random.secure();
  final Random _random;

  @override
  String next() {
    final b = List<int>.generate(16, (_) => _random.nextInt(256));
    b[6] = (b[6] & 0x0f) | 0x40; // version 4
    b[8] = (b[8] & 0x3f) | 0x80; // RFC 4122 variant
    final h = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
    return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-'
        '${h.substring(16, 20)}-${h.substring(20)}';
  }
}

/// [CommandGateway] for a build without a backend configuration: every
/// command is reported as not sent.
class UnconfiguredCommandGateway implements CommandGateway {
  const UnconfiguredCommandGateway();

  static const reason =
      'This build has no server configured, so the command was not sent.';

  @override
  Future<CommandOutcome> send(String function, CommandRequest request) async =>
      const CommandNotSent(reason);
}

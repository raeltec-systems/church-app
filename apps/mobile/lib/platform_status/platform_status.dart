/// Domain types for the tracer's platform status read. Free of widgets and SDKs.
library;

/// One synthetic platform status, as read from `api.platform_status`.
class PlatformStatus {
  const PlatformStatus({
    required this.status,
    required this.message,
    required this.isSynthetic,
    required this.updatedAt,
  });

  /// Maps a wire row (lower_snake_case keys) to the domain type.
  ///
  /// Throws [FormatException] when a required field is missing or malformed,
  /// so a bad payload is reported as a failure rather than shown as data.
  factory PlatformStatus.fromRow(Map<String, dynamic> row) {
    final status = row['status'];
    final message = row['message'];
    final isSynthetic = row['is_synthetic'];
    final updatedAt = row['updated_at'];
    if (status is! String ||
        message is! String ||
        isSynthetic is! bool ||
        updatedAt is! String) {
      throw const FormatException('Unexpected platform_status row shape');
    }
    return PlatformStatus(
      status: status,
      message: message,
      isSynthetic: isSynthetic,
      updatedAt: DateTime.parse(updatedAt).toUtc(),
    );
  }

  final String status;
  final String message;
  final bool isSynthetic;
  final DateTime updatedAt;
}

/// Why a platform status read failed.
enum PlatformStatusFailure {
  /// The server could not be reached or did not answer in time.
  unreachable,

  /// The server answered, but with an error or an unusable payload.
  rejected,
}

/// Thrown by a [PlatformStatusRepository] when a read fails.
class PlatformStatusException implements Exception {
  const PlatformStatusException(this.failure, [this.cause]);

  final PlatformStatusFailure failure;
  final Object? cause;

  @override
  String toString() => 'PlatformStatusException($failure, $cause)';
}

/// Application port for reading the platform status.
abstract interface class PlatformStatusRepository {
  /// Sends a fresh request every call. Returns `null` when no status is
  /// recorded, and throws [PlatformStatusException] on failure.
  Future<PlatformStatus?> fetch();
}

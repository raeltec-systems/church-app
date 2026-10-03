import 'dart:async';

import 'package:staff_web_trial/platform_status/platform_status.dart';

/// Test double: each call to [fetch] returns the next queued completer, so a
/// test controls exactly when and how every request finishes.
class FakePlatformStatusRepository implements PlatformStatusRepository {
  final List<Completer<PlatformStatus?>> requests = [];

  int get calls => requests.length;

  @override
  Future<PlatformStatus?> fetch() {
    final completer = Completer<PlatformStatus?>();
    requests.add(completer);
    return completer.future;
  }
}

final sampleStatus = PlatformStatus(
  status: 'operational',
  message: 'SYNTHETIC tracer status',
  isSynthetic: true,
  updatedAt: DateTime.utc(2026, 10, 3, 9, 5),
);

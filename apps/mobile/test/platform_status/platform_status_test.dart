import 'package:bic_kafue_mobile/platform_status/platform_status.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('fromRow maps the wire row', () {
    final status = PlatformStatus.fromRow({
      'status': 'operational',
      'message': 'm',
      'is_synthetic': true,
      'updated_at': '2026-10-03T11:08:28.902028+00:00',
    });
    expect(status.status, 'operational');
    expect(status.isSynthetic, isTrue);
    expect(status.updatedAt, DateTime.utc(2026, 10, 3, 11, 8, 28, 902, 28));
  });

  test('fromRow rejects a malformed row', () {
    expect(
      () => PlatformStatus.fromRow({'status': 'operational'}),
      throwsFormatException,
    );
  });
}

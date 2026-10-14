/// Church time (owner decision Q2): the church's single zone is
/// `Africa/Lusaka`, which is UTC+02:00 all year (no daylight saving). Stored
/// and sent instants stay UTC; what people type and read is church time,
/// whatever zone the device is set to. Free of widgets and SDKs.
library;

abstract final class ChurchTime {
  static const zone = 'Africa/Lusaka';
  static const offset = Duration(hours: 2);

  /// The church wall-clock reading of [instant]: a DateTime whose fields
  /// (year ... minute) are church-local. It is flagged UTC only so that no
  /// device zone is applied to it again; never send it as an instant.
  static DateTime wall(DateTime instant) => instant.toUtc().add(offset);

  /// The UTC instant of a church-local wall time.
  static DateTime instant(int year, int month, int day, int hour, int minute) =>
      DateTime.utc(year, month, day, hour, minute).subtract(offset);

  /// Parses `YYYY-MM-DD` and `HH:MM` as church-local wall time; null when
  /// either is malformed or names a day that does not exist.
  static DateTime? parse(String date, String time) {
    final d = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(date.trim());
    final t = RegExp(r'^(\d{1,2}):(\d{2})$').firstMatch(time.trim());
    if (d == null || t == null) return null;
    final y = int.parse(d[1]!), mo = int.parse(d[2]!), da = int.parse(d[3]!);
    final h = int.parse(t[1]!), mi = int.parse(t[2]!);
    if (mo < 1 || mo > 12 || da < 1 || da > 31 || h > 23 || mi > 59) {
      return null;
    }
    final at = instant(y, mo, da, h, mi);
    final w = wall(at);
    if (w.month != mo || w.day != da) return null;
    return at;
  }
}

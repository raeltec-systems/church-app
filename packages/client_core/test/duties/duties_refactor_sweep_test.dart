// Story 4.14: the helpers the refactor sweep shares between Duties and
// Follow-ups behave exactly as the copies they replaced. CI also runs this
// file with TZ=America/New_York (church time is device independent).
import 'package:church_client_core/church_client_core.dart';
import 'package:church_client_core/src/domain/wire_json.dart';
import 'package:church_client_core/testing.dart';
import 'package:church_contracts/church_contracts.dart';
import 'package:flutter_test/flutter_test.dart';

// The pre-4.14 copies (duties_screens `_dateField` / `_timeField`,
// `RotaEdit.hm`, `OutcomesQuery._ymdOf`), kept here as the reference.
String _oldDateField(DateTime at) {
  final w = ChurchTime.wall(at);
  String two(int v) => v.toString().padLeft(2, '0');
  return '${w.year.toString().padLeft(4, '0')}-${two(w.month)}-${two(w.day)}';
}

String _oldTimeField(DateTime at) {
  final w = ChurchTime.wall(at);
  String two(int v) => v.toString().padLeft(2, '0');
  return '${two(w.hour)}:${two(w.minute)}';
}

String _oldYmd(DateTime d) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '${d.year.toString().padLeft(4, '0')}-${two(d.month)}-${two(d.day)}';
}

void main() {
  group('church-time formatters', () {
    test('the church date and time around midnight in Lusaka', () {
      final before = DateTime.utc(2026, 1, 3, 21, 59);
      final after = DateTime.utc(2026, 1, 3, 22, 30);
      expect(ChurchTime.dateText(before), '2026-01-03');
      expect(ChurchTime.timeText(before), '23:59');
      expect(ChurchTime.dateText(after), '2026-01-04');
      expect(ChurchTime.timeText(after), '00:30');
      // A local (non-UTC) DateTime names the same instant.
      expect(ChurchTime.dateText(after.toLocal()), '2026-01-04');
      expect(RotaEdit.hm(after), '00:30');
      expect(ChurchTime.ymd(DateTime.utc(26, 1, 2)), '0026-01-02');
      expect(ChurchTime.ymd(DateTime.utc(2026, 12, 31)), '2026-12-31');
    });

    test('match the replaced copies at every quarter hour of a year', () {
      var at = DateTime.utc(2026, 1, 1);
      final end = DateTime.utc(2027, 1, 1);
      while (at.isBefore(end)) {
        expect(ChurchTime.dateText(at), _oldDateField(at));
        expect(ChurchTime.timeText(at), _oldTimeField(at));
        expect(RotaEdit.hm(at), _oldTimeField(at));
        expect(ChurchTime.ymd(at), _oldYmd(at));
        at = at.add(const Duration(minutes: 15));
      }
    });

    test('the queries send the same window dates', () {
      final now = DateTime.utc(2026, 3, 1, 22, 30); // 2 March in Lusaka
      expect(OutcomesQuery(days: 14).toParams(now: now), {
        'from_date': '2026-02-17',
        'to_date': '2026-03-02',
      });
      expect(const CoverageQuery(from: '2026-02-27', days: 3).toParams(), {
        'from_date': '2026-02-27',
        'to_date': '2026-03-01',
      });
    });
  });

  group('wire readers', () {
    test('values and the exact errors of the replaced copies', () {
      final m = {
        'n': 2,
        's': 'x',
        'at': '2026-10-15T08:00:00Z',
        'local': '2026-10-15T08:00:00',
        'zero': 0,
      };
      expect(wireReq<int>(m, 'n'), 2);
      expect(wireOpt<String>(m, 'missing'), isNull);
      expect(wireOpt<String>(m, 's'), 'x');
      expect(wireInstant(m, 'at'), DateTime.utc(2026, 10, 15, 8));
      expect(wireOptInstant(m, 'missing'), isNull);
      expect(wireRevision(m, 'n'), 2);
      expect(wireAccount('no_login'), AccountStanding.noLogin);
      expect(wireMap(m, 'row'), same(m));
      void fails(Object? Function() f, String message) => expect(
        f,
        throwsA(
          isA<FormatException>().having((e) => e.message, 'message', message),
        ),
      );
      fails(() => wireReq<String>(m, 'n'), 'unexpected n');
      fails(() => wireOpt<int>(m, 's'), 'unexpected s');
      fails(() => wireMap([], 'row'), 'row is not an object');
      fails(() => wireInstant(m, 'local'), 'unexpected local');
      fails(() => wireInstant(m, 'missing'), 'unexpected missing');
      fails(() => wireRevision(m, 'zero'), 'unexpected zero');
      fails(() => wireRevision(m), 'unexpected revision');
      fails(() => wireAccount('admin'), 'unexpected account');
    });
  });

  group('resendOrNewRequest', () {
    final ids = SequentialRequestIds();
    final first = resendOrNewRequest(
      unconfirmed: null,
      command: 'duties.respond',
      expected: const Optional.of(3),
      payload: const {'assignment_id': 'a', 'response': 'accepted'},
      ids: ids,
    );

    CommandRequest again({
      String command = 'duties.respond',
      Optional<int> expected = const Optional.of(3),
      Map<String, Object?> payload = const {
        'assignment_id': 'a',
        'response': 'accepted',
      },
    }) => resendOrNewRequest(
      unconfirmed: first,
      command: command,
      expected: expected,
      payload: payload,
      ids: ids,
    );

    test('the same input keeps the request id', () {
      final r = again();
      expect(r.requestId, first.requestId);
      expect(r.toJson(), first.toJson());
    });

    test('any other input is a new request', () {
      expect(
        again(command: 'duties.withdraw_acceptance').requestId,
        isNot(first.requestId),
      );
      expect(
        again(expected: const Optional.of(4)).requestId,
        isNot(first.requestId),
      );
      expect(
        again(payload: const {'assignment_id': 'a', 'response': 'declined'})
            .requestId,
        isNot(first.requestId),
      );
    });
  });
}

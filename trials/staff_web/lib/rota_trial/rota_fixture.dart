// Disposable Flutter Web trial (Q10). SYNTHETIC fixture data only — no real
// people, phones or notes. Do not build on this.
import 'package:flutter/material.dart';

/// Slot states shown on the reference rota. Every state has a text label; the
/// colours only reinforce it (design contract: never colour alone).
enum SlotStatus {
  confirmed('Confirmed', Color(0xFFDFF3E8), Color(0xFF0D6438)),
  confirmedByLeader(
    'Confirmed by leader',
    Color(0xFFDFF3E8),
    Color(0xFF0D6438),
  ),
  awaiting('Awaiting response', Color(0xFFFFF1CF), Color(0xFF6E4400)),
  needsContact('Needs contact', Color(0xFFFFF1CF), Color(0xFF6E4400)),
  declined('Declined', Color(0xFFFCE5E2), Color(0xFFA3241A)),
  draft('Draft', Color(0xFFEDF0F6), Color(0xFF586079)),
  unfilled('Unfilled', Color(0xFFFFFFFF), Color(0xFFA3241A));

  const SlotStatus(this.label, this.background, this.foreground);

  final String label;
  final Color background;
  final Color foreground;
}

class Member {
  const Member({
    required this.id,
    required this.displayName,
    required this.privatePhone,
  });

  final String id;
  final String displayName;

  /// A synthetic private field. It must never reach the grid, list or CSV.
  final String privatePhone;
}

class RotaDate {
  const RotaDate(this.iso, this.label);

  /// ISO calendar date (church-local), used in the CSV.
  final String iso;

  /// Short display label, e.g. "Sun 4 Oct".
  final String label;
}

class RotaSlot {
  const RotaSlot({
    required this.position,
    required this.date,
    required this.memberId,
    required this.status,
    this.note = '',
    this.privateCareNote = '',
  });

  final String position;
  final RotaDate date;
  final String? memberId;
  final SlotStatus status;
  final String note;

  /// A synthetic restricted field. It must never reach the grid, list or CSV.
  final String privateCareNote;

  RotaSlot copyWith({
    String? memberId,
    bool clearMember = false,
    SlotStatus? status,
  }) => RotaSlot(
    position: position,
    date: date,
    memberId: clearMember ? null : (memberId ?? this.memberId),
    status: status ?? this.status,
    note: note,
    privateCareNote: privateCareNote,
  );
}

/// A deterministic synthetic rota: positions × eight Sundays.
class RotaFixture {
  RotaFixture._(this.positions, this.dates, this.members, this.slots);

  final List<String> positions;
  final List<RotaDate> dates;
  final List<Member> members;

  /// Row-major: `slots[row][column]`.
  final List<List<RotaSlot>> slots;

  Member? memberById(String? id) {
    if (id == null) return null;
    for (final m in members) {
      if (m.id == id) return m;
    }
    return null;
  }

  factory RotaFixture.synthetic() {
    const positions = [
      'Main door',
      'Side door',
      'Parking',
      'Offering team',
      'Welcome desk',
      'Children\'s door',
    ];
    const dates = [
      RotaDate('2026-10-04', 'Sun 4 Oct'),
      RotaDate('2026-10-11', 'Sun 11 Oct'),
      RotaDate('2026-10-18', 'Sun 18 Oct'),
      RotaDate('2026-10-25', 'Sun 25 Oct'),
      RotaDate('2026-11-01', 'Sun 1 Nov'),
      RotaDate('2026-11-08', 'Sun 8 Nov'),
      RotaDate('2026-11-15', 'Sun 15 Nov'),
      RotaDate('2026-11-22', 'Sun 22 Nov'),
    ];
    // Names are synthetic. Several deliberately start with spreadsheet
    // formula triggers so the CSV export's neutralisation is exercised.
    const members = [
      Member(
        id: 'm01',
        displayName: 'Test Mwila A',
        privatePhone: '+260 000 000 001',
      ),
      Member(
        id: 'm02',
        displayName: 'Test Joseph B',
        privatePhone: '+260 000 000 002',
      ),
      Member(
        id: 'm03',
        displayName: 'Test Esther C',
        privatePhone: '+260 000 000 003',
      ),
      Member(
        id: 'm04',
        displayName: 'Test Ruth D',
        privatePhone: '+260 000 000 004',
      ),
      Member(
        id: 'm05',
        displayName: 'Test Naomi E',
        privatePhone: '+260 000 000 005',
      ),
      Member(
        id: 'm06',
        displayName: 'Test Moses F',
        privatePhone: '+260 000 000 006',
      ),
      Member(
        id: 'm07',
        displayName: '=HYPERLINK("https://example.invalid","Injected")',
        privatePhone: '+260 000 000 007',
      ),
      Member(
        id: 'm08',
        displayName: '+Test Plus G',
        privatePhone: '+260 000 000 008',
      ),
      Member(
        id: 'm09',
        displayName: '-Test Minus H',
        privatePhone: '+260 000 000 009',
      ),
      Member(
        id: 'm10',
        displayName: '@Test At I',
        privatePhone: '+260 000 000 010',
      ),
      Member(
        id: 'm11',
        displayName: '  -Test Space K',
        privatePhone: '+260 000 000 011',
      ),
    ];
    const notes = [
      '',
      'Bring the "spare" lanyard, then lock up',
      '=1+2',
      '\tTab-led note',
      'Line one\nLine two',
      '\rCR-led note',
      '  =SUM(1,2) after spaces',
    ];
    const statuses = SlotStatus.values;
    final slots = <List<RotaSlot>>[];
    for (var r = 0; r < positions.length; r++) {
      final row = <RotaSlot>[];
      for (var c = 0; c < dates.length; c++) {
        // Not every status appears in every row, so a position + status
        // filter can match nothing.
        final seed = r * 3 + c * c;
        final status = statuses[seed % statuses.length];
        final member = status == SlotStatus.unfilled
            ? null
            : members[(r * 3 + c) % members.length].id;
        row.add(
          RotaSlot(
            position: positions[r],
            date: dates[c],
            memberId: member,
            status: status,
            note: notes[(r + c) % notes.length],
            privateCareNote: 'SYNTHETIC private care note $r-$c',
          ),
        );
      }
      slots.add(row);
    }
    return RotaFixture._(positions, dates, members, slots);
  }
}

/// Story 5.3: a meeting's programme draft as the server reports it. Who may
/// read the draft, which parts are gaps and whether an assignee is still in
/// the cell are all decided by the server; these reads are presentation
/// only. Part times travel as UTC instants and are typed in church time
/// (`HH:MM` on the meeting's date). Free of widgets and SDKs.
library;

import 'cell_meetings.dart';
import 'church_time.dart';

T _req<T>(Map json, String key) {
  final v = json[key];
  if (v is! T) throw FormatException('unexpected $key');
  return v;
}

T? _opt<T>(Map json, String key) {
  final v = json[key];
  if (v == null) return null;
  if (v is! T) throw FormatException('unexpected $key');
  return v;
}

Map _map(Object? json, String what) {
  if (json is! Map) throw FormatException('$what is not an object');
  return json;
}

DateTime _instant(Map json, String key) {
  final v = _req<String>(json, key);
  // Contract v1 instants are UTC with `Z`; an offset is refused, not converted.
  final at = v.endsWith('Z') ? DateTime.tryParse(v) : null;
  if (at == null || !at.isUtc) throw FormatException('unexpected $key');
  return at;
}

int _count(Map json, String key) {
  final v = _req<int>(json, key);
  if (v < 0) throw FormatException('unexpected $key');
  return v;
}

/// The cells programme command names (1.4 envelope, `cells_command`).
abstract final class CellProgrammeCommands {
  static const create = 'cells.create_programme';
  static const save = 'cells.save_programme';
  static const cancel = 'cells.cancel_programme';
}

/// At most this many parts per programme (the server's limit).
const programmeMaxParts = 20;

enum ProgrammeState {
  draft('draft'),
  cancelled('cancelled');

  const ProgrammeState(this.wire);
  final String wire;

  static ProgrammeState fromWire(Object? v) {
    for (final s in values) {
      if (s.wire == v) return s;
    }
    throw FormatException('unexpected programme state $v');
  }
}

/// Who leads a part. [inCell] is false once they have left the meeting's
/// cell: the part keeps them, but the draft cannot be saved that way.
class ProgrammeAssignee {
  const ProgrammeAssignee({
    required this.memberId,
    required this.displayName,
    required this.inCell,
  });

  factory ProgrammeAssignee.fromJson(Object? json) {
    final m = _map(json, 'assignee');
    return ProgrammeAssignee(
      memberId: _req<String>(m, 'member_id'),
      // A deleted member's name is gone (the id is anonymised).
      displayName: _opt<String>(m, 'display_name') ?? 'Removed member',
      inCell: _req<bool>(m, 'in_cell'),
    );
  }

  final String memberId;
  final String displayName;
  final bool inCell;
}

/// One part with its stable id (kept through every save).
class ProgrammePart {
  const ProgrammePart({
    required this.partId,
    required this.position,
    required this.label,
    required this.startsAt,
    required this.endsAt,
    this.assignee,
  });

  factory ProgrammePart.fromJson(Object? json) {
    final m = _map(json, 'part');
    return ProgrammePart(
      partId: _req<String>(m, 'part_id'),
      position: _req<int>(m, 'position'),
      label: _req<String>(m, 'label'),
      startsAt: _instant(m, 'starts_at'),
      endsAt: _instant(m, 'ends_at'),
      assignee: m['assignee'] == null
          ? null
          : ProgrammeAssignee.fromJson(m['assignee']),
    );
  }

  final String partId;
  final int position;
  final String label;
  final DateTime startsAt;
  final DateTime endsAt;
  final ProgrammeAssignee? assignee;

  /// Nobody leads this part yet.
  bool get gap => assignee == null;
}

/// A programme. With the full view it carries the content; an Admin-only
/// reader gets state, revision and counts ([parts] empty, [partCount] set).
class CellProgramme {
  const CellProgramme({
    required this.programmeId,
    required this.meetingId,
    required this.state,
    required this.revision,
    required this.parts,
    required this.partCount,
    required this.gaps,
    this.topic,
    this.scripture,
    this.studyNotes,
  });

  factory CellProgramme.fromJson(Object? json) {
    final m = _map(json, 'programme');
    final revision = _req<int>(m, 'revision');
    if (revision < 1) throw const FormatException('unexpected revision');
    final parts = m['parts'] == null
        ? const <ProgrammePart>[]
        : List<ProgrammePart>.unmodifiable(
            _req<List>(m, 'parts').map(ProgrammePart.fromJson),
          );
    return CellProgramme(
      programmeId: _req<String>(m, 'programme_id'),
      meetingId: _req<String>(m, 'meeting_id'),
      state: ProgrammeState.fromWire(m['state']),
      revision: revision,
      topic: _opt<String>(m, 'topic'),
      scripture: _opt<String>(m, 'scripture'),
      studyNotes: _opt<String>(m, 'study_notes'),
      parts: parts,
      partCount: m['parts'] == null ? _count(m, 'part_count') : parts.length,
      gaps: _count(m, 'gaps'),
    );
  }

  final String programmeId;
  final String meetingId;
  final ProgrammeState state;

  /// expected_revision of the programme commands.
  final int revision;
  final String? topic;
  final String? scripture;
  final String? studyNotes;
  final List<ProgrammePart> parts;
  final int partCount;

  /// Parts nobody leads yet.
  final int gaps;

  bool get draft => state == ProgrammeState.draft;
}

/// How a roster member's account stands (the 2.3 roster vocabulary).
enum ProgrammeRosterAccount { appAccount, noLogin, accessReview }

/// A current confirmed member of the meeting's cell (assignable).
class ProgrammeRosterMember {
  const ProgrammeRosterMember({
    required this.memberId,
    required this.displayName,
    required this.account,
  });

  factory ProgrammeRosterMember.fromJson(Object? json) {
    final m = _map(json, 'roster member');
    return ProgrammeRosterMember(
      memberId: _req<String>(m, 'member_id'),
      displayName: _req<String>(m, 'display_name'),
      account: switch (m['account']) {
        'app_account' => ProgrammeRosterAccount.appAccount,
        'no_login' => ProgrammeRosterAccount.noLogin,
        'access_review' => ProgrammeRosterAccount.accessReview,
        _ => throw const FormatException('unexpected account'),
      },
    );
  }

  final String memberId;
  final String displayName;
  final ProgrammeRosterAccount account;

  /// Without a working login: the leader tells them directly.
  bool get offApp => account != ProgrammeRosterAccount.appAccount;
}

/// `api.cells_programme`: the meeting, the caller's view and the programme.
class ProgrammeRead {
  const ProgrammeRead({
    required this.meeting,
    required this.cellName,
    required this.full,
    required this.canEdit,
    required this.roster,
    this.programme,
  });

  factory ProgrammeRead.fromJson(Object? json) {
    final m = _map(json, 'programme read');
    final full = switch (m['view']) {
      'full' => true,
      'metadata' => false,
      _ => throw const FormatException('unexpected view'),
    };
    final canEdit = _req<bool>(m, 'can_edit');
    if (canEdit && !full) throw const FormatException('unexpected can_edit');
    return ProgrammeRead(
      meeting: CellMeeting.fromJson(m['meeting']),
      cellName: _req<String>(m, 'cell_name'),
      full: full,
      canEdit: canEdit,
      programme: m['programme'] == null
          ? null
          : CellProgramme.fromJson(m['programme']),
      roster: List.unmodifiable(
        _req<List>(m, 'roster').map(ProgrammeRosterMember.fromJson),
      ),
    );
  }

  final CellMeeting meeting;
  final String cellName;

  /// The content and names (leader, assistant, Pastor oversight); false for
  /// an Admin-only reader (state and counts).
  final bool full;

  /// The cell's leader or assistant: may create, save and cancel drafts.
  final bool canEdit;
  final CellProgramme? programme;
  final List<ProgrammeRosterMember> roster;
}

/// One part as typed in the editor, sent whole by `cells.save_programme`.
class ProgrammePartDraft {
  const ProgrammePartDraft({
    required this.label,
    required this.startTime,
    required this.endTime,
    this.partId,
    this.assigneeMemberId,
  });

  /// An existing part, as the editor starts it.
  factory ProgrammePartDraft.of(ProgrammePart p) => ProgrammePartDraft(
    partId: p.partId,
    label: p.label,
    startTime: ChurchTime.timeText(p.startsAt),
    endTime: ChurchTime.timeText(p.endsAt),
    assigneeMemberId: p.assignee?.memberId,
  );

  final String? partId;
  final String label;

  /// Church-local `HH:MM` on the meeting's date.
  final String startTime;
  final String endTime;
  final String? assigneeMemberId;

  Map<String, Object?> toJson() => {
    if (partId != null) 'part_id': partId,
    'label': label.trim(),
    'start_time': startTime.trim(),
    'end_time': endTime.trim(),
    'assignee_member_id': assigneeMemberId,
  };
}

/// The field error of part [index] of a refused save (`parts.<index>`).
String? partError(Map<String, String> errors, int index) =>
    errors['parts.$index'];

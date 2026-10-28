/// Story 5.3: a meeting's programme draft as the server reports it. Who may
/// read the draft, which parts are gaps and whether an assignee is still in
/// the cell are all decided by the server; these reads are presentation
/// only. Part times travel as UTC instants and are typed in church time
/// (`HH:MM` on the meeting's date). Story 5.4 adds publishing: the server's
/// member-safe projection, each part's Duties state and the department
/// positions a part may show. Free of widgets and SDKs.
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

  /// Story 5.4: publish (or republish) through Duties.
  static const publish = 'cells.publish_programme';
}

/// Story 5.7: Cannot attend notices (the member themself).
abstract final class CellAbsenceCommands {
  static const send = 'cells.send_cannot_attend';
  static const change = 'cells.change_cannot_attend';
  static const withdraw = 'cells.withdraw_cannot_attend';

  /// The note's limit (the server's).
  static const noteMax = 280;
}

/// Story 5.7: a member's Cannot attend notice for one meeting. An
/// intention for the leaders, never a duty answer or attendance.
class AbsenceNotice {
  const AbsenceNotice({
    required this.noticeId,
    required this.revision,
    required this.sentAt,
    this.note,
  });

  factory AbsenceNotice.fromJson(Object? json) {
    final m = _map(json, 'notice');
    final revision = _req<int>(m, 'revision');
    if (revision < 1) throw const FormatException('unexpected revision');
    return AbsenceNotice(
      noticeId: _req<String>(m, 'notice_id'),
      revision: revision,
      note: _opt<String>(m, 'note'),
      sentAt: _instant(m, 'sent_at'),
    );
  }

  final String noticeId;

  /// expected_revision of change and withdraw.
  final int revision;
  final String? note;
  final DateTime sentAt;
}

/// Story 5.7: an open notice as the cell's leader and assistant read it,
/// with the parts its sender holds (a coverage warning).
class StaffAbsence {
  const StaffAbsence({
    required this.noticeId,
    required this.memberId,
    required this.displayName,
    required this.partIds,
    this.note,
  });

  factory StaffAbsence.fromJson(Object? json) {
    final m = _map(json, 'absence');
    return StaffAbsence(
      noticeId: _req<String>(m, 'notice_id'),
      memberId: _req<String>(m, 'member_id'),
      displayName: _opt<String>(m, 'display_name') ?? 'Removed member',
      note: _opt<String>(m, 'note'),
      partIds: List.unmodifiable(
        (_opt<List>(m, 'part_ids') ?? const []).map((v) {
          if (v is! String) throw const FormatException('unexpected part id');
          return v;
        }),
      ),
    );
  }

  final String noticeId;
  final String memberId;
  final String displayName;
  final String? note;
  final List<String> partIds;
}

/// Story 5.8: the meeting record commands (the cell's leader or assistant,
/// once the meeting has started).
abstract final class CellRecordCommands {
  static const recordHeld = 'cells.record_meeting_held';
  static const correctHeld = 'cells.correct_meeting_held';
  static const recordLeaders = 'cells.record_actual_leaders';

  /// The server's limits: a correction reason and a guest's name.
  static const reasonMax = 280;
  static const guestNameMax = 80;
}

enum ActualLeaderKind { member, guest, nobody }

/// Story 5.8: who actually led a part (the current row, or an earlier one
/// a correction replaced). [substitute]: not the person planned when it was
/// recorded.
class ActualLeader {
  const ActualLeader({
    required this.partId,
    required this.kind,
    required this.substitute,
    required this.recordedAt,
    this.memberId,
    this.displayName,
    this.guestName,
    this.reason,
    this.recordedBy,
    this.earlier = const [],
  });

  factory ActualLeader.fromJson(Object? json) {
    final m = _map(json, 'actual leader');
    final kind = switch (m['kind']) {
      'member' => ActualLeaderKind.member,
      'guest' => ActualLeaderKind.guest,
      'nobody' => ActualLeaderKind.nobody,
      _ => throw const FormatException('unexpected kind'),
    };
    final memberId = _opt<String>(m, 'member_id');
    final guestName = _opt<String>(m, 'guest_name');
    if ((kind == ActualLeaderKind.member) != (memberId != null) ||
        (kind == ActualLeaderKind.guest) != (guestName != null)) {
      throw const FormatException('unexpected actual leader');
    }
    return ActualLeader(
      partId: _req<String>(m, 'part_id'),
      kind: kind,
      memberId: memberId,
      displayName: _opt<String>(m, 'display_name'),
      guestName: guestName,
      substitute: _req<bool>(m, 'substitute'),
      reason: _opt<String>(m, 'reason'),
      recordedAt: _instant(m, 'recorded_at'),
      recordedBy: _opt<String>(m, 'recorded_by'),
      earlier: List.unmodifiable(
        (_opt<List>(m, 'earlier') ?? const []).map(ActualLeader.fromJson),
      ),
    );
  }

  final String partId;
  final ActualLeaderKind kind;
  final String? memberId;
  final String? displayName;
  final String? guestName;
  final bool substitute;

  /// Why this row replaced the one before (null for the first).
  final String? reason;
  final DateTime recordedAt;
  final String? recordedBy;

  /// The rows this one replaced, newest first.
  final List<ActualLeader> earlier;

  /// "Grace Banda", "Pastor John (guest)" or "Nobody led it".
  String get who => switch (kind) {
    ActualLeaderKind.member => displayName ?? 'Removed member',
    ActualLeaderKind.guest => '$guestName (guest)',
    ActualLeaderKind.nobody => 'Nobody led it',
  };
}

/// Story 5.8: one held / not held value with who set it and why.
class HeldEntry {
  const HeldEntry({
    required this.revision,
    required this.held,
    required this.at,
    this.reason,
    this.by,
  });

  factory HeldEntry.fromJson(Object? json) {
    final m = _map(json, 'held entry');
    return HeldEntry(
      revision: _req<int>(m, 'revision'),
      held: _req<bool>(m, 'held'),
      reason: _opt<String>(m, 'reason'),
      by: _opt<String>(m, 'by'),
      at: _instant(m, 'at'),
    );
  }

  final int revision;
  final bool held;
  final String? reason;
  final String? by;
  final DateTime at;
}

/// Story 5.8: the meeting record (staff read): held or not, every value
/// newest first, and each part's actual leader by part id.
class MeetingRecord {
  const MeetingRecord({
    required this.held,
    required this.revision,
    required this.history,
    required this.actual,
  });

  factory MeetingRecord.fromJson(Object? json) {
    final m = _map(json, 'meeting record');
    final revision = _req<int>(m, 'revision');
    if (revision < 1) throw const FormatException('unexpected revision');
    return MeetingRecord(
      held: _req<bool>(m, 'held'),
      revision: revision,
      history: List.unmodifiable(
        _req<List>(m, 'history').map(HeldEntry.fromJson),
      ),
      actual: {
        for (final a in _req<List>(m, 'actual').map(ActualLeader.fromJson))
          a.partId: a,
      },
    );
  }

  final bool held;

  /// expected_revision of every record command after the first.
  final int revision;
  final List<HeldEntry> history;
  final Map<String, ActualLeader> actual;
}

/// Story 5.8: who led one part, as the leader chose it: a member of the cell
/// ([memberId]), a guest ([guestName]) or nobody (both null). [reason] is
/// required by the server when it replaces a recorded value.
class ActualLeaderDraft {
  const ActualLeaderDraft({
    required this.partId,
    this.memberId,
    this.guestName,
    this.reason,
  });

  final String partId;
  final String? memberId;
  final String? guestName;
  final String? reason;

  Map<String, Object?> toJson() => {
    'part_id': partId,
    'leader': memberId != null
        ? {'member_id': memberId}
        : guestName != null && guestName!.trim().isNotEmpty
        ? {'name': guestName!.trim()}
        : null,
    if (reason != null && reason!.trim().isNotEmpty) 'reason': reason!.trim(),
  };
}

/// At most this many parts per programme (the server's limit).
const programmeMaxParts = 20;

enum ProgrammeState {
  draft('draft'),
  published('published'),
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
    this.linkedSlotId,
    this.linkedLabel,
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
      // Story 5.4 (absent from 5.3 servers).
      linkedSlotId: _opt<String>(m, 'linked_slot_id'),
      linkedLabel: _opt<String>(m, 'linked_label'),
    );
  }

  final String partId;
  final int position;
  final String label;
  final DateTime startsAt;
  final DateTime endsAt;
  final ProgrammeAssignee? assignee;

  /// Story 5.4: the department position this part shows, and its name.
  final String? linkedSlotId;
  final String? linkedLabel;

  /// Nobody leads this part yet (a department part is led by its department).
  bool get gap => assignee == null && linkedSlotId == null;
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
    this.publishedRevision,
    this.publishedAt,
    this.unpublishedChanges = false,
    this.meetingChanged = false,
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
      publishedRevision: _opt<int>(m, 'published_revision'),
      publishedAt: m['published_at'] == null
          ? null
          : _instant(m, 'published_at'),
      // Story 5.6 (absent from 5.4 servers).
      unpublishedChanges: _opt<bool>(m, 'unpublished_changes') ?? false,
      meetingChanged: _opt<bool>(m, 'meeting_changed') ?? false,
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

  /// Story 5.4: the revision members read, and when it was published.
  final int? publishedRevision;
  final DateTime? publishedAt;

  /// Story 5.6: saved changes members and Duties do not have yet, and a
  /// meeting moved since the last publish (publish again to update them).
  final bool unpublishedChanges;
  final bool meetingChanged;

  bool get draft => state == ProgrammeState.draft;
  bool get published => state == ProgrammeState.published;
}

/// How a roster member's account stands (the 2.3 roster vocabulary).
enum ProgrammeRosterAccount { appAccount, noLogin, accessReview }

/// A current confirmed member of the meeting's cell (assignable).
class ProgrammeRosterMember {
  const ProgrammeRosterMember({
    required this.memberId,
    required this.displayName,
    required this.account,
    this.inCell = true,
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
      // Review finding F6: only on the recording roster.
      inCell: _opt<bool>(m, 'in_cell') ?? true,
    );
  }

  final String memberId;
  final String displayName;
  final ProgrammeRosterAccount account;

  /// False on the recording roster for someone who was in the cell when the
  /// meeting started and has moved or left since (review finding F6).
  final bool inCell;

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
    this.preview,
    this.membersSee,
    this.duties = const {},
    this.linkable = const [],
    this.absences = const [],
    this.status,
    this.record,
    this.canRecord = false,
    this.recordRoster,
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
      // Story 5.4 (absent from 5.3 servers).
      preview: m['preview'] == null
          ? null
          : ProgrammeProjection.fromJson(m['preview']),
      membersSee: m['published'] == null
          ? null
          : ProgrammeProjection.fromJson(m['published']),
      duties: {
        for (final d in (_opt<List>(m, 'duties') ?? const []).map(
          PartDuty.fromJson,
        ))
          d.partId: d,
      },
      linkable: List.unmodifiable(
        (_opt<List>(m, 'linkable') ?? const []).map(LinkableDuty.fromJson),
      ),
      // Story 5.7 (absent from 5.6 servers).
      absences: List.unmodifiable(
        (_opt<List>(m, 'absences') ?? const []).map(StaffAbsence.fromJson),
      ),
      // Story 5.8 (absent from 5.7 servers).
      status: MeetingStatus.tryParse(m['status']),
      record: m['record'] == null ? null : MeetingRecord.fromJson(m['record']),
      canRecord: _opt<bool>(m, 'can_record') ?? false,
      // Review finding F6 (absent from older servers).
      recordRoster: _opt<List>(m, 'record_roster') == null
          ? null
          : List.unmodifiable(
              _req<List>(
                m,
                'record_roster',
              ).map(ProgrammeRosterMember.fromJson),
            ),
    );
  }

  final CellMeeting meeting;
  final String cellName;

  /// The content and names (leader, assistant, Pastor oversight); false for
  /// an Admin-only reader (state and counts).
  final bool full;

  /// The cell's leader or assistant: may create, save, publish and cancel.
  final bool canEdit;
  final CellProgramme? programme;
  final List<ProgrammeRosterMember> roster;

  /// Story 5.4: the member-safe view of the programme as it stands (the
  /// server's preview), and what members read now (null until published).
  final ProgrammeProjection? preview;
  final ProgrammeProjection? membersSee;

  /// Story 5.4: each published part's Duties state, by part id (the cell's
  /// leader and assistant only).
  final Map<String, PartDuty> duties;

  /// Story 5.4: department positions a draft part may show.
  final List<LinkableDuty> linkable;

  /// Story 5.7: open Cannot attend notices (the cell's leader and assistant).
  final List<StaffAbsence> absences;

  /// Story 5.8: what is known of the meeting afterwards (null from a 5.7
  /// server), the record (leader, assistant and Pastor oversight) and
  /// whether this reader may write it (the leader or assistant, once the
  /// meeting has started and was not cancelled).
  final MeetingStatus? status;
  final MeetingRecord? record;
  final bool canRecord;

  /// Review finding F6: who the leader may name for who led a part, the
  /// cell's members when the meeting started (some may have moved since);
  /// null from an older server.
  final List<ProgrammeRosterMember>? recordRoster;

  /// The recording picker's members: [recordRoster], or the current [roster]
  /// from an older server.
  List<ProgrammeRosterMember> get recordingRoster => recordRoster ?? roster;

  /// The notice of the person holding [partId], if they sent one.
  StaffAbsence? absenceFor(String partId) {
    for (final a in absences) {
      if (a.partIds.contains(partId)) return a;
    }
    return null;
  }
}

/// One part as typed in the editor, sent whole by `cells.save_programme`.
class ProgrammePartDraft {
  const ProgrammePartDraft({
    required this.label,
    required this.startTime,
    required this.endTime,
    this.partId,
    this.assigneeMemberId,
    this.linkedSlotId,
  });

  /// An existing part, as the editor starts it.
  factory ProgrammePartDraft.of(ProgrammePart p) => ProgrammePartDraft(
    partId: p.partId,
    label: p.label,
    startTime: ChurchTime.timeText(p.startsAt),
    endTime: ChurchTime.timeText(p.endsAt),
    assigneeMemberId: p.assignee?.memberId,
    linkedSlotId: p.linkedSlotId,
  );

  final String? partId;
  final String label;

  /// Church-local `HH:MM` on the meeting's date (after midnight: the next
  /// day, when the meeting runs past midnight).
  final String startTime;
  final String endTime;
  final String? assigneeMemberId;

  /// Story 5.4: a department position this part shows instead of a person.
  final String? linkedSlotId;

  Map<String, Object?> toJson() => {
    if (partId != null) 'part_id': partId,
    'label': label.trim(),
    'start_time': startTime.trim(),
    'end_time': endTime.trim(),
    'assignee_member_id': assigneeMemberId,
    if (linkedSlotId != null) 'linked_slot_id': linkedSlotId,
  };
}

/// The field error of part [index] of a refused save (`parts.<index>`).
String? partError(Map<String, String> errors, int index) =>
    errors['parts.$index'];

/// Story 5.4: a refusal of one part's Duties side (`parts.<index>.<field>`),
/// e.g. `member_id: overlap` when the assignee is on another duty then.
String? partDutyError(Map<String, String> errors, int index, String field) =>
    errors['parts.$index.$field'];

/// Story 5.4: the refused publish asks for a reason to keep overlaps.
bool needsOverrideReason(Map<String, String> errors) =>
    errors.keys.any((k) => k.endsWith('.override_reason'));

/// Story 5.4: a department position a part may show (a Duties display link;
/// the duty stays its department's). Names and times only, never people.
class LinkableDuty {
  const LinkableDuty({
    required this.slotId,
    required this.dutyName,
    required this.startsAt,
    required this.filled,
    this.departmentName,
    this.positionName,
    this.endsAt,
  });

  factory LinkableDuty.fromJson(Object? json) {
    final m = _map(json, 'linkable duty');
    return LinkableDuty(
      slotId: _req<String>(m, 'slot_id'),
      departmentName: _opt<String>(m, 'department_name'),
      dutyName: _req<String>(m, 'duty_name'),
      positionName: _opt<String>(m, 'position_name'),
      startsAt: _instant(m, 'starts_at'),
      endsAt: m['ends_at'] == null ? null : _instant(m, 'ends_at'),
      filled: _req<bool>(m, 'filled'),
    );
  }

  final String slotId;
  final String? departmentName;
  final String dutyName;
  final String? positionName;
  final DateTime startsAt;
  final DateTime? endsAt;
  final bool filled;

  /// "Ushers: Evening ushering (Door)", as the server stores it on the part.
  String get label =>
      '${departmentName ?? 'Department'}: $dutyName'
      '${positionName == null ? '' : ' ($positionName)'}';
}

/// How a published part stands in Duties (the cell's managers only).
enum PartDutyStatus {
  awaiting,
  accepted,
  declined,
  open,
  departmentFilled,
  departmentOpen,
  cancelled,
}

/// Story 5.4: one published part's Duties state.
class PartDuty {
  const PartDuty({
    required this.partId,
    required this.status,
    this.confirmedByLeader = false,
    this.needsContact = false,
    this.shortNotice = false,
    this.assignmentId,
    this.assignmentRevision,
  });

  factory PartDuty.fromJson(Object? json) {
    final m = _map(json, 'part duty');
    final partId = _req<String>(m, 'part_id');
    Map? owned, linked;
    for (final p in _opt<List>(m, 'positions') ?? const []) {
      final position = _map(p, 'position');
      if (position['kind'] == 'owned' && position['position_key'] == 'lead') {
        owned = position;
      } else if (position['kind'] == 'linked') {
        linked = position;
      }
    }
    if (linked != null) {
      return PartDuty(
        partId: partId,
        status: _req<bool>(linked, 'cancelled')
            ? PartDutyStatus.cancelled
            : _req<bool>(linked, 'filled')
            ? PartDutyStatus.departmentFilled
            : PartDutyStatus.departmentOpen,
      );
    }
    final assignment = owned?['assignment'] == null
        ? null
        : _map(owned!['assignment'], 'assignment');
    final cancelled =
        m['occurrence_state'] == 'cancelled' || owned?['cancelled'] == true;
    return PartDuty(
      partId: partId,
      status: cancelled
          ? PartDutyStatus.cancelled
          : assignment == null
          ? PartDutyStatus.open
          : switch (assignment['response']) {
              'accepted' => PartDutyStatus.accepted,
              'declined' => PartDutyStatus.declined,
              'pending' => PartDutyStatus.awaiting,
              _ => throw const FormatException('unexpected response'),
            },
      confirmedByLeader: assignment?['response_provenance'] == 'leader',
      needsContact: assignment?['needs_contact'] == true,
      shortNotice: assignment?['short_notice'] == true,
      assignmentId: assignment == null
          ? null
          : _opt<String>(assignment, 'assignment_id'),
      assignmentRevision: assignment == null
          ? null
          : _opt<int>(assignment, 'revision'),
    );
  }

  final String partId;
  final PartDutyStatus status;
  final bool confirmedByLeader;
  final bool needsContact;
  final bool shortNotice;

  /// Story 5.5: the current assignment and its revision (the leader's
  /// direct confirmation is sent at it).
  final String? assignmentId;
  final int? assignmentRevision;

  /// Story 5.5: the leader may record that the person said yes directly.
  bool get confirmable =>
      status == PartDutyStatus.awaiting &&
      assignmentId != null &&
      assignmentRevision != null;

  String get label => switch (status) {
    PartDutyStatus.awaiting => 'Awaiting response',
    PartDutyStatus.accepted =>
      confirmedByLeader ? 'Confirmed by leader' : 'Accepted',
    PartDutyStatus.declined => 'Declined',
    PartDutyStatus.open => 'Open: nobody asked',
    PartDutyStatus.departmentFilled => 'Department duty: filled',
    PartDutyStatus.departmentOpen => 'Department duty: not filled yet',
    PartDutyStatus.cancelled => 'Cancelled',
  };
}

/// One part of the member-safe programme: who leads it by name, or the
/// department that does. No responses, notes or history.
class ProjectionPart {
  const ProjectionPart({
    required this.partId,
    required this.label,
    required this.startsAt,
    required this.endsAt,
    this.leader,
    this.department,
  });

  factory ProjectionPart.fromJson(Object? json) {
    final m = _map(json, 'programme part');
    return ProjectionPart(
      partId: _req<String>(m, 'part_id'),
      label: _req<String>(m, 'label'),
      startsAt: _instant(m, 'starts_at'),
      endsAt: _instant(m, 'ends_at'),
      leader: _opt<String>(m, 'leader'),
      department: _opt<String>(m, 'department'),
    );
  }

  final String partId;
  final String label;
  final DateTime startsAt;
  final DateTime endsAt;
  final String? leader;
  final String? department;
}

/// Story 5.4: the member-safe published programme (and the staff preview).
class ProgrammeProjection {
  const ProgrammeProjection({
    required this.programmeId,
    required this.meetingId,
    required this.parts,
    this.topic,
    this.scripture,
    this.revision,
    this.publishedAt,
    this.meetingChanged = false,
  });

  factory ProgrammeProjection.fromJson(Object? json) {
    final m = _map(json, 'programme projection');
    return ProgrammeProjection(
      programmeId: _req<String>(m, 'programme_id'),
      meetingId: _req<String>(m, 'meeting_id'),
      topic: _opt<String>(m, 'topic'),
      scripture: _opt<String>(m, 'scripture'),
      parts: List.unmodifiable(
        _req<List>(m, 'parts').map(ProjectionPart.fromJson),
      ),
      revision: _opt<int>(m, 'revision'),
      publishedAt: m['published_at'] == null
          ? null
          : _instant(m, 'published_at'),
      meetingChanged: _opt<bool>(m, 'meeting_changed') ?? false,
    );
  }

  final String programmeId;
  final String meetingId;
  final String? topic;
  final String? scripture;
  final List<ProjectionPart> parts;

  /// Set on what members read (null on a preview).
  final int? revision;
  final DateTime? publishedAt;

  /// Story 5.6: the meeting moved since this was published.
  final bool meetingChanged;
}

/// Story 5.4: `api.cells_meeting_programme`, a meeting's published programme
/// for the members of its cell (null while nothing is published).
class MeetingProgrammeRead {
  const MeetingProgrammeRead({
    required this.meeting,
    this.programme,
    this.yours = const [],
    this.myAbsence,
  });

  factory MeetingProgrammeRead.fromJson(Object? json) {
    final m = _map(json, 'meeting programme');
    return MeetingProgrammeRead(
      meeting: CellMeeting.fromJson(m['meeting']),
      programme: m['programme'] == null
          ? null
          : ProgrammeProjection.fromJson(m['programme']),
      // Story 5.5 (absent from 5.4 servers).
      yours: List.unmodifiable(
        (_opt<List>(m, 'yours') ?? const []).map((y) {
          final o = _map(y, 'own part');
          return (
            partId: _req<String>(o, 'part_id'),
            occurrenceId: _req<String>(o, 'occurrence_id'),
          );
        }),
      ),
      // Story 5.7 (absent from 5.6 servers).
      myAbsence: m['my_absence'] == null
          ? null
          : AbsenceNotice.fromJson(m['my_absence']),
    );
  }

  /// Story 5.7: the reader's own open Cannot attend notice.
  final AbsenceNotice? myAbsence;

  final CellMeeting meeting;
  final ProgrammeProjection? programme;

  /// Story 5.5: the reader's own published parts and their Duties
  /// occurrence (their answer is in My duties, never in this read).
  final List<({String partId, String occurrenceId})> yours;

  /// The reader's own Duties occurrence for [partId], if the part is theirs.
  String? occurrenceOf(String partId) {
    for (final y in yours) {
      if (y.partId == partId) return y.occurrenceId;
    }
    return null;
  }
}

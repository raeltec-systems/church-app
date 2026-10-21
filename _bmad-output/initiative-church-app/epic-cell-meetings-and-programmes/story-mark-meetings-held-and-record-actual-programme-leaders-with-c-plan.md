---
title: 'Mark meetings held and record actual programme leaders with corrections'
type: 'feature'
ticket: '8'
created: '2026-10-21'
status: 'in-progress'
baseline_revision: '302bac3'
route: 'full'
route_source: 'auto'
review: ''
review_source: ''
lenses_ran: []
review_loop_iteration: 0
context:
  - '{project-root}/docs/runbooks/cells-meetings.md'
  - '{project-root}/docs/runbooks/contracts-and-owner-seams.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** After a cell meeting nothing records whether it took place or who actually led each part, so later attendance, recaps and offerings would have to assume the plan happened and would name the planned person even when someone else served.

**Approach:** Add a Cells meeting record. Once the meeting has started, the cell's leader or assistant records whether it was held. Corrections need a reason and keep each earlier value. For a held meeting they record who actually led each programme part: a member of the cell, a named guest or nobody. These are separate attributed rows, and a change supersedes the earlier row with a reason. The planned assignee and every duty response stay as they were. An internal canonical meeting reference (held, not held, cancelled or unrecorded, plus the actual leaders) is exposed to later owners.

**Decisions:**
- Decision (agent, under owner pre-approval): the record is a Cells aggregate keyed by meeting: `cells.record_meeting_held {meeting_id, held}` creates it (expected null); `cells.correct_meeting_held {meeting_id, held, reason}` and `cells.record_actual_leaders {meeting_id, parts}` take the record revision. Only the cell's current leader or assistant writes; Admin alone does not; Pastor oversight reads.
- Decision (agent, under owner pre-approval): a meeting can be recorded only once it has started and was not cancelled (cancelling needs a meeting ahead, so held and cancelled exclude each other). Actual leaders need a held record and a programme that is not cancelled; they refer to its current parts.
- Decision (agent, under owner pre-approval): nothing is inferred. "As planned" is an explicit choice the leader makes. No duty response, duty outcome (4.10) or attendance is set from a record, and no record is set from them. A substitution is shown where the actual leader differs from the person planned when it was recorded.
- Decision (agent, under owner pre-approval): no notification is sent; the member read is unchanged (recaps, epic 7, read the reference).

## Boundaries & Constraints

**Always:** commands through `api.cells_command`; corrections keep the prior row, its actor and time, and need a reason; ASCII migration, no destructive statements; the deletion hook covers the new tables.

**Never:** a duty response, outcome or attendance written or changed; the planned assignee changed; a held cancelled meeting; another cell's leader recording.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Record held | leader, meeting started, not cancelled | record held rev 1 | ahead: `validation_failed not_started`; cancelled: `validation_failed cancelled`; again: `conflict recorded`; other cell: `forbidden` |
| Correct | at the revision, a reason | held flips, history keeps the prior value | no reason: `validation_failed reason`; same value: `validation_failed held unchanged`; stale: `conflict` |
| Actual leaders | held, parts of the programme | one current row per part; substitution marked | not held: `validation_failed held`; unknown or removed part: `parts.N.part_id`; non-member: `parts.N.member_id`; change without reason: `parts.N.reason` |
| Correction of a leader | a different value, reason | earlier row superseded and kept | identical value: no new row |
| Plan and duties | any of the above | parts' assignees and Duties positions unchanged | none |

</frozen-after-approval>

## Code Map

- `supabase/migrations/20261021111547_cells_absence_notices.sql`: dispatcher, authorizer, in-scope, staff read and erase replaced from here.
- `supabase/migrations/20261021081026_cells_meeting_reminders.sql` (or later): `app.cells_meetings()` board read replaced to add `recent`.

## Tasks & Acceptance

**Execution:**
- [x] `supabase/migrations/20261021130000_cells_meeting_records.sql`
- [x] `supabase/tests/cells_meeting_records_test.sql`
- [x] Clients: Cell meetings "Last 4 weeks" with status and Record; Plan meeting "After the meeting" (held, who led each part, All as planned, corrections with a reason, earlier values).
- [x] E2E `tools/identity-e2e/cells-meeting-records.mjs` + offline test.
- [x] Runbook section; contracts-and-owner-seams entry for `app.cells_meeting_reference`.

**Acceptance Criteria:**
- Given staff web and mobile, when a leader marks a synthetic meeting held, records a substitute for a planned part leader and corrects it, then through the API the plan and the duty response are unchanged, the correction keeps the earlier record and actor, a cancelled meeting cannot be marked held, and another cell's leader is refused.

## Implementation Notes

- Migration: `app.cells_meeting_records` (held, revision, who and when), `app.cells_meeting_record_history` (every value with actor, reason, request id), `app.cells_actual_leaders` (member, guest or nobody per part; one current row per part, superseded rows kept; the planned person at write time). Commands `cells.record_meeting_held` (expected null), `cells.correct_meeting_held` and `cells.record_actual_leaders` (record revision). Lock order: meeting (share), record (update), programme (share), membership (key share). `app.cells_meeting_status`, `app.cells_meeting_record_json`, the internal `app.cells_meeting_reference`. Re-created: authorizer, dispatcher, in-scope (`cells_meeting_record`), staff read (`status`, `record`, `can_record`), board read (`recent`), erase.
- pgTAP `cells_meeting_records_test.sql` (44). Full db:test passes on a fresh reset.
- Clients: `MeetingStatus`, `RecentMeeting`, `MeetingRecord`, `HeldEntry`, `ActualLeader`, `ActualLeaderDraft`, `CellRecordCommands`; `CellProgrammeController.recordHeld/correctHeld/recordLeaders`; `_RecordCard` and `_ActualRow` on Plan meeting; Last 4 weeks on Cell meetings. Tests in `cell_meeting_records_test.dart` (8). The two `boundaries_test.dart` failures on this Windows host are a test path bug (`replaceAll(r'\', '/')`), not a change.
- E2E `tools/identity-e2e/cells-meeting-records.mjs` (6 checks) + offline test; numbers `+44 7700 900060-900069`. Regressions: cells-absence 5/5, cells-meetings 10/10, cells-programme-revisions 6/6.

## Plan Change Log

## Review Triage Log

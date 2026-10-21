---
title: 'Send Cannot attend notices separately from duty responses'
type: 'feature'
ticket: '7'
created: '2026-10-21'
status: 'in-progress'
baseline_revision: 'd783437'
route: 'full'
route_source: 'auto'
review: ''
review_source: ''
lenses_ran: []
review_loop_iteration: 0
context:
  - '{project-root}/docs/runbooks/cells-meetings.md'
  - '{project-root}/docs/runbooks/notifications.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** A member who cannot come to a cell meeting has no way to say so in the app, and a leader cannot tell an absence from a declined part, so the plan quietly breaks or a duty is wrongly marked.

**Approach:** Add Cells absence notices: one per member and meeting, with an optional practical note, send, change and withdraw actions, actor and time kept. The cell's leader and assistant get a generic inbox notice and read who and why on Plan meeting, with a warning on any part the sender holds. The member is asked to answer a held part separately (My cell / My duties). A notice never sets a duty response, Excused or any attendance (registers are epic 7).

**Decisions:**
- Decision (agent, under owner pre-approval): notices are Cells records (`app.cells_absence_notices`); the member sends (`cells.send_cannot_attend`, expected null), changes the note (`cells.change_cannot_attend`, expected = notice revision) and withdraws (`cells.withdraw_cannot_attend`); one open notice per meeting; a withdrawn one is kept and a new one may be sent.
- Decision (agent, under owner pre-approval): the leaders' inbox notice names nobody (Notifications rule); the note is readable only by the sender and the cell's leader and assistant (not Pastor oversight, not other members); the audit holds no note.
- Decision (agent, under owner pre-approval): the coverage warning is shown on Plan meeting (who can't attend, and "Can't attend" on the part); the 4.9 coverage queue stays department-only.

## Boundaries & Constraints

**Always:** commands through `api.cells_command`; Notifications last; generic notification text; ASCII migration, no destructive statements; deletion hook covers notices and their audit.

**Never:** a duty response, Excused or attendance row from a notice; a name or note in a notification; another member reading a notice.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Send | confirmed member, meeting ahead | open notice; leader and assistant told | not a member: `not_found`; second: `conflict exists`; cancelled or started: `validation_failed` |
| Change | the member, at the revision | note changed; leaders told again | stale: `conflict`; someone else: `not_found` |
| Withdraw | the member, at the revision | withdrawn; leaders told | second: `conflict withdrawn`; someone else: `not_found` |
| Held part | member with a part sends a notice | part stays Awaiting or Accepted; member asked to answer it separately | none |
| Reads | leader/assistant; member; others | notices with notes and parts; own notice; nothing | Pastor: none |

</frozen-after-approval>

## Code Map

- `supabase/migrations/20261021094249_cells_programme_publish.sql` -- staff read, authorizer and dispatch replaced.
- `supabase/migrations/20261021081026_cells_meeting_reminders.sql` -- Notifications contract registration pattern.

## Tasks & Acceptance

**Execution:**
- [x] `supabase/migrations/20261021120000_cells_absence_notices.sql`
- [x] `supabase/tests/cells_absence_notices_test.sql`
- [x] Clients: My cell Can't come? (send, change, withdraw; the held part reminder), Plan meeting Can't attend list and part warning, `/cells/meetings` deep link.
- [x] E2E `tools/identity-e2e/cells-absence.mjs` + offline test.
- [x] Runbook section.

**Acceptance Criteria:**
- Given mobile, when a member with and without an assigned part sends, changes and withdraws a Cannot attend notice, then through the API the leader is notified, the part stays Awaiting or Accepted until the member responds separately, no attendance record exists, and another member cannot read the notice or its note.

## Implementation Notes

- Migration: `app.cells_absence_notices` (open/withdrawn, revision, note at most 280 characters, `sent_by_account`), `app.cells_absence_audit` (content-free), source `cells_absence_notice` with kinds `cells_absence_sent` and `cells_absence_withdrawn` (link `/cells/meetings`), `app.cells_absence_notify` (current leaders and assistants; a change cancels the notice still waiting), three commands, the authorizer/dispatch/in-scope (`cells_absence_notice` replays for its sender), `absences` on the staff read (leader and assistant), `my_absence` on the member read, the deletion hook.
- pgTAP `cells_absence_notices_test.sql` (26). Full db:test passes on a fresh reset.
- Clients: `AbsenceNotice`, `StaffAbsence`, `CellAbsenceCommands`, `MemberProgrammeController.sendCannotAttend/changeCannotAttend/withdrawCannotAttend`, `_AbsenceSection` on My cell, `_AbsencesCard` and the "Can't attend" part label on Plan meeting, `/cells/meetings` deep link. Tests in `cell_youre_on_test.dart`.
- E2E `tools/identity-e2e/cells-absence.mjs` (5 checks) + offline test; numbers `+44 7700 900050-900059`.

## Plan Change Log

- The single `send` command with an optional revision became `send` (expected null) and `change` (expected revision): the 1.4 kernel refuses an expected revision on a command that does not require one.

## Review Triage Log

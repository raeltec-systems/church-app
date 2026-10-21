---
title: 'Draft a meeting programme with validated parts and visible gaps'
type: 'feature'
ticket: '3'
created: '2026-10-21'
status: 'in-progress'
baseline_revision: '5.2 branch head'
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

**Problem:** A cell's leader has meetings (5.1) but cannot plan what happens in them, so nobody knows who leads the opening prayer or the Bible study, and gaps are discovered on the night.

**Approach:** Add revisioned programme records per meeting (topic, scripture, study notes and ordered parts with label, start, end or duration, optional assignee from the cell's confirmed roster including members without a login) with Draft and Cancelled states (Published arrives in 5.4), server validation of order and fit inside the meeting, unassigned parts kept as visible gaps, drafts readable only by the cell's leader and assistant and Pastor oversight (Admin alone gets metadata only), and a staff web **Plan meeting** editor with an accessible part list and a member preview.

**Decisions:**
- Decision (agent, under owner pre-approval): one programme per meeting (`meeting_id` unique). Its date, time and venue are the meeting's own (5.1); changing them is a meeting move, not a programme edit, so there is one source of truth for when and where.
- Decision (agent, under owner pre-approval): `cells.save_programme` replaces the draft's whole content at the programme revision (topic, scripture, study notes, parts); parts keep a stable `part_id` when the client sends it back, new parts get new ids, and parts left out are marked removed (never deleted), so 5.4 can link one Duties slot per stable part.
- Decision (agent, under owner pre-approval): part times are typed as church-local `HH:MM` on the meeting's date (`start_time` and `end_time`, or `duration_minutes`); parts must be in time order, inside the meeting, and may not overlap; at most 20 parts; labels 1-60 characters.
- Decision (agent, under owner pre-approval): Pastor oversight uses the existing Pastor role (read-only, as Duties does); a new oversight scope waits for an owner request. Admin alone reads state, revision and counts only, never topic, notes, parts or names.
- Decision (agent, under owner pre-approval): an assignee must be a current confirmed member of the meeting's cell; an assignee who later leaves the cell stays on the draft but is flagged `not_in_cell` (transfer effects are 5.9).
- Decision (agent, under owner pre-approval): the leader or assistant creates, saves and cancels drafts (epic Notes: assistants manage programmes); Admin and Pastor do not edit.

## Boundaries & Constraints

**Always:** every change through `api.cells_command` with revision checks; reads through `api` wrappers behind the live-access predicate and the Q4 gate; text fields printable and length-limited, like Duties' topic and instructions (the `SYNTHETIC ` rule applies to names and labels of records, as in 2.6, not to programme free text); ASCII migration without `\u` escapes, no destructive statements, privileges revoked; deletion hook covers assignees and actors.

**Never:** publishing, Duties slots or member reads of a programme (5.4), responses (5.5), notices for programme changes (5.6), notes or names to an Admin-only reader.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Create | leader or assistant, meeting ahead | empty draft, revision 1 | other cell's leader, member, Admin-only, Pastor: `forbidden`; second draft: `conflict {"meeting_id": "exists"}`; cancelled or started meeting: `validation_failed` |
| Save | parts in order inside the meeting, one unassigned | revision + 1; unassigned part listed as a gap | stale revision: `conflict` |
| Bad parts | overlap, out of order, before start or after end, end before start, assignee not in the cell | `validation_failed {"parts": {"<index>": "<code>"}}` | nothing written |
| Read draft | leader, assistant, Pastor | full draft with roster | cell member, other leader: `403 not_granted`; Admin-only: metadata only |
| Cancel draft | leader or assistant | Cancelled, read-only | stale: `conflict` |
| Deletion | assignee or actor erased | assignee cleared, actor anonymised | none |

</frozen-after-approval>

## Code Map

- `supabase/migrations/20261021073514_cells_meetings.sql`, `20261021081026_cells_meeting_reminders.sql` -- meetings, capacity, command dispatch to extend.
- `docs/design-handoff/screenshots/admin-06-plan-meeting.png` -- the editor and member preview reference.
- `packages/client_core/lib/src/presentation/cell_screens.dart` -- Cell meetings card (add **Plan**).

## Tasks & Acceptance

**Execution:**
- [x] `supabase/migrations/20261021084446_cells_programmes.sql`
- [x] `supabase/tests/cells_programmes_test.sql`
- [x] Clients: domain, controller, **Plan meeting** screen (`/cells/meetings/:meetingId/plan`) with member preview, **Plan** on each meeting row.
- [x] E2E `tools/identity-e2e/cells-programmes.mjs` + offline test.
- [x] Runbook section.

**Acceptance Criteria:**
- Given staff web, when a leader drafts a programme with an unassigned part, tries overlapping and out-of-meeting parts and saves under a stale revision, then the bad saves are refused, the stale save is a conflict, and through the API a cell member, a leader of another cell and Admin-only access cannot read the draft while Pastor oversight can.

## Implementation Notes

- Server: one migration with three tables (programmes, parts with stable ids and `removed_at`, a content-free audit), `app.cells_free_text` for printable, length-limited text, three commands through the existing dispatch (`revision_required` false for `create_programme`), the in-scope recheck for aggregate `cells_programme`, and `api.cells_programme(meeting_id)` (full for leader/assistant and the Pastor role, metadata for an Admin-only reader, 403 `not_granted` otherwise). Part errors are keyed `parts.<index>` (the 1.4 envelope allows any snake_case token as a code and free-form keys). `cells_erase_member` extended. It also carries the 5.2 review fixes (see the 5.2 plan's triage log).
- pgTAP `supabase/tests/cells_programmes_test.sql` (40); the 5.2 file gains the review-fix cases (45); the command-foundation ledger lists `api/app.cells_programme`.
- Clients: `domain/cell_programmes.dart` (`ProgrammeRead`, `CellProgramme`, `ProgrammePart`, `ProgrammeRosterMember`, `ProgrammePartDraft`), `CellProgrammeController` (autoDispose family by meeting id), `PlanMeetingScreen` at `/cells/meetings/:meetingId/plan` (taste rules: the state and the gap count first, colour only on gaps and errors, the save one click away, honest read-only and metadata states), **Plan** on meeting rows. Tests: `test/identity/cell_programmes_test.dart` (16) and one 5.2 chip test.
- E2E `tools/identity-e2e/cells-programmes.mjs` (11 checks) with offline `cells-programmes.test.mjs`; numbers `+44 7700 900010-900019`. Regression runs of the 5.1, 5.2 and 2.6 E2Es are in `evidence-5.3/`.

## Plan Change Log

## Review Triage Log

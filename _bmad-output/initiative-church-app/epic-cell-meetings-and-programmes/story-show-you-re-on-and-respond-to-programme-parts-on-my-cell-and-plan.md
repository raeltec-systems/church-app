---
title: 'Show You''re on and respond to programme parts on My cell and Home'
type: 'feature'
ticket: '5'
created: '2026-10-21'
status: 'in-progress'
baseline_revision: '450962a'
route: 'full'
route_source: 'auto'
review: ''
review_source: ''
lenses_ran: []
review_loop_iteration: 0
context:
  - '{project-root}/docs/runbooks/cells-meetings.md'
  - '{project-root}/docs/runbooks/duties.md'
  - '{project-root}/docs/runbooks/contracts-and-owner-seams.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** A programme is published (5.4) and each person is asked through Duties, but the member only sees it in My duties, nothing on My cell or Home says "You're on", and a leader cannot record that a member without a login said yes (Confirmed by leader is department-only).

**Approach:** Mobile My cell shows the next meeting's published programme with the member's own part first ("You're on"), its actual Awaiting, Accepted, Confirmed by leader or Declined answer, reporting time and instructions, from the member's own Duties read, and Accept / Can't do it through the Duties response commands; other parts show names only. Home gets a My cell card. The member programme read names the reader's own parts and their Duties occurrence. A Duties contract change lets a cell's current leader or assistant record the 4.9 attributed direct confirmation for a cell part (provenance `leader`), shown on staff Plan meeting.

**Decisions:**
- Decision (agent, under owner pre-approval): the answer shown on My cell and Home comes from the member's own My duties read, matched by the part's Duties occurrence (`yours` in `api.cells_meeting_programme`); the programme read itself never carries an answer, so no member sees another's.
- Decision (agent, under owner pre-approval): the cell-scope confirmation is `duties.confirm_by_leader` itself (the 4.9 command), widened in Duties to a cell-owned assignment when the actor is a current leader or assistant of that cell; contact attempts, the coverage queue, leader alerts and outcomes stay department-only (a later contract change if the church asks). The leader records it from the published programme on Plan meeting ("They said yes directly"), not from a separate cell coverage screen.
- Decision (agent, under owner pre-approval): Home shows My cell only for a member with a confirmed cell and a next meeting; its You're on line appears once the programme is published.

## Boundaries & Constraints

**Always:** member answers only through the Duties response commands at the assignment revision (stale refused); the leader confirmation is attributed (actor, channel, reason) and distinct from member acceptance; Duties changes are a recorded contract change in a Duties migration; ASCII migrations, no destructive statements; honest states (loading, not published, could not load).

**Never:** other members' answers in any member read; a leader confirming for a department duty they don't manage; a cell-side copy of Duties state.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| You're on | member with a published part | My cell and Home show the part, Awaiting, reporting time, instructions | not published: "not published yet"; read fails: says so |
| Member answers | Accept / Can't do it | `duties.respond` at the revision; answer shown | stale: `conflict` |
| Leader confirms | accountless member's part, leader or assistant | Confirmed by leader (provenance leader, channel, reason, actor) | member, Admin, Pastor, other cell's leader, department leader: `not_found`; second: `conflict responded` |
| Others | another member reads the programme | names, never answers | none |

</frozen-after-approval>

## Code Map

- `supabase/migrations/20261014212507_duties_coverage.sql` -- 4.9 `duties_confirm_by_leader`, `duties_lock_for_leader`.
- `supabase/migrations/20261015110202_duties_lifecycle.sql` -- latest `duties_authorize_command`; `20261014023442_duties_rota_series.sql` -- `duties_in_scope`.
- `packages/client_core/lib/src/presentation/cell_screens.dart` -- My cell, Plan meeting; `duties_screens.dart` -- Home, My duties.

## Tasks & Acceptance

**Execution:**
- [x] `supabase/migrations/20261021100000_duties_cell_confirmation.sql` (Duties contract change)
- [x] `supabase/migrations/20261021100500_cells_youre_on.sql`
- [x] `supabase/tests/cells_youre_on_test.sql`
- [x] Clients: `yours`, `MemberProgrammeController`, `confirmByLeader`, My cell You're on, Home My cell card, Plan meeting direct confirmation.
- [x] E2E `tools/identity-e2e/cells-youre-on.mjs` + offline test.
- [x] Runbook sections.

**Acceptance Criteria:**
- Given staging, when a confirmed member accepts their part from My cell and declines another from My duties, and the leader confirms an accountless member's part by phone, then Confirmed by leader shows distinct from member acceptance, the plan shows names but never statuses to other members, and a stale response is refused after a change.

## Implementation Notes

- Duties contract change: `app.duties_lock_for_confirm` (department duties through the unchanged `duties_lock_for_leader`; cell-owned duties for a current cell leader or assistant), `duties_confirm_by_leader` replaced to use it (coverage cases closed only for department duties), `duties_in_scope` (a cell occurrence replay needs the cell scope), `duties_authorize_command` (also share-locks cell grants).
- Cells: `app.cells_meeting_programme` adds `yours` (the reader's parts named in the published projection, with `duty_occurrence_id`).
- pgTAP `supabase/tests/cells_youre_on_test.sql` (20). Full db:test passes on a fresh reset.
- Clients: `MeetingProgrammeRead.yours`/`occurrenceOf`, `PartDuty.assignmentId/assignmentRevision/confirmable`, `MemberProgrammeController` (`memberProgrammeProvider`), `CellProgrammeController.confirmByLeader` (sends `duties.confirm_by_leader` through `duties_command`), `_MyCellProgrammeCard`/`_YoureOn` on My cell, `MyCellHomeCard` on Home, "They said yes directly" on Plan meeting's published view. Tests `test/identity/cell_youre_on_test.dart` (8).
- E2E `tools/identity-e2e/cells-youre-on.mjs` (7 checks) + offline test; numbers `+44 7700 900030-900039`. Regression runs of the 5.4, Duties coverage, owner-ops and responses E2Es in `evidence-5.5/`.

## Plan Change Log

## Review Triage Log

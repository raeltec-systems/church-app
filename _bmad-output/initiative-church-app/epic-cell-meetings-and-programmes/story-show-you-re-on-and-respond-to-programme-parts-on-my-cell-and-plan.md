---
title: 'Show You''re on and respond to programme parts on My cell and Home'
type: 'feature'
ticket: '5'
created: '2026-10-21'
status: 'done'
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
- [x] `supabase/migrations/20261021101314_duties_cell_confirmation.sql` (Duties contract change)
- [x] `supabase/migrations/20261021101323_cells_youre_on.sql`
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

Independent review of `450962a..172085c` (2026-10-21, a separate reviewer agent; no high-severity finding: only a current leader or assistant of the part's own cell confirms, department duties go through the unchanged lock, replay widening is safe, `yours` leaks nothing). Fixes before staging, in place:

1. Medium, deferred to 5.9: a member transferred out of the cell can still be confirmed on the old cell's part (no `cell_transferred` hook ends cell parts yet; Duties cannot read Cells membership without breaking the module boundary). Story 5.9 applies transfer and removal to programmes and cell duties and closes this. Runbook known limit.
2. Medium, fixed: My cell declined in one tap and showed no failure. **Can't do it** now asks once more ("Yes, I can't"), and the card says Sending, a refused answer, an unconfirmed outcome or Not sent. Tests added.
3. Low-Medium, fixed: honest states. My cell says "Loading your answer…" or "could not be loaded here" instead of sending the member away; Home says when the programme could not be loaded. Tests added.
4. Low, fixed: Accept / Can't do it follow `needsResponse(now)`; an accepted part offers **Can't make it anymore** (withdraw, confirmed once more); labels match My duties ("Can't make it").
5. Low, fixed: the leader's confirm form stays open (with the typed reason) until the part shows the answer; **Not now** waits while sending. Not fixed: hiding the button on the leader's own part (the server refuses `own`; the leader is rarely a member of their own programme).
6. Low, accepted: the `leader_confirmed` audit has no cell id (traceable through the occurrence); `reminders_skipped` after a cell confirmation records capacity `member` (Duties' department-only capacity helper). Recorded.
7. Low, accepted: the cell path does not call Cells' open-gate or active-cell checks (Duties does not call Cells; the Q4 gate is the same one Duties checks).
8. Nit, accepted: `CellPaths.myCell` repeats `ClientPaths.myCell` (cell screens do not import the router).
9. Tests added: department regression both ways, stale confirmation, the audit row, `yours` empty after a cancel, and the client cases above.

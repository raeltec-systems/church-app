---
title: 'Preview and publish a safe programme that creates or links duty slots'
type: 'feature'
ticket: '4'
created: '2026-10-21'
status: 'done'
baseline_revision: '52d8ff0'
route: 'full'
route_source: 'auto'
review: ''
review_source: ''
lenses_ran: []
review_loop_iteration: 0
context:
  - '{project-root}/docs/runbooks/contracts-and-owner-seams.md'
  - '{project-root}/docs/runbooks/duties.md'
  - '{project-root}/docs/runbooks/cells-meetings.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** A leader can draft a programme (5.3) but members never see it and nobody is asked to take their part, so a printed plan is still the only way to tell people they are on.

**Approach:** Add a Published state. Publishing calls the 4.11 Duties owner operations inside the Cells command's transaction: one cell-owned Duties occurrence per stable part with one position (`lead`), whose assignee is asked for an explicit response (Awaiting) or which stays open, or a display link (`department`) to an existing department position, never cloned or changed. A republish puts the same state, so nothing is duplicated. On publish a dedicated member-safe projection is written (topic, scripture, parts with times, the named leader or linked department; no study notes, responses, notes or history), readable only by current confirmed members of the cell with an approved active account; the staff read carries the same projection built from the programme as its preview.

**Decisions:**
- Decision (agent, under owner pre-approval): a part's Duties source is `cells_programme_part` (source id = part id, source revision = the programme revision, which every save and publish bumps); a removed part is never current. Registered in the 5.4 migration (1.5 source type and the 4.11 `cell_part` role).
- Decision (agent, under owner pre-approval): one position per part (`lead`); a part shows either a person or a department position (`linked_slot_id`), never both. The department positions offered are those overlapping the meeting (a Duties contract change: `app.duties_owner_linkable`, recorded in the 4.11 plan), as the consumer guide requires instead of a Cells workaround.
- Decision (agent, under owner pre-approval): the Duties location of a cell part is the meeting's venue (the assignee is a confirmed member of the cell); topic and scripture are the programme's; no per-part instructions or reporting time yet.
- Decision (agent, under owner pre-approval): a Duties refusal of one part is answered under that part (`parts.<index>.<field>`); the 4.4 overlap gate is honoured: the leader changes the part or publishes with an `override_reason`.
- Decision (agent, under owner pre-approval): a published programme is not edited in this story (material revisions are 5.6); cancelling it cancels its cell-owned duties through Duties and ends its display links, and members stop reading it.
- Decision (agent, under owner pre-approval): the member read is `api.cells_meeting_programme(meeting_id)`; the cell's leader, an Admin or a Pastor who is not a member of the cell uses the staff read instead.

## Boundaries & Constraints

**Always:** AD-2 lock order: Identity (the authorizer's grants), then the people a publish may notify (`duties_owner_session` and `duties_lock_people`), then Cells (meeting, programme), then Duties, then Notifications; Duties only through the owner operations, never its tables; the projection is written, never derived from private fields on read (AD-5); ASCII migration, no destructive statements, privileges revoked; deletion hook covers every new member-linked column and names in the projection.

**Never:** cloning or changing a department duty; responses, notes or history in the member read; editing a published programme (5.6); programme change notices (5.6); leader confirmation for accountless members (5.5).

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Publish | leader or assistant, saved draft with assigned, unassigned and department parts | Published; one cell-owned slot per owned part (assignees pending, unassigned open), one display link | member, Admin, Pastor, other leader: `forbidden`; stale: `conflict`; no parts: `validation_failed {"parts": "required"}` |
| Overlap | assignee on another duty then | `validation_failed {"parts.<i>.member_id": "overlap", ...}`, nothing published | with `override_reason`: published |
| Republish | published programme at its revision | no new slot, link or assignment | as publish |
| Member read | confirmed member with an approved account | meeting with venue, projection equal to the staff preview, no private fields | other cell, Admin, leader not a member, no member access: 403 |
| Cancel | published programme | cell-owned duties cancelled, link ended, members read nothing; department duty unchanged | stale: `conflict` |
| Deletion | assignee erased | name removed from the projection, part a gap | none |

</frozen-after-approval>

## Code Map

- `supabase/migrations/20261015035112_duties_owner_operations.sql`, `20261015110202_duties_lifecycle.sql` -- the owner operations, `duties_owner_session`, `duties_lock_people`, the fixture caller to copy.
- `supabase/migrations/20261021084446_cells_programmes.sql` -- programmes, parts, commands, staff read.
- `docs/runbooks/contracts-and-owner-seams.md` -- the consumer guide (release gate, step 7).

## Tasks & Acceptance

**Execution:**
- [x] `supabase/migrations/20261021093943_duties_owner_linkable.sql` (Duties contract change)
- [x] `supabase/migrations/20261021094249_cells_programme_publish.sql` (with the 5.3 review fixes)
- [x] `supabase/tests/cells_programme_publish_test.sql`
- [x] Clients: domain (projection, Duties state, linkable duties, member read), controller (publish), Plan meeting (publish, overlap reason, department duties, published view), 5.3 client review fixes.
- [x] E2E `tools/identity-e2e/cells-programme-publish.mjs` + offline test.
- [x] Runbook section.
- [x] Staging apply (release gate confirmed by the owner; `evidence-5.4/staging-verify.md`).

**Acceptance Criteria:**
- Given a synthetic programme with assigned, unassigned and department-linked parts, when it is published, then there is one current slot per part/position with Awaiting responses, the department duty is unchanged and still owned by its department, a republish creates no duplicate slot, the preview matches the member read, and a member's API read contains no response, note or history fields.

## Implementation Notes

- Server: `cells.publish_programme {programme_id, override_reason?}` (expected = programme revision) in `20261021094249_cells_programme_publish.sql`: people locked first (`duties_owner_session` of the cell, then the parts' assignees), then the meeting and the programme; refuses a cancelled programme, a cancelled or started meeting, no parts, or an assignee who left the cell; bumps the revision, sets Published, calls `app.cells_publish_part` per part (put_part with `lead`, or link_duty with `department`, unlinking a different slot first), writes `app.cells_programme_projections`, audits `programme_published`. A Duties `validation_failed` is re-keyed under its part. `cells.cancel_programme` cancels the owned occurrences (`duties_owner_cancel_part` at the occurrence revision) and unlinks, and withdraws the projection. Staff read adds `preview`, `published`, `duties` (per part, from `duties_owner_part`; leader and assistant only) and `linkable`. Member read `api.cells_meeting_programme`. Deletion removes names from projections and anonymises publishers.
- Duties contract change `app.duties_owner_linkable` (4.11 plan, change log).
- pgTAP `supabase/tests/cells_programme_publish_test.sql` (45, including 5.3 fixes 1, 2, 6 and 9); command-foundation ledger adds the member read. Full db:test passes on a fresh reset. (`duties_owner_decisions_test` 32, a 3 s board timing, failed once while the whole suite ran in parallel and passes alone at about 0.4 s: load-sensitive, unchanged code.)
- Clients: `cell_programmes.dart` (`ProgrammeProjection`, `PartDuty`, `LinkableDuty`, `MeetingProgrammeRead`), `CellProgrammeController.publish`, `clearFieldErrors`, Plan meeting: **Publish to members** (a saved draft only), the overlap reason, **Department duty** choices on a part, the published view (who is on, each answer, what members see, cancel). 5.3 client review fixes 10-12. Tests: `test/identity/cell_programmes_test.dart` (25).
- E2E `tools/identity-e2e/cells-programme-publish.mjs` (12 checks) + offline test; numbers `+44 7700 900020-900029`. Regression runs of 5.3, 5.2, 5.1 and the 4.11 owner-ops E2E in `evidence-5.4/`.

## Plan Change Log

## Review Triage Log

Independent review of `52d8ff0..1c8a62d` (2026-10-21, a separate reviewer agent). The safe-projection read cases were repeated and hold (body fields, access via `identity_require_access` plus a current membership, withdrawal on cancel, names removed on deletion; publish is all or nothing through the kernel's rollback). 5.4 was not yet on staging, so the fixes are in the same migration:

1. High, fixed (client): the leader's own save came back as a newer revision and the editor called it "Changed elsewhere", blocking Publish. The editor now compares the typed content with the server's (ids aside) and simply reloads when they match. Widget test added.
2. Medium, fixed: cancelling or moving a meeting left its published programme's duties live. While a programme is published, `cells.move_meeting` and `cells.cancel_meeting` answer `conflict {"meeting_id": "programme_published"}` (a trigger keyed on the running command, set by the Cells dispatcher). Generation by a schedule change is not refused; reconciliation is 5.6 (runbook known limit).
3. Medium, fixed: a department position gone between save and publish answered a bare `not_found`; it is now `parts.<i>.linked_slot_id: link_unavailable`.
4. Medium/low, fixed: the authorizer now key-share-locks the actor's member row before the grants (Identity's order), so a deactivation during a publish waits instead of deadlocking.
5. Low, fixed: publish rechecks part times against the meeting (`parts.<i>: outside_meeting`).
6. Low, fixed: a Duties conflict during a publish carries the programme's revision.
7. Low, accepted: a projection names the leader as published until a republish or deletion (transfer and removal effects are 5.9).
8. Low, accepted: notices are queued per part as each Duties call runs; no lock cycle found (Notifications is still after every Duties row of that part).
9. Low, fixed (client): former names follow the current offer; the reason field also shows when the reason itself is refused; Publish waits while the draft is stale; an ended department link reads "Department duty: link ended".
10. Low, fixed: cancelling a programme whose duty has started answers `meeting_id: started`.
11. Tests added: no Duties rows after a refused publish, the meeting guard (move and cancel), the member read after a transfer, the save-then-publish flow. Not added: a department position cancelled between save and publish (covered by the mapping; Duties' own refusal is tested in 4.11).

---
title: 'Publish material programme revisions atomically and flag department mismatches'
type: 'feature'
ticket: '6'
created: '2026-10-21'
status: 'in-progress'
baseline_revision: '149ead6'
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

**Problem:** A published programme (5.4) cannot be changed: a new time, a swapped person or a moved meeting leaves people holding stale assignments, and a linked department duty is never told its programme changed.

**Approach:** Let the leader change a published programme (members keep the last publish) and publish the revision in one transaction through the 4.11 owner operations, so Duties revises cell-owned assignments with its own material rules (prior consent superseded and kept in history, obsolete jobs cancelled, change notices sent; notes-only keeps answers), ends removed parts, and flags a linked department duty for its owner's review instead of changing it. A meeting move by the cell's leader carries the programme along and is published as a revision; the staff page and members are told.

**Decisions:**
- Decision (agent, under owner pre-approval): material versus notes-only is Duties' own classification (4.2/4.11): time, label (duty name), place and person are material; topic and scripture are notes-only; study notes never reach Duties. Cells adds no second classification.
- Decision (agent, under owner pre-approval): a saved change to a published programme stays Published with "unpublished changes"; members and Duties keep the last publish until the leader publishes again.
- Decision (agent, under owner pre-approval): a part keeps its kind once published (person's slot or department link): switching is `published_kind` (remove it and add a new part), because Duties never reuses a cancelled position key.
- Decision (agent, under owner pre-approval): department mismatch codes are Duties' (`time`, `label`, `place`, `cancelled`), compared with what was last published (part time and label, meeting time and venue); the duty itself is never changed.
- Decision (agent, under owner pre-approval): the cell's leader or assistant may move a meeting with a published programme (its parts follow, the page and members are told, the leader publishes the revision); Admin alone may not (Duties owner operations need the cell scope), and cancelling such a meeting stays refused until the programme is cancelled (which flags and cancels its duties).

## Boundaries & Constraints

**Always:** one transaction per publish; Duties only through the owner operations; AD-2 lock order as 5.4; members read the stored projection; ASCII migration, no destructive statements.

**Never:** changing or cloning a department duty; resetting answers on a notes-only change; a Cells-side copy of Duties' material rules.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Notes only | topic, scripture, study notes changed; publish | answers kept | stale: `conflict` |
| Time change / swap | part time or person changed; publish | new pending revision there only; old acceptance in history; old reminders cancelled | late answer to old revision: `conflict` |
| Removed part | part left out; publish | its duty cancelled (or link ended and flagged) | none |
| Department part changed | label or time, or meeting time/venue | department flagged (`label`, `time`, `place`); duty unchanged | none |
| Meeting moved | leader moves | parts follow, `meeting_changed` on staff and member reads; publish moves the duties | Admin alone: `conflict programme_published` |
| Meeting cancelled | published programme | refused until the programme is cancelled | `conflict programme_published` |

</frozen-after-approval>

## Code Map

- `supabase/migrations/20261021094249_cells_programme_publish.sql` -- publish, cancel, save, the guard and the follow trigger replaced here.
- `supabase/migrations/20261015190139_duties_owner_decisions.sql` -- `duties_owner_flag_review`.

## Tasks & Acceptance

**Execution:**
- [x] `supabase/migrations/20261021110000_cells_programme_revisions.sql`
- [x] `supabase/tests/cells_programme_revisions_test.sql` (and the 5.4 suite's changed expectations)
- [x] Clients: unpublished changes and meeting moved banner with **Publish changes**, **Change the programme**, `published_kind` text, members told of a moved meeting.
- [x] E2E `tools/identity-e2e/cells-programme-revisions.mjs` + offline test.
- [x] Runbook section.

**Acceptance Criteria:**
- Given staff web and the API, when a published programme's time changes, an assignee is swapped, only the study notes change, the meeting moves and another is cancelled, then new pending revisions appear only where material, old acceptances are kept in history, no stale reminders remain, the department duty is unchanged with a mismatch for its leader, and a late response to an old revision is refused.

## Implementation Notes

- `20261021110000_cells_programme_revisions.sql`: published snapshot columns (`published_starts_at`, `published_ends_at`, `published_venue` on programmes; `published_kind`, `published_label`, `published_starts_at`, `published_ends_at`, `published_slot_id` on parts), backfilled for programmes already published; `cells_programme_part_check` answers for removed parts too; the follow trigger moves published programmes' parts; the guard lets the cell's leader or assistant move; `cells_programme_json` adds `unpublished_changes` and `meeting_changed`; save allows published programmes and refuses a kind switch; `cells_publish_part` (new five-argument function) ends removed parts, flags changed department links and records the published snapshot; publish walks live parts then parts removed since the last publish and records the meeting snapshot; cancel also ends removed-but-published parts and flags department links; the member read adds `meeting_changed`.
- pgTAP `cells_programme_revisions_test.sql` (28); the 5.4 suite's expectations follow 5.6 (published programmes are saved; the leader moves). Full db:test passes on a fresh reset.
- Clients: `CellProgramme.unpublishedChanges/meetingChanged`, `ProgrammeProjection.meetingChanged`; Plan meeting: the warning banner with **Publish changes**, **Change the programme** (the same editor; its publish reads **Publish changes**; cancelling stays on the published view), the `published_kind` refusal text; My cell: "The meeting moved. Your leader is updating the programme". Tests in `cell_programmes_test.dart` and `cell_youre_on_test.dart`.
- E2E `tools/identity-e2e/cells-programme-revisions.mjs` (6 checks) + offline test; numbers `+44 7700 900040-900049`. Regression runs of 5.5, 5.4 (its preview comparison now ignores `meeting_changed`), 5.1 and the owner-ops E2E in `evidence-5.6/`.

## Plan Change Log

## Review Triage Log

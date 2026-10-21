---
title: 'Apply cell transfer, removal and deletion to programmes and cell duties'
type: 'feature'
ticket: '9'
created: '2026-10-21'
status: 'in-progress'
baseline_revision: '7ac0f18'
route: 'full'
route_source: 'auto'
review: ''
review_source: ''
lenses_ran: []
review_loop_iteration: 0
context:
  - '{project-root}/docs/runbooks/cells-meetings.md'
  - '{project-root}/docs/runbooks/contracts-and-owner-seams.md'
  - '{project-root}/docs/runbooks/identity-access.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** A member who moves to another cell keeps their old cell's future parts and duties. They can still be confirmed on them (story 5.5 finding), their open Cannot attend notices stay open, the old cell's leaders are not told a part needs someone, and a cell's last leader can be deactivated while programmes are published ahead.

**Approach:** Inside the Cells transfer command (`cells.confirm_request` ending an old membership), in the same transaction:
- clear the member from the old cell's future programme parts (draft and published), so each becomes a gap; the published projection stops naming them;
- end their old-cell cell-part assignments through a Duties operation (vacated, position unfilled, the member told their duty was released);
- close their open notices in the old cell;
- tell the old cell's leader and assistant that a published part needs someone.

Old-cell reads are already refused at once (current membership). Register a Cells handover hook: the last reachable leader or assistant of an active cell with a published programme ahead is last responsible. Admins resolve a recorded obligation once the cell has a leader again. The clients keep private programme and venue state in memory only and drop it on a refused read.

**Decisions:**
- Decision (agent, under owner pre-approval): the only membership end in the product is a transfer (2.6; `end_reason` `transferred`). Removal without a new cell does not exist yet, so "membership-end commands" means the transfer. Deletion is the existing Cells hook (extended through 5.8).
- Decision (agent, under owner pre-approval): Duties contract change. `app.duties_owner_vacate_member {cell_id, member_id}` ends the member's current assignments on the cell's future published cell parts and clears their planned positions. It behaves as the 4.12 vacate (superseded, `vacated`, jobs cancelled, coverage closed, `duty_released` to the member, no vacancy reason). It is called by Cells inside its transfer, whose actor (the new cell's leader or an Admin) does not lead the old cell. The 4.11 session rule cannot apply here, so this is a recorded contract change.
- Decision (agent, under owner pre-approval): the leaders' notice is Cells-owned (`cells_programme` / `cells_part_vacated`, generic, link `/cells/meetings`), one per affected published programme. Draft-only changes notify nobody. Actual-leader records (5.8) are past facts and stay.
- Decision (agent, under owner pre-approval): the handover obligation is `cell_leader` (subject = cell), always last responsible. It is resolved by `cells.resolve_handover {cell_id}` (Admin, cell revision) once the cell has a reachable leader or assistant again.

## Boundaries & Constraints

**Always:** one transaction (a failing step rolls the transfer back); AD-2 lock order (Identity, Cells member rows, Cells meetings then programmes, Duties, Notifications last); ASCII migration, no destructive statements; nothing private persisted on a client.

**Never:** a Cells write of `app.duties_*`; a notice or a part kept open for a member who left; another reason disclosed in a notification.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Transfer with an accepted part and an open notice | confirm_request to the new cell | old reads denied; part a gap; assignment ended vacated; notice withdrawn (left_cell); leaders told; new cell readable | any failure rolls back |
| Transfer with only a draft part | same | part cleared; nobody told | none |
| Past meetings | started meeting parts and actual leaders | unchanged | none |
| Deactivate the last leader with a programme ahead | identity deactivation | `conflict handover_required` | revoke scope likewise |
| Resolve | Admin, a reachable leader again | obligations resolved | no leader: `conflict leader_required`; none pending: `validation_failed no_handover` |
| Deletion | erase / check | remaining 0 | none |

</frozen-after-approval>

## Code Map

- `supabase/migrations/20261021094249_cells_programme_publish.sql`: `app.cells_confirm_request` (latest).
- `supabase/migrations/20261015190139_duties_owner_decisions.sql`: `app.duties_vacate_member` (latest), copied as the cell variant.
- `supabase/migrations/20261007075946_cell_membership.sql`: `app.cells_cell_json`.

## Tasks & Acceptance

**Execution:**
- [x] `supabase/migrations/20261021140000_cells_transfer_effects.sql`
- [x] `supabase/tests/cells_transfer_effects_test.sql`
- [x] Clients: Admin cells "Needs a leader" with Mark handover done; scope-loss tests on My cell, Home and Plan meeting.
- [x] E2E `tools/identity-e2e/cells-transfer.mjs` + offline test.
- [x] Runbook section; contracts-and-owner-seams (Duties contract change); duties.md note.

**Acceptance Criteria:**
- Given a synthetic member with an accepted part and an open notice moved from `SYNTHETIC Shikoswe Cell` to `SYNTHETIC Estates C5/C7 Cell`, then old-cell programme and venue reads are denied at once, the part is vacant with a leader notice, the notice is closed, new-cell access is open, nothing private is persisted on either client, and a deletion check answers zero.

## Implementation Notes

- Migration: `withdrawn_reason` on notices; Duties `app.duties_vacate_cell_member` (the 4.16 vacate scoped to a cell's own parts) behind `app.duties_owner_vacate_member`; Cells source `cells_programme` / `cells_part_vacated`; `app.cells_transfer_effects` called by the re-created `cells.confirm_request`; handover hook `app.cells_report_handover`, `app.cells_handover_pending`, `cells.resolve_handover`; `handover_pending` on `app.cells_cell_json`.
- pgTAP `cells_transfer_effects_test.sql` (54 after the review).
- Clients: `AdminCell.handoverPending`, `CellAdminController.resolveHandover`, the Admin cells "Needs a leader" label and Mark handover done; scope-loss widget tests (My cell, Plan meeting) and `cell_transfer_test.dart` (3).
- E2E `tools/identity-e2e/cells-transfer.mjs` (7) + offline test; numbers `+44 7700 900070-900079`. Regressions: cells 13/13, cells-meeting-reminders 9/9, cells-youre-on 7/7, cells-absence 5/5, cells-meeting-records 6/6, duties-lifecycle 16/16, duties-owner-ops 13/13, lifecycle 9/9.

## Plan Change Log

## Review Triage Log

Independent review of `7ac0f18..0be7e83` (2026-10-21, a separate reviewer agent; the Duties copy diffed against the 4.16 vacate: only the intended removals; no deadlock cycle with publish, save, cancel, record_actual_leaders or the Duties lifecycle hooks; grants and ASCII clean). Not yet on staging, so fixed in place:

1. Medium-high, fixed: the effects worked from the parts' current (possibly unpublished) assignee. A programme published with the member then changed to someone else kept the member's published name, and one published with someone else then changed to the member lost that person's name. The Duties operation now answers the occurrences it ended. Cells un-names exactly those parts in the projection, and clears the member from planned parts separately. pgTAP: both directions.
2. Medium, fixed: Cells and Duties cut off "future" differently (meeting start vs part start), so a meeting under way lost the member's later part duty but kept the plan. Cells now names the part occurrences of its meetings still ahead, and Duties vacates only those (`occurrence_ids`, a contract detail). pgTAP: a meeting under way keeps duties, plan and notice.
3. Medium, fixed: notices for any meeting were closed, and without audit rows. Now only meetings still ahead are affected, each with a `notice_withdrawn` audit row naming the transfer's actor. pgTAP added.
4. Low-medium, fixed: notices are now written before Duties, which writes Notifications. Every Cells row written after Duties (parts, projections, programmes) is locked before it.
5. Low, fixed: the transfer key-shares the moved member's Identity row first (AD-2), as publish and cancel lock people.
6. Low, accepted: a patched projection keeps its revision. Clients read the projection whole on every read and keep nothing by revision. The programme's revision moves.
7. Low, accepted: after a transfer a published programme shows unpublished changes (the gap). That is intended: the leader plans the part again and republishes.
8. Low, accepted:
   - `cells.resolve_handover` locks obligations after the cell row. Identity's resolve takes only the obligation row, and no Identity command locks a cell row, so no cycle exists.
   - An archived cell's pending obligation is cleared once it has a leader again. Cells cannot be archived yet.
   - No test runs a real deletion through to a resolve: Identity's deletion tests cover recording, and the Cells resolve is tested against a recorded row.
9. Tests:
   - Added: a transfer confirmed by the new cell's leader (Duties records them as the actor, capacity `lifecycle`), the unpublished-change, under-way and notice cases above.
   - Not added: a concurrent publish and transfer, and moving back (reviewer found no defect). The notifications-policy-unavailable path is unchanged code. A Home scope-loss test: Home reads the same in-memory provider as My cell, which is tested.
   - The 5.9 client code went into the 5.8 review-fix commit `d1faec7` and is reviewed with this triage: `handoverPending` read with a default, an Admin-only button, notices for done and still no leader. Widget tests are in `cell_transfer_test.dart`.

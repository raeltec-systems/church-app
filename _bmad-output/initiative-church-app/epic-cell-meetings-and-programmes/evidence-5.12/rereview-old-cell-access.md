# Re-review: old-cell access fix (20261021132636_cells_external_check_fixes.sql)

## 1. Diff check
- `app.cells_confirm_request`: the only change from 20261021122802 is the guard at lines 72-80. It looks for an active `cell_leader`/`cell_assistant` grant on the old cell and returns `conflict leads_current_cell`. It runs after the old membership row is locked and before any write.
- `app.cells_record_actual_leaders`: the only change from 20261021115855 is lines 115-118. The membership check moved from `ended_at is null` to membership at the meeting's `starts_at`.
- The local DB bodies match the file. Grants are kept. `confirm_request` is the only code that ends a membership.

## 2. Probe (rolled back, scratchpad, 5.9 fixture header): 68 tests, 67 pass (d12, see Findings)
- **(a) PASS.** Assistant 3 and leader 2 could not be moved by the Admin, by the Estates leader, or by an Admin `cell_id` override. All attempts returned `leads_current_cell`. A full before/after snapshot was identical: memberships, audit, requests, revisions, programmes, duties, jobs, notices and grants. The request stayed pending.
- **(b) PASS.** After `identity.revoke_scope` the move succeeded. Then:
  - `cells_programme` (future and past meetings): PT403.
  - `cells_meetings`: PT403.
  - `cells_meeting_programme`: PT403.
  - `cells_my_cell`: shows Estates, no old venue.
  - Receipt replay of `save_programme`, a fresh edit, and `record_actual_leaders`: forbidden.
- **(c) PASS.** Member 5 leads Estates. Moving them from Shikoswe to a third cell worked, and both Shikoswe reads were then refused. `cells_meetings` lists Estates only. Moving 5 into Estates worked; moving them back out was refused.
- **(d) PASS.**
  - Pastor: the move is allowed and the member view is lost. The Pastor keeps full `cells_programme` oversight, which is by design.
  - Admin: metadata only, no venue.
  - An open request back to the old cell gives no programme and no venue.
  - Replaying a Cannot-attend receipt returns the stored snapshot (no venue), which is the intended rule.
  - Duties: `duties_rota` is PT403 and responding to the vacated duty is refused.
- **(e) PASS.**
  - Credited: members in the cell at the start who have since moved, a member who joined exactly at the start, and a guest name.
  - Refused (`not_in_cell`): members who joined after the start, a membership that ended exactly at the start, and someone who was never a member.

## Findings
- **Low / informational.** `api.duties_my_duties` still lists the moved member's own past old-cell duty (meeting mt3), with `location` set to the old venue. The cause is the 90-day window in `app.duties_my_duties` (20261015035112_duties_owner_operations.sql). It is their own history and a snapshot, so no new access. This is the d12 failure. In the fixture the Duties occurrence keeps its original date, so it first showed as pending.
- **Note (untested).** The transfer cut-off uses the Cells meeting's `starts_at`, while Duties keeps its own time. If the two drift, a duty with the venue stays until the occurrence ends. This matches the by-design rule that a meeting under way keeps its duties.
- **Informational.** Local `schema_migrations` still records 20261021150000, the name before the rename. The content is identical.

## 3. Repo suites
`cells_transfer_effects_test.sql` + `cells_meeting_records_test.sql`: PASS, 111 tests (58 + 53), 0 failures.

## Verdict
Old-cell access: **PASS**. No path was found that keeps private access to, or editing of, a cell the member has left.

---
title: 'Expose Duties and Follow-ups owner operations for programmes and later owners'
type: 'feature'
ticket: '11'
created: '2026-10-15'
status: 'built'
baseline_revision: '2f8cf1d2b4624a905f2a7f1920526d3ab86de888'
route: 'full'
route_source: 'auto'
review: ''
review_source: ''
lenses_ran: []
review_loop_iteration: 0
context:
  - '{project-root}/docs/runbooks/contracts-and-owner-seams.md'
  - '{project-root}/docs/runbooks/duties.md'
  - '{project-root}/docs/runbooks/follow-ups.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** Cells (epic 5) and Content (epic 6) must reach Duties without cloning duties or writing its tables, but Duties has no owner operations: nothing creates, revises or cancels a cell-owned occurrence inside the caller's transaction, nothing links a programme part to an existing department duty, nothing flags a linked meeting or event change for the department's review, and the cell-owned exclusions of 4.4-4.10 keep cell parts out of My duties and member responses. The Follow-ups source operations have no consumer guide or shared fixtures for the later owners.

**Approach:** One forward migration adds Duties owner operations (server-only `app.duties_owner_*`, called by a registered source owner inside its own command), a registry of link sources, a stable part/position-to-slot link table, an owner-review flag table with a client command for the department to clear it, and replaced bodies so cell-owned parts behave as Duties assignments for their member. A SYNTHETIC Cells-like fixture caller proves the operations in pgTAP and an E2E; contract fixtures (SQL, Dart, TypeScript) pin the source references of programmes, events, visitors, care, missing reports and counts, and custody.

**Decisions:**
- Decision (agent, under owner pre-approval): **registration.** `app.duties_register_link_source(module, source_type, role)` with role `cell_part` (Cells, or a SYNTHETIC `fixture_` source) or `event` (Content, or a SYNTHETIC `fixture_` source). The module must own the source type (1.5 registry) and have a dependency edge to `duties`. Every operation rechecks the caller's part or event through `app.contract_check_source` at the given revision (`conflict {"source_revision": "stale"}` otherwise). No contract version change: the part and the event are v1 `source_ref` values; the position key is a separate field.
- Decision (agent, under owner pre-approval): **operations** (input one jsonb object, answer ids, revisions, states and counts; refusals are the kernel's codes through `app.cmd_fail`, so they surface in the caller's envelope; none is client-executable):
  - `duties_owner_put_part`: create (expected_revision null) or revise (expected_revision = the occurrence revision) one cell-owned published occurrence for a part, with 1-10 positions `{position_key, position_name?, member_id|null}`. Revision goes through the 4.2 engine (`duties_apply_change`): material fields and assignee changes supersede, notes-only changes keep answers, a new key adds a position, a missing key cancels its position (4.9 rules), a renamed position or a re-used cancelled key is refused, an identical put is a no-op. Overlaps need `override_reason` (4.4 gate). Deadlines follow 4.8 (the caller's `response_deadline` or the default; Short notice).
  - `duties_owner_cancel_part`: cancels the occurrence through the 4.3 `duties_cancel_one` (notices, jobs) and ends the part's display links.
  - `duties_owner_link_duty` / `duties_owner_unlink`: a display link from a part position to a published, not started department-owned position. Nothing of the duty changes (no lock beyond FOR SHARE, no revision); the department keeps sole authority. Anything not linkable is `not_found`.
  - `duties_owner_flag_review`: a changed meeting (cell_part source: its display-linked duties) or event (event source: department duties whose `event_ref` is the event) flags an owner-review mismatch with the changed field codes (`time`, `place`, `label`, `assignee`, `cancelled`). No duty, answer, revision or reminder changes; repeated flags merge into the open one.
  - Reads: `duties_owner_part` (the part's positions with responses, Short notice and needs-contact flags; display links show the department duty's name, times, state and `filled` only, never people), `duties_owner_conflicts` (the 4.4 conflict query with its disclosure rules for the viewer), `duties_owner_event_links` (ids, revisions, states, open review only) and `duties_owner_topic` (the sermon-draft topic/scripture read for the occurrence's current assignee or its managers).
- Decision (agent, under owner pre-approval): **links.** One active link per `(source_type, source_id, position_key)` (partial unique index; a concurrent second link gets `conflict {"position_key": "linked"}`); an owned link is permanent and its slot is linked once (unique), so the part/position-to-slot link is stable. Position keys match `^[a-z0-9][a-z0-9_-]{0,63}$` (a token or a lowercase uuid).
- Decision (agent, under owner pre-approval): **authority.** The actor must hold `cell_leader` or `cell_assistant` for the part's cell now (Identity grants, FOR SHARE); the Admin role alone, Pastor or a department scope is `forbidden`. A cell-owned occurrence is never managed through `api.duties_command` (unchanged: `not_found`); a department duty is never changed through an owner operation (`not_found`), and a cell leader's department commands stay `forbidden`. Cell membership of an assignee is the caller's check (Cells owns its roster); Duties requires an active member.
- Decision (agent, under owner pre-approval): **clearing.** `duties.clear_review {flag_id}` through `api.duties_command` (expected = the flag's revision, aggregate = the occurrence, so a replay rechecks management) by the department's leader, deputy or Admin; Pastor and others `not_found`. The board and rota show open flags (codes only) and the number of linked programme parts; staff web shows a Needs review chip with Mark reviewed.
- Decision (agent, under owner pre-approval): **cell parts for the member.** My duties lists cell parts (owner `cell`, the cell's leaders and assistants by name); respond, Can't make it anymore and bulk accept accept them; notices and member reminders are sent and checked as for department duties (eligibility: the assignee, active). Leader alerts, the coverage queue, leader confirmation, contact attempts and outcomes stay department-only (fail closed): they are the first contract change Cells needs (recorded below), and the owner read exposes the gaps meanwhile.
- Decision (agent, under owner pre-approval): **privacy and gates.** No note, reason, contact data or assignee of another owner crosses: the owner read and links carry no response notes or override reasons, display links no people. Q4 gate on every operation and read; Q2 through the notification calls (production inert). Erasure clears and anonymises the new actor columns (link and flag) and `_remaining` counts them.
- Decision (agent, under owner pre-approval): **synthetic caller.** Module `fixture` gets edges to `duties` and `followups`, a SYNTHETIC part table, part and event source types with check hooks and caller functions that write their own row first, then call Duties and Follow-ups (open a `fill_part` task for an unfilled position, resolve it when filled). Registrations for it happen only in tests and the E2E.
- Decision (agent, under owner pre-approval): **fixtures.** New `source_ref` and `task_source` cases for programme parts, events, sermon drafts, visitors, care, missing reports and counts, and custody, plus private-field refusals; all three implementations pass them unchanged.

## Boundaries & Constraints

**Always:** forward migration after `20261015002121`; replaced bodies copied from their latest version with every earlier review fix; ASCII, `search_path = ''`, no backslashes, no DROP/TRUNCATE/`delete from`; new functions revoked from public, anon, authenticated and service_role, no new client grant; AD-2 order (the caller's rows, Identity grants, member locks, Duties occurrence, slots, assignments, links, Follow-ups, Notifications last); fixed church-time test dates; SYNTHETIC data, pgTAP +44 7700 900160-900169, E2E 900240-900249.

**Never:** Cells tables, screens or commands (epic 5); cloning or mutating a linked department duty; client-executable owner operations; cell-scope coverage, alerts, confirmation or outcomes; lifecycle hooks (entry 12); editing merged migrations or frozen blocks; SMS.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Create | caller part rev 1, two positions, one assignee | cell-owned occurrence, two slots, owned links, one pending assignment, notice queued | stale part `conflict`; no cell scope `forbidden` |
| Revise | new time, other assignee, added and removed position | supersede, new pending revisions, added slot, removed slot cancelled; one transaction | stale expected `conflict`; renamed or cancelled key refused |
| Cancel | cancel the part | occurrence cancelled, assignments cancelled with notices | started / already cancelled refused |
| Link | part position -> department slot | display link; department duty unchanged | second link same key `conflict linked`; draft/cancelled/started/cell `not_found` |
| Mismatch | meeting or event change | open flag on the department duty, nothing else changes | flag merge; clear by department leader only |
| Authority | cell leader edits department duty (command or operation) | refused | `forbidden` / `not_found` |
| Member | assignee answers a cell part | accepted or declined, reminders as 4.8 | stale / ended as 4.2 |
| Erasure | linker or clearer erased | actor columns anonymised, remaining 0 | none |

</frozen-after-approval>

## Code Map

- `supabase/migrations/20261015002121_duties_outcomes.sql` (4.10) -- latest `duties_state_ok`, `duties_authorize_command`, `duties_command`, `duties_my_assignment_json`, `duties_deletion_remaining`, `duties_erase_member` (S1 erase lock order).
- `supabase/migrations/20261014212507_duties_coverage.sql` (4.9) -- latest `duties_respond`, `duties_accept_many` (4.5 lock order), `duties_apply_change`, `duties_plan_reminders`, `duties_occurrence_json` (3-arg, B1 reason gating), `duties_rota_occurrence_json` (2-arg), `duties_cancel_position` (slot-cancel pattern), `duties_close_cases`.
- `supabase/migrations/20261014171038_duties_reminders.sql` (4.8) -- `duties_withdraw_acceptance`, `duties_alert_recipients`, `duties_record_contact_need`.
- `supabase/migrations/20261014052239_duties_overlaps.sql` (4.4) -- `duties_my_duties`, `duties_conflicts_json`, `duties_gate_created`, `duties_lock_members`, cell_id column.
- `supabase/migrations/20261014001142_duties_revisions.sql` (4.2) -- `duties_update_reminder_check`; `20261013220239` (4.1) -- `duties_assignment_reminder_check`.
- `supabase/migrations/20261014110258_followups_registry.sql`, `20261014130535_followups_reminders.sql` -- Follow-ups owner operations (not changed).
- `packages/contracts/fixtures/v1/{source_ref,task_source}.json`, `packages/contracts/dart/tool/embed_fixtures.dart`, `supabase/tests/contract_fixtures_check.sh`.
- `packages/client_core/lib/src/domain/duties.dart` (`MyDuty`, `DutyOwnerKind`, `DutyLeaderName`, occurrence parsing), `presentation/duties_screens.dart`, `duties_rota_screens.dart`, `application/duties_controllers.dart`.
- Tests: `supabase/tests/duties_*_test.sql` (cell-owned expectations of 4.4/4.5), `command_foundation_test.sql` (privilege ledger), `tools/identity-e2e/duties-outcomes.mjs` (E2E pattern).

## Tasks & Acceptance

**Execution:**
- [x] `supabase/migrations/20261015120000_duties_owner_operations.sql` -- registry, link and flag tables, owner operations, clear command, replaced bodies, synthetic caller, privileges.
- [x] `supabase/tests/duties_owner_operations_test.sql`, `duties_owner_operations_scale_test.sql`; earlier tests updated for cell parts and the ledger.
- [x] `packages/contracts/fixtures/v1/source_ref.json`, `task_source.json`, regenerated Dart fixtures.
- [x] `packages/client_core` cell parts in My duties, review flag and linked count on board/rota with Mark reviewed; tests.
- [x] `tools/identity-e2e/duties-owner-ops.mjs` + `.test.mjs`.
- [x] `docs/runbooks/contracts-and-owner-seams.md`, `duties.md`, `follow-ups.md`; `evidence-4.11/`; CI evidence step.

**Acceptance Criteria:**
- Given the synthetic caller, when it creates, revises and cancels a cell-owned position in one transaction, links a department duty, flags and clears a mismatch, then the department duty is unchanged and managed only by its department, a cell leader cannot edit it, a second link for the same part/position is refused, and the fixtures pass in SQL, Dart and TypeScript.

## Implementation Notes

- Implemented directly (no implementation subagent inside this builder run), as 4.1-4.10. CHECKPOINT 1 pre-approved by the owner (owner-decisions-milestone-1.md, -2.md); the frozen block's decisions are the agent's under that pre-approval.
- Server: `supabase/migrations/20261015120000_duties_owner_operations.sql` (ASCII, no backslashes, no DROP/TRUNCATE/`delete from`, `search_path = ''` everywhere; every new function revoked from public, anon, authenticated and service_role; **no new client grant**: `duties.clear_review` goes through the existing `api.duties_command`).
  - New tables: `app.duties_link_sources` (registry), `app.duties_part_links` (stable part/position-to-slot links; partial unique index on the active key; owned slot unique; guard trigger `app.duties_part_link_guard`: only a display link ends, the caller's revision moves forward and erasure anonymises; a direct DELETE is refused, the FK cascade from slot/occurrence is allowed for local clean-ups), `app.duties_review_flags` (one open flag per occurrence and source; codes only), SYNTHETIC `app.fixture_programme_parts` and `app.fixture_events`; index `duties_occurrences_event_ref`.
  - New functions: registration `duties_register_link_source`; helpers `duties_review_fields_ok`, `duties_owner_ref_errors`, `duties_position_key_error`, `duties_owner_session`, `duties_owner_source`, `duties_owner_positions`, `duties_owner_cancel_slot`, `duties_owner_positions_json`, `duties_owner_part_answer`, `duties_review_json`, `duties_linked_parts`; operations `duties_owner_put_part`, `duties_owner_cancel_part`, `duties_owner_link_duty`, `duties_owner_unlink`, `duties_owner_flag_review`; reads `duties_owner_part`, `duties_owner_conflicts`, `duties_owner_event_links`, `duties_owner_topic`; command `duties_clear_review`; SYNTHETIC caller `fixture_programme_part_check`, `fixture_event_check`, `fixture_programme_begin`, `fixture_programme_publish`, `fixture_programme_cancel`, `fixture_programme_link`, `fixture_programme_unlink`, `fixture_programme_changed`, `fixture_programme_open_followup`, `fixture_event_changed`; edges `fixture -> duties`, `fixture -> followups`.
  - Replaced bodies (each copied from its latest version, changes marked "Story 4.11", every earlier review fix kept):
    - from `20261015002121` (4.10): `duties_state_ok` (capacities `cell_leader`/`cell_assistant`; `link_kind`, `link_role`, `review_field`; seven audit actions), `duties_authorize_command` and `duties_command` (`duties.clear_review`), `duties_my_assignment_json` (owner `cell`, `cell_id`, left join on departments, the cell's leaders/assistants), `duties_deletion_remaining` and `duties_erase_member` (4.10 S1 lock order kept; link and flag actors anonymised and counted).
    - from `20261014212507` (4.9): `duties_respond` (cell refusal removed), `duties_accept_many` (cell refusal removed; the 4.5 lock order unchanged), `duties_apply_change` (cell branch: an active member is asked, a null member leaves a gap and needs no deadline; department path unchanged), `duties_plan_reminders` (member reminders for cell parts; leader alerts stay department-only; 4.8 memoised policy, reachable leaders, fresh keys and passed-deadline alerts, and the 4.9 decline-alert rule kept), `duties_occurrence_json` 3-argument (B1 reason gating kept; `reviews`, `linked_parts` added), `duties_rota_occurrence_json` 2-argument (`reviews`, `linked_parts`).
    - from `20261014171038` (4.8): `duties_withdraw_acceptance` (cell refusal removed).
    - from `20261014052239` (4.4): `duties_my_duties` (cell parts listed).
    - from `20261014001142` (4.2): `duties_update_reminder_check`; from `20261013220239` (4.1): `duties_assignment_reminder_check` (a cell part's recipient is eligible while the assignee is an active member).
  - Not replaced: `duties_cancel_one` (4.9) and the 4.4 overlap gate are called as they are; Follow-ups and Notifications functions are unchanged; 4.9 coverage/confirmation/contact and 4.10 outcomes stay department-only.
- Decision (agent, under owner pre-approval): **the actor is the live session.** Owner operations read the acting member and account from `app.identity_evaluate_grant` (the caller's request), never from the payload (stricter than `followups_open_task`, which takes actor ids). A system-principal caller is a later contract change. Duties takes no new Identity lock in an operation: the caller's authorizer holds the actor's grant rows FOR SHARE first (AD-2), as the SYNTHETIC caller does; Duties rechecks the scope on current rows. This replaces the frozen block's "(Identity grants, FOR SHARE)" wording for the operations.
- Decision (agent, under owner pre-approval; **pending owner acknowledgement**): `duties.clear_review` refuses anyone who does not manage the department with `forbidden` (as every other department command through `duties_lock_occurrence`), not `not_found` as the frozen block says; an unknown flag is `not_found`. Recorded in the Plan Change Log.
- Decision (agent, under owner pre-approval): a revise releases the member of each position whose member changes before the occurrence's own fields change, then asks the new members, so nobody being replaced is re-asked in between (no phantom assignment, the right notice kinds: `duty_released` to the old member, `duty_assigned` to the new one).
- Decision (agent, under owner pre-approval): an identical put answers `changed: false` without writing (Cells can republish without duplicates); a put that changes nothing but carries `response_deadline` is refused `not_material` (4.2 rule).
- Decision (agent, under owner pre-approval): no contract version change and no new wire kind. Parts and events are v1 `source_ref` values; the fixtures gain later owners' source references and task identities plus private-field refusals; `supabase/tests/contract_fixtures_check.sh` also runs the `source_ref` fixtures through the operations' own reference validator (`app.duties_owner_ref_errors`).
- Decision (agent, under owner pre-approval): registrations of the SYNTHETIC caller happen only in tests and the E2E (not in the migration), so staging and production have no link source until Cells or Content registers one.
- Decision (agent, under owner pre-approval): flags send no notification (the board and rota show them); they are codes only; flags on a cancelled or started duty are not raised.
- Clients (`packages/client_core`): `MyDuty` (`departmentId`/`departmentName` nullable, `cellId`, `ownerLabel`), `DutyOwnerKind.cell` (answerable), `DutyLeaderName.isAssistant`/`roleLabel`, new `DutyReview`, `LeaderDuty`/`RotaOccurrence` `reviews` and `linkedParts`, `DutyCommands.clearReview`, controller `clearReview` on the board and rota, notices `reviewCleared`/`reviewAlreadyCleared`, widget `_OwnerReviews` on the board row and the rota date panel, calendar text for a cell part. `testing.dart` `myDutyData(ownerKind: 'cell')` sends the cell shape. Tests: new `test/duties/duties_owner_ops_test.dart` (8); `duties_responses_test.dart` (a cell part is now answerable).
- Earlier tests changed for the new behaviour (no merged migration edited): `duties_tracer_test.sql`, `duties_revisions_test.sql` (My duties key subsets drop `cell_id`), `duties_overlaps_test.sql` (the cell part is listed in My duties), `duties_responses_test.sql` (cell parts are answered since 4.11).
- Matrix audit: Create (pgTAP "Create a cell-owned part" and "Who may create"; E2E X10), Revise (pgTAP "Revise" incl. stale, renamed, cancelled key, identical put, not_material; E2E X12), Cancel (pgTAP cancel and one-transaction blocks; E2E X40, X41), Link (pgTAP link block incl. second link, owned key, cell-owned/unknown targets; E2E X20, X21 incl. a two-transaction race), Mismatch (pgTAP flag/merge/clear incl. stale, replay, cleared twice, Pastor/cell leader refused; E2E X30, X31; widget tests), Authority (pgTAP "A cell leader cannot edit"; E2E X22, X90), Member (pgTAP member block; E2E X11, X12; widget test), Erasure (pgTAP erasure block). All ran and passed (see Verification).
- Fictional numbers: pgTAP +44 7700 900160-900169, E2E +44 7700 900240-900249 (grepped: unused before).
- Open owner questions: Q4 unchanged (fail closed). New, with the fail-closed default built: may a cell programme name the assignee of a linked department duty? Built: no. New (review N5), default built: should the owning department's leader be notified of an owner-review mismatch? Built: no notification; board and rota only. Pending owner acknowledgement: the `clear_review` refusal code (above).
- Contract changes expected from epic 5 (recorded here per the ticket's unknown): cell-scope leader alerts, coverage queue, Confirmed by leader, contact attempts and outcomes for cell parts; a discovery read of linkable department duties; the creator's reminders for a part; a system-principal caller; naming a linked duty's assignee (owner question above).
- Review amendments (independent review, 2026-10-15; no blockers; the migration was unmerged and unapplied, so `20261015120000_duties_owner_operations.sql` was amended in place; the frozen block is unchanged):
  - Decision S1 (part cell binding): new `app.duties_owner_part_cell_ok`; `duties_owner_put_part` and `duties_owner_link_duty` answer `not_found` when any link of the same `(source_type, source_id)` names another cell, so a leader of C2 can no longer take over or link C1's part by naming C2. The check-hook alternative (the hook returning the part's cell) was not taken: the v1 source check answers only `{current, revision}`, and changing that shape is a contract change; the first link binds the cell instead. Tests: pgTAP S1 block (put and link refused, links and occurrence unchanged). Runbook: `cell_id` must be the part's own cell.
  - Decision S2 (older clients): `MyDuties.fromJson` reads each row on its own; a row the client cannot read is left out, logged (`dart:developer`, `church.duties`) and counted (`skipped`), and My duties says that some duties need a newer app. Release gate recorded here and in `contracts-and-owner-seams.md` (consumer guide step 7) and `duties.md`: **no `cell_part` registration in a migration (epic 5) and no staging cell-part data until every client runs the 4.11 build or later**, with the client-compatibility note. Tests: wire mapping (one bad row skipped) and widget (`my-duties-skipped`).
  - Decision S3 (member copy): `DutyAction.ownerKind`; the Accepted / Answer sent / Can't make it anymore / bulk notices for a cell part say "Your answer is saved. Your cell leader sees it in the programme"; department duties keep "Your leader now sees ...". Widget tests for both.
  - Decision S4 (test): pgTAP accepts then withdraws a cell part: `duty_starting` goes from pending to cancelled, no `duties_coverage` job, the owner read shows Declined and never the note.
  - N1: a create that asks nobody refuses `response_deadline` (`not_material`). N2: an identical put records the caller's part revision on the links. N3: the conflicts read covers at most 120 days (`{"ends_at": "out_of_range"}`); runbook: the caller restricts `member_id` to its roster. N4: runbook: Content authorises its editors before calling the event reads and flags. N5: flags stay board-only (owner question above); `duties_review_json` shows only reviews of published duties that have not started. N6: **Mark reviewed** carries the accessible label "Mark reviewed: <duty>". N7: the link guard lets a delete pass only when the parent slot or occurrence is gone (the foreign-key cascade), tested both ways. N8: documented: a part holds at most 50 positions over its life (cancelled included); a programme that needs more starts a new part. N9: left as is, as the review asked. N10: scale thresholds tightened to 2 s each (create and revise timed apart).
- Remaining (not builder steps): staging apply of the migration with per-function md5 parity (parent; no owner SQL paste; no Edge Function redeploy); rebuild the staging staff web and APK; owner manual checks in `docs/runbooks/duties.md`, story 4.11.

## Plan Change Log

- 2026-10-15 (review): amendments S1-S4 and N1-N10 applied to the unmerged migration, clients, tests and runbooks; recorded under Implementation Notes, "Review amendments". The `clear_review` refusal code stays `forbidden`, pending owner acknowledgement. The frozen block is unchanged.

- 2026-10-15 (build): two details of the frozen decisions were built differently, fail closed, recorded under Implementation Notes: owner operations take no new Identity lock (the caller's authorizer holds the grant rows first; Duties rechecks the scope on current rows), and `duties.clear_review` answers `forbidden` (not `not_found`) to anyone who does not manage the department, as every department command does. The frozen block is unchanged.

## Review Triage Log

- Independent review 2026-10-15 (probes in the coordinator's scratchpad `rev/`): no blockers.
- S1 (should, a part's cell never checked): fixed (`duties_owner_part_cell_ok` in put and link; pgTAP; runbook).
- S2 (should, older clients and cell parts): fixed (tolerant `MyDuties`; client tests; release gate in plan and guide).
- S3 (should, member copy promised leader awareness): fixed (owner-aware notices; widget tests).
- S4 (should, no positive withdraw test): added (pgTAP).
- N1, N2, N3, N5, N6, N7, N10: fixed; N4, N8: documented; N5 owner question recorded; N9: left as is.

## Verification

**Commands:**
- `npx supabase db reset && npm run -s db:test && npm run -s db:smoke` -- expected: pass.
- e2e-main.sh (worktree copy) with `duties-owner-ops` appended -- expected: each `exit=0`.
- `npm run -s contracts:test`, `dart test` in `packages/contracts/dart`, node tool tests, `npm run -s ci:policy-test` -- expected: pass.
- `flutter analyze && flutter test` in `packages/client_core`, `apps/staff`, `apps/mobile`; `TZ=America/New_York` for `test/duties` and mobile -- expected: pass.
- `npm run -s ci:secrets && npm run -s ci:migrations -- --base origin/main && npm run -s ci:function-imports`; evidence scan -- expected: clean.

**Results (2026-10-15, rerun after the review amendments; merged with `ccr-93e730dd-89lbvg` incl. 187f0d1):**
- db reset 0; db:test PASS (41 files, 3554 tests, 64 s; `duties_owner_operations_test.sql` 167, `duties_owner_operations_scale_test.sql` 13, each threshold 2 s: flag 400 = 470 ms, event links 10 ms, board with 400 reviews 356 ms, create 10-position part 488 ms, revise 534 ms, owner read 11 ms, My duties with 200 parts 190 ms); db:smoke pass (fixtures 260 SQL cases + 25 envelopes + 29 `source_ref` cases through the owner operations).
- Every E2E `exit=0` (28 scripts, reset before each, one at a time; `duties-owner-ops` 13/13 including a two-transaction link race; `duties-responses` 12/12 with V40 for answerable cell parts) (`evidence-4.11/e2e-suite-summary.txt`).
- contracts:test 265/0; Dart contracts 282 pass; node tool tests (CI set) 219/0; ci:policy-test 56/0.
- flutter analyze clean in client_core, apps/staff, apps/mobile; flutter test client_core 621 (`duties_owner_ops_test.dart` 10), apps/staff 40, apps/mobile 55; under `TZ=America/New_York` client_core `test/duties` + `test/followups` 193 and apps/mobile 55.
- ci:secrets clean (1575 files); ci:migrations (`--base origin/main`) 47 ordered, unique, non-destructive; ci:function-imports ok; evidence scan clean.

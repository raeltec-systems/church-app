---
title: 'Expose Duties and Follow-ups owner operations for programmes and later owners'
type: 'feature'
ticket: '11'
created: '2026-10-15'
status: 'in-progress'
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
- [ ] `supabase/migrations/20261015120000_duties_owner_operations.sql` -- registry, link and flag tables, owner operations, clear command, replaced bodies, synthetic caller, privileges.
- [ ] `supabase/tests/duties_owner_operations_test.sql`, `duties_owner_operations_scale_test.sql`; earlier tests updated for cell parts and the ledger.
- [ ] `packages/contracts/fixtures/v1/source_ref.json`, `task_source.json`, regenerated Dart fixtures.
- [ ] `packages/client_core` cell parts in My duties, review flag and linked count on board/rota with Mark reviewed; tests.
- [ ] `tools/identity-e2e/duties-owner-ops.mjs` + `.test.mjs`.
- [ ] `docs/runbooks/contracts-and-owner-seams.md`, `duties.md`, `follow-ups.md`; `evidence-4.11/`; CI evidence step.

**Acceptance Criteria:**
- Given the synthetic caller, when it creates, revises and cancels a cell-owned position in one transaction, links a department duty, flags and clears a mismatch, then the department duty is unchanged and managed only by its department, a cell leader cannot edit it, a second link for the same part/position is refused, and the fixtures pass in SQL, Dart and TypeScript.

## Implementation Notes

## Plan Change Log

## Review Triage Log

## Verification

**Commands:**
- `npx supabase db reset && npm run -s db:test && npm run -s db:smoke` -- expected: pass.
- e2e-main.sh (worktree copy) with `duties-owner-ops` appended -- expected: each `exit=0`.
- `npm run -s contracts:test`, `dart test` in `packages/contracts/dart`, node tool tests, `npm run -s ci:policy-test` -- expected: pass.
- `flutter analyze && flutter test` in `packages/client_core`, `apps/staff`, `apps/mobile`; `TZ=America/New_York` for `test/duties` and mobile -- expected: pass.
- `npm run -s ci:secrets && npm run -s ci:migrations -- --base origin/main && npm run -s ci:function-imports`; evidence scan -- expected: clean.

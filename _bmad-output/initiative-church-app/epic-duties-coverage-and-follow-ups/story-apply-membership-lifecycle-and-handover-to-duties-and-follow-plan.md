---
title: 'Apply membership lifecycle and handover to duties and follow-ups'
type: 'feature'
ticket: '12'
created: '2026-10-15'
status: 'in-progress'
baseline_revision: '269acf1493ba632f647c10f74525eb583d411065'
route: 'full'
route_source: 'auto'
review: ''
review_source: ''
lenses_ran: []
review_loop_iteration: 0
context:
  - '{project-root}/docs/runbooks/identity-access.md'
  - '{project-root}/docs/runbooks/duties.md'
  - '{project-root}/docs/runbooks/follow-ups.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** Identity's 2.10/2.11 lifecycle seams (hold, deactivation, deletion, `scope_revoked`, handover and deletion hooks) reach no Duties or Follow-ups behaviour: a deactivated or departed member keeps future assignments and open tasks, nobody is told a position is empty, the last leader of a department can be deactivated, a removed member cannot be taken out of a department, and a held member's duties only reach Needs contact once a reminder fires.

**Approach:** One forward migration registers Duties and Follow-ups lifecycle hooks (`membership_deactivated`, `deletion_requested`, `access_hold_applied`, `scope_revoked`) and handover hooks, adds `duties.remove_member` and `duties.resolve_handover`, a leader vacancy notice and a `vacated` flag on the board and the coverage queue; Follow-ups hands open tasks over under the Q4 owner-scope rule. Everything runs inside Identity's (or the Duties command's) transaction in AD-2 order, Notifications last.

**Decisions:**
- Decision (agent, under owner pre-approval): **deactivation and deletion** (`membership_deactivated`, and `deletion_requested` for a member deactivated earlier): every current assignment of the member on a published occurrence that has not started (department duties and cell parts, any answer) ends (`superseded`, end reason `member_left`), leaving the position unfilled; the member's jobs for it and its leaders' alerts are cancelled and its coverage case closes (`superseded`); the member's planned draft positions are cleared. The member gets no notice (no access). Past and started duties, answers, outcomes and history are kept. Department membership rows are kept (a restoration does not restore assignments).
- Decision (agent, under owner pre-approval): **removal from a department** is `duties.remove_member {department_id, member_id}` (Admin, expected = department revision): the membership row ends (attributed), the member's current assignments of that department's future published duties end (`removed`) with `duty_released` to the member (routed to Needs contact when the app cannot reach them), and their draft plans there are cleared. `validation_failed {"member_id": "not_in_department"}` otherwise.
- Decision (agent, under owner pre-approval): **vacancy flag and leader notice**: each ended position whose member had not declined sends `duties_coverage` / `duty_vacated` ("Position needs cover") now to each reachable current leader and deputy of the department (never the member; held or in-review leaders are skipped and refused at delivery), keyed by the ended assignment's revision (fresh keys); delivered while the position is still unfilled, not cancelled and not started. The board and the coverage queue show `vacated: {since}` on such a position. No reason (hold, deactivation, deletion, removal) is ever disclosed: one generic flag. Cell parts get no leader alert (4.11: cell-scope alerts are a later contract change); the owner read shows the gap.
- Decision (agent, under owner pre-approval): **login hold** (`access_hold_applied`, any hold kind): duties are kept; each current assignment of a published, not-started duty that is not declined gets a Needs contact entry at once (kind `access_hold`, shown as `not_reached` while the member still cannot be reached in the app, so a release clears it). No leader alert (a hold is never disclosed).
- Decision (agent, under owner pre-approval): **`scope_revoked`**: Duties and Follow-ups authority is already checked on current grants at every command and replay; the hook additionally cancels the removed leader's pending leader alerts of departments they no longer lead or deputise, moves task supervision to another current holder of the task's scope (leaders first, reachable first) and hands over tasks whose owner left the task's roster.
- Decision (agent, under owner pre-approval): **handover hooks**: Duties reports `department_leader` (subject = department) when the member leads or deputises an active department and no other approved, reachable member holds its leader or deputy scope (`last_responsible: true`, so a deactivation is refused `handover_required`). Follow-ups reports `followup_task` per active task the member owns, `last_responsible` when no other candidate exists. Candidates (Q4 owner-scope rule): the task's supervisor, other holders of the task's scope, live Pastors, then other roster members; the Follow-ups lifecycle hook reassigns each task to the first candidate and resolves its obligation (`handed_over`); a task finished or reassigned later resolves its obligation through a trigger. `duties.resolve_handover {department_id}` (Admin, department revision) resolves a department's pending obligations once it has a reachable leader or deputy again (`conflict {"department_id": "leader_required"}` otherwise); a deletion's erasure waits for it.
- Decision (agent, under owner pre-approval): **actor and gates**: hook audit rows are attributed to the session's account and its member (the Admin or the deleting member), capacity `lifecycle`, or the nil UUID with no session. Ending work never needs Q2: with the policy unavailable the notices are skipped and audited `reminders_skipped` (`policy_unavailable`). Q4: hooks run regardless (they only reduce processing); erasure follows Identity's `identity_deletion_retention` gate (fixture in local/staging, closed in production).
- Decision (agent, under owner pre-approval): **erasure**: the new attribution columns (`ended_by_member`, `ended_by_account` of department memberships) are anonymised and counted in `_remaining`; the 4.10 S1 lock-first order is kept.

## Boundaries & Constraints

**Always:** forward migration after `20261015035112`; replaced bodies copied from their latest version with every earlier review fix; ASCII, `search_path = ''`, no backslashes, no DROP/TRUNCATE/`delete from`; new functions revoked from public, anon, authenticated and service_role, no new client grant (both commands go through `api.duties_command`); AD-2 lock order (Identity rows, Duties departments, series, occurrences, slots, member advisory locks, membership rows, assignments, coverage cases, Follow-ups, Notifications last); fixed church-time test dates; SYNTHETIC data, pgTAP +44 7700 900460-900469, E2E 900470-900479.

**Never:** Identity, Cells or Notifications behaviour changes; editing merged migrations, hand-pasted functions or frozen blocks; disclosing any hold, deactivation or deletion reason; restoring assignments on restoration; SMS.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Deactivate | member with pending, accepted and declined future duties, a past duty, a draft plan, open tasks | future assignments ended, positions unfilled and flagged, jobs cancelled, leaders alerted (not for the declined one), draft cleared, tasks handed over, past kept; one transaction | a raising hook rolls back the deactivation |
| Last leader | sole leader of an active department | deactivation `conflict handover_required`, nothing changes | second leader granted, then allowed |
| Remove from department | Admin removes M | membership ended, M's future duties there vacated, `duty_released` to M | not a member `validation_failed` |
| Login hold | held member with duties | duties kept, Needs contact at once, cleared on release | none |
| scope_revoked | leader removed | commands and replays `forbidden`/`not_found`, pending alerts cancelled, supervision moved | none |
| Delete | member with duties and tasks | as deactivation; obligations block erasure until resolved; check answers 0 | handover pending |
| Q2 closed | policy unavailable | work ends, notices skipped and audited | none |

</frozen-after-approval>

## Code Map

- `supabase/migrations/20261007151523_membership_lifecycle.sql` (2.10) -- `identity_register_handover_hook`, `identity_collect_handover` (called before grants end), `identity_resolve_handover_obligation`, `identity_deactivate_membership` (grants end with `scope_revoked`, then obligations recorded, then `membership_deactivated`); `20261007174952_member_deletion.sql` (2.11) -- deletion begin dispatches `membership_deactivated` (if approved) and `deletion_requested`; erase steps wait on pending obligations.
- `20261003134340_cross_epic_contracts.sql` -- `contract_register_lifecycle_hook(module, event, handler)` (handler `(jsonb) returns void`), event `{event, member_id, occurred_at, identity_revision}`; dispatch by lock rank (duties 20, followups 30, notifications 40). `20261006234820_identity_grants.sql` -- `identity_end_grant` dispatches `scope_revoked` with no scope details.
- `20261015035112_duties_owner_operations.sql` (4.11) -- latest `duties_state_ok`, `duties_authorize_command`, `duties_command`, `duties_deletion_remaining`, `duties_erase_member` (S1), `duties_occurrence_json` (3-arg).
- `20261014212507_duties_coverage.sql` (4.9) -- `duties_notify` (cancel ops close cases), `duties_close_cases`, `duties_cancel_position` (ending pattern), `duties_coverage` (queue), `duties_decline_alert_check` (alert check pattern).
- `20261014171038_duties_reminders.sql` (4.8) -- `duties_needs_contact`, `duties_alert_recipients`, `duties_leader_reachable`, `duties_contact_needs`.
- `20261013220239_duties_department_tracer.sql` (4.1) -- `duties_department_json`, `duties_add_member` (Admin pattern), `duties_command_actor`.
- `20261014110258_followups_registry.sql`, `20261014130535_followups_reminders.sql` -- `followups_scope_roster`, `followups_holds_scope`, `followups_activity_event`, `followups_cancel_reminders`, `followups_schedule_reminders`, `followups_lock_pastor`.
- Clients: `packages/client_core/lib/src/domain/duties.dart`, `duty_coverage.dart`, `application/duties_controllers.dart`, `membership_lifecycle_controllers.dart`, `presentation/duties_screens.dart`, `duties_coverage_screens.dart`, `membership_lifecycle_screen.dart`, `domain/followups.dart` (activity attribution).

## Tasks & Acceptance

**Execution:**
- [ ] `supabase/migrations/20261015043644_duties_lifecycle.sql` -- hooks, commands, vacancy kind and flag, Follow-ups handover, replaced bodies, privileges.
- [ ] `supabase/tests/duties_lifecycle_test.sql`, `duties_lifecycle_scale_test.sql`; ledgers and earlier tests updated.
- [ ] `packages/client_core` -- remove member, handovers and resolve, `vacated` flag, handover refusal text, task handover attribution; tests.
- [ ] `tools/identity-e2e/duties-lifecycle.mjs` + `.test.mjs`.
- [ ] Runbooks `duties.md`, `follow-ups.md`, `identity-access.md`; `evidence-4.12/`; CI evidence step.

**Acceptance Criteria:**
- Given synthetic members with upcoming duties and open tasks, when they are held, deactivated, removed from the department and deleted through the API, then vacancies are flagged with leader notices, jobs are cancelled in the same transaction, the last leader's deactivation is refused until handover, a held member's duty is listed with Needs contact, and the deletion check answers zero.

## Implementation Notes

## Plan Change Log

## Review Triage Log

## Verification

**Commands:**
- `npx supabase db reset && npm run -s db:test && npm run -s db:smoke` -- expected: pass.
- e2e-main.sh (worktree copy) with `duties-lifecycle` appended -- expected: each `exit=0`.
- `npm run -s contracts:test`, `dart test` in `packages/contracts/dart`, node tool tests, `npm run -s ci:policy-test` -- expected: pass.
- `flutter analyze && flutter test` in `packages/client_core`, `apps/staff`, `apps/mobile`; `TZ=America/New_York` for `test/duties` and mobile -- expected: pass.
- `npm run -s ci:secrets && npm run -s ci:migrations -- --base origin/main && npm run -s ci:function-imports`; evidence scan -- expected: clean.

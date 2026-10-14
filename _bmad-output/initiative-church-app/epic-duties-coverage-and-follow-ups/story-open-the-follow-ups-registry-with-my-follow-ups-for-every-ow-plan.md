---
title: 'Open the Follow-ups registry with My follow-ups for every owner'
type: 'feature'
ticket: '6'
created: '2026-10-14'
status: 'in-progress'
baseline_revision: '269cd5d2d35320656d273e559e2cb573597884bc'
route: 'full'
route_source: 'auto'
review: ''
review_source: ''
lenses_ran: []
review_loop_iteration: 0
context:
  - '{project-root}/docs/runbooks/contracts-and-owner-seams.md'
  - '{project-root}/docs/runbooks/command-foundation.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** No Follow-ups owner exists, so a source (a duty contact, a visitor, a missing report) cannot hand one accountable person a next action with a due date, and nobody sees their own follow-up work.

**Approach:** Add the Follow-ups owner module: one task per `source_type/source_id/purpose`, its activity and separately restricted private notes; a source-owner registration of purposes (label, allowed scope kinds, outcomes, legal lifecycle effects, optional context hook); owner operations a source calls in its own transaction (open a task, apply a source event); `followups.*` commands through the 1.4 envelope (create for SYNTHETIC/manual purposes, update, reassign); reads for the owner, the supervising scope and Admin routing; a deletion hook; the SYNTHETIC `fixture_followup` source; My follow-ups on mobile Home and staff web, a staff supervision screen and an Admin routing screen.

**Decisions:**
- Decision (agent, under owner pre-approval): **who acts.** The owner updates their own task (status, review date, outcome, next action, private note). Any current holder of the task's scope (the named supervisor or another leader of that scope) may record the same updates, always attributed as "recorded by <actor> for <owner>", which is how an accountless owner's work is recorded. Scope holders and Admins reassign the owner or the supervisor. Admin in that capacity sees routing metadata only (owner, supervisor, scope, purpose, state, due and review dates) and cannot update a task. Pastor gets nothing from the role alone.
- Decision (agent, under owner pre-approval): **states.** Open, In progress and Waiting are active and move freely between each other. Waiting needs a review date (future, at most a year away); every review-date change is an activity row. Done and Closed are terminal in 4.6 (no reopen). Closing needs a reason (1-200 characters). The original due date never changes in 4.6 and stays shown while Waiting; `overdue` follows the due date (Open/In progress) or the review date (Waiting), and `due_passed` keeps the overdue history.
- Decision (agent, under owner pre-approval): **uniqueness.** One task per source/purpose for ever (terminal tasks included); a second create is refused `conflict {"purpose": "task_exists"}`.
- Decision (agent, under owner pre-approval): **creation.** Real sources create tasks with the owner operation `app.followups_open_task` inside their own command (entries 9 and 11). `followups.create_task` accepts only purposes registered with `manual_create`; in 4.6 that is the SYNTHETIC `fixture_followup/synthetic_check_in`, whose source check answers current only in local and staging. The creator must hold the scope (or be Admin and name a supervisor who holds it).
- Decision (agent, under owner pre-approval): **privacy.** Activity is content-free (codes, states, dates, ids). Next action, outcome, close reason, source context and private notes go only to the owner and the scope holders. A registered context hook may add a minimal `{label}`; a malformed answer shows no context (fail closed). The care/finance note grants arrive with their owners; 4.6 registers only practical purposes.
- Decision (agent, under owner pre-approval): **candidates.** Owners are picked from approved, non-deleted members (name and app account / no login only), behind the Q4 personal-data gate like every Follow-ups read and command, so production stays inert.
- Decision (agent, under owner pre-approval): **deletion.** The hook anonymises tasks, activity and notes (nil UUID) and clears note bodies the member wrote or that sit on their tasks (`erased_at`); no rows are deleted, so there is no `_rows` file and no owner paste. A deleted owner's active tasks stay active, show a former member and can be reassigned (handover obligations are entry 12).
- Decision (agent, under owner pre-approval): **out of scope.** No reminders or Notifications calls (entry 7), no lifecycle or handover hooks (entry 12), no due-date change, no reopen. Mobile gets no new tab: the Home card opens `/followups`.

## Boundaries & Constraints

**Always:** state changes through `api.followups_command` (registered `followups` authorizer, revision checks, idempotent replay with an `in_scope` recheck); reads through `api` wrappers over definer `app` functions behind live access and the Q4 gate; tables have RLS and no client privileges; ASCII, `search_path = ''`, no `\u`, no DROP/TRUNCATE/`delete from`; new client functions in the privilege ledgers; lock order: actor grants FOR SHARE, receipt, task FOR UPDATE (Follow-ups after source owners, before Notifications); SYNTHETIC data and numbers +44 7700 900210-900229.

**Never:** reminders, lifecycle/handover hooks, care/finance grants, editing Duties behaviour, real people or numbers.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Create | scope holder; SYNTHETIC purpose; active owner; future due | Open task, `created` activity | none |
| Duplicate | same source and purpose | refused | `conflict {"purpose":"task_exists"}` |
| Outsider create | no scope, not Admin | refused | `forbidden` |
| Lifecycle | owner: in_progress, waiting+review, done; another: closed+reason | states, activity; due date unchanged | waiting without review `review_at: required`; close without reason `close_reason: required`; terminal `conflict {"task_id":"finished"}` |
| Supervisor update | scope holder updates an accountless owner's task | activity `on_behalf_of` = owner | none |
| Reassign | scope holder or Admin; new active owner | owner changes, activity | owner tries: `forbidden` |
| Admin view | Admin routing and detail | metadata only, no notes/next action/context | none |
| Source event | `resolved`/`cancelled` | registered effect: close (`source_resolved`) or keep | none |
| Stale | wrong expected revision | refused | `conflict` with current revision |
| Deletion | erase/check | anonymised, note bodies cleared, check 0 | none |

</frozen-after-approval>

## Code Map

- `supabase/migrations/20261003134340_cross_epic_contracts.sql` -- `followups` module (rank 30), prefix, edges `followups -> platform, identity, notifications`; `contract_register_purpose`, `contract_require_source_owner`, `contract_validate_handler`, `contract_check_source`, `contract_require('task_source', ...)`, `contract_registration_fail`.
- `supabase/migrations/20261013220239_duties_department_tracer.sql` -- template: `_state_ok` vocabularies, actor helper, `_require_open(_read)`, text/instant/uuid validators (rewrite the text check with `chr()`: no `\u`), audit, authorizer, `in_scope`, command entry, reads, deletion hook, privilege block.
- `supabase/migrations/20261006234820_identity_grants.sql` -- `identity_member_has_scope/role`, `identity_evaluate_grant`, `identity_scope_kinds`, `identity_grants`; `20261007063340_membership_review.sql` `identity_member_account_label`; `..._membership_applications.sql` `identity_applications_open`.
- `supabase/tests/command_foundation_test.sql` (authenticated EXECUTE ledger), `notifications_routing_test.sql` (deletion check string per owner), `duties_tracer_test.sql` (pgTAP helpers to copy).
- `packages/client_core/lib/src/{domain/duties.dart, application/duties_controllers.dart, presentation/duties_screens.dart, adapters/supabase_duties_repository.dart}` -- client pattern; `MemberHomeScreen` (duties_screens.dart) gets the Follow-ups card; `domain/church_time.dart` for church time.
- `packages/client_core/lib/{church_client_core.dart, composition.dart, supabase_adapters.dart, testing.dart}`, `src/application/providers.dart`, `src/presentation/shell_routing.dart` -- wiring, fakes, routes.
- `apps/mobile/lib/app.dart`, `apps/staff/lib/app.dart` -- staff destinations (My follow-ups for member access; Follow-ups for scope holders; Follow-up routing for Admin).
- `tools/identity-e2e/duties.mjs`, `harness.mjs`, `deletion.mjs` (`identity.create_member` for an accountless member) -- E2E pattern.

## Tasks & Acceptance

**Execution:**
- [ ] `supabase/migrations/20261014120000_followups_registry.sql` -- purposes, tasks, activity, notes; registration; owner operations; commands, authorizer, in_scope; reads; deletion hook; SYNTHETIC fixture source; privileges.
- [ ] `supabase/tests/followups_registry_test.sql` + ledgers (`command_foundation_test.sql`, `notifications_routing_test.sql`) -- the matrix.
- [ ] `packages/client_core/lib/src/{domain/followups.dart, application/followups_controllers.dart, presentation/followups_screens.dart, adapters/supabase_followups_repository.dart}` + exports, provider, composition, fake, routes -- client.
- [ ] `apps/mobile/lib/app.dart` (Home card via `MemberHomeScreen`), `apps/staff/lib/app.dart` -- destinations; tests in `packages/client_core/test/followups/followups_test.dart` and both app tests.
- [ ] `tools/identity-e2e/followups.mjs` + `followups.test.mjs` -- the verify over HTTP.
- [ ] `docs/runbooks/follow-ups.md` (+ link in `contracts-and-owner-seams.md`) -- model, registration guide, owner manual checks.
- [ ] `evidence-4.6/` -- E2E JSONL and suite summary.

**Acceptance Criteria:**
- Given the local stack, when the E2E runs, then a leader creates SYNTHETIC tasks for an app member and an accountless member, the owner sees them in My follow-ups and moves one through In progress, Waiting (due date kept), Done, a second is Closed with a reason (refused without), the leader reassigns one and records an update for the accountless owner, a duplicate is refused, Admin routing shows no private content, and direct table queries are refused.
- Given the full local verification, when run, then every listed check passes.

## Implementation Notes

## Plan Change Log

## Review Triage Log

## Design Notes

- Registration: `app.followups_register_purpose(module, source_type, purpose, config jsonb, context_hook regprocedure)`; config keys `label`, `scope_kinds`, `outcomes`, `on_source_resolved`/`on_source_cancelled` (`close`|`keep`), `manual_create`. The purpose must already be registered with `contract_register_purpose` by the source's owner.
- Followups never calls a source owner directly: the source check goes through `contract_check_source`, the context hook through its registered signature (dynamic, like the platform hooks).

## Verification

**Commands:**
- `npx supabase db reset && npm run -s db:test && npm run -s db:smoke` -- expected: pass.
- e2e-main.sh copy with `followups` appended -- expected: each `exit=0`.
- `npm run -s contracts:test && node --test tools/**/*.test.mjs && npm run -s ci:policy-test` -- expected: pass.
- `flutter analyze && flutter test` in `packages/client_core`, `apps/mobile`, `apps/staff`; follow-ups tests under `TZ=America/New_York` -- expected: pass.
- `npm run -s ci:secrets && npm run -s ci:migrations -- --base origin/main && npm run -s ci:function-imports` -- expected: pass.

**Manual checks (if no CLI):**
- Parent session: apply the migration to staging and compare per-function md5. No owner SQL paste.
- Owner: `docs/runbooks/follow-ups.md`, "Owner manual checks (story 4.6)".

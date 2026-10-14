---
title: 'Open the Follow-ups registry with My follow-ups for every owner'
type: 'feature'
ticket: '6'
created: '2026-10-14'
status: 'built'
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
- [x] `supabase/migrations/20261014120000_followups_registry.sql` -- purposes, tasks, activity, notes; registration; owner operations; commands, authorizer, in_scope; reads; deletion hook; SYNTHETIC fixture source; privileges.
- [x] `supabase/tests/followups_registry_test.sql` + ledgers (`command_foundation_test.sql`, `notifications_routing_test.sql`) -- the matrix.
- [x] `packages/client_core/lib/src/{domain/followups.dart, application/followups_controllers.dart, presentation/followups_screens.dart, adapters/supabase_followups_repository.dart}` + exports, provider, composition, fake, routes -- client.
- [x] `apps/mobile/lib/app.dart` (Home card via `MemberHomeScreen`), `apps/staff/lib/app.dart` -- destinations; tests in `packages/client_core/test/followups/followups_test.dart` and both app tests.
- [x] `tools/identity-e2e/followups.mjs` + `followups.test.mjs` -- the verify over HTTP.
- [x] `docs/runbooks/follow-ups.md` (+ link in `contracts-and-owner-seams.md`) -- model, registration guide, owner manual checks.
- [x] `evidence-4.6/` -- E2E JSONL and suite summary.

**Acceptance Criteria:**
- Given the local stack, when the E2E runs, then a leader creates SYNTHETIC tasks for an app member and an accountless member, the owner sees them in My follow-ups and moves one through In progress, Waiting (due date kept), Done, a second is Closed with a reason (refused without), the leader reassigns one and records an update for the accountless owner, a duplicate is refused, Admin routing shows no private content, and direct table queries are refused.
- Given the full local verification, when run, then every listed check passes.

## Implementation Notes

- Implemented directly (no implementation subagent is available inside this builder run).
- Server: `supabase/migrations/20261014120000_followups_registry.sql`. Vocabularies through `app.followups_state_ok` (widened later by replacement, as Duties does). The text validator builds its invisible-character class with `chr()` (`app.followups_invisible_class`), so the file holds no `\u` escape and survives the MCP apply byte for byte. No `_rows` file: deletion anonymises and clears note text (`erased_at`) without deleting rows.
- Decision (agent, under owner pre-approval): `followups.create_task` and `app.followups_open_task` take `source_revision` because the shared `source_ref` contract (`contract_check_source`) requires it; it is stored on the task as the revision the task was opened at.
- Decision (agent, under owner pre-approval): an Admin with a scope acts as a scope holder for that scope (the scope capacity wins); an owner who also holds the scope acts as owner on their own task. Updates by Admin capacity are `forbidden`; reassign by the owner without scope is `forbidden`; anyone else gets `not_found`.
- Decision (agent, under owner pre-approval): in production the SYNTHETIC accounts are not live members, so a create is refused (`forbidden`) before the Q4 gate is even reached; the gate itself is pinned by pgTAP (`app.followups_require_open()` raises `unavailable` in production) and the reads answer `403 unavailable`.
- Decision (agent, under owner pre-approval): the Home card lives in `MemberHomeScreen` (duties_screens.dart, one added child and an import); no other Duties code changed. Staff web gets **My follow-ups** (member access), **Follow-ups** (department leader/deputy, cell leader/assistant) and **Follow-up routing** (Admin).
- Ledgers: `command_foundation_test.sql` (five followups pairs added to the authenticated EXECUTE list), `notifications_routing_test.sql` (deletion check `cells=0,duties=0,fixture=0,followups=0,notifications=0`). New `supabase/tests/followups_registry_test.sql` (143 checks).
- Clients: `packages/client_core/lib/src/{domain/followups.dart, application/followups_controllers.dart, presentation/followups_screens.dart, adapters/supabase_followups_repository.dart}`; routes `/followups`, `/followups/tasks/:taskId`, `/followups/supervision`, `/admin/followups`; fakes `FakeFollowUps`, `followUpTaskData`, `followUpPersonData` in `testing.dart`. Tests: `packages/client_core/test/followups/followups_test.dart` (17), one test each in `apps/mobile/test/mobile_app_test.dart` and `apps/staff/test/staff_app_test.dart`. No deep-link pattern yet (no reminder links until entry 7).
- E2E: `tools/identity-e2e/followups.mjs` (13 checks, F01-F51) with offline `followups.test.mjs`. Fictional numbers: pgTAP +44 7700 900210-900219, E2E 900220-900229 (unused before; grepped).
- Runbook: `docs/runbooks/follow-ups.md` (model, commands, reads, registration guide, deletion, clients, local and hosted steps, owner manual checks, open owner question); linked from `contracts-and-owner-seams.md`.
- Open owner question (fail-closed default taken): Q4, whether owners may ever be chosen from outside the task's target. Since the review a leader and an Admin choose only from the target's roster (its current members and leaders); production also stays closed behind the Q4 gate.
- Decision (agent, under owner pre-approval, review S1): a department's leader and deputy, and a cell's leader and assistant, are one scope family on the same target; the family is registered by the owner of the scope kind (Duties, Cells) with a read-only roster hook, so Follow-ups never reads another owner's tables.
- Decision (agent, under owner pre-approval, review S2): an Admin reassigns within the task's roster too; the spec gives Admin routing metadata, not a church-wide choice of owner.
- Decision (agent, under owner pre-approval, review S3): only SYNTHETIC `fixture_` sources may allow hand-made tasks until a registered source-scope check exists.
- Decision (agent, under owner pre-approval, review N2): source events are gated by Q4 like every other Follow-ups change, so a production source cannot close tasks while the module is inert.
- Matrix audit: Create, Duplicate, Outsider create, Lifecycle, Supervisor update, Reassign, Admin view, Stale, Deletion are covered in pgTAP and (except Source event, Stale and Deletion) also over HTTP in the E2E; Source event (close and keep) is pgTAP only (no client source exists yet).

## Plan Change Log

- 2026-10-14, review of 4.6 (no blockers; S1-S4 and N1-N8, N10 fixed in place, migration 20261014120000 edited before any merge or apply):
  - **S1 scope families.** Finding: an exact (scope_kind, scope_id) match split a department's leader and deputy (and a cell's leader and assistant). Amended: `app.followups_scope_families` and `app.followups_register_scope_family` (Duties registers `department_leader`/`department_deputy` as `department`, Cells `cell_leader`/`cell_assistant` as `cell`), and one rule `app.followups_member_holds` (same target id, same family, kind in the purpose's current `scope_kinds`) used by every command and read (also N4). Avoids: deputies blind to their leader's tasks. KEEP: the target id stays exact.
  - **S2 owner candidates.** Finding: every scope holder saw up to 500 approved members. Amended: candidates are the target's roster only (Duties `app.duties_followups_roster`: current department members; Cells `app.cells_followups_roster`: current cell members; plus the family's current scope holders), returned per scope in supervision and per active task scope in Admin routing; create, reassign (Admin too) and `followups_open_task` refuse anyone else (`owner_member_id: not_in_scope`). Avoids: exposing the church roster. Q4 widening stays an open owner question.
  - **S3 manual create.** Finding: a hand-made task never checks that its source belongs to the scope and blocks the source for ever. Amended: `manual_create: true` is refused (PCTR1) unless the source type starts with `fixture_`; documented in the runbook.
  - **S4 duplicate submits.** Amended: the task screen clears note, next action and reason after a confirmed save; the create form keeps one SYNTHETIC source id per draft until the server answers.
  - **N1-N8, N10.** Read hooks must be STABLE/IMMUTABLE and not SECURITY DEFINER; hook failures `raise log` the SQLSTATE only; `followups_source_event` is behind the Q4 gate; activity and notes name an erased person "a former member"; the authorizer and reassign share-lock a named supervisor's grants; mobile keeps a My follow-ups link on Home when nothing is active; "Open task" (with a semantics label), "N active", "Mark in progress"; unrelated reformatting of `apps/staff/test/staff_app_test.dart` reverted; tests added for Admin-with-scope, erasing the supervising and creating leader, the exact production code (`forbidden`) and an E2E concurrent open.
  - Not done: the optional change-supervisor control on staff (reassign still accepts `supervisor_member_id` over the API); N9 is the parent's rename.

## Review Triage Log

- 2026-10-14, independent review: 0 blockers, 4 should-fix (S1-S4), 10 nits (N1-N10). S1-S4 fixed; N1-N8 and N10 fixed (the change-supervisor control of N7 was optional and is not built); N9 is a parent-session action (rename after staging).

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

**Results (2026-10-14, after the review fixes S1-S4, N1-N8, N10):**
- db reset 0; db:test PASS (32 files, 2783 tests, including `followups_registry_test.sql` 143); db:smoke pass, no SMS provider.
- Every E2E `exit=0` (23 scripts), `followups` 15/15 (adds the roster refusal and a concurrent open that makes one task).
- contracts:test 242/0; node tool tests (CI set) 189/0; ci:policy-test 56/0.
- flutter analyze clean in all three; flutter test client_core 536 (followups 20), apps/staff 36, apps/mobile 51; under `TZ=America/New_York` client_core `test/followups` 20 and apps/mobile 51.
- ci:secrets clean; ci:migrations (`--base origin/main`) ordered, unique, non-destructive; ci:function-imports ok; evidence scan clean (no numbers, tokens or note text).
- Evidence: `evidence-4.6/followups-e2e.jsonl`, `evidence-4.6/e2e-suite-summary.txt`.
- Remaining (not builder steps): staging apply and md5 parity (parent session; no owner SQL paste; the migration now also creates `app.duties_followups_roster` and `app.cells_followups_roster`), staging client rebuild, owner manual checks in `docs/runbooks/follow-ups.md` story 4.6, open owner question Q4 (owners from outside the target).

---
title: 'Publish a one-position department duty and accept it on mobile'
type: 'feature'
ticket: '1'
created: '2026-10-13'
status: 'in-progress'
baseline_revision: '239a701d3adebed22fd7c4699539f74dc02c1d06'
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

**Problem:** No Duties owner exists, so a leader cannot give a member a duty, and the member cannot see or answer it.

**Approach:** Add the Duties owner module (tracer): Admin-created departments, the Duties-registered `department_leader`/`department_deputy` Identity scope kinds, department members (with or without a login), a published one-position occurrence with one slot and one assignment carrying a leader-entered response deadline, `publish_duty` and `respond` commands through the 1.4 envelope, a registered `duties_assignment` reminder source whose `duty_assigned` job reaches the 3.1 inbox, a staff web Departments (Admin) and Duties (leader) screen, and a mobile Duties list and assignment detail where the assignee accepts or declines.

**Decisions:**
- Decision (agent, under owner pre-approval): in 4.1 only an Admin creates departments and adds department members (D1 says Admin); leaders gain member management later if the owner wants it. Leader and deputy are given with the audited 2.3 `identity.grant_scope` command.
- Decision (agent, under owner pre-approval): a department's leader, its deputy and an Admin may publish for it (D1 "only that scope's authorised leaders manage it ... Admin can manage"); Pastor has read-only church-wide oversight without members' response notes; a cell leader gets nothing.
- Decision (agent, under owner pre-approval): responses are refused once the duty has started (fail closed; later decline and corrections arrive with 4.5 and 4.10); a late response after the deadline but before the start is accepted.
- Decision (agent, under owner pre-approval): the new-duty inbox item is one `duty_assigned` job scheduled at publish time. No direct-contact route is registered in 4.1, so an accountless or held assignee's need is recorded `unrouted` in the 3.8 reminder health view until 4.8 adds the leader's Needs contact route.
- Decision (agent, under owner pre-approval): member deletion deletes the member's department memberships (`_rows` file) and keeps assignments and audit as anonymous facts (member and account ids replaced by the nil UUID, response note cleared), as Cells does for its retained facts.

## Boundaries & Constraints

**Always:** every state change through `api.duties_command` (1.4 envelope, registered `duties` authorizer, handler/in-scope functions, revision checks, idempotent replay); every read through an `api` wrapper over a definer `app` function behind the live-access predicate and the Q4 personal-data gate (`app.identity_applications_open()`); department names start `SYNTHETIC ` while Q4 is unapproved; only a department's leader or deputy, or an Admin, publishes for it; Pastor reads every department (no member notes); only the assignee responds; the enqueue runs inside the publish transaction (Notifications last in lock order); a deletion hook erases or anonymises every new member-linked row (row deletions in a separate `_rows` file, fail-closed stub in the main file); new client-executable functions are added to the privilege ledgers; ASCII migration, search_path pinned, no anon grants, no DROP/TRUNCATE/`delete from` in the main file.

**Never:** revisions/supersession (4.2), recurring series, drafts or multi-position occurrences (4.3), overlap warnings (4.4), later decline, bulk accept or calendar export (4.5), default deadlines, Short notice, response/pre-service reminders or direct-contact routes (4.8), coverage queue (4.9), lifecycle/handover hooks (4.12); real names or numbers; touching hand-pasted functions.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Publish | leader of D, assignee a current D member, start in future, deadline after now and not after the (reporting) start | occurrence + slot + pending assignment; one `duty_assigned` job; worker delivers one inbox item | none |
| Publish outside scope | non-leader, other department's leader, cell leader | `forbidden` | nothing written |
| Bad assignee or times | assignee not a D member / deleted; start past; deadline past or after start | `validation_failed` with `member_id`, `starts_at`, `response_deadline` codes | nothing written |
| Accept/decline | assignee, expected = assignment revision, response accepted/declined, optional note | state recorded with actor, account, time; revision + 1; pending jobs cancelled `responded` | none |
| Respond refused | another member; stale revision; already answered; duty started | `not_found` (not yours), `conflict` + current_revision, `conflict {"assignment_id":"responded"}`, `validation_failed {"assignment_id":"started"}` | nothing changes |
| Replay | same request id and body | the stored result | none |
| Direct table query | any client role on `app.duties_*` | no privilege | permission denied |
| Deletion | member erased | membership rows deleted (`_rows`), assignments/audit anonymised, check answers 0 | stub fails closed without `_rows` |

</frozen-after-approval>

## Code Map

- `supabase/migrations/20261003134340_cross_epic_contracts.sql` -- `duties` module, `duties_` prefix and edges (platform, identity, followups, notifications) already exist.
- `supabase/migrations/20261007075946_cell_membership.sql` -- the template: scope-kind registration, actor helper, text validation, authorizer, in-scope, entry/api wrappers, reads, privilege block.
- `supabase/migrations/20261006234820_identity_grants.sql` -- `identity_register_scope_kind`, `identity_evaluate_grant`, `identity_member_has_scope/role`, `identity_require_access`, `cmd_register_authorizer`.
- `supabase/migrations/20261008073631_notifications_inbox.sql`, `..._source_contracts.sql`, `..._routing.sql` -- fixture_reminder source: `contract_register_source_type`, `contract_register_reminder_kind`, `contract_register_reminder_contract` (four-key check), `notifications_enqueue`, `notifications_cancel`.
- `supabase/migrations/20261007174952_member_deletion.sql` + `20261008135900_notifications_routing_rows.sql` -- deletion hook + `_rows` stub pattern.
- `supabase/tests/command_foundation_test.sql` (authenticated EXECUTE ledger), `notifications_routing_test.sql` (deletion check per owner) -- ledgers to extend.
- `packages/client_core/lib/src/{domain,application,presentation,adapters}/cell_*` -- client template (strict wire parsing, controller with honest states, `_CellsPage`).
- `packages/client_core/lib/src/presentation/shell_routing.dart` -- routes and `deepLinkTargets`.
- `apps/mobile/lib/app.dart`, `apps/staff/lib/app.dart` -- destinations; `packages/client_core/lib/{composition.dart,testing.dart}` -- adapter wiring and fakes.
- `tools/identity-e2e/inbox.mjs`, `cells.mjs`, `harness.mjs` -- E2E pattern (worker credential, fictional numbers, cleanup).

## Tasks & Acceptance

**Execution:**
- [ ] `supabase/migrations/20261013200000_duties_department_tracer.sql` -- tables (departments, department members, occurrences, slots, assignments, audit), scope kinds, source + reminder contract, commands, authorizer, reads, deletion hook with stub, privileges.
- [ ] `supabase/migrations/20261013200100_duties_department_tracer_rows.sql` -- real `duties_deletion_purge_rows`.
- [ ] `supabase/tests/duties_tracer_test.sql` -- pgTAP for the matrix; extend ledgers in `command_foundation_test.sql`, `notifications_routing_test.sql` (and any test listing deletion owners).
- [ ] `packages/client_core/lib/src/domain/duties.dart`, `application/duties_controllers.dart`, `presentation/duties_screens.dart`, `adapters/supabase_duties_repository.dart` + exports, providers, composition, fakes, routes, deep link -- client.
- [ ] `apps/mobile/lib/app.dart`, `apps/staff/lib/app.dart` -- Duties tab (mobile), Departments (Admin) and Duties (leader/Admin/Pastor) sidebar entries.
- [ ] `packages/client_core/test/duties/duties_test.dart`, app tests -- wire parsing, publish/respond flows, unknown outcome.
- [ ] `tools/identity-e2e/duties.mjs` + `duties.test.mjs` -- local E2E of the verify.
- [ ] `docs/runbooks/duties.md` (+ links in `contracts-and-owner-seams.md`) -- model, commands, reads, local runs, hosted steps, owner manual checks.

**Acceptance Criteria:**
- Given the local stack, when the E2E runs, then Admin creates `SYNTHETIC Preaching Rota`, grants a leader, adds a member, the leader publishes, the worker delivers one inbox item whose open target is `/duties/assignments/<id>`, the member accepts, and the leader board shows Accepted; another member, a non-leader and direct table queries are refused.
- Given the full local verification, when run, then db:test, db:smoke, every E2E, contracts, offline tool tests, flutter analyze/test, secrets, migrations and function-imports checks pass.

## Implementation Notes

## Plan Change Log

## Review Triage Log

## Design Notes

- Notification source revision = the assignment's aggregate revision; a response bumps it, so the delivered item opens as superseded afterwards (the duty screen is the live view). 4.2 creates a new assignment row per material revision (new source id).
- Times travel as UTC instants; clients show device-local time (as the inbox does); church time is Africa/Lusaka for staff and phones in Zambia.

## Verification

**Commands:**
- `npx supabase db reset && npm run -s db:test && npm run -s db:smoke` -- expected: all pass
- `bash <scratchpad>/e2e-worktree.sh` (every E2E incl. `duties`) -- expected: each `exit=0`
- `npm run -s contracts:test && node --test tools/auth-harness/*.test.mjs tools/identity-e2e/*.test.mjs supabase/functions/*/*.test.mjs tools/identity-deletion/*.test.mjs tools/notifications/*.test.mjs` -- expected: pass
- `flutter analyze && flutter test` in `packages/client_core`, `apps/mobile`, `apps/staff` -- expected: pass
- `npm run -s ci:secrets && npm run -s ci:migrations -- --base origin/ccr-93e730dd-89lbvg && npm run -s ci:function-imports` -- expected: pass

**Manual checks (if no CLI):**
- Owner staging walkthrough in `docs/runbooks/duties.md` (story 4.1 owner checks).

---
title: 'Generate recurring multi-position rotas with drafts and series edits'
type: 'feature'
ticket: '3'
created: '2026-10-14'
status: 'in-progress'
baseline_revision: 'c55d1d65d2926546a237b1e191c83c6ea2cf85b2'
route: 'full'
route_source: 'auto'
review: ''
review_source: ''
lenses_ran: []
review_loop_iteration: 0
context:
  - '{project-root}/docs/runbooks/duties.md'
  - '{project-root}/docs/runbooks/command-foundation.md'
  - '{project-root}/docs/runbooks/notifications.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** Leaders can only publish one-off, one-position duties, so a quarterly multi-position rota means dozens of separate publishes, there are no drafts to prepare it privately, and a series cannot be changed or cancelled from one occurrence onwards.

**Approach:** A forward migration adds Duties-owned rota series expanded in church time by the shared 3.3 calculation (`app.notifications_occurrences`, Q2 zone), multi-position draft occurrences (one slot per named position) with draft assignees that never notify, an explicit "Publish N draft slots" command, per-position assignment, "this occurrence" (`duties.revise_duty`, extended) and "this and future" edits and cancellation that preserve started occurrences and update every position of an occurrence together through the 4.2 revision engine, a manager-only rota read, and the staff web rota grid with an accessible list.

**Decisions:**
- Decision (agent, under owner pre-approval): a series repeats every N days, weeks or months between a church-local `from_date` and `until_date` (a single date when equal) at church-local times; generation happens once at creation, is bounded (at most 60 occurrences, 10 positions, a window of 366 days, future starts only) and idempotent (unique series/date; command replay). Exception dates are skipped.
- Decision (agent, under owner pre-approval): drafts are occurrences in state `draft`; a draft assignee is a slot field (`draft_member_id`), not an assignment, so My duties, reminders and the 4.1/4.2 leader board never see drafts (the board stays published-only for older clients). Drafts are read only through `api.duties_rota` by the department's leader, deputy, Admin and Pastor (read-only).
- Decision (agent, under owner pre-approval): `duties.publish_drafts {series_id, slot_count, deadline_before}` publishes every not-started draft occurrence of the series; `slot_count` must equal the server's count (`conflict {"slot_count": "changed"}`); each assignment's deadline is (reporting or start) minus `deadline_before` in church time (`app.notifications_shift`), the creator's choice until entry 8 adds defaults; a deadline already passed is refused (`{"deadline_before": "passed"}`), as is a draft assignee who can no longer serve (`{"member_id": "unavailable"}`). Unassigned positions publish unfilled.
- Decision (agent, under owner pre-approval): commands: `duties.create_series`, `duties.assign_slot` (draft: set or clear; published: give the position to a member with an answer-by, superseding any current assignment by 4.2 rules), `duties.publish_drafts`, `duties.revise_duty` (this occurrence; drafts edited in place without notices), `duties.revise_series` (this and future, church-local times, `deadline_before` for published occurrences whose material fields change), `duties.cancel_occurrence`, `duties.cancel_series` (this and future). Started occurrences are never changed.
- Decision (agent, under owner pre-approval): cancelling a published occurrence ends its current assignments (`cancelled`), cancels their jobs (`source_cancelled`), records a `cancelled` slot revision and sends a generic `duty_cancelled` notice (link `/duties`) to pending or accepted assignees.
- Decision (agent, under owner pre-approval): new fields are classified explicitly: `topic`, `scripture` are notes (update notice); `event_ref` (an opaque linked-event id until Content exists) is a reference (recorded, no notice); `position_name` is material and fixed at creation in 4.3.
- Decision (agent, under owner pre-approval): member deletion clears draft assignees and anonymises series creators (nil UUID); no new row deletions, so no new `_rows` file.

## Boundaries & Constraints

**Always:** forward migration later than `20261013221115` (4.1/4.2 files untouched; `create or replace`; vocabularies via `app.duties_state_ok`); every change through `api.duties_command` with revision checks and scope-rechecked replay; lock order grants -> receipt -> department share -> series -> occurrences (date order) -> membership -> slots -> assignments -> Notifications; answers carry ids, revisions, states and counts only; reads behind live access, the Q4 gate and the production synthetic filter; leaders see `app_account`/`no_login` only; inactive members filtered; church time via `ChurchTime` on clients; clients keep `pending` across reloads and resend unconfirmed commands with the same request id.

**Never:** overlap warnings or load (4.4); defaults, Short notice or response/pre-service reminders (4.8); coverage queue (4.9); adding or renaming positions after creation; editing hand-pasted, 4.1 or 4.2 migration files; real names or numbers.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Generate | leader, weekly Sundays 13 weeks, 3 positions | 13 draft occurrences x 3 slots in church time (00:30 church time stays Sunday); no jobs; member sees nothing | >60 / window / past / bad rule: `validation_failed` |
| Assign drafts | leader sets/clears slot member | draft assignee stored; no job | non-member/inactive: `not_in_department`/`unknown`; stale: `conflict` |
| Publish N | `slot_count` = server count, `deadline_before` | occurrences published, pending assignments + one `duty_assigned` job each, slot revision 1 | count changed: `conflict`; passed deadline; unavailable assignee |
| Edit this | `revise_duty` on a published 3-position occurrence | all positions revised together (material: 3 new pending revisions; notes: answers stand) | 4.2 refusals |
| Edit this and future | anchor + patch | anchor and later not-started occurrences change; earlier and started unchanged; each keeps its own responses | `deadline_before` required/passed |
| Cancel | one occurrence / this and future | occurrence `cancelled`, assignments cancelled, jobs cancelled, `duty_cancelled` notice; late answer `conflict {"assignment_id":"cancelled"}` | started: refused |
| Coverage | 2 of 3 accepted | read shows `confirmed 2`, `required 3` from current positions | none |
| Refusals | member, other department, Pastor, gate closed, untrusted session, revoked scope incl. replay | `forbidden`, `unavailable`, `unauthenticated` | nothing written |
| Races | two leaders publish/assign at once; edit vs respond | one success + one `conflict`; either order consistent | none |
| Deletion | draft assignee / series creator erased | draft cleared, creator nil, check 0 | none |

</frozen-after-approval>

## Code Map

- `supabase/migrations/20261013220239_duties_department_tracer.sql`, `20261013221115_duties_revisions.sql` -- read-only reference: helpers, `duties_revise_duty` per-slot loop (extracted into a shared helper here), reminder checks, `duties_in_scope`, deletion hook, authorizer and dispatch (all replaced by `create or replace`).
- `supabase/migrations/20261008102121_notifications_scheduling.sql` -- `notifications_policy()`, `notifications_occurrences(policy, rule, from, until)`, `notifications_shift`; reused, never duplicated.
- `supabase/tests/duties_revisions_test.sql`, `duties_tracer_test.sql`, `command_foundation_test.sql` -- client-executable ledgers and audit column list to extend.
- `packages/client_core/lib/src/{domain/duties.dart, application/duties_controllers.dart, presentation/duties_screens.dart, adapters/supabase_duties_repository.dart, presentation/shell_routing.dart}` + `testing.dart` fakes; `apps/staff/lib/app.dart` sidebar.
- `tools/identity-e2e/duties-revisions.mjs` -- E2E template (worker credential, cleanup, races).

## Tasks & Acceptance

**Execution:**
- [ ] `supabase/migrations/20261014093000_duties_rota_series.sql` -- series table, occurrence/slot/revision columns, vocab, field classes, shared change helper, seven commands, `duty_cancelled` contract, rota read, replaced projections/source check/in_scope/authorizer/dispatch/deletion hook, privileges.
- [ ] `supabase/tests/duties_rota_test.sql` (+ ledgers in the 4.1/4.2/command tests) -- the matrix.
- [ ] client_core domain (`DutyRota`, series/occurrence/slot models, edits), controller, repository, rota screen (grid + list), routes, fakes; staff sidebar **Rota**; board shows position names and hides the member picker on multi-position duties; mobile shows position, topic and scripture.
- [ ] `packages/client_core/test/duties/duties_rota_test.dart` (+ staff app test) -- parsing, grid/list, publish N, scopes, cancel, pending/unconfirmed.
- [ ] `tools/identity-e2e/duties-rota.mjs` + `.test.mjs`; add to the E2E list.
- [ ] `docs/runbooks/duties.md` story 4.3 section with owner manual checks.

**Acceptance Criteria:**
- Given the local stack, when `duties-rota.mjs` runs, then a quarterly Sunday series with three positions is generated as drafts invisible to the member, some positions are assigned, "Publish N" publishes them with one inbox job per assignment, an occurrence and then this-and-future are edited, one occurrence is cancelled with its jobs cancelled, earlier occurrences are unchanged, each occurrence keeps its own responses, "2 of 3 confirmed" is derived from current positions, and races give one success and one conflict.
- Given the full local verification, when run, then db:test, db:smoke, every E2E, contracts, offline tool tests, flutter analyze/test, secrets, migrations and function-imports pass.

## Implementation Notes

## Plan Change Log

## Review Triage Log

## Verification

**Commands:**
- `npx supabase db reset && npm run -s db:test && npm run -s db:smoke` -- expected: all pass
- `bash <scratchpad>/e2e-4-3.sh` (every E2E incl. `duties`, `duties-revisions`, `duties-rota`) -- expected: each `exit=0`
- `npm run -s contracts:test && node --test tools/**/*.test.mjs supabase/functions/*/*.test.mjs` -- expected: pass
- `flutter analyze && flutter test` in `packages/client_core`, `apps/mobile`, `apps/staff` -- expected: pass
- `npm run -s ci:secrets && npm run -s ci:migrations -- --base origin/ccr-93e730dd-89lbvg && npm run -s ci:function-imports` -- expected: pass

**Manual checks (if no CLI):**
- Parent session: apply `20261014093000_duties_rota_series.sql` to staging after `20261013221115`, run `tools/ci/verify-hosted.sql`, compare per-function md5 with local (the MCP apply decodes `\uXXXX`). New client grant: `api.duties_rota()` / `app.duties_rota()`. No rows file, no Edge Function change.
- Owner staging walkthrough: `docs/runbooks/duties.md`, story 4.3, "Owner manual checks".

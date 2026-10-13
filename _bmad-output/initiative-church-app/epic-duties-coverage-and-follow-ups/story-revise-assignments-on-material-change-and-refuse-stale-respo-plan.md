---
title: 'Revise assignments on material change and refuse stale responses'
type: 'feature'
ticket: '2'
created: '2026-10-13'
status: 'in-progress'
baseline_revision: 'b08a13cad503cf49e33bdc530cc06dc80031b968'
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

**Problem:** A published duty cannot be changed, so a leader cannot move a duty's time or place, and nothing stops an answer given for old details from counting for new ones.

**Approach:** Add immutable slot revisions and the assignment lifecycle (`current`, `superseded`, `cancelled`) to the 4.1 Duties owner through a forward migration, a `duties.revise_duty` command (occurrence revision checked) that classifies each changed field as material or notes, supersedes the current assignment with a new pending one (new deadline, same or new assignee) on a material change while keeping the old answer with its actor, time and provenance, cancels the old assignment's jobs and sends generic change notices, sends a generic update without touching the answer on a notes-only change, and refuses a response to a superseded assignment with the changed fields. Both clients show the revision, the kept history and the refusal.

**Decisions:**
- Decision (agent, under owner pre-approval): material fields are the spec list: `duty_name` (duty), `starts_at` (date and start), `ends_at`, `reporting_at`, `location`, `member_id` (assignee). `instructions` is the only notes field. `response_deadline` is an assignment field: it is required with a material change (the "recalculated" deadline is the leader's until entry 8 adds the 3.3 default) and refused with a notes-only change (`not_material`). The classification lives in `app.duties_slot_field_class(field)` in the migration.
- Decision (agent, under owner pre-approval): the payload is a patch (present keys only; `null` clears an optional field); keys whose value equals the current one are no change; no change at all is `validation_failed {"occurrence_id": "unchanged"}`; a duty that has started cannot be revised (`{"occurrence_id": "started"}`); a revision outside the manager's scope is `forbidden` (as for publish).
- Decision (agent, under owner pre-approval): a stale response is `conflict` with `field_errors` `{"assignment_id": "superseded", <field>: "changed", ...}` (the fields changed since that assignment's slot revision, `member_id` when the duty went to someone else); no id or name of the new assignee is disclosed. A `cancelled` assignment answers `{"assignment_id": "cancelled"}` (the state is added now; the command that cancels arrives with 4.3).
- Decision (agent, under owner pre-approval): notices are three new generic reminder kinds on `duties_assignment`: `duty_changed` (same assignee, new pending revision, link to the new assignment), `duty_updated` (notes-only, to a pending or accepted current assignee, link to the assignment) and `duty_released` (the old assignee when the duty goes to someone else, link `/duties`). A new assignee gets the 4.1 `duty_assigned`. The old assignment's pending jobs are cancelled `source_revised` in the same transaction; delivered items open as out of date.
- Decision (agent, under owner pre-approval): slot revisions snapshot the slot's fields and assignee; they are immutable except that member deletion replaces person ids with the nil UUID. No new rows need deleting, so the existing purge function is reused and only `app.duties_erase_member` / `app.duties_deletion_remaining` are replaced (no new `_rows` file).

## Boundaries & Constraints

**Always:** forward migration only (later version than `20261013220300`; never edit the 4.1 files); `create or replace` for functions; vocabulary widening via `app.duties_state_ok`; everything through `api.duties_command` (1.4 envelope, revision checks, idempotent replay with scope recheck); Notifications last in the lock order (department share -> occurrence update -> slot -> assignment -> notifications); command answers carry ids, revisions and states only; reads behind live access and the Q4 gate; Pastor sees history without notes; leaders never see access-review labels; inactive members filtered; church time via `ChurchTime`; clients keep `pending` across reloads and resend unconfirmed commands with the same request id; ASCII migration, search_path pinned, no anon grants, no DROP/TRUNCATE/`delete from`.

**Never:** multi-position or recurring series, drafts, occurrence cancellation (4.3); overlap warnings (4.4); later decline or bulk accept (4.5); default deadlines, response/pre-service reminders (4.8); coverage queue or leader confirmation (4.9); lifecycle hooks (4.12); editing the hand-pasted or 4.1 migration files; real names or numbers.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Material change, same assignee | leader, expected = occurrence revision, new `starts_at` + `response_deadline` | occurrence and slot revision + 1, slot revision row (`material`, `[starts_at]`), old assignment `superseded` with its answer kept, new pending assignment; old jobs cancelled `source_revised`; one `duty_changed` job | none |
| Material change, new assignee | `member_id` of another current member + deadline | as above; new member gets `duty_assigned`, old member `duty_released` | `not_in_department`, `unknown` |
| Notes-only | only `instructions` | occurrence/slot revision + 1 (`notes`); answer untouched; one `duty_updated` job (pending/accepted) | `response_deadline` given: `not_material` |
| Stale response | member answers an assignment that was superseded | nothing changes | `conflict {"assignment_id":"superseded","starts_at":"changed",...}` |
| Concurrent edits | two managers, same expected revision | one success, one `conflict` + `current_revision` | none |
| Replay | same request id and body | stored result (scope rechecked) | revoked scope: `forbidden` |
| Refusals | non-manager, Pastor, started duty, no change, deadline missing/after start, gate closed, untrusted session | `forbidden`, `{"occurrence_id":"started"}`, `{"occurrence_id":"unchanged"}`, `{"response_deadline":"required"\|"after_start"}`, `unavailable`, `unauthenticated` | nothing written |
| Deletion | member erased | revision snapshots and history anonymised (nil UUID), check answers 0 | none |

</frozen-after-approval>

## Code Map

- `supabase/migrations/20261013220239_duties_department_tracer.sql` -- 4.1 owner (read-only reference): `duties_state_ok`, helpers (`duties_text`, `duties_instant`, `duties_uuid`, `duties_manage_capacity`, `duties_member_active`, `duties_occurrence_start`), `duties_occurrence_json`, `duties_my_assignment_json`, reminder checks, `duties_respond`, `duties_authorize_command` (command allowlist), `duties_command` (dispatch), `duties_in_scope`, `duties_erase_member`, `duties_deletion_remaining`.
- `supabase/migrations/20261008102121_notifications_scheduling.sql` -- `notifications_enqueue`, `notifications_cancel` (selector with optional `reminder_kind`).
- `supabase/migrations/20261008090057_notifications_source_contracts.sql` -- per-kind reminder checks (`contract_check_reminder`), link template rule.
- `supabase/tests/duties_tracer_test.sql` -- 4.1 pgTAP (its my-duties key assertion changes with the new keys); helpers to copy.
- `packages/client_core/lib/src/{domain/duties.dart, application/duties_controllers.dart, presentation/duties_screens.dart}` -- extend models, controller and screens; `presentation/shell_routing.dart` deep links.
- `tools/identity-e2e/duties.mjs` -- E2E template (worker credential, cleanup, psql).

## Tasks & Acceptance

**Execution:**
- [ ] `supabase/migrations/20261014090000_duties_revisions.sql` -- vocab widening, `duties_slot_revisions` (+ immutability trigger, backfill), assignment lifecycle columns, field classification, `duties.revise_duty`, respond refusal, new reminder kinds/checks, reads with history/changes, replaced dispatch/authorizer/deletion hook.
- [ ] `supabase/tests/duties_revisions_test.sql` (+ fix `duties_tracer_test.sql`, ledgers if needed) -- matrix.
- [ ] client_core domain/controller/screens/routing + `test/duties/duties_revisions_test.dart` -- leader Edit form and history; member Changed state, stale refusal, deep link from an old id.
- [ ] `tools/identity-e2e/duties-revisions.mjs` + `.test.mjs` -- local E2E of the verify.
- [ ] `docs/runbooks/duties.md` -- 4.2 section with owner manual checks.

**Acceptance Criteria:**
- Given the local stack, when the E2E runs, then a member accepts, the leader changes the time, a new pending revision appears with the old acceptance in history and its jobs cancelled, a late accept of the old revision is refused with what changed, a notes-only edit keeps Accepted, two concurrent edits give one success and one conflict, and a replay returns the original result.
- Given the full local verification, when run, then db:test, db:smoke, every E2E, contracts, offline tool tests, flutter analyze/test, secrets, migrations and function-imports pass.

## Implementation Notes

## Plan Change Log

## Review Triage Log

## Verification

**Commands:**
- `npx supabase db reset && npm run -s db:test && npm run -s db:smoke` -- expected: all pass
- `bash <scratchpad>/e2e-a71ad.sh` (every E2E incl. `duties` and `duties-revisions`) -- expected: each `exit=0`
- `npm run -s contracts:test && node --test tools/auth-harness/*.test.mjs tools/identity-e2e/*.test.mjs supabase/functions/*/*.test.mjs tools/identity-deletion/*.test.mjs tools/notifications/*.test.mjs` -- expected: pass
- `flutter analyze && flutter test` in `packages/client_core`, `apps/mobile`, `apps/staff` -- expected: pass
- `npm run -s ci:secrets && npm run -s ci:migrations -- --base origin/ccr-93e730dd-89lbvg && npm run -s ci:function-imports` -- expected: pass

---
title: 'Remind follow-up owners and supervisors on the task schedule'
type: 'feature'
ticket: '7'
created: '2026-10-14'
status: 'built'
baseline_revision: 'bf72e5d7fc7ee6a17a8a66e93312ec7d36bce19c'
route: 'full'
route_source: 'auto'
review: ''
review_source: ''
lenses_ran: []
review_loop_iteration: 0
context:
  - '{project-root}/docs/runbooks/follow-ups.md'
  - '{project-root}/docs/runbooks/contracts-and-owner-seams.md'
  - '{project-root}/docs/runbooks/notifications.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** Follow-up tasks (4.6) have owners, supervisors and deadlines but nobody is reminded: an owner does not hear of a new task, a deadline passes silently, a supervisor never learns a task is overdue, and nothing guarantees that a reassigned or finished task stops chasing anyone.

**Approach:** Follow-ups registers two reminder sources (owner `followups_task`: `followup_assigned`, `followup_due`; supervisor `followups_supervision`: `followup_overdue`) with fixed generic text and the deep link `/followups/tasks/{source_id}`, and schedules them through the 3.3 calculation inside its own commands (Notifications last): an assignment notice, reminders at the actionable deadline (due date, or review date while Waiting) from the creator's specs or the church default, and one supervisor alert a day after a missed deadline. Reassignment moves the owner's reminders, Done/Closed/closing source events cancel everything, and a source may register a purpose-specific schedule that replaces the generic one (proved with SYNTHETIC `synthetic_report_due`). The owner's Q4 answer on owner scope (task's own group plus Pastors) lands in the same forward migration.

**Decisions:**
- Decision (agent, under owner pre-approval): **revision.** The reminders' source revision is a new task column `schedule_revision`, moved only when the actionable deadline moves (into/out of Waiting, a new review date); notes, outcomes and Open <-> In progress never re-send. Past entries are never enqueued, so a supervisor is alerted once per deadline.
- Decision (agent, under owner pre-approval): **two sources** so an owner who is also the supervisor keeps both schedules (Notifications keeps one schedule per source and recipient).
- Decision (agent, under owner pre-approval): **creator reminders** are owner deadline reminders only (`reminders` on create and on the owner operation; null = church default, `[]` = none); the assignment notice and the one-day supervisor alert are fixed rules; reminders are not editable after creation in 4.7.
- Decision (agent, under owner pre-approval): **source-specific schedule** = `{owner, supervisor, on_assignment}` registered per purpose by the source's owner; it replaces the whole generic schedule and refuses creator reminders (`fixed_by_source`); it uses the generic Follow-ups kinds and text; it applies to existing tasks at their next re-plan.
- Decision (agent, under owner pre-approval): **no direct-contact route** in 4.7: an accountless or held owner's reminder is recorded `unrouted` (Reminder health) and the supervisor alert still follows (fail closed, like Duties 4.1 before 4.8).
- Decision (agent, under owner pre-approval): **no backfill** of tasks opened before 4.7 (scheduling needs the Q2 policy at migration time, which production lacks); they get reminders at their next deadline change, state change or reassignment.
- Owner decision (Q4 owner scope, 2026-10-14, relayed by the coordinator): "allow only from task's own group and pastor": owner candidates are the target's roster plus current Pastors (live, approved, not under deletion); nobody else, a former Pastor is refused; a Pastor owner gets only the owner's rights. The Q4 personal-data gate itself is unchanged.

## Boundaries & Constraints

**Always:** forward-only migration after 20261014110258 (`create or replace` keeps signatures and grants); ASCII, `search_path = ''`, no `\u`, no DROP/TRUNCATE/`delete from`; no new client grant; lock order Identity, receipt, task FOR UPDATE, Notifications last; reminder text and links generic (never next action, outcome, reason, context, names or notes); church time Africa/Lusaka, no quiet hours; production inert (Q4 gate, Q2 policy); SYNTHETIC data, pgTAP +44 7700 900360-900369, E2E 900370-900379.

**Never:** editing the 4.6 migration or any frozen block; a direct-contact route, lifecycle/handover hooks (entry 12) or real sources (entries 9, 11, epic 7); Edge Function changes; SMS; real people or numbers.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Assign | leader creates a task for M | jobs: assigned (now) + due (deadline) for M, overdue (deadline + 1 day) for L; worker delivers one item per key; open = current, link to the task | none |
| Missed deadline | deadline and the day after pass | M due reminder and exactly one L alert; re-plans add none | none |
| Waiting | owner sets / changes a review date | activity records it; due date kept; reminders and snoozes move (old items out of date) | none |
| Reassign | owner M -> O; supervisor L -> P | M's pending cancelled `reassigned`; O assigned + due; alert to P | stray old-owner job `ineligible` |
| Finish | Done, Closed, source resolved | nothing pending, nothing delivered | none |
| Creator reminders | `reminders` specs or `[]` | owner due jobs follow them | malformed `validation_failed {"reminders": "invalid"}` |
| Source schedule | purpose with a registered schedule | its owner/supervisor specs only, no notice | creator reminders `fixed_by_source` |
| Q4 owners | Pastor / non-Pastor outsider / former Pastor | Pastor accepted (owner rights only); others refused | `owner_member_id: not_in_scope` |

</frozen-after-approval>

## Code Map

- `supabase/migrations/20261014110258_followups_registry.sql` -- 4.6 owner (read-only): commands, owner operations, reads, `followups_scope_roster`, `followups_holds_scope`, `followups_overdue`.
- `supabase/migrations/20261008102121_notifications_scheduling.sql`, `20261008135811_notifications_routing.sql` -- `notifications_set_schedule` (task schedule type, `deadline` anchor, Waiting review date), `notifications_cancel` (ends schedules), `notifications_enqueue`, `notifications_reminders_error`, snooze.
- `supabase/migrations/20261008090057_notifications_source_contracts.sql` -- reminder contracts and the four-key check; `20261013220239_duties_department_tracer.sql` -- the Duties source/contract pattern.
- `packages/client_core/lib/src/{domain/followups.dart, presentation/followups_screens.dart, presentation/shell_routing.dart}`, `lib/testing.dart` -- client model, create form, task summary, `deepLinkTargets`, fakes.
- `tools/identity-e2e/duties.mjs` -- worker-script E2E pattern; `followups.mjs` -- 4.6 E2E (its cleanup gains Notifications rows).

## Tasks & Acceptance

**Execution:**
- [x] `supabase/migrations/20261014130535_followups_reminders.sql` -- columns, schedule registry, sources and contracts, scheduling helpers, replaced commands/owner operations/reads, Q4 roster, SYNTHETIC `synthetic_report_due` with its schedule.
- [x] `supabase/tests/followups_reminders_test.sql` (132, worker-driven) and `supabase/tests/followups_registry_test.sql` (three Q4 assertions) -- the matrix.
- [x] `packages/client_core` (domain reminders, create-form choice, summary line, deep link, Q4 refusal text, fake) + `test/followups/followups_reminders_test.dart`; `apps/mobile/test/mobile_app_test.dart`, `apps/staff/test/staff_app_test.dart` (reminder item opens the task).
- [x] `tools/identity-e2e/followups-reminders.mjs` + `.test.mjs`; `tools/identity-e2e/followups.mjs` cleanup.
- [x] `docs/runbooks/follow-ups.md` (story 4.7, owner checks, Q4 decided), `docs/runbooks/contracts-and-owner-seams.md`; 4.6 plan owner-decision entry.
- [x] `evidence-4.7/` and `.github/workflows/ci.yml` (evidence scan step, follow-ups tests under `TZ=America/New_York`).

**Acceptance Criteria:**
- Given the local stack, when `followups-reminders.mjs` runs through the real worker script, then every matrix row except the stray-job and Q4 former-Pastor cases (pgTAP) passes over HTTP, and every follow-up inbox item carries only its contract's generic text.
- Given the full local verification, when run, then every listed check passes.

## Implementation Notes

- Implemented directly (no implementation subagent inside this builder run).
- Server: `supabase/migrations/20261014130535_followups_reminders.sql`. New: `followups_tasks.schedule_revision` and `.reminders`, `app.followups_reminder_schedules`, `followups_reminder_specs_error`, `followups_reminders_field`, `followups_register_reminder_schedule`, `followups_reminder_source_check`, `followups_reminder_check`, `followups_cancel_reminders`, `followups_reminder_rules`, `followups_schedule_reminders`, `followups_reminders_json`. Replaced (same signatures, grants kept): `followups_scope_roster`, `followups_open_task`, `followups_source_event`, `followups_create_task`, `followups_update_task`, `followups_reassign`, `followups_task_json`, `followups_supervision`. No `_rows` file, no owner paste, no Edge Function change.
- Decision (agent, under owner pre-approval): an owner or supervisor who is no longer an active member gets no schedule (their pending reminders are cancelled `owner_inactive` / `no_supervisor_alert`), so an erased (nil) owner never makes a command fail.
- Decision (agent, under owner pre-approval): the SYNTHETIC source-specific purpose is not `manual_create`; it is opened through `app.followups_open_task` (pgTAP directly, E2E via SQL as the source's owner operation), so the 4.6 manual-purpose lists are unchanged.
- Decision (agent, under owner pre-approval): the supervisor alert's `actionable` also requires the task to be overdue now, so a deadline moved later never alerts early.
- Q4 owner decision: `app.followups_scope_roster` adds current Pastor-role holders; one function covers create, reassign (Admin too), the owner operation and both candidate lists. Three 4.6 pgTAP assertions changed accordingly (Pastor now a candidate; the outsider case uses a non-Pastor; Admin roster count 7).
- Clients: `FollowUpReminderSpec`, `FollowUpReminders`, `FollowUpReminderSchedule`, `followUpReminderChoices`, `FollowUpTask.reminders`, `FollowUpPurpose.fixedReminders`, `FollowUpDraft.reminders`; create form **Choose the owner's reminders**; summary line `followup-reminders-text`; `ClientPaths.deepLinkTargets` gains `/followups/tasks/<uuid>`; refusal texts for `not_in_scope` and `reminders`. `pumpStaff` in the staff test gained an optional `setUp`.
- E2E: `tools/identity-e2e/followups-reminders.mjs` (12 checks, R01-R90) with offline test; the 4.6 E2E cleanup now removes the Notifications rows its tasks create (otherwise member deletion hits the jobs/schedules foreign keys).
- Review amendments (2026-10-14, independent review of 4.7; the migration `20261014130535` was edited in place because it had not been merged or applied anywhere, as 4.6 did before its merge):
  - Decision (agent, under owner pre-approval, review B1): `followups_reassign` moves `schedule_revision` whenever the owner or the supervisor changes, and `followups_schedule_reminders` moves it first when a recipient whose schedule of the task ended at the current revision (reassigned away, `owner_inactive`) is active again. Avoids: M -> O -> M or L -> P -> L, or a returning owner, colliding with cancelled logical keys and silently getting nothing. Cost: a supervisor change re-keys the owner's future reminders too (a pending snooze of the owner is cancelled `source_revised`).
  - Decision (agent, under owner pre-approval, review S1): after re-planning the supervisor, if the current deadline's alert time has already passed and no `followup_overdue` for that deadline reached this supervisor (delivered at any revision with `scheduled_at` at or after the deadline, or pending at the current revision), one alert is enqueued now. A new supervisor of an already overdue task is told once; the old supervisor coming back is not told again.
  - Decision (agent, under owner pre-approval, review S2): `followups_require_open` and `followups_require_open_read` also need a valid Q2 policy (`followups_reminders_ready`, which never raises): every command, read and owner operation answers `unavailable {"policy": "gate_closed"}` / `403 unavailable` (non-retryable; the clients say "Not available yet") when Q4 or Q2 is closed. Gate prerequisite "Q4 approval requires Q2 approval" written in `follow-ups.md` and in `production-promotion-identity.md` section 6.
  - Decision (agent, under owner pre-approval, review S3): `followups_register_reminder_schedule` refuses `before` specs in the supervisor list (PCTR1).
  - Decision (agent, under owner pre-approval, review N1): a Pastor candidate needs live access too (`followups_pastor_live`: role, active reviewed link without an open hold, not dormant), and the Pastor grant is share-locked on create, open and reassign (`followups_lock_pastor`). The same check is NOT applied to the task's own group: accountless and held members stay valid owners there by design (4.6: the supervisor records for them).
  - Decision (agent, under owner pre-approval, review N2): `followups_clamp_specs` drops specs a narrower policy no longer allows (offset over `max_offset`, beyond `max_reminders`) at plan time; a creator's stored list is narrowed once, a source schedule on each re-plan; each narrowing is an activity row `reminders_adjusted` (code `policy_limit`, capacity `source`). Commands never fail for it.
  - Decision (agent, under owner pre-approval, review N4): no assignment notice to an owner who is the acting creator or reassigner (`p_actor`).
  - Review N5: the task screen speaks of the review date while Waiting (`labelFor`, `ownerText(waiting:)`, `supervisorText(waiting:)`).
  - Review N6: the client refusal tests now run through the real `SupabaseCommandGateway` over mock HTTP (the request path, Content-Profile and payload; `not_in_scope`, `fixed_by_source` and `unavailable gate_closed` mapped to their texts), plus a `SupabaseFollowUpsRepository.fetchTask` request/parse test and its 403 `unavailable` denial.
  - Review N7: the source and reminder checks answer `current: false` for a missing `source_revision` (never null).
  - Review N8: not changed. Setting `reminders` inside the insert would need a new signature for the 4.6 `followups_insert_task` (an overload, not a replacement), so it stays a same-transaction update right after the insert, before any scheduling.
  - Review N9: noted as reviewed; no code change in this pass.
  - Tests: `followups_reminders_test.sql` grows to 132 (B1 owner and supervisor round trips and the returning inactive owner, S1 both cases, S2 Q2 closed with Q4 open for commands, reads and the owner operation, S3, owner-is-supervisor with N4, N1 held Pastor, N2 narrower policy, N7).
- Matrix audit: Assign, Missed deadline, Waiting, Reassign, Finish, Creator reminders, Source schedule and Q4 are covered in pgTAP (`followups_reminders_test.sql`) and over HTTP (R10-R80); the stray old-owner job and the former Pastor are pgTAP only.

## Plan Change Log

- 2026-10-14, independent review of 4.7:
  - **B1 reassigning back dropped reminders.** Finding: M -> O -> M and L -> P -> L rebuilt jobs at the same `schedule_revision`, colliding with the cancelled keys. Amended: reassignment moves the revision; a returning recipient (also after inactivity) moves it before planning. KEEP: one alert per deadline.
  - **S1 past deadlines.** Finding: leaving Waiting onto a long-passed due date, or a new supervisor on an overdue task, got no alert. Amended: one alert now when the alert time passed and none for that deadline reached the supervisor.
  - **S2 gate order.** Finding: Q4 open with Q2 closed made commands fail as a retryable error. Amended: Follow-ups needs both gates (fail closed, `gate_closed`); runbooks state "Q4 approval requires Q2 approval".
  - **S3** supervisor `before` specs refused at registration. **S4** missing tests added.
  - **N1, N2, N4, N5, N6, N7** fixed; N8 and N9 noted (Implementation Notes).

- 2026-10-14, coordinator relayed the owner's Q4 answer mid-build ("allow only from task's own group and pastor"): added to this story's migration, tests (pgTAP, client, E2E R80), runbook and the 4.6 plan (dated owner-decision entry outside its frozen block). Avoids: editing the merged 4.6 migration.

## Review Triage Log

- 2026-10-14, independent review of 4.7: 1 blocker (B1), 4 should-fix (S1-S4), nits N1, N2, N4-N9. All fixed except N8 (not simple; see Implementation Notes) and N9 (noted); see the Change Log.

## Design Notes

- Generic schedule: owner `{intent: due_at, task_state, review_at?, reminders: creator specs or null}`, kinds `{"deadline": "followup_due"}`; supervisor same intent with `[{"anchor": "deadline", "after": "1 day"}]`, kinds `{"deadline": "followup_overdue"}`; notice `followup_assigned` enqueued now when the owner is new.
- Missing reports (epic 7) register `{"owner": [{deadline, before 0}, {deadline, after 2 days}], "supervisor": [], "on_assignment": false}` -- exactly the SYNTHETIC `synthetic_report_due`.

## Verification

**Commands:**
- `npx supabase db reset && npm run -s db:test && npm run -s db:smoke` -- expected: pass.
- `scratchpad/e2e-47.sh` (e2e-main.sh with `followups-reminders` appended) -- expected: each `exit=0`.
- `npm run -s contracts:test && node --test <CI set> && npm run -s ci:policy-test` -- expected: pass.
- `flutter analyze && flutter test` in `packages/client_core`, `apps/staff`, `apps/mobile`; `TZ=America/New_York` for `test/followups`, `test/duties` and mobile -- expected: pass.
- `npm run -s ci:secrets && npm run -s ci:migrations -- --base origin/main && npm run -s ci:function-imports`; `bash tools/auth-harness/scan-evidence.sh <evidence-4.7> tools/identity-e2e/followups-reminders.mjs docs/runbooks/follow-ups.md` -- expected: clean.

**Manual checks (if no CLI):**
- Parent session: apply the migration to staging after `20261014110258`, compare per-function md5, run `verify-hosted.sql`. No owner SQL paste, no Edge Function redeploy.
- Owner: `docs/runbooks/follow-ups.md`, "Owner manual checks (staging, phone and web, story 4.7)".

**Results (2026-10-14, after the review fixes B1, S1-S4, N1, N2, N4-N7):**
- db reset 0; db:test PASS (33 files, 2915 tests, including `followups_reminders_test.sql` 132 and `followups_registry_test.sql` 143); db:smoke pass (0 failures, no SMS provider).
- Every E2E `exit=0` (24 scripts, reset before each), `followups-reminders` 12/12, `followups` 15/15 (`evidence-4.7/e2e-suite-summary.txt`).
- contracts:test 242/0; node tool tests (CI set) 194/0; ci:policy-test 56/0.
- flutter analyze clean in all three; flutter test client_core 550 (follow-ups 34), apps/staff 37, apps/mobile 52; under `TZ=America/New_York` client_core `test/followups` + `test/duties` 122 and apps/mobile 52.
- ci:secrets clean; ci:migrations (`--base origin/main`) ordered, unique, non-destructive; ci:function-imports ok; evidence scan clean (evidence-4.7, the E2E tool, follow-ups and production-promotion runbooks). Migration ASCII, no `\u`, no DROP/TRUNCATE/`delete from`, no grants.
- Evidence: `evidence-4.7/followups-reminders-e2e.jsonl`, `evidence-4.7/e2e-suite-summary.txt`.
- Remaining (not builder steps): staging apply and md5 parity (parent session; no owner SQL paste; no Edge Function redeploy), staging client rebuild, owner manual checks in `docs/runbooks/follow-ups.md` story 4.7 (record in `evidence-4.7/owner-check.md`); production: approve `q2_church_time` before or with `q4_personal_data`.

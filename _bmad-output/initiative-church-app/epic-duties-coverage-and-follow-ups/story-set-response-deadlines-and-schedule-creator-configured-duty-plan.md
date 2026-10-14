---
title: 'Set response deadlines and schedule creator-configured duty reminders'
type: 'feature'
ticket: '8'
created: '2026-10-14'
status: 'built'
baseline_revision: '7f43e77de1340e40d2bb9dee6cd7d84070c27c98'
route: 'full'
route_source: 'auto'
review: ''
review_source: ''
lenses_ran: []
review_loop_iteration: 0
context:
  - '{project-root}/docs/runbooks/duties.md'
  - '{project-root}/docs/runbooks/contracts-and-owner-seams.md'
  - '{project-root}/docs/runbooks/notifications.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** Since 4.1 every duty needs a leader-typed answer-by, nothing reminds an assignee before it, a leader is never told that an answer is overdue or that a duty was given at short notice, and an accountless or held assignee's notices end `unrouted` in Reminder health instead of on the leader's list.

**Approach:** Duties stores each new assignment's deadline: the creator's, or the shared 3.3 lead-time default (`app.notifications_response_deadline`; Short notice when that has passed). Creators choose reminders per duty or per series (null = defaults). Every assignment gets a member schedule (`app.notifications_set_schedule`, Notifications last) and an overdue/short-notice alert for the department's leaders and deputies on a second source. Answers re-plan or cancel. A direct-contact route records held and accountless assignees' needs for the leader's Needs contact list.

**Decisions:**
- Decision (agent, under owner pre-approval): **deadline**. `response_deadline` stays optional everywhere (publish_duty, assign_slot, revise_duty, `deadline_before` of publish_drafts and revise_series); absent = the 3.3 band default for that assignment at the moment it is created (assigned now, anchored on the reporting time or start). Creator deadlines keep the 4.1-4.3 checks (past/after_start/passed refused). The default is stored (`deadline_source` `default`) and always passed to Notifications explicitly, so a later policy re-plan never moves a stored deadline.
- Decision (agent, under owner pre-approval): **Short notice** = a default deadline that had already passed when the assignment was made: stored deadline = that moment, `short_notice` true. The member's new-duty or changed notice is the "respond now" message (one item, merged per the FR); the leaders get one `duty_short_notice` alert now and the assignment shows **Short notice** with a direct-contact flag.
- Decision (agent, under owner pre-approval): **member reminders** use the 3.3 response anchors: `response_deadline` and `starts_at` (reporting or start). Defaults when the creator sets none: the policy's response defaults (24 hours before and at the deadline) plus one pre-service reminder 24 hours before reporting or start (`app.duties_default_reminders`, adjustable in one function; specs over the policy's limits are dropped, never an error). `[]` means no member reminders. Response reminders stop on accept or decline; accepted keeps pre-service reminders; decline stops everything.
- Decision (agent, under owner pre-approval): **leader alerts** are fixed rules, not creator options: `duty_response_overdue` at the deadline and `duty_short_notice` now, to each current department leader and deputy (not the assignee), each recipient re-checked at delivery (still manages the department, answer still pending). A (re)plan of an unanswered assignment whose deadline has passed and whose leaders have no alert yet enqueues one now (the 4.7 S1 lesson).
- Decision (agent, under owner pre-approval): **configuring** reminders: `reminders` on publish_duty and create_series (the series value is copied to every generated date), and `duties.set_reminders` for one date (`occurrence_id`) or a series from a date onwards (`series_id`, `from_occurrence_id`), re-planning current assignments without asking anyone again.
- Decision (agent, under owner pre-approval): **Needs contact** = a Duties list (`app.duties_contact_needs`, idempotent on the need id, keyed to the assignment) fed by the direct-contact route of every member kind; the leader board shows an assignment as needing contact while a need of its current revision is still relevant, or while it is Short notice and unanswered. The need never says why (no hold disclosed). Contact attempts and confirmation stay entry 9.
- Decision (agent, under owner pre-approval): **fresh keys**: every new assignment (also A -> B -> A) is a new source id, so returning recipients never collide with cancelled logical keys; the leader source is keyed by the same assignment id.

## Boundaries & Constraints

**Always:** forward-only migration after 20261014130535 (`create or replace` keeps signatures and grants; every replaced body keeps the 4.1-4.5 review fixes); ASCII, `search_path = ''`, no backslashes, no DROP/TRUNCATE/`delete from`; no anon grant, no new client grant (both new commands go through `api.duties_command`); AD-2 lock order with Notifications last; reminder text generic; Africa/Lusaka, no quiet hours; production inert (Q2 and Q4 gates); SYNTHETIC data, pgTAP +44 7700 900650-900669, E2E 900670-900689.

**Never:** editing merged migrations or any frozen block; coverage queue, contact attempts or leader confirmation (entry 9); lifecycle hooks (entry 12); Edge Function changes; SMS; quiet hours.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Quarterly rota | publish drafts 30+ days ahead, no lead | deadline start - 14 days (`default`); jobs: notice, due -24 h and at deadline, starting -24 h; leaders' overdue at deadline | none |
| Mid-week for Sunday | assigned 3-30 days ahead | deadline start - 48 h | none |
| Same day | default passed | Short notice: one member notice, leaders' short-notice alert now, no overdue | none |
| Creator | deadline and reminders | stored as given (`creator`); jobs follow the specs | bad specs `{"reminders": "invalid"\|"out_of_range"}` |
| Accept / decline | member answers | accept: response and leader jobs cancelled, pre-service kept; decline: all cancelled | none |
| Reassign / cancel | A -> B -> A; cancel date | old jobs cancelled, each new assignment fresh jobs; cancelled: nothing pending | stray old job `obsolete` |
| Held / accountless | worker runs | no inbox item; need on the leader's Needs contact | none |
| Snooze | member snoozes a due reminder | delivered later; stops on answer | none |

</frozen-after-approval>

## Code Map

- `supabase/migrations/20261014052239_duties_overlaps.sql` -- latest `duties_apply_change` (deadline required at line ~546), `duties_publish_duty`, `duties_publish_drafts`, `duties_revise_duty`, `duties_revise_series` (passes null lead; no replacement needed), `duties_assign_slot` (passes null deadline; no replacement needed), `duties_cancel_one`.
- `supabase/migrations/20261014081513_duties_member_responses.sql` -- latest `duties_respond`, `duties_withdraw_acceptance`, `duties_accept_many`, history guard, dispatcher/authorizer, `duties_my_assignment_json`, 3-arg `duties_occurrence_json`, `duties_rota_occurrence_json`.
- `supabase/migrations/20261014023442_duties_rota_series.sql` -- `duties_notify` (the ops runner every change uses), `duties_create_series`, `duties_lock_occurrence`, `duties_lock_series`, `duties_in_scope`.
- `supabase/migrations/20261013220239_duties_department_tracer.sql`, `20261014001142_duties_revisions.sql` -- reminder checks (`duties_assignment_reminder_check` = pending; `duties_update_reminder_check` = not declined), contracts.
- `supabase/migrations/20261008102121_notifications_scheduling.sql`, `20261008135811_notifications_routing.sql` -- `notifications_response_deadline`, `notifications_plan`, `notifications_set_schedule`, `notifications_cancel` (ends schedules), `contract_register_direct_contact_route`.
- `packages/client_core/lib/src/domain/duties.dart`, `presentation/duties_screens.dart`, `presentation/duties_rota_screens.dart` -- models, publish form, board, rota, My duties.

## Tasks & Acceptance

**Execution:**
- [x] `supabase/migrations/20261014153012_duties_reminders.sql` -- columns, sources/kinds/contracts/route, deadline and plan helpers, replaced commands/engine/projections, `duties.set_reminders`, create_series wrapper.
- [x] `supabase/tests/duties_reminders_test.sql` (+ earlier duties tests where job counts change) -- the matrix through the worker.
- [x] `packages/client_core` (domain, publish/rota forms, Short notice, Needs contact, set reminders) + `test/duties/duties_reminders_test.dart`; app tests.
- [x] `tools/identity-e2e/duties-reminders.mjs` + `.test.mjs`.
- [x] `docs/runbooks/duties.md` (story 4.8, owner checks), `contracts-and-owner-seams.md`.
- [x] `evidence-4.8/`, `.github/workflows/ci.yml` evidence scan step.

**Acceptance Criteria:**
- Given the local stack, when `duties-reminders.mjs` runs through the real worker script, then every matrix row passes over HTTP and every duty inbox item carries only its contract's generic text.
- Given the full local verification, when run, then every listed check passes.

## Implementation Notes

- Implemented directly (no implementation subagent inside this builder run).
- Server: `supabase/migrations/20261014153012_duties_reminders.sql` (2340 lines at first build, 2708 after the review fixes; no backslashes, ASCII, no DROP/TRUNCATE/`delete from`, no grants).
  - New columns: `duties_assignments.deadline_source` (`creator` | `default`, existing rows `creator`) and `.short_notice` (check: only with a default deadline); `duties_occurrences.reminders`, `duties_series.reminders` (null = defaults). New table `app.duties_contact_needs` (RLS on, no client privileges; FK to the assignment `on delete cascade`, so the earlier E2E/owner clean-ups that delete assignments keep working).
  - New source `duties_coverage` (check `duties_coverage_source_check`), kinds `duty_response_due`, `duty_starting` (on `duties_assignment`, reusing the 4.1 pending check and the 4.2 not-declined check), `duty_response_overdue`, `duty_short_notice` (on `duties_coverage`, `duties_coverage_reminder_check`); the direct-contact route `duties_record_contact_need` for the seven member kinds.
  - New functions: `duties_reminders_field`, `duties_default_reminders`, `duties_reminder_specs`, `duties_default_deadline`, `duties_alert_recipients`, `duties_needs_contact`, `duties_plan_reminders`, `duties_after_answer`, `duties_set_reminders`, `duties_create_series_with_reminders`, plus the three checks and the route handler; all revoked from public, anon, authenticated, service_role.
  - Replaced (latest body copied, changes marked "Story 4.8"; a body-by-body diff against the previous version shows only those lines): `duties_state_ok` (4.5), `duties_assignment_history_guard` (4.5), `duties_notify` (4.3), `duties_apply_change` (4.4), `duties_publish_duty` (4.4), `duties_publish_drafts` (4.4), `duties_revise_duty` (4.4), `duties_respond` (4.5), `duties_withdraw_acceptance` (4.5), `duties_accept_many` (4.5), `duties_authorize_command` (4.5), `duties_command` (4.5), `duties_my_assignment_json` (4.5), `duties_occurrence_json` 3-arg (4.5), `duties_rota_occurrence_json` (4.5). `duties_assign_slot` and `duties_revise_series` are not replaced: they already pass a null deadline to the change engine, which now applies the default.
- Decision (agent, under owner pre-approval): the deadline default is computed by the shared `app.notifications_response_deadline` with the assignment made now; the stored deadline (default included) is always sent to Notifications as the intent's `response_deadline`, so `notifications_replan_all` never moves a Duties deadline.
- Decision (agent, under owner pre-approval): the member's "respond now" on Short notice is the notice the command queued (`kinds.respond_now` = `duty_assigned` / `duty_changed`, same logical key as the notice, so one item). Without a notice (erased member) nobody is planned.
- Decision (agent, under owner pre-approval): an answer keeps the 4.1-4.5 blanket cancel (`responded`), then `duties_after_answer` ends the leaders' alerts and, for an acceptance, plans the pre-service reminders at the new revision. ~~Because that plan needs the Q2 policy, an acceptance now needs Q2 like publishing does.~~ Superseded by review item 4 (below): the answer is always recorded.
- Decision (agent, under owner pre-approval): `reminders` on `create_series` goes through a wrapper (`duties_create_series_with_reminders`) that validates the field, calls the unchanged 4.3 command without it and copies the value to the series and its dates; a malformed list is refused before the series is checked (one error set).
- Decision (agent, under owner pre-approval): leader recipients are chosen at plan time (current leader and deputy grants of the department, live members, not the assignee) and rechecked at delivery; a leader granted later is alerted from the next re-plan (`duties.set_reminders`). Admins and Pastors get no alert. Cell-owned occurrences are not planned (entry 11).
- Decision (agent, under owner pre-approval): the S1 lesson: a non-fresh plan of an unanswered assignment whose deadline has passed enqueues one `duty_response_overdue` now for each leader with no live alert at the revision. The B1 lesson needs no revision counter here: every new assignment is a new source id (pgTAP and E2E prove A -> B -> A).
- Decision (agent, under owner pre-approval): Needs contact lists the current assignee only (short notice while pending; `not_reached` while a need of the current revision is still relevant). ~~Released/cancelled needs are recorded, not listed.~~ Superseded by review item 3 (below). No reason is ever shown.
- Earlier tests changed for the new behaviour (no merged migration edited): `duties_tracer_test.sql` (a missing deadline now takes the default: the refusal case uses a malformed one; the accountless notice is now `direct_contact`; job queries filter notices; 4.8 keys excluded from the 4.1 key list), `duties_revisions_test.sql` (two malformed-deadline cases instead of missing ones; notice-only job helper; 4.8 keys excluded), `duties_rota_test.sql` (two malformed lead/deadline cases; notice-only job helper), `duties_overlaps_test.sql` and `duties_responses_test.sql` (notice-only job queries). Client: `duties_revisions_test.dart` (a material change saves without a new answer-by; `/duties/leader` is now a deep-link target).
- The 4.1-4.5 E2E clean-ups (`duties.mjs`, `duties-revisions.mjs`, `duties-rota.mjs`, `duties-overlaps.mjs`, `duties-responses.mjs`) now delete the Notifications schedules and Needs contact rows their duties create (otherwise member deletion hits the schedules' foreign key).
- Clients: `DutyDeadlineSource`, `DutyReminderAnchor`, `DutyReminderSpec`, `dutyReminderChoices`, `DutyReminders`, `DutyContactNeed`, `DutyCommands.setReminders`, `DutyLeads.churchDefault`; `MyDuty`/`PositionAssignment`/`RotaAssignment` gain deadline source, Short notice and (leaders) Needs contact; `LeaderDuty`/`RotaOccurrence` gain reminders; `DutyDraft.responseDeadline` optional and `reminders`; `SeriesDraft.reminders`; controllers `setReminders`, `setSeriesReminders`, `publishDrafts(lead?)`; notice `remindersSet`. New part file `duties_reminder_widgets.dart` (`_ReminderChoice`, `_RemindersEditor`, `_contactFlags`, `_NeedsContactList`). `testing.dart` `myDutyData(extra:)`.
- E2E: `tools/identity-e2e/duties-reminders.mjs` (15 checks, D01-D90) with offline test; `duties-revisions.mjs` job summary limited to notice kinds (its R12 otherwise lists the 4.8 reminders).
- Matrix audit: Quarterly rota (pgTAP 14-day/48-hour bands; E2E D11), Mid-week (pgTAP; D10), Same day (pgTAP incl. a short-notice change; D12), Creator (pgTAP incl. refusals; D20), Accept / decline (pgTAP incl. later decline and bulk; D30, D31), Reassign / cancel (pgTAP A -> B -> A and cancel; D40, D41; the stray old job is covered by the global no-stale assertion), Held / accountless (pgTAP; D50), Snooze (pgTAP; D60). No quiet hours: pgTAP and D70. All ran and passed.
- Review amendments (2026-10-14, independent review; the migration was unmerged and unapplied, so it was edited in place; see the Plan Change Log):
  - Decision (agent, review 1): the Q2 policy is validated once per transaction. `app.notifications_zone_known(text)` remembers a checked zone in a transaction-local setting (pg_timezone_names cost about 53 ms a call); `app.notifications_policy_errors` uses it; `app.notifications_policy()` remembers the validated policy keyed by the md5 of `policy_effective('q2_church_time')`, so a policy change in the same transaction is seen. Leader alerts are single enqueued jobs instead of a Notifications schedule per leader. Timings (local, `duties_reminders_scale_test.sql` under `statement_timeout = '8s'`): before, 26 slots 16.7 s and about 200 slots 125 s, `accept_many` of 14 dates 1.95 s; after, 26 slots 0.5 s, 200 slots 3.7-4.5 s, `accept_many` of 50 dates 0.45-0.65 s. The 4.7 Follow-ups tests are unchanged and pass.
  - Decision (agent, review 1): the scale test locks its tables in SHARE UPDATE EXCLUSIVE mode so an autovacuum ANALYZE cannot record them as empty while they hold only its uncommitted rows (measured 12-44 s for 200 slots in the full suite before the lock; never alone). A populated database has real statistics.
  - Decision (agent, review 2): leader alert recipients must be reachable in the app (`app.duties_leader_reachable`: `notifications_recipient_route` is `member`); a held or in-review leader is not chosen and an alert queued before a hold is refused at delivery (`recipient_ineligible`, never an unrouted need).
  - Decision (agent, review 3): released and cancelled notices for members the app cannot reach are listed for the department's leaders, deputies and Admins (`app.duties_contact_notices`, `contact_notices` on `api.duties_leader_board`; empty for Pastor oversight) until the old start, never with a reason; `duties_leader_board` (4.4 body) replaced to add it.
  - Decision (agent, review 4): an answer (respond, withdraw, accept_many) succeeds with Q2 closed or invalid: `duties_after_answer` catches the policy's `unavailable` refusal, skips the re-plan and audits `reminders_skipped` / `policy_unavailable` (`duties_state_ok` vocabulary extended). The answer has already cancelled the reminders and alerts.
  - Decision (agent, review 5): a default deadline that leaves less than one hour after the assignment is Short notice (deadline = now); a creator answer-by time equal to the start or reporting time is `after_start`; a lead of zero is `out_of_range`.
  - Decision (agent, review 6): before the member answers, a start-anchored reminder is sent as `duty_response_due` (asks for the answer); `duty_starting` only after an acceptance. Clients: the reminders editor stays open with the field error until the server accepts; Cancel resets; stored specs outside the choices show as "(custom)" and are kept; rota answer-by pickers start at the church default; "before the reporting time" when the duty has one.
  - Review 7: pgTAP adds a material `revise_series` with no stale jobs, the opened item's exact contract text (replacing the near-tautological contract count), deadline edges, held deputy, contact notices and Q2-invalid answers; the E2E adds `set_reminders` racing `accept_many` (3 rounds, both succeed, consistent, no deadlock) and S1 driven by the real clock (a creator deadline 75 s ahead passes, a new deputy is granted, `set_reminders` re-plans, the deputy gets one overdue alert).
  - Review 8: no back-fill; the runbook says staging duties published before 4.8 get reminders only after their next change.
- Open owner questions: none blocking. The deadline bands and the 24-hour pre-service default are the agent's reading of Q2 (ticket `unknown`); the owner may change the bands in the `q2_church_time` value and the pre-service default in `app.duties_default_reminders`.

## Plan Change Log

- 2026-10-14 (review): migration `20261014153012_duties_reminders.sql` amended in place (unmerged, unapplied): per-transaction policy memo (`notifications_zone_known`, replaced `notifications_policy_errors` and `notifications_policy`), leader alerts as single jobs, reachable leaders only, released/cancelled contact notices (`duties_contact_notices`, replaced `duties_leader_board`), answers recorded with Q2 unavailable, one-hour minimum answer window and start-equal refusal, pending pre-service reminders as `duty_response_due`, zero lead refused (`duties_lead`). Intent and the I/O matrix are unchanged. Superseded earlier decisions are struck through in Implementation Notes.

## Review Triage Log

- 2026-10-14 independent review (probes in the coordinator's scratchpad `rv48/`): 1 blocker (policy validation cost; fixed, timings above), 2 held leaders alerted (fixed), 3 released/cancelled not listed (fixed), 4 acceptance needed Q2 (fixed), 5 default deadline minutes after assignment and start-equal deadline (fixed), 6 client nits (fixed), 7 test gaps (added), 8 no back-fill (documented). All accepted; none deferred.

## Verification

**Commands:**
- `npx supabase db reset && npm run -s db:test && npm run -s db:smoke` -- expected: pass.
- e2e-main.sh with `duties-reminders` appended -- expected: each `exit=0`.
- `npm run -s contracts:test && node --test <CI set> && npm run -s ci:policy-test` -- expected: pass.
- `flutter analyze && flutter test` in `packages/client_core`, `apps/staff`, `apps/mobile`; `TZ=America/New_York` for `test/duties` and mobile -- expected: pass.
- `npm run -s ci:secrets && npm run -s ci:migrations -- --base origin/main && npm run -s ci:function-imports`; evidence scan -- expected: clean.

**Results after the review fixes (2026-10-14):**
- db reset 0; db:test PASS (35 files, 3053 tests; `duties_reminders_test.sql` 135, `duties_reminders_scale_test.sql` 8 with timings publish 26 = 0.6 s, publish 200 = 4.5 s, accept 50 = 0.57 s under `statement_timeout = '8s'`; the 4.7 Follow-ups files unchanged and passing); db:smoke pass (no SMS provider).
- Every E2E `exit=0` (25 scripts, reset before each; `duties-reminders` 17/17 incl. D82 race and D85 S1; `followups` 15/15 and `followups-reminders` 12/12 unchanged) (`evidence-4.8/e2e-suite-summary.txt`).
- contracts:test 242/0; node tool tests (CI set) 200/0; ci:policy-test 56/0.
- flutter analyze clean in client_core, apps/staff, apps/mobile; flutter test client_core 567 (also under `TZ=America/New_York`), apps/staff 38, apps/mobile 53.
- ci:secrets clean; ci:migrations (`--base origin/main`) ordered, unique, non-destructive; ci:function-imports ok; migration 2708 lines, ASCII, no backslashes, no DROP/TRUNCATE/`delete from`; evidence scan clean.

**Results at first build (2026-10-14, superseded):**
- db reset 0; db:test PASS (34 files, 3018 tests, including `duties_reminders_test.sql` 103); db:smoke pass (0 failures, no SMS provider).
- Every E2E `exit=0` (25 scripts, reset before each; `duties-reminders` 15/15; `duties-revisions` 13/13 after its helper fix) (`evidence-4.8/e2e-suite-summary.txt`).
- contracts:test 242/0; node tool tests (CI set) 200/0; ci:policy-test 56/0.
- flutter analyze clean in client_core, apps/staff, apps/mobile; flutter test client_core 564 (`test/duties/duties_reminders_test.dart` 14), apps/staff 38, apps/mobile 53; under `TZ=America/New_York` client_core `test/duties` + `test/followups` 136 and apps/mobile 53.
- ci:secrets clean; ci:migrations (`--base origin/main`) ordered, unique, non-destructive; ci:function-imports ok; evidence scan clean (evidence-4.8, the E2E tool, duties and seams runbooks).
- Remaining (not builder steps): staging apply of `20261014153012_duties_reminders.sql` and per-function md5 parity (parent; no owner SQL paste; no Edge Function redeploy), staging staff web and APK rebuild, owner manual checks in `docs/runbooks/duties.md` story 4.8 (record in `evidence-4.8/owner-check.md`).

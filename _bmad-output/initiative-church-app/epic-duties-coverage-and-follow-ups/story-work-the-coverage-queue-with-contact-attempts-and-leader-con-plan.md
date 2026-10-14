---
title: 'Work the coverage queue with contact attempts and leader confirmation'
type: 'feature'
ticket: '9'
created: '2026-10-14'
status: 'built'
baseline_revision: 'a7ab3e2d220ee70971233977be60281c3025447b'
route: 'full'
route_source: 'auto'
review: ''
review_source: ''
lenses_ran: []
review_loop_iteration: 0
context:
  - '{project-root}/docs/runbooks/duties.md'
  - '{project-root}/docs/runbooks/follow-ups.md'
  - '{project-root}/docs/runbooks/identity-access.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** Since 4.8 a leader sees answers, Short notice and Needs contact on the board, but has no scoped queue of what needs attention, cannot see a permitted contact route, cannot record a contact attempt or a phone confirmation (an accountless member can never be confirmed), is not told when a member declines, cannot cancel one position, and Pastor has no church-wide view of gaps. Follow-ups has no real source yet.

**Approach:** One Duties read (`api.duties_coverage`) gives the scoped queue (next seven church days by default, date and duty filters) with per-department counts; three commands through `api.duties_command` record a contact attempt (opening or updating a Follow-ups task through the owner seams), record **Confirmed by leader**, and cancel a position; reassignment reuses `duties.assign_slot`. A coverage case per assignment ties the attempts to one Follow-ups task that closes with the assignment. Contact routes come only from a new scoped Identity read behind the Q4 gate. Staff web and mobile get the queue screen; mobile Home gets the leader's Needs attention card.

**Decisions:**
- Decision (agent, under owner pre-approval): **who.** The queue's full view (contact routes, attempt notes, confirmation reasons, response notes) is for the department's current leaders and deputies only. Admin (role alone) and Pastor see an operational view of every department: positions, states, names, deadlines, counts, never a contact route or free text. Contact attempts and leader confirmation are for leaders and deputies only (they own the Follow-ups task; an Admin is not in the task's group); reassign and cancel position also for Admins (as in 4.3). Anyone else `403 not_granted`.
- Decision (agent, under owner pre-approval): **queue states** per position of a published, not yet started occurrence in the window: `unfilled` (no current assignment), `confirmed` (accepted by the member or by a leader), `declined`, `overdue` (pending, deadline passed), `changed` (pending re-ask of the same member after a material change), `awaiting`; `needs_contact` is the 4.8 flag. Filters: All, Unfilled, Overdue, Declined (declined and changed), Awaiting, Needs contact, Confirmed. Window: church dates, default today + 6 days, at most 31 days; duty filter = case-insensitive name match. At most 1000 positions (`truncated`).
- Decision (agent, under owner pre-approval): **contact routes** are the 2.5 labelled routes only (`app.identity_contact_routes`, never a phone username), through `app.identity_scoped_contact_routes` (owner Identity): the Q4 gate (`identity_applications_open`), the viewer must hold the department scope, and while `q4_personal_data` is not approved only SYNTHETIC routes are returned. Clients open the phone or messaging app (`tel:` / `sms:`); nothing is sent automatically.
- Decision (agent, under owner pre-approval): **contact attempt** `duties.record_contact_attempt {assignment_id, channel, outcome, note?, next_follow_up_at}` (expected = assignment revision) on a current pending or declined assignment of a published duty that has not started. Channels `phone|message|in_person|other`; outcomes `no_answer|left_message|will_answer|cannot_serve|other`; note 1-280 practical characters (shown to the department's leaders and deputies only); next follow-up in the future, before the (reporting) start, at most a year away. The first attempt opens a coverage case and a Follow-ups task (source `duties_coverage_case`, purpose `coverage_follow_up`, owner and supervisor = the recording leader, scope = their department scope, due = next follow-up); later attempts on the open case set that task Waiting with the next follow-up as review date and the outcome (new Follow-ups owner operation `app.followups_source_review`). The task closes (`source_resolved`) when the assignment is accepted, confirmed or superseded, and (`source_cancelled`) when it is cancelled; a later need opens a fresh case and task (fresh keys).
- Decision (agent, under owner pre-approval): **Confirmed by leader** `duties.confirm_by_leader {assignment_id, channel, reason}` (expected = assignment revision) on a current **pending** assignment only (a decline is reassigned): response accepted with provenance `leader`, the leader as actor, the time, the channel and a required reason (1-200); shown everywhere as "Confirmed by leader", never as the member's own acceptance; the member cannot withdraw it (4.5 rule). Response reminders and leader alerts stop, the pre-service reminder is planned, the case and task close.
- Decision (agent, under owner pre-approval): **position cancellation** `duties.cancel_position {slot_id}` (expected = occurrence revision) on a published duty that has not started: the last remaining position cancels the whole occurrence (also a one-off duty, which 4.3 could not cancel); otherwise the slot is marked cancelled, its assignment ends `cancelled` with the 4.3 notice, and it no longer counts as required.
- Decision (agent, under owner pre-approval): **decline alert** `duty_declined` on `duties_coverage` to each reachable current leader and deputy (never the assignee; held or in-review leaders skipped and refused at delivery) when a member declines or withdraws; keyed by the assignment and its new revision, so every decline is a fresh key; delivered while the assignment is current, declined and not started; it opens `/duties/coverage`.
- Decision (agent, under owner pre-approval): **gates.** Every command and read stays behind Q4 (production inert). With Q2 closed or invalid, a confirmation and a contact attempt are still recorded: the Follow-ups step and the re-plan are skipped and audited (`followup_skipped` / `reminders_skipped`, code `policy_unavailable`), as 4.8 decided for answers.
- Decision (agent, under owner pre-approval): **lock order** grants -> receipt -> department -> series -> occurrence -> slot -> assignment -> coverage case -> Follow-ups -> Notifications.

## Boundaries & Constraints

**Always:** forward-only migration after 20261014171038; replaced bodies copied from their latest version with every earlier review fix; ASCII, `search_path = ''`, no backslashes, no DROP/TRUNCATE/`delete from`; no anon grant; new client grant only `api.duties_coverage` and its `app` body; set-based reads (no per-row expensive calls), timing test under `statement_timeout = '8s'`; reminder text generic; SYNTHETIC data, pgTAP +44 7700 900780-900789, E2E 900790-900799.

**Never:** editing merged migrations or frozen blocks; completion outcomes (entry 10), lifecycle hooks (12), cell-owned coverage (11); SMS or automatic messages; showing a hold or deletion reason; Edge Function changes.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Queue | rota with unanswered app member, accountless member, decline, empty slot | each position in its state; counts; leader sees the accountless member's labelled route | Pastor/Admin: no route, no notes; other leader: 403 |
| Contact attempt | first, then second | case + task opened (due = next follow-up), then task Waiting (review date) | started/accepted/unknown refused; Q2 closed: attempt kept, task skipped |
| Confirm by phone | accountless pending | accepted, provenance leader, channel, reason; reminders and alerts stop; task closed | no reason / declined / not leader refused |
| Reassign the decline | assign_slot to another member | old assignment superseded, its reminders and alerts cancelled, task closed | overlap gate as 4.4 |
| Cancel position | multi or single position | slot cancelled (or occurrence) with notice; not required | draft/started/cancelled refused |
| Decline | member declines | one `duty_declined` per reachable leader, fresh key each decline | held leader skipped |

</frozen-after-approval>

## Code Map

- `supabase/migrations/20261014171038_duties_reminders.sql` -- latest `duties_state_ok`, `duties_assignment_history_guard`, `duties_notify`, `duties_apply_change`, `duties_respond`, `duties_accept_many`, `duties_after_answer`, `duties_authorize_command`, `duties_command`, `duties_my_assignment_json`, 3-arg `duties_occurrence_json`, `duties_rota_occurrence_json`; `duties_alert_recipients`, `duties_leader_reachable`, `duties_needs_contact`, `duties_coverage_*` checks (reuse).
- `supabase/migrations/20261014052239_duties_overlaps.sql` -- latest `duties_cancel_one`, `duties_assign_slot`, `duties_overlap_counts`, `duties_erase_member`, `duties_deletion_remaining`.
- `supabase/migrations/20261014023442_duties_rota_series.sql` -- `duties_in_scope` (occurrence aggregates for leader commands), `duties_lock_occurrence`.
- `supabase/migrations/20261014130535_followups_reminders.sql`, `20261014110258_followups_registry.sql` -- `followups_open_task`, `followups_source_event`, `followups_schedule_reminders`, `followups_activity_event`, `followups_register_purpose`, `followups_require_open`.
- `supabase/migrations/20261007063340_membership_review.sql` -- `app.identity_contact_routes` (labelled 2.5 routes).
- `packages/client_core/lib/src/{domain,application,adapters,presentation}/duties*` -- models, `DutiesController`, `_DutiesPage`, `_CandidatePicker`, `MemberHomeScreen`; `shell_routing.dart` routes and deep-link targets.

## Tasks & Acceptance

**Execution:**
- [x] `supabase/migrations/20261014201500_duties_coverage.sql` -- tables, vocabularies, Identity read, Follow-ups purpose and review seam, commands, hooks, queue read, replaced bodies.
- [x] `supabase/tests/duties_coverage_test.sql`, `duties_coverage_scale_test.sql`, privilege ledger -- the matrix, privacy, gates, timing.
- [x] `packages/client_core` coverage domain, repository port and adapter, controller, screens (queue, actions, Home card), routes; tests; apps (nav, url launcher port).
- [x] `tools/identity-e2e/duties-coverage.mjs` + `.test.mjs`.
- [x] `docs/runbooks/duties.md`, `follow-ups.md`; `evidence-4.9/`; CI evidence step.

**Acceptance Criteria:**
- Given the local stack, when `duties-coverage.mjs` runs, then the ticket's verify line passes over HTTP (attempt, phone confirmation, reassignment, task opened and closed, reminders cancelled, other leader and Admin see nothing private).
- Given the full local verification, when run, then every listed check passes.

## Implementation Notes

- Implemented directly (no implementation subagent inside this builder run), as 4.1-4.8.
- Server: `supabase/migrations/20261014201500_duties_coverage.sql` (ASCII, no backslashes, no DROP/TRUNCATE/`delete from`, `search_path = ''` everywhere; new functions revoked from public, anon, authenticated and service_role; one client grant: `api.duties_coverage` / `app.duties_coverage` to authenticated).
  - New: `duties_slots.cancelled_at/_by_member/_by_account`; `duties_assignments.confirmed_channel/confirmed_reason` (constraint `duties_assignments_leader_confirmed`: provenance `leader` iff a channel, only on an acceptance); tables `app.duties_coverage_cases` (one open case per assignment, partial unique index) and `app.duties_contact_attempts` (immutable except erasure, trigger `duties_contact_attempt_guard`; `recorded_at` defaults to `clock_timestamp()` so attempts in one transaction keep their order), both RLS on, no client privilege, FK to the assignment `on delete cascade` (so the earlier E2E clean-ups keep working).
  - Identity: `app.identity_scoped_contact_routes(viewer, scope_kind, scope_id, member_ids)` (labelled 2.5 routes; Q4 gate; viewer must hold the scope; SYNTHETIC routes only until `q4_personal_data` is approved; never phone usernames or reasons).
  - Follow-ups: owner operation `app.followups_source_review` (task Waiting with a review date and outcome, activity capacity `source`, reminders re-planned through `followups_schedule_reminders`). No Follow-ups body is replaced.
  - Sources and contracts: source type `duties_coverage_case` with purpose `coverage_follow_up` (registered with `followups_register_purpose`, context hook `duties_coverage_case_context`); reminder kind `duty_declined` on `duties_coverage` (check `duties_decline_alert_check`, link `/duties/coverage`).
  - New functions: `duties_close_cases`, `duties_lock_for_leader`, `duties_code`, the commands `duties_record_contact_attempt`, `duties_confirm_by_leader`, `duties_cancel_position`, and the read `duties_coverage`.
  - Replaced bodies (copied from their latest versions; every earlier review fix kept; changes marked "Story 4.9"): from `20261014171038` (4.8): `duties_state_ok`, `duties_assignment_history_guard`, `duties_plan_reminders` (the re-plan only cancels overdue/short-notice alerts, never a decline alert), `duties_after_answer` (decline alert; audit capacity of the actor), `duties_notify` (closes coverage cases of cancelled assignments first: Follow-ups before Notifications), `duties_apply_change` (skips cancelled positions, refuses a cancelled target), `duties_respond` and `duties_accept_many` (an acceptance closes the case before Notifications), `duties_authorize_command`, `duties_command`, `duties_my_assignment_json`, `duties_occurrence_json` (3 arguments), `duties_rota_occurrence_json`; from `20261014052239` (4.4): `duties_erase_member`, `duties_deletion_remaining`. `duties_withdraw_acceptance` is not replaced (its call to `duties_after_answer` now alerts the leaders).
- Decision (agent, under owner pre-approval): leader commands on an assignment are keyed to the occurrence aggregate (`duties_occurrence`), so the kernel's replay recheck is "still manages the department"; the lock helper share-locks department, series and occurrence, then the assignment, then the case.
- Decision (agent, under owner pre-approval): an attempt or confirmation by Pastor, another department's leader or a member answers `not_found` (no disclosure); the Admin role alone answers `forbidden` (it may see the department, but holds no scope for the task).
- Decision (agent, under owner pre-approval): the queue lists duties that have not started (completion is entry 10); a material change of the same member is `changed` (in the Declined filter: "needs a new confirmation"); the counts' `declined` includes changed; `conflicts` counts filled positions with an overlap; `overdue_follow_ups` counts open cases whose next follow-up has passed.
- Decision (agent, under owner pre-approval): a material change also closes the case of the superseded assignment (`superseded`, task `source_resolved`); the new revision starts without a case (a fresh key if contact is needed again).
- Decision (agent, under owner pre-approval): contact routes are listed only for members whose position is not yet confirmed; the Home card counts only departments the reader leads or deputises.
- Decision (agent, under owner pre-approval): cancelling the last remaining position cancels the date through the 4.3 `duties_cancel_one` (one-off duties included; 4.3 `cancel_occurrence` still refuses one-off duties).
- Decision (agent, under owner pre-approval): with Q2 closed or invalid, a case closed by a change's notification runner (`duties_notify` has no actor) is written to the server log, not the audit; most such commands then fail on their own notices (which need the policy), but a cancellation with no notice to send (an unfilled or declined position) succeeds and leaves the task open (its reminders stop at delivery: the source is no longer current). Documented as a known limit.
- Earlier tests changed by the review fixes: `followups_reminders_test.sql` test 8 reads only its own purpose's schedule (4.9 registers `coverage_follow_up`); `duties_reminders_scale_test.sql` analyzes its own rows before measuring (the 4.9 scale test's in-transaction ANALYZE leaves row counts in pg_class that made the 4.8 publish of 200 slots time out when the suite ran straight after a reset).
- Earlier tests changed for the new behaviour (no merged migration edited): `duties_tracer_test.sql` and `duties_revisions_test.sql` (the client-executable list gains `duties_coverage`; the My duties key subsets drop the 4.9 keys; a decline's pending-job check ignores the decline alert), `duties_reminders_test.sql` (the `duties_coverage` link check ignores `duty_declined`; a decline and a later decline leave only the leaders' decline alert), `duties_responses_test.sql` (the provenance vocabulary now has `leader`; the staged leader answer sets its channel), `command_foundation_test.sql` (privilege ledger), and the E2E `duties-reminders.mjs` D31 (the decline alert).
- Clients: `duty_coverage.dart` (part of `duties.dart`): `DutyCoverageCommands`, `CoverageStatus`, `CoverageFilter`, `ContactChannel`, `ContactOutcome`, `DutyContactRoute`, `CoverageConfirmation`, `CoverageAttempt`, `CoverageFollowUp`, `CoverageAssignment`, `CoveragePosition`, `CoverageCounts`, `CoverageDepartment`, `DutyCoverage`, `CoverageQuery`, `ContactAttemptDraft`, `LeaderConfirmationDraft`, the `DutyCoverageRepository` and `ContactLauncher` ports; `MyDuty.confirmedByLeader` (no "Can't make it anymore" for it), `PositionAssignment.confirmation`, `DutyPosition.cancelled`, `LeaderDuty.required`, `RotaAssignment.confirmedByLeader`, `RotaPosition.cancelled`. Adapter `SupabaseDutyCoverageRepository`; providers `dutyCoverageRepositoryProvider`, `contactLauncherProvider`; controllers `DutyCoverageController` (query provider, `recordAttempt`, `confirm`, `assign`, `cancelPosition`), `LeaderAttentionController`; five notices. Screens (`duties_coverage_screens.dart`, part of `duties_screens.dart`): `DutyCoverageScreen` (`/duties/coverage`, both apps), `LeaderNeedsAttentionCard` (first on Home, leaders and deputies only); board, rota and My duties labels. Staff sidebar **Coverage**; deep link `/duties/coverage`. Apps: `url_launcher` 6.3.3 (already transitive) and `UrlContactLauncher` (tel:/sms:, E.164 only); Android `<queries>` for DIAL and SENDTO. `testing.dart`: `FakeDutyCoverage`, `FakeContactLauncher`.
- Matrix audit: Queue (pgTAP states/counts/routes/privacy; E2E C11, C40; widget tests), Contact attempt (pgTAP first/second/refusals/Q2 skipped; E2E C20, C21), Confirm by phone (pgTAP incl. refusals and Q2; E2E C30; widget tests), Reassign the decline (pgTAP O2 incl. pending decline alert cancelled and A -> B -> A; E2E C31), Cancel position (pgTAP multi, last, one-off with a case, refusals; E2E C50), Decline (pgTAP leader+deputy, held deputy skipped, fresh key; E2E C10). All ran and passed (see Verification).
- Open owner question (fail-closed default taken): Q4, which contact fields a leader may see in production. Staging shows only the labelled 2.5 routes through the scoped Identity read; production shows nothing until `q4_personal_data` is approved, and then still only labelled routes (never phone usernames).
- Review amendments (independent review, 2026-10-14; the migration was unmerged and unapplied, so `20261014201500_duties_coverage.sql` was amended in place; the frozen block is unchanged):
  - Decision B1: the Confirmed by leader `reason` on the Duties board and rota (`duties_occurrence_json`) is shown only when the viewer's capacity for that department (`duties_manage_capacity` of `app.duties_viewer`) is `department_leader` or `department_deputy`; the Admin role alone sees by, at and channel only. The other reads were audited: the coverage queue already gated reasons, notes and routes to leader/deputy scope; the rota passes no notes; My duties shows the member their own answer. Audit note: the Admin seeing members' own answer notes on the board is the 4.1 behaviour (`with_notes = capacity is not null`), unchanged here and out of this story's scope. Tests: pgTAP (leader yes, Admin and Pastor no on board, queue and rota) and E2E C40.
  - Decision S1 (option b): `app.followups_source_event` (4.7) is replaced so it needs only the Q4 gate (closing or keeping a source's tasks and cancelling their reminders schedules nothing). With Q2 closed or invalid a confirmation, an acceptance and a cancellation close the case and its task (`source_resolved` / `source_cancelled`) and cancel the task's reminders. `duties_apply_change` and `duties_cancel_one` set `app.duties_actor`, which `duties_notify` reads, so every skip is audited with an actor. This supersedes the earlier decision that a case closed while Q2 was invalid leaves its task open. Tests: pgTAP for confirm, accept and cancel_position with Q2 invalid (task closed, reminders cancelled).
  - Decision S2: `duties_lock_for_leader` refuses an attempt or confirmation on the actor's own assignment with `validation_failed {"assignment_id": "own"}`; the client hides the actions on the leader's own duty with "This is your own duty: answer it in My duties." and maps the refusal to the notice `ownAssignment`. Tests: pgTAP and widget test.
  - Decision S3: `duties_coverage_supervisor` picks another current leader or deputy of the department whom the app can reach (a leader first, then by member id); only when nobody else holds the scope the recorder supervises, answered as `supervisor_fallback: true` and audited. The task's scope is the supervisor's scope (the owner is in the same department group, so the Q4 owner-scope rule holds). Tests: a deputy records and a leader supervises; a single-leader department falls back.
  - Decision N1: a source-specific reminder schedule (owner at the due or review time, no supervisor alert, no assignment notice); due and review dates are refused after the duty start, so nothing is sent after the service. Cases of started duties close lazily (`started`, `duties_close_started_cases`, `skip locked`) at the next attempt or confirmation in that department; documented in the runbook.
  - Decision N2/N3: a new attempt on a case whose task was finished by hand, or whose task owner no longer holds the department scope, closes that case (`replaced`; its task `source_resolved` if still active) and opens a fresh case and task for the recorder.
  - Decision N4: `duties_cancel_one` (4.4 body) skips cancelled positions.
  - Decision N5: the queue computes every position's state for the counts but builds the JSON only for the first 1000 listed.
  - Decision N6: the scale test uses a real month (39 other departments with 30 more duties each over days 7-30; Admin 4,930 positions).
  - Decision N7: a malformed From date shows "Use YYYY-MM-DD" and does not query.
  - Decision N8: `changed` is counted once, under declined (labelled "Declined or changed"); `awaiting` counts only positions awaiting an answer.
  - Decision N9: an attempt on an erased or departed assignee answers `validation_failed {"member_id": "required_reassign"}`.
  - Replaced bodies added by the review: `followups_source_event` (from `20261014130535_followups_reminders.sql`, its latest version) and `duties_cancel_one` (from `20261014052239`, 4.4).
- Remaining (not builder steps): staging apply of `20261014201500_duties_coverage.sql` and per-function md5 parity (parent; no owner SQL paste; no Edge Function redeploy); rebuild the staging staff web and APK (`url_launcher` direct dependency, Android tel:/sms: queries); owner manual checks in `docs/runbooks/duties.md`, story 4.9 (record in `evidence-4.9/owner-check.md`).


## Plan Change Log

- 2026-10-14: independent review amendments B1, S1 (option b), S2, S3, N1-N9 applied to the unmerged migration, clients, tests, E2E and runbooks; recorded under Implementation Notes, "Review amendments". The earlier Q2 decision (task left open) is superseded by S1. Frozen block unchanged.

## Review Triage Log

- B1 (blocker, Admin sees Confirmed by leader reason on the board): fixed (scope-gated reason; pgTAP and E2E C40).
- S1 (should, task left open when Q2 invalid): fixed, option (b) (`followups_source_event` Q4-only; actor passed; pgTAP per closing path).
- S2 (should, leader acts on own assignment): fixed (`own` refusal; client hint and notice; pgTAP and widget test).
- S3 (should, supervisor = recorder): fixed (another reachable leader or deputy, leader first; recorded fallback; pgTAP).
- N1 (alert after the service): fixed (owner-only schedule before the duty; lazy close of started cases).
- N2, N3 (hand-closed task, owner without scope): fixed (case `replaced`, fresh task).
- N4 (cancel_one on cancelled slots): fixed.
- N5 (JSON for every position): fixed.
- N6 (31-day timing on thin data): fixed (real month).
- N7 (malformed From date): fixed.
- N8 (double counting): fixed.
- N9 (attempt on erased assignee): fixed.

## Verification

**Commands:**
- `npx supabase db reset && npm run -s db:test && npm run -s db:smoke` -- expected: pass.
- e2e-main.sh with `duties-coverage` appended -- expected: each `exit=0`.
- `npm run -s contracts:test && node --test <CI set> && npm run -s ci:policy-test` -- expected: pass.
- `flutter analyze && flutter test` in `packages/client_core`, `apps/staff`, `apps/mobile`; `TZ=America/New_York` for `test/duties` and mobile -- expected: pass.
- `npm run -s ci:secrets && npm run -s ci:migrations -- --base origin/main && npm run -s ci:function-imports`; evidence scan -- expected: clean.

**Results after the review fixes (2026-10-14):**
- db reset 0; db:test PASS (37 files, 3220 tests; `duties_coverage_test.sql` 157, `duties_coverage_scale_test.sql` 10 with leader 250 positions 207 ms, Pastor 40 departments 478 ms, Admin 31 days of a real month (4,930 positions) 914 ms); passed after a reset four times out of four; db:smoke pass.
- Every E2E `exit=0` (26 scripts, reset before each, run one at a time; `duties-coverage` 12/12 including the B1 board checks).
- contracts:test 242/0; node tool tests (CI set) 206/0; ci:policy-test 56/0.
- flutter analyze clean in client_core, apps/staff, apps/mobile; flutter test client_core 592 (`duties_coverage_test.dart` 25), apps/staff 39, apps/mobile 55; under `TZ=America/New_York` client_core `test/duties` + `test/followups` 164 and apps/mobile 55.
- ci:secrets clean; ci:migrations (`--base origin/main`) ordered, unique, non-destructive; ci:function-imports ok; evidence scan clean.

**Results of the first build (2026-10-14):**
- db reset 0; db:test PASS (37 files, 3191 tests; `duties_coverage_test.sql` 129, `duties_coverage_scale_test.sql` 9 with leader 250 positions 178 ms, Pastor 40 departments 611 ms, Admin 31 days 665 ms under `statement_timeout = '8s'`); db:smoke pass (no SMS provider).
- Every E2E `exit=0` (26 scripts, reset before each; `duties-coverage` 12/12). A container restart interrupted the first run after 23 passing scripts; the last three were re-run (`duties-reminders` D90 needed `duty_declined` in its generic-text list, then 17/17) (`evidence-4.9/e2e-suite-summary.txt`).
- contracts:test 242/0; node tool tests (CI set) 206/0; ci:policy-test 56/0.
- flutter analyze clean in client_core, apps/staff, apps/mobile; flutter test client_core 590 (`test/duties/duties_coverage_test.dart` 23), apps/staff 39, apps/mobile 55; under `TZ=America/New_York` client_core `test/duties` + `test/followups` 162 and apps/mobile 55.
- ci:secrets clean; ci:migrations (`--base origin/main`) ordered, unique, non-destructive; ci:function-imports ok; evidence scan clean (evidence-4.9, the E2E, the duties and follow-ups runbooks).

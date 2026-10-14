---
title: 'Set response deadlines and schedule creator-configured duty reminders'
type: 'feature'
ticket: '8'
created: '2026-10-14'
status: 'in-progress'
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
- [ ] `supabase/migrations/20261014153012_duties_reminders.sql` -- columns, sources/kinds/contracts/route, deadline and plan helpers, replaced commands/engine/projections, `duties.set_reminders`, create_series wrapper.
- [ ] `supabase/tests/duties_reminders_test.sql` (+ earlier duties tests where job counts change) -- the matrix through the worker.
- [ ] `packages/client_core` (domain, publish/rota forms, Short notice, Needs contact, set reminders) + `test/duties/duties_reminders_test.dart`; app tests.
- [ ] `tools/identity-e2e/duties-reminders.mjs` + `.test.mjs`.
- [ ] `docs/runbooks/duties.md` (story 4.8, owner checks), `contracts-and-owner-seams.md`.
- [ ] `evidence-4.8/`, `.github/workflows/ci.yml` evidence scan step.

**Acceptance Criteria:**
- Given the local stack, when `duties-reminders.mjs` runs through the real worker script, then every matrix row passes over HTTP and every duty inbox item carries only its contract's generic text.
- Given the full local verification, when run, then every listed check passes.

## Implementation Notes

## Plan Change Log

## Review Triage Log

## Verification

**Commands:**
- `npx supabase db reset && npm run -s db:test && npm run -s db:smoke` -- expected: pass.
- e2e-main.sh with `duties-reminders` appended -- expected: each `exit=0`.
- `npm run -s contracts:test && node --test <CI set> && npm run -s ci:policy-test` -- expected: pass.
- `flutter analyze && flutter test` in `packages/client_core`, `apps/staff`, `apps/mobile`; `TZ=America/New_York` for `test/duties` and mobile -- expected: pass.
- `npm run -s ci:secrets && npm run -s ci:migrations -- --base origin/main && npm run -s ci:function-imports`; evidence scan -- expected: clean.

---
title: 'Calculate church-time reminder schedules from a versioned policy'
type: 'feature'
ticket: '3'
created: '2026-10-08'
status: 'done'
baseline_revision: '19ca3b1098c9a320fc78e0bf03c276cca9b2374c'
route: 'full'
route_source: 'auto'
review: ''
review_source: ''
lenses_ran: []
review_loop_iteration: 0
context:
  - '{project-root}/docs/runbooks/notifications.md'
  - '{project-root}/docs/runbooks/contracts-and-owner-seams.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** Jobs carry whatever `scheduled_at` a source passes; nothing turns church-local intent (Africa/Lusaka, creator deadlines and offsets, short notice, snooze) into UTC instants under a numbered policy, and a policy or schedule change cannot move future jobs. Duties, follow-ups and visits all need one shared calculation (AD-9, N3).

**Approach:** Put the decided Q2 defaults in a numbered, validated `q2_church_time` value (staging/local fixture moved to Africa/Lusaka). Add pure SQL calculations (response deadline by lead-time band, reminder plan with skip-passed, respond-now, merge and expiry, task Waiting review anchor, local recurrence with exceptions, snooze clamp) and Notifications owner operations that store a source's schedule intent per recipient, reconcile its future jobs in the caller's transaction, re-plan every active schedule on a policy change, and snooze one delivered item.

## Boundaries & Constraints

**Always:** all instants stored UTC; local arithmetic in the policy zone (whole days on the local calendar, hours/minutes absolute); every tunable (bands, default reminders per schedule type, merge window, snooze choices, limits) lives in the policy value with an integer `policy_version`, never in code; a malformed or missing-version policy fails closed (`unavailable {"policy": "gate_closed"}`, content-free log line); jobs record `policy_version` and `expires_at`; reconciliation runs in the caller's transaction, enqueues only entries after `now()` (plus respond-now on a fresh short-notice schedule), and never revives or re-sends past-due work; no quiet hours; stored intents hold only instants, booleans, enums and reminder specs (no text); `notifications_` prefix, `search_path = ''`, no client grants, ASCII, non-destructive migration with a version after `20261008090057`.

**Never:** a quiet-hours window or deferral; client API, screens or snooze UI (entry 7 wraps the snooze operation); worker leases, attempts or expiry handling (entry 4); recipient routing (entry 5); editing `policy_approve` or other platform functions; applying to staging.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Long lead | start >= 30 days after assignment, no creator deadline | deadline = start - 14 local days, band `long`, reminders 24 h before and at deadline | — |
| Medium lead | 2..30 days | deadline = start - 48 h, band `medium` | — |
| Short lead | < 48 h, start - 24 h still ahead | deadline = start - 24 h, band `short` | — |
| Passed | < 24 h ahead | `short_notice`, deadline = now, passed offsets skipped, one `respond_now` entry (fresh mode only) | — |
| Creator deadline | before start / after start | used as given / refused | `validation_failed {"response_deadline": "after_start"}` |
| Local dates | 09:00 Lusaka in Jan and Jul; monthly from 31 Jan; weekly with an exception date | 07:00Z both; 28/29 Feb then 31 Mar; excepted date absent | invalid rule: `validation_failed` |
| Merge | two entries within the merge window | one entry at the earlier instant listing both anchors | — |
| Expiry | entry after `expires_at` | dropped | — |
| Waiting task | state `waiting` with `review_at` | anchor `deadline` = review_at | waiting without review_at: `validation_failed {"review_at": "required"}` |
| Snooze | delivered item, choice in policy; choice past expiry | job at now + choice; clamped to `expires_at` | unknown choice `invalid`; expired/superseded `conflict`; not caller's `not_found` |
| Schedule change | new revision or intent | pending non-plan jobs of that source+recipient cancelled `rescheduled`, future plan enqueued once | stale revision: `conflict` |
| Policy change | new `policy_version` | active schedules re-planned: future jobs moved, past-due ones never enqueued, stale sources skipped | — |
| Production | Q2 unapproved | schedule, reconcile and snooze refused, nothing written | `unavailable {"policy": "gate_closed"}` |

Decision (agent, under owner pre-approval): bands, offsets, snooze choices (1 hour, 24 hours, 2 days) and merge window follow the epic Notes' reading of the owner's ranges and live in the fixture value; tasks default to one reminder at the actionable deadline (FR Task reminders).
Decision (agent, under owner pre-approval): `policy_version` is an integer inside the policy value; the fixture is version 1. An approval without a valid version fails closed at scheduling time; `app.notifications_policy_errors(value)` lets the owner check a value before `policy_approve`. Policy re-planning is an explicit operator call (`app.notifications_replan_all`) run after a policy change, because platform functions may not call Notifications.
Decision (agent, under owner pre-approval): snooze is a server owner operation here, wrapped for clients by entry 7; a new snooze replaces the item's earlier pending snooze, and a revision change cancels it.
Decision (agent, under owner pre-approval): a merged entry takes the kind of its highest-precedence anchor (respond_now, response_deadline, deadline, starts_at); the source re-plans (e.g. `responded: true`) when an answer should drop response reminders.

</frozen-after-approval>

## Code Map

- `supabase/migrations/20261003134340_cross_epic_contracts.sql` -- `app.policy_gates` (fixture_value), `policy_effective`, `contract_instant_error`, `contract_local_error`, `contract_unknown_keys`, `contract_token_error`, `contract_check_source`, `cmd_fail`, `cmd_utc`. Do not edit.
- `supabase/migrations/20261008073631_notifications_inbox.sql` -- `notifications_jobs` (logical key unique index), inbox items, `notifications_cancel`.
- `supabase/migrations/20261008090057_notifications_source_contracts.sql` -- current `notifications_enqueue` (replace, keep behaviour), `contract_check_reminder`, `notifications_job_key`, `fixture_reminder_open_check` (fixture hook used by tests).
- `supabase/tests/notifications_inbox_test.sql`, `notifications_source_contracts_test.sql` -- setup helpers (claims, sessions, `identity_seed_synthetic_link`, production marker via absent row / `platform_set_environment`).
- Module rules: notifications may call platform and identity only; boundary guard scans function bodies.

## Tasks & Acceptance

**Execution:**
- [x] `supabase/migrations/20261008102121_notifications_scheduling.sql` -- fixture value v1 (Africa/Lusaka); `notifications_policy_errors`, `notifications_policy`; duration and local helpers; `notifications_response_deadline`, `notifications_plan`, `notifications_occurrences`, `notifications_snooze_at`; `notifications_schedules` table; job columns `policy_version`, `expires_at`, `schedule_id`, `snoozed_from_item_id`; `notifications_enqueue_job` + enqueue wrapper; `notifications_set_schedule`, `notifications_replan_all`, `notifications_snooze_item`; cancel also ends schedules; privileges.
- [x] `supabase/tests/notifications_scheduling_test.sql` -- table-driven pgTAP for the whole matrix, guards and privileges.
- [x] `docs/runbooks/notifications.md`, `contracts-and-owner-seams.md` -- policy value shape, owner operations, operator re-plan, staging/owner steps.

**Acceptance Criteria:**
- Given the local stack after `db reset`, when db:test, db:smoke, every E2E, contracts and tool tests, scan-secrets and check-migrations run, then all pass.
- Given the boundary guards, when pgTAP runs, then no unowned objects, unpinned functions or boundary violations exist.

## Implementation Notes

- Implemented directly (no subagent tool in this run). Files: `supabase/migrations/20261008102121_notifications_scheduling.sql`, `supabase/tests/notifications_scheduling_test.sql` (96 after review fixes, table-driven: bad policies, deadline cases, plan cases, intent errors), `docs/runbooks/notifications.md` (Story 3.3 section, owner production steps), `docs/runbooks/contracts-and-owner-seams.md` (schedule consumer guide, Q2 approval check).
- Snooze choices are written `"1 hour"`, `"24 hours"`, `"2 days"` (durations accept singular and plural units); the Design Notes' `"1 hours"` was a typo.
- A pending job that stays in a re-plan takes the new `policy_version`, digest and expiry, so "jobs record the applied policy version" holds after a policy change.
- Re-planning keeps a due-but-undelivered job at the current revision (the worker delivers it) and cancels only future or older-revision jobs; the `respond_now` of a short-notice schedule is issued once per source revision (`respond_now_revision`), so a policy re-plan or a repeated fresh call never sends a second one.
- `notifications_cancel` now also ends the matching schedules (any kind selector), so a later re-plan cannot revive cancelled reminders; sources that only want to drop some reminders re-plan instead (consumer guide).
- Surprise: in pgTAP a job inserted by a function called inside a `select ... where` is invisible to that same statement's snapshot; the test stores the result first.
- Matrix audit: long/medium/short/passed bands and creator deadlines (deadline_cases, S1, S2), local dates (Jan/Jul, leap month end, weekly exception, invalid rule, window), merge in/out of window, expiry, responded, no quiet hours, Waiting task and its errors (plan_cases, intent_errors, T1), snooze calc and operation (clamp, choice, expired, not_found, superseded, revision cancel), schedule change and stale revision (S1), policy change without past-due work, reinstatement, stale and ended schedules (replan2/replan3), production refusal of policy, set_schedule, replan and snooze: all in `notifications_scheduling_test.sql`, which ran and passed in `db:test`.
- Owner/staging steps remaining (not blocking `built`): the parent applies the migration to staging and runs the smoke checks in `notifications.md` (Story 3.3, Hosted staging); Israel approves `q2_church_time` for production at entry 10 (steps in the same section).

## Plan Change Log

- 2026-10-08, independent review of 3.3 (coordinator; four mediums, three lows), patched in place in the unapplied migration `20261008102121`:
  1. A kind-selective `notifications_cancel` no longer ends the schedule: it stays active and records the kind in `cancelled_kinds` (reset on a new revision), so a re-plan keeps the other kinds and never revives the cancelled one.
  2. `notifications_snooze_item` refuses (`conflict {"item_id": "superseded"}`) when the job's schedule is not active, its revision moved, its kind was cancelled, or it is a response kind and the intent is `responded`; re-planning a responded intent cancels pending snoozes of response kinds (`responded`).
  3. Re-planning respects merges already sent: an entry within the merge window after a due or delivered job of the same schedule and revision is `covered`, not enqueued. `notifications_apply_schedule` takes an optional `p_now` so tests can re-plan at a later instant.
  4. `notifications_occurrences` jumps to one step before the window, however old `local_start` is, and raises `validation_failed {"window": "out_of_range"}` instead of returning a silent empty list when the 1000-step cap is hit.
  5. Decision (agent, under owner pre-approval; adjustable policy values, also recorded in the epic Notes): the default deadline is 14 days before the start if the lead is 30 days or more; else 48 hours before if the lead is at least 72 hours (so at least 24 hours to respond); else 24 hours before if the lead is more than 24 hours; else short notice (respond now). The fixture's second band is now `min_lead` 72 hours; this replaces the frozen matrix's "2..30 days" medium band. Boundary tests at exactly 30 days, 72 hours, 48 hours and 24 hours.
  6. The effective response deadline is never after the start (`least(..., starts_at)`), also when the start has passed (short notice).
  7. The policy validator bounds `merge_window` to at most 1 day and every band's `before_start` to at most `max_offset`.
  Tests: `notifications_scheduling_test.sql` grew from 79 to 96.

## Review Triage Log

## Design Notes

Policy value (fixture adds `fixture_label`):
`{"policy_version":1,"zone":"Africa/Lusaka","quiet_hours":null,"deadline_bands":[{"min_lead":"30 days","before_start":"14 days"},{"min_lead":"72 hours","before_start":"48 hours"},{"min_lead":"0 minutes","before_start":"24 hours"}],"default_reminders":{"response":[{"anchor":"response_deadline","before":"24 hours"},{"anchor":"response_deadline","before":"0 minutes"}],"task":[{"anchor":"deadline","before":"0 minutes"}]},"merge_window":"30 minutes","snooze_choices":["1 hour","24 hours","2 days"],"max_reminders":6,"max_offset":"90 days"}`

Durations are `^(0|[1-9][0-9]{0,3}) (minutes|hours|days)$`. Intent (`response`): `assigned_at, starts_at, response_deadline?, expires_at? (default starts_at), responded?, reminders?`; (`task`): `due_at, task_state, review_at?, expires_at?, reminders?`. `reminders: null` = policy default, `[]` = none. A reminder spec is `{anchor, before}` or `{anchor, after}`.

## Verification

**Commands:**
- `npx supabase db reset && npm run -s db:test && npm run -s db:smoke` -- expected: all pass
- E2E loop (scratchpad `e2e-main.sh`, worktree path) -- expected: every suite passes
- `npm run -s contracts:test && node --test tools/**/*.test.mjs && npm run -s ci:secrets && npm run -s ci:migrations` -- expected: pass

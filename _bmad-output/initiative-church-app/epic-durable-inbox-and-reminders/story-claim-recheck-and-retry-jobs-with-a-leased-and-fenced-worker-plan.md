---
title: 'Claim, recheck and retry jobs with a leased and fenced worker'
type: 'feature'
ticket: '4'
created: '2026-10-08'
status: 'in-progress'
baseline_revision: 'fc3444679f5b4144ee6db50110d7332344032df3'
route: 'full'
route_source: 'auto'
review: ''
review_source: ''
lenses_ran: []
review_loop_iteration: 0
context:
  - '{project-root}/docs/runbooks/notifications.md'
  - '{project-root}/docs/runbooks/system-access-and-operations.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** The 3.1 tracer step `notifications.deliver_due` claims and delivers in one transaction run by an operator script: there is no lease that survives a worker, no fencing token, no attempt record, no central retry/expiry policy, no expiry of obsolete jobs, no schedule recheck and no Cron. N4/AD-8/AD-17 need a scheduled, separately authenticated worker that keeps one logical outcome per job under races, crashes and uncertain results.

**Approach:** Two system commands of purpose `notifications_worker`: `notifications.claim {limit?}` (expires obsolete jobs, reclaims expired leases, leases a bounded batch with a fresh fencing token) and `notifications.attempt {job_id, lease_token}` (fences, rechecks lease, expiry, source/revision, actionability, recipient eligibility and membership, the approved schedule, then writes the one inbox item or records a retry/terminal outcome; every attempt is a row in `notifications_attempts`). Central `notifications_worker_settings` holds lease, batch, attempts, backoff and default expiry. A new Edge Function `notifications-worker` forwards the caller's system credential to claim and attempt. Cron runs `app.notifications_scheduler_tick()`, which reads the credential from Supabase Vault and posts to the function with pg_net; operator functions enable (one named job per environment), disable and report the scheduler. `deliver_due` becomes claim+attempt in one transaction (same rules).

## Boundaries & Constraints

**Always:** lease/fence/recheck logic only in SQL (the Edge Function is transport and holds no credential of its own); fencing tokens from one monotonic sequence; a stale or expired lease never changes a job; cancelled work is never dispatched; inbox item unique per job (no exactly-once promise beyond that); every attempt recorded content-free (outcome token, SQLSTATE only); all tunables in the settings row (validated, operator-set); Cron command text holds no secret; tick and enable refuse production unless `ops_system_access` is open; answers and logs carry counts/outcomes only (claim returns opaque job ids and tokens to the worker, never logged); `notifications_` prefix, `search_path = ''`, no client grants; migration ASCII, non-destructive, no `delete from`, version after `20261008102121`; agent never deploys a function, creates a hosted schedule or handles a hosted credential.

**Never:** push/FCM, device tokens or provider attempts (entry 6); held/accountless routing or deletion hooks (entry 5); health screens (entry 8); quiet hours; widening `job_state` (needs DROP CONSTRAINT).

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Racing claims | two workers claim one due batch | disjoint leases; each job delivered once | `skip locked` |
| Killed mid-lease | A claims, never attempts; lease expires | B's claim reclaims with a higher token; A's attempt `fenced`, B's `delivered` | live lease is not reclaimable |
| Stale token | attempt with an older token | `fenced`, job unchanged, attempt recorded | — |
| Cancelled after claim | source cancels between claim and attempt | `cancelled`, no item | — |
| Revised after enqueue | revision moved, job not cancelled | job `obsolete` (`source_changed`) | — |
| Revoked grant | contract `recipient_eligible` false or member not approved | job `ineligible` | — |
| Schedule changed | schedule ended/stale/revision moved/kind cancelled/responded | `obsolete` (`schedule_changed`) | — |
| Expired | now past `expires_at` (or `scheduled_at` + default ttl) | `obsolete` (`expired`) at claim or attempt | — |
| Transient failure | check raises | `failed`, lease released, `next_attempt_at` = backoff; later attempt delivers | at `max_attempts`: `obsolete` (`attempts_exhausted`) |
| Edge auth | no/malformed/other-purpose credential | 401 / 403, nothing claimed | content-free log |
| Cron | scheduler enabled, app closed | due job delivered by the tick | missing Vault secret or URL: tick `not_configured` |

Decision (agent, under owner pre-approval): `job_state` keeps its 3.1 values (widening the CHECK needs DROP CONSTRAINT); a new `finish_reason` token says why (`expired`, `attempts_exhausted`, `source_changed`, `not_actionable`, `schedule_changed`, `no_contract`, `recipient_ineligible`, `membership_inactive`). Exhausted retries end `obsolete`: the FR retries "until the message is no longer useful".
Decision (agent, under owner pre-approval): defaults lease 120 s, batch 25, max attempts 5, backoff 60 s doubling to 3600 s (the 3.1 curve), default expiry 7 days after `scheduled_at`; operator-adjustable values, not church policy.
Decision (agent, under owner pre-approval): the main migration enables `pg_net` and `pg_cron` (no schedule); the schedule is created only by `app.notifications_scheduler_enable(operator, every)`, run by the parent on staging after the owner stores the credential as Vault secret `notifications_worker_credential`; the Edge URL is a non-secret settings value.
Decision (agent, under owner pre-approval): the SYNTHETIC fixture gains `check_fault_until` (SQL-only) so the transient-failure case can be shown locally and on staging.

</frozen-after-approval>

## Code Map

- `supabase/migrations/20261008073631_notifications_inbox.sql` -- jobs table (failed_attempts/last_failed_at reused as retry count), inbox items, `deliver_due` registration.
- `supabase/migrations/20261008090057_notifications_source_contracts.sql` -- current `notifications_sys_deliver_due`, `contract_check_reminder`, `notifications_job_key`, `fixture_reminder_open_check` (replace to honour the fault column).
- `supabase/migrations/20261008102121_notifications_scheduling.sql` -- `notifications_schedules`, job `expires_at`/`schedule_id`, snooze schedule rules to mirror in the recheck.
- `supabase/migrations/20261007140729_assisted_recovery.sql` -- `sys_execute` registry: payload check `(jsonb)`, handler `(uuid, uuid, jsonb) -> {data}`, handler runs in a subtransaction; principals get commands only at creation (grant new commands to existing `notifications_worker` principals).
- `supabase/functions/identity-deletion/{index.ts,logic.mjs}` -- Edge pattern to copy (credential forwarding, timeouts, content-free logs, Node-tested logic); `supabase/config.toml` function entries.
- `tools/identity-e2e/deletion.mjs` -- `supabase functions serve` + local credential minting pattern; `harness.mjs` psql/http helpers.
- Tests to keep green: `notifications_inbox_test.sql` (deliver_due backoff), `system_access_test.sql` (allowlist pin), `command_foundation_test.sql`.

## Tasks & Acceptance

**Execution:**
- [ ] `supabase/migrations/<ts>_notifications_worker.sql` -- extensions, settings, job columns, attempts, runs, token sequence, claim/attempt (internal + handlers + checks + registrations + grants to existing principals), deliver_due rewrite, fixture fault, scheduler tick/enable/disable/status, privileges.
- [ ] `supabase/tests/notifications_worker_test.sql` -- the matrix, settings validation, scheduler refusals, privileges; pin updates in existing tests.
- [ ] `supabase/functions/notifications-worker/{index.ts,logic.mjs,logic.test.mjs}`, `supabase/config.toml` -- the Edge worker.
- [ ] `tools/identity-e2e/worker.mjs` + `.test.mjs` -- local HTTP E2E incl. Edge and a real pg_cron run.
- [ ] `.github/workflows/ci.yml` -- new node tests if not covered by globs.
- [ ] `docs/runbooks/notifications.md`, `system-access-and-operations.md` -- worker, settings, parent deploy/schedule steps, owner Vault/credential steps, rotation, staging demo.

**Acceptance Criteria:**
- Given a reset local stack, when db:test, db:smoke, every E2E, contracts and tool tests, scan-secrets and check-migrations run, then all pass.
- Given the guards, when pgTAP runs, then no unowned, unpinned or boundary-violating objects exist.

## Implementation Notes

## Plan Change Log

## Review Triage Log

## Verification

**Commands:**
- `npx supabase db reset && npm run -s db:test && npm run -s db:smoke` -- expected: pass
- E2E loop (scratchpad `e2e-main.sh`, worktree path, plus `worker`) -- expected: every suite passes
- `npm run -s contracts:test && node --test tools/**/*.test.mjs supabase/functions/*/logic.test.mjs && npm run -s ci:secrets && npm run -s ci:migrations` -- expected: pass

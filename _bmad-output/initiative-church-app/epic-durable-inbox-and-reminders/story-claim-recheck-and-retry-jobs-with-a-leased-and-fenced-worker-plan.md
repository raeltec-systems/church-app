---
title: 'Claim, recheck and retry jobs with a leased and fenced worker'
type: 'feature'
ticket: '4'
created: '2026-10-08'
status: 'done'
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
- [x] `supabase/migrations/<ts>_notifications_worker.sql` -- extensions, settings, job columns, attempts, runs, token sequence, claim/attempt (internal + handlers + checks + registrations + grants to existing principals), deliver_due rewrite, fixture fault, scheduler tick/enable/disable/status, privileges.
- [x] `supabase/tests/notifications_worker_test.sql` -- the matrix, settings validation, scheduler refusals, privileges; pin updates in existing tests.
- [x] `supabase/functions/notifications-worker/{index.ts,logic.mjs,logic.test.mjs}`, `supabase/config.toml` -- the Edge worker.
- [x] `tools/identity-e2e/worker.mjs` + `.test.mjs` -- local HTTP E2E incl. Edge and a real pg_cron run.
- [x] `.github/workflows/ci.yml` -- new node tests if not covered by globs.
- [x] `docs/runbooks/notifications.md`, `system-access-and-operations.md` -- worker, settings, parent deploy/schedule steps, owner Vault/credential steps, rotation, staging demo.

**Acceptance Criteria:**
- Given a reset local stack, when db:test, db:smoke, every E2E, contracts and tool tests, scan-secrets and check-migrations run, then all pass.
- Given the guards, when pgTAP runs, then no unowned, unpinned or boundary-violating objects exist.

## Implementation Notes

- Implemented directly (no subagent tool in this run). Files: migration `supabase/migrations/20261008121248_notifications_worker.sql`; pgTAP `supabase/tests/notifications_worker_test.sql` (83); pins updated in `system_access_test.sql` (allowlist) and `notifications_inbox_test.sql` (worker principal now holds three commands); Edge Function `supabase/functions/notifications-worker/{index.ts,logic.mjs,logic.test.mjs}` + `config.toml`; E2E `tools/identity-e2e/worker.mjs` (+ test); CI evidence scan step; runbooks `notifications.md` (Story 3.4 section, cross-references) and `system-access-and-operations.md`; evidence `evidence-3.4/`.
- The retry counter reuses the 3.1 `failed_attempts`/`last_failed_at` columns and the backoff is computed from them (base 60 s doubling to 3600 s = the 3.1 curve), so the 3.1 pgTAP cases that age `last_failed_at` stay valid; no `next_attempt_at` column.
- `deliver_due` keeps its exact five-key answer (claimed includes jobs it expired; obsolete includes expired and exhausted), so 3.1-3.3 tests and `tools/notifications/worker.mjs` are unchanged.
- Lease fields record the last lease; "live" = pending and `lease_expires_at > now()`. Finishing or failing ends the lease (`least(lease_expires_at, now())`), keeping the token for the fence.
- The schedule recheck mirrors the 3.3 snooze rules (ended/stale, revision moved, kind cancelled, responded response kind).
- The Edge Function forwards the caller's credential exactly like `identity-deletion`; the run loop lives in `logic.mjs` with the system call injected, so Node tests cover claim/attempt ordering, the deadline, uncertain answers and malformed claims.
- The tick reads Vault and calls `net.http_post` by dynamic SQL, so the function exists even where pg_net is missing (answers `not_configured`). The enable refuses a second Cron job running the tick (one scheduler per environment).
- Staging check (read-only, 2026-10-08): `pg_cron` and `pg_net` not installed, `supabase_vault` 0.3.1 installed; the migration enables both.
- Surprise: in pgTAP a SQL helper that runs a command and selects its job in one statement sees no row (snapshot); helpers that need the new job are plpgsql.
- Matrix audit: racing claims (pgTAP sequential leases + E2E W10 concurrent HTTP claims), killed mid-lease/reclaim/higher token/stale token/lapsed own lease (pgTAP, E2E W20/W21), cancelled after claim (pgTAP, W30), revised after enqueue (pgTAP, W31), revoked grant and inactive membership (pgTAP, W32), schedule changed (pgTAP), expired at claim and at attempt incl. default ttl (pgTAP, W33), transient failure/backoff/exhausted (pgTAP, W40), Edge auth 401/403 (W02) and batch run (W50), Cron with the app closed (W60), tick not_configured/gate_closed/sent and single scheduler (pgTAP). All ran and passed.
- Owner/staging steps remaining (not blocking `built`; superseded by the review redesign, see Plan Change Log 1): parent applies the migration and runs `verify-hosted.sql`, deploys `notifications-worker` (MCP `deploy_edge_function`, `verify_jwt: false`), sets `worker_url` and runs `app.notifications_scheduler_new_trigger('israel')`; owner mints/registers a staging credential and sets the Edge secrets `NOTIFICATIONS_WORKER_SYSTEM_CREDENTIAL` (the credential) and `NOTIFICATIONS_WORKER_TRIGGER` (copied from the Vault trigger); parent runs one tick, then `app.notifications_scheduler_enable('israel')`; owner runs the app-closed demonstration (runbook `notifications.md`, Story 3.4, Hosted staging steps 1-9). Credential rotation every 30 days at most.

## Plan Change Log

- 2026-10-08, independent review of 3.4 (coordinator; two mediums, six lows), patched in place in the unapplied migration `20261008121248`:
  1. (medium) Decision (agent, under owner pre-approval; supersedes the frozen Decision that the Cron tick sends the Vault-held credential): `net.http_request_queue` headers may be readable by other roles while queued, so the worker credential no longer enters the database. It is the Edge Function secret `NOTIFICATIONS_WORKER_SYSTEM_CREDENTIAL` (owner-set, like 2.9). Cron sends only a random trigger (`nwt_<64 hex>`) from Vault `notifications_worker_trigger`, generated by `app.notifications_scheduler_new_trigger` (value never returned); the owner copies it into the Edge secret `NOTIFICATIONS_WORKER_TRIGGER`. The function compares it in constant time; missing/wrong = 401, nothing started. Runs stay idempotent; one run per instance (409 busy). pgTAP asserts the queue never holds a system credential; E2E W62 asserts no credential in queue, Vault or Cron.
  2. (medium) A recheck cancelled by the statement timeout is caught explicitly (`when query_canceled`) and counted `failed`; `deliver_due` then releases the rest of its batch and stops. Independently, a lapsed lease whose holder recorded no attempt is counted once as `lapsed` at the next claim (new column `lapsed_attempts`; failures + lapses reach `max_attempts` -> `attempts_exhausted`; no backoff for a lapse). Tested with a slow pgTAP hook (`pg_sleep`, 500 ms timeout) and a repeatedly crashing worker.
  3. (low) `lease_seconds` minimum 30; the Edge run stops 15 s before the lease ends and releases deferred jobs through the new `notifications.release` command (no attempt counted). Runbook: disable the scheduler before lowering the lease.
  4. (low) `deliver_due` is capped by `batch_max` (3.1 pgTAP raises it to 100 for its paging case).
  5. (low) Operator actions recorded in `app.ops_operator_actions` (`worker_policy_changed`, `scheduler_enabled`, `scheduler_disabled`, `scheduler_trigger_rotated`; target null). The CHECK was widened by the 2.3/2.12 retire-by-rename pattern (`ops_retired_operator_actions_v2`, rows copied); ledger test and the seams ledger updated.
  6. (low) `worker_url` pinned per environment (`app.notifications_worker_url_error`): local any http(s) host; staging exactly its own project function; production https `<ref>.supabase.co` (ref pinned at entry 10). The tick re-checks it.
  7. (low) Interval floor 15 s (`1 minute` or `15-59 seconds`); runbook documents trimming `cron.job_run_details`.
  8. (low) Status test asserts exact live leases and lapses; new claimed-then-replan (new revision cancels the leased job) and claimed-then-snooze (re-snooze cancels the leased snooze) cases. pgTAP 83 -> 110; E2E 15 -> 17 checks.

## Review Triage Log

## Verification

**Commands:**
- `npx supabase db reset && npm run -s db:test && npm run -s db:smoke` -- expected: pass
- E2E loop (scratchpad `e2e-main.sh`, worktree path, plus `worker`) -- expected: every suite passes
- `npm run -s contracts:test && node --test tools/**/*.test.mjs supabase/functions/*/logic.test.mjs && npm run -s ci:secrets && npm run -s ci:migrations` -- expected: pass

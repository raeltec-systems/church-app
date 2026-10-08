---
title: 'Send generic expiring push through FCM and retire invalid tokens'
type: 'feature'
ticket: '6'
created: '2026-10-08'
status: 'in-progress'
baseline_revision: 'a52c3b89ec6fb7b5ec75ee1f57bda786852e6585'
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

**Problem:** Story 3.5 creates one pending member-push job per inbox item, but nothing sends it: there is no FCM adapter, no push lease/recheck/retry, no invalid-token retirement, no client registration or push-tap handling (N7, N4, AD-8, AD-13, AD-18).

**Approach:** Push jobs get their own lease, fencing, lapse and backoff (same sequence and central policy as 3.4). Three system commands of purpose `notifications_worker` keep every rule in SQL: `notifications.push_claim` (lapses, expiry, bounded lease), `notifications.push_prepare` (recheck now; answers the generic message and the live targets) and `notifications.push_record` (per-device provider answers; retire invalid tokens; accepted / retry / end), plus `notifications.push_release`. The Edge worker sends through an FCM HTTP v1 adapter with an injectable transport and OAuth signer, after the inbox stage, only when the owner's service account secret is set and the operator switch `push_enabled` is on (default off). Clients get a push port, registration controller and tap handling with a default-off no-op adapter.

## Boundaries & Constraints

**Always:** payload = contract's fixed `title`/`body` + `data.item_id` only; the item id is the stable notification id (Android `collapse_key` + notification `tag`, APNs `apns-collapse-id`), provider TTL / `apns-expiration` from the push job's expiry; tokens never logged, returned to clients, or written to evidence (only the worker principal receives them in `push_prepare`); attempts record provider acceptance or failure only (`accepted`, never delivered/read); the service account is an Edge secret only (never repo/DB/chat); OAuth and FCM URLs pinned to Google except a local fake when `SUPABASE_URL` is plain http; new SQL prefixed, `search_path = ''`, no client grants, ASCII, non-destructive, no `delete from`, version after `20261008135900`; deletion stays covered by the existing rows file (push attempts live in `app.notifications_attempts`); no deploy or hosted change.

**Never:** committing Firebase config (google-services.json, GoogleService-Info.plist, firebase_options with real ids); adding firebase packages; settings/inbox/snooze screens (entry 7); health view (entry 8); browser push; promising delivery or exactly-once.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Accepted | live token, FCM 200 | attempt `accepted`; push job `accepted` | — |
| Invalid token | FCM 404 UNREGISTERED, 403 SENDER_ID_MISMATCH, 400 on `message.token` | attempt `token_invalid`, device retired `provider_invalid`; job ends when nothing is owed | other 400 = `rejected`, token kept |
| Transient | 429 / 5xx / network | attempt `transient`, failure counted, backoff, same notification id on retry | 429 or provider auth error stops the run; at `max_attempts` -> `failed` (`attempts_exhausted`) |
| Expired | push job past expiry | `obsolete` (`expired`) at claim or prepare, nothing sent | — |
| Stale | source not current/actionable, recipient routed away, push setting off, item snoozed, responded | `obsolete` with reason, nothing sent | check raises: transient |
| Lapse / fence | worker dies after send | next claim counts `lapsed`, resends with the same id; late record `fenced` | — |
| Off | `push_enabled` false or no Edge secret | nothing claimed; inbox unaffected | — |
| Client denied | OS permission denied | no registration; inbox item still there | — |
| Tap | payload `item_id` | app opens `/inbox/<id>`; signed out -> sign-in -> back to the item, server rechecks | malformed id ignored |

Decision (agent, under owner pre-approval): client FCM wiring is the port + no-op default-off adapter; a real `firebase_messaging` adapter needs the owner's Firebase app ids, APNs entitlement and a device, so it is a listed follow-up (owner steps in the runbook).
Decision (agent, under owner pre-approval): `push_enabled` (worker settings, default false, operator-set) is the push kill switch; with it off the Edge function never claims push jobs and they expire.
Decision (agent, under owner pre-approval): a 400 retires a token only when FCM names the `message.token` field, so a payload bug can never retire every device.
Decision (agent, under owner pre-approval): a device signing out retires its own registration first (best effort, bounded); server-side sign-out without the app is a follow-up.

</frozen-after-approval>

## Code Map

- `supabase/migrations/20261008135811_notifications_routing.sql` -- `notifications_push_jobs` (states pending/cancelled/accepted/failed/obsolete), `notifications_queue_push`, `notifications_recipient_route`, device tokens/settings, lifecycle hooks (cancel push jobs).
- `supabase/migrations/20261008121248_notifications_worker.sql` -- lease pattern to mirror (`notifications_claim`, `_release`, `_finish_job`, backoff, `_job_expiry`), `sys_command_kinds` + `sys_principal_commands` registration, `notifications_configure_worker` and `notifications_scheduler_status` (replace in place).
- `supabase/migrations/20261008090057_notifications_source_contracts.sql` -- `contract_check_reminder`, contract `title`/`body`.
- `supabase/migrations/20261008102121_notifications_scheduling.sql` -- `jobs.snoozed_from_item_id`, schedule `responded` rule (mirror the attempt's recheck).
- `supabase/migrations/20261008135900_notifications_routing_rows.sql` -- purge deletes attempts (job join) first: push attempts stay covered; no rows file needed.
- `supabase/functions/notifications-worker/{index.ts,logic.mjs}` -- add push stage after `runOnce`; keep 3.4 answer keys.
- `tools/identity-e2e/worker.mjs`, `routing.mjs`, `harness.mjs` -- serve/env-file/credential minting/cleanup patterns.
- `packages/client_core/lib/src/{application/providers.dart,presentation/shell_routing.dart,presentation/sign_in_screen.dart,presentation/inbox_screen.dart,presentation/account_screen.dart}`; `apps/mobile/lib/app.dart`.
- Pins: `system_access_test.sql` (command allowlist), `notifications_worker_test.sql` (status/settings keys), `notifications_routing_test.sql`.

## Tasks & Acceptance

**Execution:**
- [ ] `supabase/migrations/<ts>_notifications_push.sql` -- settings `push_enabled`; push-job lease/failure columns; attempt columns (`push_job_id`, `device_id`, `provider_status`, `provider_code`); claim/prepare/record/release + checks, registrations, grants to existing principals; configure/status replaced; privileges.
- [ ] `supabase/tests/notifications_push_test.sql` + pin updates -- the matrix in SQL.
- [ ] `supabase/functions/notifications-worker/{fcm.mjs,fcm.test.mjs,logic.mjs,logic.test.mjs,index.ts}` -- adapter (signer, token cache, message, classify), push run loop, wiring.
- [ ] `tools/identity-e2e/push.mjs` + `.test.mjs` -- fake FCM (OAuth + send, signature-checked) through the served function; e2e list in CI/scratch script.
- [ ] `packages/client_core` push port, registration + tap controllers, sign-in continuation, sign-out retire; `apps/mobile` bridge; widget/unit tests.
- [ ] `docs/runbooks/notifications.md` (+ system-access) -- push section, owner Firebase/APNs/secret steps, parent deploy steps, follow-ups; CI evidence scan step; evidence-3.6.

**Acceptance Criteria:**
- Given a reset local stack, when db:test, db:smoke, every E2E, contracts, tool and function tests, flutter analyze/test (client_core, mobile, staff), scan-secrets and check-migrations run, then all pass.
- Given any run, when evidence, function logs and answers are scanned, then no token, credential, service-account field or payload text beyond the fixed generic text appears.

## Implementation Notes

## Plan Change Log

## Review Triage Log

## Verification

**Commands:**
- `npx supabase db reset && npm run -s db:test && npm run -s db:smoke` -- expected: pass
- E2E loop (scratchpad `e2e-main.sh` for this worktree, plus `push`) -- expected: every suite passes
- `npm run -s contracts:test && node --test tools/**/*.test.mjs supabase/functions/*/*.test.mjs && npm run -s ci:secrets && npm run -s ci:migrations` -- expected: pass
- `flutter analyze && flutter test` in `packages/client_core`, `apps/mobile`, `apps/staff` -- expected: pass

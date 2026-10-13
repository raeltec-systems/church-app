# Review of stories 3.8 to 3.10 (commits b1c870c..3987a06), 2026-10-13

Independent review after the work was done in a separate session. Inputs: two read-only reviewers
(SQL; clients, CI and refactor) and a full local verification run on `3987a06` (db reset,
db:test, db:smoke, contracts, Flutter for client_core/staff/mobile, all 17 E2Es). Staging was
inspected read-only: its latest migration is still `20261008183514` (3.7); 3.8 is not applied and
the deployed notifications-worker is the pre-refactor version (push live, every-minute runs OK).

## Verification results on 3987a06

| Check | Result |
|---|---|
| Flutter analyze + test | pass (client_core 427, staff 31, mobile 44) |
| db:test | **FAIL**: `command_foundation_test.sql` #17 and `notifications_routing_test.sql` #2 (privilege ledgers do not list the new client-executable health read) |
| E2E | 15/17 pass; **`deletion` FAIL** (isolated restore: `schema "auth" does not exist`); **`push` FAIL** 6/12 (P20-P23, P30, P40) |

## Prioritized findings

### P1 - blocking (break deploys, CI or recovery)

1. [x] **Edge Functions import a file outside their folder.** `supabase/functions/{identity-deletion,notifications-worker}/logic.mjs` import `../../../packages/shared_runtime/system_access.mjs`. The documented MCP deploy (runbooks list only `index.ts`, `logic.mjs`, `fcm.mjs`) would fail with module-not-found and take the worker or deletion function down on the next redeploy; the CLI bundle path is unproven. The 3.9 plan's own "deploy-bundle check still needed" was not done. **Fixed 2026-10-13:** Moved to `supabase/functions/_shared/system_access.mjs`; functions import `../_shared/system_access.mjs`, Node tools import the new path, `packages/shared_runtime` removed. Deploy lists in `notifications.md` and `identity-access.md` name `../_shared/system_access.mjs`. CI step `npm run ci:function-imports` (`tools/ci/check-function-imports.mjs` + test) fails any import leaving `supabase/functions/`. `functions serve` proven by the deletion, worker and push E2Es.
2. [x] **3.8 migration breaks the backup-restore drill.** `app.ops_operators.auth_user_id ... references auth.users` makes an app-only backup unrestorable into an isolated database (deletion E2E). Recovery from backups is a core guarantee (story 2.11). **Fixed 2026-10-13:** `20261013000000` stays as merged; the new `20261013190000_notifications_health_repair.sql` (owner-approved cleanup marker, 2026-10-13) drops the FK, keeping `auth_user_id uuid unique`; triggers on `auth.users` (delete, soft delete) clear the mapping; the health read requires a live trusted session for an existing, unbanned Auth user. Deletion E2E 12/12 (isolated restore passes).
3. [x] **Push E2E broken by the new `outbound_sending` gate.** `tools/identity-e2e/push.mjs` never opens it, so nothing is sent. **Fixed 2026-10-13:** `push.mjs` approves `outbound_sending` in setup and restores the gate row exactly in cleanup (P00/P99 record it). Push E2E 12/12.
4. [x] **Staging push would stop when 3.8 is applied.** Push now needs `outbound_sending` open, but `tools/ci/verify-hosted.sql` fails staging if it is open. The rules contradict each other. **Fixed 2026-10-13:** Owner decision: staging may have the gate open. `verify-hosted.sql` accepts it on staging; production needs an approval naming production. Documented in `notifications.md` 3.6 (step 7) and 3.8.
5. [x] **db:test red.** Two privilege-ledger tests do not list the new health read. **Fixed 2026-10-13:** Health read added to the ledgers in `command_foundation_test.sql` and `notifications_routing_test.sql`. db:test green.

### P2 - should fix (wrong behaviour)

6. [x] With the gate closed, `notifications_sys_push_claim` returns early: push jobs never expire and lapsed leases are never counted (regression from 3.6). Include `expire_only`. **Fixed 2026-10-13:** `notifications_sys_push_claim` always runs the claim (expiry and lapse counting); `notifications_push_claim` leases only with the gate open; answer carries `gate_closed`. pgTAP cases added.
7. [x] The new prepare outcome `gate_closed` is unknown to the worker (`PUSH_OUTCOMES`), so a deliberate pause is counted as `unexpected`. **Fixed 2026-10-13:** `gate_closed` added to `PUSH_OUTCOMES`; `parsePushClaim` carries/validates `gate_closed`; unit test in `push-run.test.mjs`.
8. [x] Health "stale" uses `last_tick_at` (updated even on `not_configured`/`gate_closed`) instead of `last_success_at`, so a scheduler that never hands off looks healthy. **Fixed 2026-10-13:** Stale = no `last_success_at` within 5 minutes; test with fresh not_configured/gate_closed ticks.
9. [x] The direct-contact backlog counts an append-only table with no window, so it only ever grows. **Fixed 2026-10-13:** Backlog = unrouted needs recorded in the last 24 h (+ oldest due); `routed_24h`, `total_unrouted`, `total` reported separately; client and screen updated.
10. [x] Push `failed_attempts_24h` omits `failed` and `lapsed`. **Fixed 2026-10-13:** Push failures = transient + rejected + failed + lapsed + exhausted (24 h); tested.
11. [x] `verify-hosted.sql` production assertions (no scheduler job, push off) are unconditional; after the owner legitimately activates production, every later promotion fails at verify, after `db push` has already run. **Fixed 2026-10-13:** Each production assertion is conditional on its gate being unapproved (scheduler: ops_system_access + q2 + q12; push and outbound: outbound approval naming production). Offline test plus five rolled-back local runs.
12. [x] Staff health screen shows "not authorized" for every refusal (signed out, untrusted, unavailable); the nav entry is visible signed out; the "server refusal" test actually exercises the unconfigured repository. **Fixed 2026-10-13:** Per-reason refusal banners and a separate failed-read banner; nav entry hidden while signed out (own icon); refusal tests use a refusing repository for each reason.
13. [x] `scan-evidence.sh --personal-data` passes spaced international numbers and unlabeled names, and reports "clean" for a missing path or a flag passed second. **Fixed 2026-10-13:** Flags in any position; unknown flag, missing path or a bare `--personal-data` exit 2; spaced E.164 and unlabeled two-word names (vocabulary allowlist) are flagged; tests added.
14. [x] `packages/shared_runtime/*.test.mjs` is not run by CI. **Fixed 2026-10-13:** Resolved by the move: `supabase/functions/*/*.test.mjs` in the CI auth-harness job now includes `_shared`.
15. [x] Plan statuses overstated: 3.8 and 3.10 are `built` although the 3.8 staging demonstration and all 3.10 execution items are not done; the runbook has no hosted step to apply `20261013000000` or redeploy the two functions. **Fixed 2026-10-13:** 3.8 and 3.10 plans set to `in-review` with the pending owner/staging items; 3.8 runbook has a Hosted staging section (apply via MCP, redeploy both functions with `_shared`, checks).

### P3 - nits

16. [x] `notifications_sys_push_prepare` cast `::bigint` instead of `::numeric::bigint` (a JSON `5.0` lease token becomes `internal_error`). **Fixed 2026-10-13:** `::numeric::bigint`; pgTAP sends `5.0`.
17. [x] Mapped-operator path relies on the Admin check raising PT401 for an untrusted session; make it explicit and test it. **Fixed 2026-10-13:** Explicit PT401 for unauthenticated/untrusted sessions before either path; tested (no AMR claim, banned user, soft-deleted user).
18. [x] Health tests: deactivated operator, cleared mapping, push and token sections. **Fixed 2026-10-13:** Tests for deactivated operator, cleared mapping, deleted/soft-deleted Auth user, push and token sections.
19. [x] `_optionalDate` hides malformed timestamps; duplicate nav icon; `/admin/reminder-health` reachable (server-gated) from mobile. **Fixed 2026-10-13:** `_optionalDate` throws on malformed values (tested); distinct nav icon; the route is registered only on staff web (`reminderHealth: true`), mobile test proves it absent.

## Fix plan

Status 2026-10-13: phases A, B, C and the repository part of D are done (see the "Review fixes (2026-10-13)" sections in the 3.8, 3.9 and 3.10 plans). Phase D's hosted part (apply 3.8 to staging, redeploy both functions with `_shared`, re-check push and the health view) is left to the parent session and the owner, as listed in the 3.8 runbook's Hosted staging section.

**Phase A - restore green and deployability (P1).**
- Move the shared module to `supabase/functions/_shared/system_access.mjs`; tools import from there; update the deploy file lists in `notifications.md` and `identity-access.md`; add a CI step that bundles both functions (`deno check`/`supabase functions deploy --dry-run` equivalent) so an outside import fails CI.
- Edit `20261013000000` in place (it is applied nowhere hosted): drop the `auth.users` foreign key; keep `auth_user_id uuid unique` and clear it from the existing account-deletion path instead.
- Decide the `outbound_sending` rule: staging may have it open (push tests need it); production stays closed until approved. Update `verify-hosted.sql` (staging accepts open) and the 3.6/3.8 runbooks; open the gate in `push.mjs` setup and close it in cleanup.
- Add the health read to the two privilege ledgers.

**Phase B - behaviour (P2 6-10).** Gate-closed claim still expires and counts lapses; add `gate_closed` to the worker outcomes with a unit test; stale from `last_success_at` plus a test for fresh ticks with no success; direct-contact backlog = unrouted within 24 h (cumulative shown separately); include `failed`/`lapsed` in push failures.

**Phase C - release tooling and clients (P2 11-14).** Make production verify assertions conditional on each gate being unapproved; map health refusals per reason, hide the nav entry when signed out, fix and add the staff tests; harden `scan-evidence.sh` (spaced E.164, fail on missing path/unknown flag); add the shared tests to CI.

**Phase D - honest status and staging.** Set 3.8/3.10 plans to `in-review` with the pending owner items; add the staging apply/redeploy steps; after A-C pass locally (full db:test and all 17 E2Es), apply 3.8 to staging, redeploy both functions with `_shared`, re-check the live push and the health view.

P3 items ride with the phase that touches the same file.

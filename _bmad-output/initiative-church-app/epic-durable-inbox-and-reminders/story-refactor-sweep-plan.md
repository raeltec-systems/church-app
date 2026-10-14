---
title: 'Refactor sweep'
type: 'refactor'
ticket: '9'
created: '2026-10-13'
status: 'built'
baseline_revision: 'b1c870ceb0770adcff4585d9cb63e8cd8644f57f'
route: 'full'
route_source: 'auto'
review: 'quick'
review_source: 'pinned'
lenses_ran: ['quick']
review_loop_iteration: 0
context:
  - '{project-root}/docs/runbooks/contracts-and-owner-seams.md'
  - '{project-root}/docs/runbooks/system-access-and-operations.md'
  - '{project-root}/docs/runbooks/notifications.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** The notification and identity-deletion Edge functions independently implement the same request boundary primitives, and system-credential shape checks are repeated across Edge and operator tooling. These copies can drift in header construction, envelope shape, UUID validation, body-length parsing, or accepted credential formats.

**Approach:** Move the pure, runtime-neutral primitives and the canonical credential pattern into a small shared JavaScript module. Keep function-specific body limits and business rules at their current owners, and preserve existing exports where callers or tests use them.

## Boundaries & Constraints

**Always:** Preserve current request and response behavior, including legacy JWT key handling, malformed Content-Length rejection, lowercase UUID matching, credential environment/length rules, and the 256-byte notifications versus 1024-byte identity-deletion limits. Keep edge business logic, authorization, worker loops, logging, and database contracts in their current boundaries. Verify both Node tests and Supabase function bundling/import paths.

**Never:** Change SQL, migrations, APIs, fixture contracts, authorization policy, credential entropy/format, client behavior, or acceptance behavior. Do not absorb deferred push token refresh, Android icon, FCM auto-init, or session-expiry registration behavior. Do not merge worker loops, SQL lease logic, or pgTAP helpers; prior refactor records establish these as intentional boundaries. Do not edit historical build/evidence records.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Body size within limit | Missing or numeric Content-Length at/below caller limit | Request continues as before | None |
| Body size invalid/over limit | Malformed length, or 257/1025 bytes for the respective function | Existing 413 invalid response | Fail closed |
| Platform key headers | Publishable key or legacy `eyJ...` key | Existing `apikey`; add Bearer authorization only for legacy JWT | None |
| Credential boundary | Valid environment-prefixed 43-character credential or malformed value | Existing accepted value or fail-closed rejection | No credential value in logs/errors |

</frozen-after-approval>

## Code Map

- `packages/shared_runtime/system_access.mjs` -- proposed pure canonical definitions for UUID and credential patterns plus request helpers, with no Node/Deno-only dependencies.
- `supabase/functions/notifications-worker/logic.mjs` -- caller that owns the 256-byte limit and notification-specific logic.
- `supabase/functions/identity-deletion/logic.mjs` -- caller that owns the 1024-byte limit and deletion-specific logic.
- `tools/identity-deletion/worker.mjs` -- Node operator worker with duplicate credential and UUID validation.
- `tools/ci/secret-patterns.mjs` and `tools/ops/system-credential.mjs` -- scanner, scrubber, mint/digest shape validation; preserve their public exports and behavior.
- `packages/shared_runtime/system_access.test.mjs` -- focused tests for pure shared primitive boundaries.
- `supabase/functions/notifications-worker/logic.test.mjs`, `supabase/functions/identity-deletion/logic.test.mjs`, and `tools/identity-deletion/worker.test.mjs` -- existing boundary tests to extend or keep passing.
- `supabase/functions/notifications-worker/index.ts` and `supabase/functions/identity-deletion/index.ts` -- Edge import consumers; confirm deploy bundling resolves the shared module.
- `packages/client_core/lib/src/application/push_controllers.dart` and the shared `SupabaseApiReader` -- client code already uses a common API reader; the remaining push-registration behavior is tracked as deferred work, so no client cleanup is selected.

## Tasks & Acceptance

**Execution:**
- [x] `packages/shared_runtime/system_access.mjs` -- define pure shared patterns and helpers -- provide one source for request and credential primitives without imposing a caller's body limit.
- [x] `supabase/functions/notifications-worker/logic.mjs` and `supabase/functions/identity-deletion/logic.mjs` -- delegate duplicated primitives to the shared module while retaining each local `MAX_BODY_BYTES` and stable public API -- remove drift without changing behavior.
- [x] `tools/identity-deletion/worker.mjs`, `tools/ci/secret-patterns.mjs`, and `tools/ops/system-credential.mjs` -- use/re-export the shared credential and UUID definitions as appropriate -- keep operator and scanner checks aligned with Edge validation.
- [x] `packages/shared_runtime/system_access.test.mjs` and relevant existing `.test.mjs` files -- cover shared boundaries and retain per-function size, header, envelope, and malformed credential assertions -- prevent contract weakening.
- [x] `supabase/functions/*/index.ts` -- inspect both Edge entrypoints' shared import resolution and deploy-bundle compatibility -- ensure production functions can load the module.

**Acceptance Criteria:**
- Given the shared helper is called with either function's existing byte limit, when the Content-Length is absent, malformed, at/below, or above the limit, then its result and each function's HTTP response match current behavior.
- Given publishable or legacy JWT keys and valid or malformed system credentials, when either function or operator tooling validates them, then headers and acceptance/rejection remain unchanged.
- Given the Edge functions are bundled for deployment, when the shared module is resolved, then both bundles succeed without runtime-specific imports or behavior changes.
- Given the affected Node test suites run, when all assertions complete, then tests pass without weakening existing permission, scheduling, worker, client, or lifecycle checks.

## Implementation Notes

## Plan Change Log

## Review Triage Log

- maybe-false / defer — The prescribed `supabase functions serve` command started the Edge Runtime and listed both entrypoints without import errors, but this environment has no Kong container and requests to the local function port failed; a real invocation or deploy-bundle check is still needed to confirm the external shared-module imports execute.
- medium / patch — carried: `tools/identity-deletion/worker.mjs` had changed legacy JWT headers from apikey-only to Bearer authorization; the implementation restored apikey-only behavior and added a regression assertion in `tools/identity-deletion/worker.test.mjs`.
- false / reject — Direct requests to the Edge Runtime container loaded both entrypoints and the shared module; identity-deletion returned 401 when the credential was missing, while 257-byte and 1025-byte requests returned the expected 413 responses and exact-limit requests returned 400 invalid-body responses. The missing Kong container prevented the gateway URL, but did not block runtime execution.
- false / reject — The final worker still constructs its system-route headers with `apikey` and no `authorization`; the added legacy-key regression assertion passed, so the previously reported behavior is absent.

## Design Notes

The shared module must stay independent of `tools/` and function-specific policy so both Deno Edge code and Node tooling can import it. Keep `MAX_BODY_BYTES` local to each function and pass the limit into the shared length parser. Keep the credential regex as a source string for the scanner's existing pattern API, with an anchored `RegExp` export for validators. UUID checks remain the same lowercase pattern; no UUID normalization is introduced.

## Verification

**Commands:**
- `node --test supabase/functions/notifications-worker/logic.test.mjs supabase/functions/identity-deletion/logic.test.mjs tools/identity-deletion/worker.test.mjs tools/ci/*.test.mjs tools/ops/*.test.mjs` -- expected: all affected primitive, worker, secret scanning, and credential tooling tests pass.
- `supabase functions serve notifications-worker --no-verify-jwt` and `supabase functions serve identity-deletion --no-verify-jwt` (or equivalent bundle checks available in this repository) -- expected: both entrypoints resolve the shared module; do not send production credentials or invoke destructive actions.
- `git diff --check` -- expected: no whitespace errors.

**Manual checks:**
- Compare the existing 256/1024 byte boundaries, legacy key headers, envelope fields, and valid/malformed credential cases before and after the extraction. Confirm deferred client behaviors and SQL files remain untouched.

## Review fixes (2026-10-13)

Source: `review-3.8-3.10.md` findings 1 and 14. The shared module the sweep introduced in
`packages/shared_runtime/` was outside the Edge Function deploy boundary: the documented MCP deploy
(`index.ts`, `logic.mjs`, `fcm.mjs`) would have failed with module-not-found.

- Moved to `supabase/functions/_shared/system_access.mjs` (+ test), the Supabase convention for
  shared function code; `identity-deletion` and `notifications-worker` import
  `../_shared/system_access.mjs`; `tools/identity-deletion/worker.mjs`, `tools/ops/system-credential.mjs`
  and `tools/ci/secret-patterns.mjs` import the new path; `packages/shared_runtime/` removed.
- CI: `npm run ci:function-imports` (`tools/ci/check-function-imports.mjs`, 5 tests in
  `check-function-imports.test.mjs`) fails when any file under `supabase/functions/` imports a path
  outside it or a missing file; the shared test now runs in the CI auth-harness job through
  `supabase/functions/*/*.test.mjs`.
- Runbooks: the deploy file lists in `notifications.md` and `identity-access.md` include
  `../_shared/system_access.mjs` (name relative to the entrypoint folder for MCP
  `deploy_edge_function`; the CLI bundles `_shared` itself).
- `supabase functions serve` serves both functions with the shared module (deletion, worker and
  push E2Es pass). The hosted redeploy of both functions is listed in the 3.8 plan's pending items.

Status stays `built`: no owner item belongs to this refactor beyond the 3.8 staging redeploy.

**Full local verification (after all review fixes):** `npx supabase db reset`; `npm run -s db:test` (26 files, 2144 tests, PASS); `npm run -s db:smoke` (exit 0); `npm run -s contracts:test` (242); `npm run -s ci:policy-test` (56); `node --test tools/auth-harness/*.test.mjs tools/identity-e2e/*.test.mjs supabase/functions/*/*.test.mjs tools/identity-deletion/*.test.mjs tools/notifications/*.test.mjs` (156, includes `_shared`); `ci:secrets`, `ci:migrations -- --base origin/main` (34), `ci:function-imports`, `env:check` and all 23 CI evidence scans clean; Flutter analyze clean and tests pass for `packages/client_core` (428), `apps/staff` (33), `apps/mobile` (45); `verify-hosted.sql` exercised locally in five rolled-back marker/gate cases. E2E, each after a reset:

```
run exit=0 
grants exit=0 
apply exit=0 27/27 checks passed 
review exit=0 18/18 checks passed 
cells exit=0 13/13 checks passed 
recovery exit=0 20/20 checks passed 
credentials exit=0 15/15 checks passed 
assisted exit=0 16/16 checks passed 
lifecycle exit=0 9/9 checks passed 
deletion exit=0 12/12 checks passed 
runbooks exit=0 16/16 checks passed 
inbox exit=0 13/13 checks passed 
source-contracts exit=0 10/10 checks passed 
worker exit=0 17/17 checks passed 
routing exit=0 18/18 checks passed 
push exit=0 12/12 checks passed 
inbox-screens exit=0 12/12 checks passed
```

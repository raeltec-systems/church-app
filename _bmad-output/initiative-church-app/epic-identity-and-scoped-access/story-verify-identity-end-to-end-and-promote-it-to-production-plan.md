---
title: 'Verify identity end to end and promote it to production'
type: 'chore'
ticket: '14'
created: '2026-10-07'
status: 'in-progress'
baseline_revision: 'aca0241196bee6cedb930bc3b7448e6f52851f5e'
route: 'full'
route_source: 'auto'
review: ''
review_source: ''
lenses_ran: []
review_loop_iteration: 0
context: ['{project-root}/docs/runbooks/identity-access.md', '{project-root}/docs/runbooks/environments-and-promotion.md']
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** Stories 2.1-2.13 proved identity on the local stack and with spot checks on staging, but there is no closing staging run of the integrated workflows and the full role/combined-role permission matrix, no independent rerun of the entry 2 / entry 9 security cases on staging, and no ordered production promotion package with the Q1/Q4 gates.

**Approach:** Build both clients cleanly for staging; add an automated, staging-only, synthetic-only API suite (`tools/identity-e2e/staging-suite.mjs`) that runs every workflow reachable without owner secrets plus the full permission matrix with exact expected codes and the security reruns; run it and record evidence; write the production promotion package and the owner demonstration script; leave production and the owner-only items open (`blocked`).

Decision (agent, under owner pre-approval): production is not touched; the entry stays open (`blocked`) for the production project, SMTP sender, first real Admin and the owner demonstration, as the ticket's `unknown` says.

Decision (agent, under owner pre-approval): the send-email hook chosen on 2026-10-07 (owner decision 2) is not built in this entry. Production email recovery stays fail-closed (`q1_auth_recovery` unapproved) until the owner creates the sender account; the hook becomes its own deferred-work entry and a listed gate in the promotion package.

Decision (agent, under owner pre-approval): `lead_pastor` is assigned only by the restricted operator (SQL); the suite proves Admin cannot grant it and records the lead-pastor combined-role row as an owner step instead of writing SQL on staging.

Decision (agent, under owner pre-approval): the suite keeps its synthetic personas between runs in a state file OUTSIDE the repository (passwords never in the repo, never printed), reusing accounts and drawing deletion subjects from a numbered pool (`+1 202 555 0120-0149`), because staging Auth users cannot be deleted without the owner and fictional numbers are finite.

Decision (agent, under owner pre-approval): an observed platform behaviour that the runbooks say to record rather than fix (gateway `x-forwarded-for` handling) is logged as a `finding`, separate from pass/fail.

## Boundaries & Constraints

**Always:** Staging origin `https://tmurpotfluignacfueki.supabase.co` only (exact-origin guard); publishable key only; fictional numbers `+1 202 555 0100-0199` only, SYNTHETIC names, no email sends; evidence redacted (no token, password, grant secret, digest, request code, phone or email); every admin probe in the matrix uses a payload that must fail validation so nothing is mutated; read-only SQL on staging for readbacks.

**Never:** Production; applying migrations, deploying functions or changing Auth settings on staging; SMS settings; service-role/secret keys; owner credentials; committing state or passwords; weakening existing tests.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Non-staging origin | `--origin http://127.0.0.1:54321` or any other | refuses before any request | exit 1 |
| State file in repo | `STAGING_SUITE_STATE` under the git worktree | refuses | exit 1 |
| Auth 429 | sign-in/sign-up rate limit | waits and retries (bounded) | fails after the bound |
| Function per-client limit | >10 attempts/10 min | suite paces itself; unexpected `rate_limited` waits one window | step fails after one retry |
| Matrix cell | principal x surface | exact HTTP status + detail (reads) or envelope code (commands) | mismatch = FAIL line |

</frozen-after-approval>

## Code Map

- `tools/identity-e2e/harness.mjs` -- reuse `redact`, `amrMethods`, `sleep`, `EPOCH_WAIT_MS`; local-only parts (`localKey`, `psql`, `assertLocalOrigin`) are not used.
- `tools/identity-e2e/{grants,review,cells,credentials,assisted,lifecycle,deletion,run}.mjs` -- the local scenarios the staging suite mirrors (command names, payloads, expected codes).
- `/tmp/.../scratchpad/stg2*.mjs` -- earlier staging probes (sign-up, application, approve, assisted request/redeem through `functions/v1/identity-assisted-recovery`).
- Access rules: `app.identity_require_access/require_grant/applicant_outcome`, `app.identity_authorize_command` (admin list, member credential, withdraw), `app.cells_authorize_command`, `app.cmd_execute` (envelope validation precedes authorization; failures roll back the receipt).
- `docs/runbooks/environments-and-promotion.md` -- promotion workflow (no Edge Function step; production phone provider note conflicts with identity's phone sign-in).
- `docs/runbooks/identity-support.md` RB1 -- open first-real-Admin question.
- `.github/workflows/ci.yml` -- runs `tools/identity-e2e/*.test.mjs` with node --test.

## Tasks & Acceptance

**Execution:**
- [x] scratchpad `build-2.14.sh` -- clean staging builds: arm64 release APK and sealed staff web; hashes and logs to `evidence-2.14/builds/`.
- [x] `tools/identity-e2e/staging-suite.mjs` (+ `staging-suite.test.mjs`) -- origin/phone/state guards, personas, matrix, scenarios, security reruns, pacing, redacted JSONL + summary.
- [x] `evidence-2.14/` -- `staging-suite.jsonl`, `staging-suite-summary.md`, `security-checks.md`, `builds.md`, `owner-demonstration.md`, `README.md`.
- [x] `docs/runbooks/production-promotion-identity.md` (+ link from `environments-and-promotion.md`) -- ordered production steps with every gate.
- [x] `deferred-work.md` -- send-email hook entry (plus first-Admin/dormancy procedure and the promote.yml function step).

**Acceptance Criteria:**
- Given staging, when the suite runs, then every check passes or is an explicitly listed owner/local-only item, and the matrix covers every role and combined role against every `api` read and command.
- Given the repo, when the full local verification runs, then all existing checks still pass.

## Implementation Notes

- Builds (scratchpad `build-2.14.sh`, commit `aca0241`): arm64 release APK sha256 `c0391f96…5ebc83`; staff web sealed tree `9a1f2f03…53a8`, refused as production; both bundle scans clean. `evidence-2.14/builds.md`.
- Suite `tools/identity-e2e/staging-suite.mjs` (+ 9 unit tests in `staging-suite.test.mjs`, picked up by the existing CI glob): exact-origin, fictional-range, state-outside-repo and publishable-key guards; personas converged idempotently from a 0600 state file; paced to Auth (25 sign-ins/5 min) and to the function's per-client (10/10 min) and per-number (5/h) limits, all persisted between runs; heals personas a broken run left held or deactivated (assisted reset when a hold needs the member's own reset).
- Matrix expectations derived from the SQL (`identity_require_access/require_grant/applicant_outcome`, the identity and cells authorizers, `cmd_execute` order). Two expectations were corrected after the first staging run, both by reading the code, not by copying results: the system route refuses every user session with `forbidden` (`sys_execute` step 1, `user_session_rejected`), and `cells.create_cell`/`update_cell` check Admin before the payload.
- X18 finding (recorded, not a defect): with `phone_autoconfirm` Auth accepts a direct `PUT /user` phone change; Identity's binding review holds the account in `review_required`, and the Admin restore returns the approved number. A run where the same persona had also changed its password directly showed C51 (restore keeps a security hold); X19/X20 moved to a second persona.
- Credential-change requests are limited to 5 per account per 24 h; the suite rotates four subjects (3 requests per run).
- Production package `docs/runbooks/production-promotion-identity.md` (linked from environments-and-promotion.md C3/C8 and identity-support.md RB1). Found while writing it: no operator path to approve `dormancy_days`, no first-real-Admin path, no function deploy step in `promote.yml`, send-email hook not built: all recorded as gates and deferred-work entries; production stays fail-closed.
- CI: scan-evidence step for evidence-2.14, the suite and the production package.
- No change under `apps/`, `packages/`, `supabase/`.

## Plan Change Log

## Review Triage Log

## Verification

**Commands:**
- `node tools/identity-e2e/staging-suite.mjs --evidence <evidence-2.14>/staging-suite.jsonl` -- expected: all checks pass, findings listed.
- `node --test tools/identity-e2e/*.test.mjs` -- expected: pass.
- `npx supabase db reset && npm run db:test && npm run db:smoke`, the 11 identity E2Es, `npm run contracts:test`, `npm run ci:secrets`, `npm run ci:migrations` -- expected: unchanged results.

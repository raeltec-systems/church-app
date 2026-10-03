---
title: 'Refactor sweep'
type: 'refactor'
ticket: '11'
created: '2026-10-03'
status: 'built'
baseline_revision: '33940ed7e354f8ff83255695ddfa5db2f6552236'
route: 'full'
route_source: 'auto'
review: ''
review_source: ''
lenses_ran: []
review_loop_iteration: 0
context: []
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** Stories 1.1 and 1.3–1.10 left duplication and drift that later stories would copy: the four `db:smoke` scripts each re-implement local-stack env loading, the psql/docker fallback and synthetic-user creation; the system-credential format is written out three times in JS; CI repeats the npm policy commands inline; and one tool header and two runbooks contradict the current code.

**Approach:** Apply only cleanup that the build records justify and that leaves behaviour, contracts and acceptance unchanged. Each step is rerun-verified against the existing checks. Every other candidate is rejected or deferred below with a reason.

- Decision (agent, under owner pre-approval): no SQL change. Merged migrations are immutable (CI policy). A new migration that only consolidates revoke loops would add hosted-apply work while staging still lacks `20261003161000_recovery_journal` (owner-blocked), and it would have no caller.
- Decision (agent, under owner pre-approval): the auth harness (`tools/auth-harness/**`) is left untouched. 1.2 is blocked on an owner provider decision, and its scan patterns encode a different, stricter evidence policy.

## Boundaries & Constraints

**Always:**
- Every existing check passes with the same counts or more: db:test, db:smoke (same ok lines), contracts:test, ci:policy-test, env:check, ci:migrations `--base origin/main`, ci:secrets, recovery:rehearse, and auth-harness `node --test` plus `scan-evidence.sh`.
- Smoke scripts keep every case, message and cleanup behaviour.

**Never:**
- Edit a merged migration, add SQL, or apply anything to a hosted project.
- Implement deferred behaviour: rate limits or retention for `sys_audit`, gate-opening mechanisms, or Q4/Q12 values.
- Touch 1.2's open behaviour, the evidence directories, or completed plans' records.
- Weaken any secret pattern, contract, test or CI gate.

## Selected and rejected scope

| # | Candidate (source) | Verdict | Reason |
|---|---|---|---|
| S1 | `pg()`, env eval, `die`/`uuid`, synthetic-user curl repeated in 4 smoke scripts (1.4, 1.5, 1.9 Code Maps: "pg() … to mirror") | select | Test-helper duplication. Two copies have already diverged (`PGAPPNAME`). |
| S2 | `sysc_(local\|staging\|production)_[A-Za-z0-9_-]{43}` in `secret-patterns.mjs`, `TOKEN_RE` and `scrub` (1.9) | select | Repeated secret pattern. A format change could silently leave the scanner or the scrubber behind. |
| S3 | `ci.yml` policy job repeats the `package.json` command lines (1.8, 1.10 extended both) | select | Config duplication. The test glob already changed twice. |
| S4 | `scan-secrets.mjs` header says a bare `sb_secret_` fails bundle mode; `secret-patterns.mjs` says it does not | select | Stale comment that contradicts the code. |
| S5 | `command-foundation.md` names only 1.4 migrations, but 1.5 redefined the kernel's envelope check (`contract_check`) and added owner-prefix guards. `tracer.md` describes `db:test`/`db:smoke` as tracer-only | select | Runbook drift and missing cross-links. |
| R1 | Revoke-privilege loops in the 1.5/1.10 migrations | reject | Immutable migrations. See the decision above. |
| R2 | Merge `scan-evidence.sh` patterns into `secret-patterns.mjs` | reject | A different policy: evidence forbids publishable keys and harness shapes. Auth lane, 1.2 blocked. |
| R3 | `auth-harness/lib.mjs` scrub vs ops scrub | reject | Structured key redaction vs exact known-secret replacement. |
| R4 | ClickHouse log-scan SQL (ops vs auth-harness) | reject | Different projects and shapes. Evidence cites these files by path. |
| R5 | pgTAP `pg_temp` helpers | reject | `supabase test db` runs each file in its own session with no include mechanism. The helpers differ. |
| R6 | Mobile vs staff widget tests | reject | The shared harness is already in `client_core/testing.dart` (1.7 #12). The rest is shell-specific. |
| R7 | `trials/staff_web` copy of the platform-status code | reject | A disposable 1.6 evidence app, kept until the owner signs off Q10. |
| R8 | `rehearse.mjs` `localEnv()` | reject | JS, one caller. Sharing with bash is not worth a cross-language helper. |
| R9 | `isMain` idiom and small argv helpers | reject | One-liners with no drift risk. |
| R10 | 1.5 plan Code Map names a non-existent `20261003170000_…` file. Evidence READMEs carry older test counts | reject | Historical build records, not live docs. |
| R11 | deferred-work: features gate coupling (1.8), `sys_audit` growth (1.9). 1.3 deferred B/C/F/G/H | defer | Feature or production behaviour (release epic, Q12, AD-20). Not cleanup. |
| R12 | `RESTRICTED_OPERATORS` and `'israel'` repeated in config, SQL and smoke | reject | Deliberate reviewed policy data. The runbook documents both places. |
| R13 | The `sysc_` regex in migration `20261003154040` | reject | Immutable. S2 covers the JS side only. |

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Smoke, stack up | `npm run db:smoke` | Same ok lines as the baseline (56 ok, 0 FAIL, 223 fixture cases, 15 matrix cases) | — |
| Smoke, no host psql | `psql` not on PATH | `pg` falls back to the `supabase_db_` container | — |
| Stack down | status missing a var | The script aborts before any request | `: "${VAR:?}"` message, non-zero exit |
| Credential format | minted token | `TOKEN_RE` matches, `findSecrets` flags it, `scrub` redacts it, all from one pattern | Malformed token still throws in `digestOf` |

</frozen-after-approval>

## Code Map

- `supabase/tests/{api_smoke,command_api_smoke,contract_fixtures_check,system_api_smoke}.sh` -- each evals `npx supabase status -o env`. Three define `pg()` (only `command_api_smoke` passes `PGAPPNAME` into docker). Two create a synthetic user through admin POST, then a password token. The cleanup traps differ per script and stay local.
- `tools/ci/secret-patterns.mjs` -- `RULES` (system_credential rule). It is the lowest-level module: `environments.mjs` imports it, and `system-credential.mjs` imports `environments.mjs`. A shared constant must live here to avoid an import cycle.
- `tools/ops/system-credential.mjs:26,64` -- `TOKEN_RE` and the `scrub` regex.
- `.github/workflows/ci.yml` policy job -- the inline `node …` lines repeat `package.json` scripts (`ci:policy-test`, `env:check`, `ci:migrations`, `ci:secrets`, `ci:drift:staging`). This job runs no `npm ci`, but `npm run` needs no dependencies for these scripts.
- `tools/ci/scan-secrets.mjs:5-6` -- the header comment.
- `docs/runbooks/command-foundation.md`, `docs/runbooks/tracer.md` -- the drift described in S5.

## Tasks & Acceptance

**Execution:**
- [x] `supabase/tests/lib/local_stack.sh` (new) -- `require_local_stack VAR…`, `pg`, `sql`, `uuid`, `die`, `synthetic_user_create`, `synthetic_user_token` -- one helper for S1.
- [x] The four smoke scripts -- source the helper and delete their local copies, leaving cases unchanged.
- [x] `tools/ci/secret-patterns.mjs`, `tools/ops/system-credential.mjs` (+ test) -- export `SYSTEM_CREDENTIAL_PATTERN` and derive all three regexes from it. Add a test that a non-env prefix and a 42-char body are refused by all three.
- [x] `.github/workflows/ci.yml` -- the policy job calls the npm scripts.
- [x] `tools/ci/scan-secrets.mjs` -- correct the header.
- [x] `docs/runbooks/command-foundation.md`, `docs/runbooks/tracer.md` -- fix the drift and add cross-links.

**Acceptance Criteria:**
- Given the cleanup, when every listed check reruns, then each passes with counts ≥ baseline and the smoke ok lines are identical.
- Given `git diff --stat`, then no file under `supabase/migrations/`, `tools/auth-harness/`, `evidence-*` or a completed plan changed.

## Implementation Notes

Implemented directly (no coding subagent was available to this builder). Touched files: `supabase/tests/lib/local_stack.sh` (new), `supabase/tests/{api_smoke,command_api_smoke,contract_fixtures_check,system_api_smoke}.sh`, `tools/ci/secret-patterns.mjs`, `tools/ops/system-credential.mjs` (+ test), `tools/ci/scan-secrets.mjs`, `.github/workflows/ci.yml`, `docs/runbooks/command-foundation.md`, `docs/runbooks/tracer.md`. Nothing changed under `supabase/migrations/`, `tools/auth-harness/`, `evidence-*` or any Flutter package, and nothing was applied to a hosted project.

- S1: the helper only defines functions. `require_local_stack` replaces each script's `eval` plus `: "${VAR:?}"`. Its abort message is now uniform ("supabase status did not report VAR"), and the exit stays non-zero. The docker fallback now passes `PGAPPNAME` for every script, which is harmless where it is unused. Cleanup traps, cases and messages are unchanged. `supabase test db` ignores the `.sh` file in `tests/lib/`, and still reports 5 files.
- S2: the shared constant lives in `secret-patterns.mjs`, because `environments.mjs` imports that module and `system-credential.mjs` imports `environments.mjs`. Putting it in `system-credential.mjs` would create an import cycle. Boundary semantics are unchanged: the scan uses `\b…(?![A-Za-z0-9_-])`, `TOKEN_RE` uses `^…$` and the scrubber is unanchored. A new test asserts that all three accept and refuse the same shapes.
- S3: `npm run` needs no `npm ci` for these node-only scripts. The drift script still skips with exit 0 when `SUPABASE_ACCESS_TOKEN` is empty (checked locally). `promote.yml` already runs `ci.yml` through `workflow_call`, so it inherits the change.

Verification, before → after (local stack reset from this worktree's migrations both times):

| Check | Before | After |
|---|---|---|
| `npm run db:test` | 5 files, 357 tests PASS | 5 files, 357 PASS |
| `npm run db:smoke` | exit 0, 56 ok, 0 FAIL (ok-line md5 `87745dd9…`) | identical md5, 56 ok, 0 FAIL |
| Helper fallback | — | psql hidden from PATH → `pg` uses the db container. A missing var aborts with exit 1 |
| `npm run contracts:test` | 226 pass | 226 pass |
| `npm run ci:policy-test` | 47 pass | 48 pass (+1 shared-shape test) |
| `npm run env:check` | valid | valid |
| `npm run ci:migrations -- --base origin/main` | 8 ordered, non-destructive | same |
| `npm run ci:secrets` | clean, 968 files | clean, 970 files (the helper and this plan are now tracked) |
| `npm run recovery:rehearse` | `problems: []` | `problems: []` |
| auth-harness `node --test` / `scan-evidence.sh` | 22 pass / clean | 22 pass / clean |
| Flutter analyze/test | not run, because no package was touched | — |

## Plan Change Log

## Review Triage Log

## Verification

**Commands:**
- `npx supabase db reset && npm run db:test` -- expected: 5 files, 357 tests PASS (baseline 357).
- `npm run db:smoke` -- expected: exit 0, ok/FAIL lines byte-identical to baseline (56 ok).
- `npm run contracts:test` (226), `npm run ci:policy-test` (47 → 48), `npm run env:check`, `npm run ci:migrations -- --base origin/main`, `npm run ci:secrets`, `npm run recovery:rehearse` (`problems: []`) -- expected: all exit 0.
- `node --test tools/auth-harness/*.test.mjs` (22) and `bash tools/auth-harness/scan-evidence.sh` -- expected: unchanged and clean.
- No Flutter package is touched, so no flutter analyze/test applies (state this in the report).

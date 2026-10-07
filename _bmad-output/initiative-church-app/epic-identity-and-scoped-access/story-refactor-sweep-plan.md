---
title: 'Refactor sweep'
type: 'refactor'
ticket: '13'
created: '2026-10-07'
status: 'built'
baseline_revision: '1fff4a71f9a2e9087bd008ae47c50d5dd76cfb66'
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

**Problem:** Stories 2.1-2.12 left maintainability debt: every identity E2E (`tools/identity-e2e/*.mjs`) carries its own copy of the stack/psql/reporting/HTTP harness; the member-summary adapter duplicates the refresh-once read flow and denial mapping of `SupabaseApiReader` (which imports `isJwtRejection` backwards from it); retired database objects are tracked only in scattered prose.

**Approach:** Behaviour-preserving cleanup only. Selected list (one-line justification each):
1. **Shared E2E harness** (`tools/identity-e2e/harness.mjs`): `localKey`, `psql`, `sleep`, the epoch/resend waits, the evidence reporter (`log`/`check`/summary/exit code), the local HTTP client and the main-guard move out of 11 copies; `run.mjs` re-exports `assertLocalOrigin`/`redact`/`amrMethods`. Justification: ~40 identical lines x 11 files; the 2.1/2.2/2.3 triage fixes had to be repeated per file.
2. **One read flow for the member summary**: `SupabaseMemberAccessRepository` delegates to `SupabaseApiReader` and maps `AccessRead` to `MemberAccessResult`; `memberAccessDenialFor` is derived from `accessDenialFor` (`notGranted` -> `reviewRequired`, as today); `isJwtRejection` lives with the reader. Justification: two copies of the 2.2 refresh-once rule and two denial maps can drift (inconsistent error-code mapping).
3. **Retired-object ledger**: one table in `docs/runbooks/contracts-and-owner-seams.md` listing every `retired_*` object awaiting an owner-approved drop, plus a pgTAP test pinning that set. Justification: retired tables (1.9/2.3/2.12) are not in `app.contract_retired_functions` and are recorded only in prose.

Decision (agent, under owner pre-approval): no database migration. The only repeated SQL is inline (e.g. the admin-role `for update` lock in 10 command bodies); consolidating it means re-creating large hosted command bodies for no behaviour gain, the riskiest possible diff. Recorded as not selected.

Decision (agent, under owner pre-approval): the 2.7 triage item "receipts keep email/phone/name in result" (deferred to 2.13) changes stored command results and replay answers, i.e. behaviour; it becomes its own deferred-work entry, not part of this sweep.

**Not in scope (own entry / owner decision):** session persistence across restarts; applicant-without-member deletion; handover/lifecycle/deletion hooks for future owners; production send-email hook / SMTP sender (Q1); WAF/edge rule and attempt-row retention; command-receipt PII minimisation (new deferred entry); stolen-session password change via `PUT /user`; staff reclaim of `/otp`-squatted numbers; unauthenticated `sys_audit` growth (Q12); staging runs of the 2.7-2.12 matrices (owner consolidated test); SQL admin-lock helper; per-controller `_refusal` maps (domain-specific, not duplication); `ops_`/`rcv_require_operator` twins (platform module boundary).

## Boundaries & Constraints

**Always:** Every check that passes before passes after with unchanged expectations: pgTAP, db:smoke, recovery rehearsal, all 11 identity E2Es (reset before each), contracts tests with unchanged fixtures, node unit tests, flutter analyze + test (client_core, staff, mobile), scan-secrets, scan-evidence, check-migrations. E2E step names, checks and evidence line shapes stay the same. Public Dart exports stay available.

**Never:** No migration; no change to `api.*`, the v1 contract or fixtures; no change to the owner-paste functions; no new behaviour; no weakened or deleted test assertion; no secrets.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| E2E run | any identity E2E on the local stack | same checks, same `N/N checks passed`, same JSONL fields | non-local origin still refused |
| Summary refresh | PGRST301/303 then success / refusal | refresh once, retry; refused refresh -> signedOut | second rejection -> failed, session kept |
| Summary denial | forbidden + not_granted | `reviewRequired` (unchanged) | unknown message -> failed |

</frozen-after-approval>

## Code Map

- `tools/identity-e2e/{run,grants,apply,review,cells,recovery,credentials,assisted,lifecycle,deletion,runbooks}.mjs` -- each `main()` repeats `localKey`, `psql`, `sleep`, `EPOCH_WAIT_MS`, `--evidence` parsing, `log`/`check`, `http`, `password`, summary/exit and the `process.argv[1]` guard. Variants: `apply` reads no secret/service key; `assisted`/`runbooks` psql pipe stderr; `assisted` http adds `sink`/`xff`; `runbooks` http uses `redirect: 'manual'` and returns `location`; `deletion` http adds `headers`, psql takes a db name. Keep per-file `isFictional*` ranges and exported helpers (their `.test.mjs` import them).
- `tools/identity-e2e/run.test.mjs` -- imports `amrMethods, assertLocalOrigin, isFictional, redact` from `run.mjs`: keep re-exports.
- `.github/workflows/ci.yml` -- runs `tools/identity-e2e/*.test.mjs`: put the harness test at `tools/identity-e2e/harness.test.mjs`.
- `packages/client_core/lib/src/adapters/supabase_api_reader.dart` -- generic refresh-once reader + `accessDenialFor`.
- `packages/client_core/lib/src/adapters/supabase_member_access_repository.dart` -- duplicate flow; exported via `lib/supabase_adapters.dart` (keep `isJwtRejection`, `memberAccessDenialFor` public). Summary rpc is sent with no params today; keep that (nullable params).
- `packages/client_core/test/identity/identity_adapters_test.dart` -- existing adapter tests stay unchanged.
- `docs/runbooks/contracts-and-owner-seams.md` (Retired functions bullet), `docs/runbooks/identity-access.md` (lines ~251, ~270) -- retired-object prose.

## Tasks & Acceptance

**Execution:**
- [x] `tools/identity-e2e/harness.mjs` (+ `harness.test.mjs`) -- shared harness with the variants above as options -- remove 11 copies.
- [x] `tools/identity-e2e/*.mjs` -- use the harness; keep scenario code byte-identical apart from the replaced helpers.
- [x] `packages/client_core/lib/src/adapters/supabase_api_reader.dart`, `supabase_member_access_repository.dart` -- delegate and derive the mapping; add a test that every `AccessDenial` maps as before.
- [x] `docs/runbooks/contracts-and-owner-seams.md`, `identity-access.md` -- retired-object ledger; prose points to it.
- [x] `supabase/tests/retired_objects_ledger_test.sql` -- pin the retired object set and its zero client privileges.
- [x] `_bmad-output/initiative-church-app/deferred-work.md` -- add the receipt-PII entry.

**Acceptance Criteria:**
- Given the baseline and the change, when the full check set runs, then every result matches (counts may only grow by the new tests).
- Given the diff, when inspected, then no file under `supabase/migrations/` or `packages/contracts/` changed.

## Implementation Notes

- Harness: `startRun` (evidence/log/check/finish), `localKey({ admin })`, `psql(sql, { captureStderr })`, `dbContainer`, `localHttp(keys, { redirect, onText })` with per-call `token/admin/profile/headers/xff/sink`, `password`, `sleep`, `EPOCH_WAIT_MS`, `RESEND_WAIT_MS`, `runMain`. `run.mjs` and `grants.mjs` keep their own `PASS: N checks` summary and `process.exit` (their output shape is unchanged); `apply.mjs` still reads only the publishable key; `assisted`/`runbooks` keep psql stderr captured; `deletion` keeps its own `psqlIn` (db name, stdin). `assisted` now finds the db container by name filter like the others (same container locally).
- Member summary: `SupabaseMemberAccessRepository` wraps `SupabaseApiReader.read('identity_my_member_summary', null, MemberSummary.fromJson)` (params made nullable so no params are sent, as before). `memberAccessDenialOf(AccessDenial)` is the single mapping (`notGranted` -> `reviewRequired`); `memberAccessDenialFor` is derived from `accessDenialFor`. `isJwtRejection` moved to `supabase_api_reader.dart` and is re-exported from the member-access file, so `supabase_adapters.dart` exports are unchanged. New `test/identity/member_access_mapping_test.dart` pins the pre-2.13 table; existing adapter tests untouched.
- Ledger: table in `contracts-and-owner-seams.md` (Owner registry and guards); `identity-access.md` prose links to it. `supabase/tests/retired_objects_ledger_test.sql` pins the 13 retired relations/functions in app/api/public, checks the function subset equals `app.contract_retired_functions`, and zero privileges for anon/authenticated/service_role/public.
- Deferred: receipt-PII minimisation entry added to `deferred-work.md`.
- No migration, no change under `supabase/migrations/` or `packages/contracts/`.

## Plan Change Log

## Review Triage Log

## Verification

**Commands:**
- `bash /tmp/claude-0/-home-user-church-app/53f9d846-6f17-5fcb-9db8-59c7e3ac6bf0/scratchpad/verify-2.13.sh after` -- expected: identical to `v213-before/summary.txt` except new test counts.
- `git diff --stat 1fff4a71f9a2e9087bd008ae47c50d5dd76cfb66 -- supabase/migrations packages/contracts` -- expected: empty.

**Results (2026-10-07, local stack, after the change):**
- 11 identity E2Es, reset before each: run 30, grants 18, apply 27/27, review 18/18, cells 13/13, recovery 20/20, credentials 15/15, assisted 16/16, lifecycle 9/9, deletion 12/12, runbooks 16/16 -- identical to the 2.12 baseline runs.
- pgTAP 18 files / 1487 tests PASS (baseline 17 / 1482; +5 ledger tests; mutation check: an unlisted `retired` table or a client grant makes it fail). db:smoke ok=138 notok=0; recovery:rehearse 0.
- contracts:test 239/239 (fixtures unchanged); ci:policy-test 49; node unit 90 (baseline 87, +3 harness tests); ci:migrations 0; ci:secrets 0; scan-evidence clean for every evidence folder.
- flutter analyze clean and tests pass: client_core 348 (baseline 345, +3 mapping tests), staff 26, mobile 27.
- `git diff --stat 1fff4a7 -- supabase/migrations packages/contracts`: empty.


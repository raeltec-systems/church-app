---
title: 'Install the transactional API command foundation'
type: 'feature'
ticket: '4'
created: '2026-10-03'
status: 'done'
baseline_revision: 'dfa367db1bae7ae6ade7dfab75cfaf2de99b853a'
route: 'full'
route_source: 'auto'
review: ''
review_source: ''
lenses_ran: []
review_loop_iteration: 0
context:
  - '{project-root}/_bmad-output/initiative-church-app/architecture-church-app/architecture-church-app.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** The tracer (1.1) only proves an allowlisted read. Feature epics need one reusable, tested way to change state through `api`: versioned envelope, current-actor authorization, revision locking, payload-bound receipts and safe errors, all in one transaction.

**Approach:** One migration adds a command kernel in `app` (envelope validation, actor resolution, authorization seam, receipt reservation and replay, error mapping) and one synthetic aggregate (`app.fixture_counters`) with create/increment commands exposed through one invoker `api` RPC. pgTAP proves privileges and single-session semantics; an HTTP script proves duplicate, replay, stale, simultaneous, rollback and revoked-authority outcomes through PostgREST.

## Decisions

- Decision (agent, under owner pre-approval): current actor = `auth.uid()` from the verified JWT, behind `app.cmd_current_actor()`. The AD-3 trusted-password/live-session predicate belongs to the identity epic and replaces the body of this seam; missing actor fails closed as `unauthenticated`.
- Decision (agent, under owner pre-approval): authority is a labelled fixture table `app.fixture_command_grants` (actor, command, revoked_at), behind `app.cmd_authorize()`. No grant or revoked grant → `forbidden`, checked before existence (no disclosure) and before any receipt replay.
- Decision (agent, under owner pre-approval): domain errors are returned as an error envelope (HTTP 200) after rolling back the command's subtransaction; no receipt is stored for errors. Unexpected SQL errors map to `unavailable` with no SQL text.
- Decision (agent, under owner pre-approval): lock order = authority row (FOR SHARE) → receipt key reservation (insert, waits on an in-flight duplicate) → aggregate row (FOR UPDATE). Receipt keys are per actor/request, so this extends AD-2's Identity → aggregates order without cross-request deadlocks.
- Decision (agent, under owner pre-approval): payload hash = built-in `sha256` over the canonical jsonb text of `{version, command, expected_revision, payload}`; no extension required. `anon` gets no EXECUTE (PostgREST denies); `authenticated` gets EXECUTE on the api wrapper and the single definer entry point only.
- Decision (agent, under owner pre-approval): no read view for the fixture aggregate; success/conflict envelopes carry the revision. Hosted HTTP evidence is not run (would need hosted Auth users); hosted gets the migration, SQL-level role-switch checks and advisors.

## Boundaries & Constraints

**Always:** Tables/definer functions in `app` with RLS on, `search_path = ''`, qualified names; `api` wrapper is `security invoker`; explicit EXECUTE grants, none to PUBLIC/anon; errors use only the AD-2 vocabulary; synthetic data labelled; same migration version locally and hosted.

**Never:** Feature business rules, real member data, objects in `auth`/`storage`/`realtime`, client table DML, edits to 1.1's migrations or Flutter apps, SMS configuration.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Create | granted actor, `expected_revision` null, new request_id | `{request_id, data, revision: 1}`, one receipt | None |
| Duplicate | same actor/command/request_id/payload | Original result returned; no second mutation | None |
| Changed replay | same request_id, different payload | `conflict` | No mutation |
| Stale revision | expected_revision ≠ current | `conflict` + `current_revision` | No mutation, no receipt |
| Simultaneous | N parallel increments at the same revision | Exactly one success, N−1 `conflict` | Row lock serializes |
| Rolled-back failure | increment breaks the value check after the write | `validation_failed`; value, revision and receipts unchanged | Subtransaction rollback |
| Revoked authority | grant revoked, incl. replay of a stored request | `forbidden` | No replay |
| No actor / bad envelope | anon, unknown version, missing request_id | denied / `unauthenticated` / `validation_failed` | — |
| Direct DML / PUBLIC | client roles on `app` tables, PUBLIC/anon on functions | Denied | Permission error |

</frozen-after-approval>

## Code Map

- `supabase/migrations/20261003112319_platform_status_tracer.sql` -- `app`/`api` schemas and global "revoke execute on functions from public" default; reuse, do not edit.
- `supabase/migrations/20261003114608_revoke_public_default_privileges.sql` -- public default ACL removal; do not edit.
- `supabase/tests/platform_status_test.sql` -- pgTAP style to follow (`begin; plan(n); … finish(); rollback;`). `npm run db:test` runs every `supabase/tests/*.sql`.
- `supabase/tests/api_smoke.sh` -- HTTP style (`supabase status -o env`, curl helpers); `db:smoke` in `package.json` runs it; CI `db` job runs `db:test` and `db:smoke` with auth+rest+kong+db running.
- `supabase/config.toml` -- only `api` exposed; email signups without confirmation locally.
- Local stack containers `supabase_*_church-app` are running; `psql` is at `/usr/bin/psql`; `DB_URL` comes from `supabase status -o env`.

## Tasks & Acceptance

**Execution:**
- [x] `supabase/migrations/<hosted-version>_command_foundation.sql` -- `app.cmd_receipts`, `app.fixture_command_grants`, `app.fixture_counters`; kernel helpers (`cmd_fail`, `cmd_current_actor`, `cmd_authorize`, `cmd_payload_hash`, `cmd_reserve_receipt`); definer entry `app.fixture_counter_command`; invoker `api.fixture_counter_command(version, command, request_id, expected_revision, payload)`; grants/revokes -- the foundation.
- [x] `supabase/tests/command_foundation_test.sql` -- pgTAP: privileges, definer settings, and create/duplicate/changed replay/stale/rollback/revoked/unauthenticated/bad-envelope as `authenticated` with JWT claims -- single-session evidence.
- [x] `supabase/tests/command_api_smoke.sh` + `package.json` `db:smoke` -- HTTP evidence through PostgREST with admin-created synthetic users, including simultaneous writes queued behind a held row lock and parallel duplicates -- real API evidence; CI unchanged because `db:smoke` already runs.
- [x] Hosted `tmurpotfluignacfueki` -- `apply_migration`, rename local file to the recorded version, role-switch SQL check in a rolled-back transaction, `get_advisors(security)`.
- [x] `docs/runbooks/command-foundation.md` -- how to add a command on this kernel.

**Acceptance Criteria:**
- Given `npx supabase db reset`, when `npm run db:test` and `npm run db:smoke` run, then all pass.
- Given hosted migration history, when listed, then it equals the local `supabase/migrations` versions.

## Design Notes

Envelope: request `{version: 1, command, request_id, expected_revision, payload}`; success `{request_id, data, revision}`; error `{request_id, code, message, field_errors, current_revision?}`. Entry flow: validate envelope → actor → authorize (lock grant) → reserve receipt (existing: same hash → stored result, else `conflict`) → lock aggregate → check revision → mutate → store result. A `begin … exception` block wraps everything after validation so any failure rolls back the reservation and mutation.

## Verification

**Commands:**
- `npx supabase db reset && npm run db:test && npm run db:smoke` -- expected: all pass.

## Implementation Notes

Implemented 2026-10-03 directly (no subagent tool in this session).

**What landed**
- `supabase/migrations/20261003123459_command_foundation.sql`:
  - Tables `app.cmd_receipts` (PK actor/command/request_id, payload hash, stored result), `app.fixture_command_grants` and `app.fixture_counters`. All three have RLS on, no policies and no client privileges.
  - Kernel `app.cmd_execute`, which calls handlers by `regprocedure`. Helpers: `cmd_fail` (custom SQLSTATE `PCMD1`), `cmd_error_envelope`/`cmd_error_message`, `cmd_utc`, `cmd_current_actor`, `cmd_authorize`, `cmd_payload_hash` (built-in `sha256`, no extension) and `cmd_reserve_receipt`.
  - Fixture handlers for create and increment.
  - Definer entry point `app.fixture_counter_command`, which holds the command allowlist.
  - Invoker wrapper `api.fixture_counter_command`.
  - EXECUTE is granted only to `authenticated`, and only on those two entry functions.
- `supabase/tests/command_foundation_test.sql`: 57 pgTAP assertions covering privileges and every single-session matrix row.
- `supabase/tests/command_api_smoke.sh`: 24 HTTP checks through Kong, PostgREST and GoTrue.
  - Synthetic users are created with the local Auth admin API and deleted again afterwards. Their rows are removed too.
  - For the simultaneous cases, a psql session holds the counter row lock while 5 identical requests, then 8 distinct ones, are fired. The script asserts that ≥2 backends were waiting on locks; it observed 5 and 8.
  - `package.json` `db:smoke` now runs it after `api_smoke.sh`, so CI picks it up unchanged. It needs curl, jq and psql, which ubuntu-24.04 runners ship.
- `docs/runbooks/command-foundation.md`: how to add a command and which seams later epics replace.

**Surprises**
- In `select pg_sleep(n) from t ... for update` the projection runs before LockRows, so the row lock is only held briefly. The lock holder therefore uses separate statements.
- `results_eq` over `name || text` needed an explicit `collate "C"`.

**Verification**
- Local: `npx supabase db reset` → `npm run db:test` 86/86 (57 new) → `npm run db:smoke` 30/30 ok (24 new). After the run all fixture tables and `auth.users` are empty.
- Hosted `tmurpotfluignacfueki`:
  - `apply_migration` recorded version `20261003123459`, and the local file was renamed to match. The sha256 of the stored statements equals the local file (`502fd9fe…`).
  - History is 112319, 114608 and 123459 on both sides.
  - Role-switch SQL in a rolled-back transaction gave create success, changed-payload `conflict` and ungranted `forbidden`.
  - PUBLIC execute: 0. anon execute: 0. authenticated executes only the two entry functions. Fixture tables are empty afterwards.
- Security advisors: only `rls_enabled_no_policy` (INFO) on the three `app` tables, which is intended: deny-all, with access only through definer functions.
- Hosted HTTP was not exercised; that would need hosted Auth users. Local PostgREST covers the same migration.

**Matrix audit:** each row is covered, and each covering test ran and passed:
- Create: pgTAP plus HTTP.
- Duplicate: pgTAP, plus HTTP with parallel duplicates.
- Changed replay: pgTAP plus HTTP.
- Stale: pgTAP plus HTTP.
- Simultaneous: HTTP.
- Rolled-back failure: pgTAP plus HTTP.
- Revoked authority, including replay: pgTAP plus HTTP.
- No actor / bad envelope: pgTAP; anon is checked in pgTAP and over HTTP (401).
- Direct DML / PUBLIC: pgTAP, plus HTTP (406 for `app`).

**Review follow-up (2026-10-03)**
- New migration `supabase/migrations/20261003131021_command_foundation_hardening.sql`. The applied `20261003123459` is left unchanged.
  - **Replay scope recheck.** The kernel is now `app.cmd_execute(envelope jsonb, handler, scope, revision_required)`. Before any receipt replay it reads `aggregate_type`/`aggregate_id` from the receipt and calls the per-command scope seam. For the fixture that seam is `app.fixture_counter_in_scope`: the actor must still own the counter, read `FOR SHARE`. If the check fails the answer is `forbidden`, and no stored data is returned.
  - **One jsonb envelope.** `api.fixture_counter_command(jsonb)` takes PostgREST's single unnamed JSON body. The kernel validates the shape of every envelope field: a request_id that is missing gives `required`, one that is malformed gives `invalid`; version gives `required` or `unsupported`; expected_revision gives `invalid`, `required` or `must_be_null`; payload must be an object; unknown envelope keys are rejected. Each of these returns a `validation_failed` envelope, and a valid request_id is still echoed.
  - **Actor seam.** `app.cmd_current_actor()` reads `sub` without casting it, so a missing or non-UUID `sub` gives `unauthenticated`.
  - **Exception mapping.** The kernel now maps only `PCMD1`. Every other error gives `unavailable`. The handlers translate their own known constraint outcomes: a unique violation on intent_key gives `conflict`, and a value check violation gives `validation_failed {"by": "out_of_range"}`. The `by` cast now runs only after the shape checks.
  - **Volatility.** `cmd_utc`, `cmd_error_envelope`, `cmd_payload_hash` and `fixture_counter_data`/`fixture_counter_outcome` are now STABLE, because they call STABLE builtins.
- `command_foundation_test.sql` now has 70 assertions. New cases:
  - replay is in scope; then scope is lost while the grant is kept, and the replay is `forbidden` and discloses nothing
  - a non-UUID `sub` gives `unauthenticated`
  - an internal cast error gives `unavailable`, with no receipt
  - create with a revision gives `must_be_null`
  - a non-object payload is rejected
  - malformed request_id and malformed expected_revision are rejected
  - all nine increment `by`/`counter_id`/extra-field branches
- `command_api_smoke.sh` now has 32 checks.
  - `new_actor` runs in the main shell, aborts setup on any failure, and registers the user for cleanup as soon as it is created.
  - `hold_lock` and `sql` share the psql or docker-exec fallback `pg()`.
  - New HTTP cases: malformed request_id, omitted request_id, malformed expected_revision and omitted version, each returning HTTP 200 with a `validation_failed` envelope.
  - New concurrent revocation case: the revoker was seen waiting on a Lock while an in-flight command held the grant `FOR SHARE`. The command then committed at revision 4, the revocation committed after it, and later replays and writes were `forbidden`.
- Local results: `db reset`, then `db:test` passed 99/99 and `db:smoke` passed 38/38. All fixture tables and `auth.users` were empty afterwards.
- **Hosted is not done.** `apply_migration` returned `cancelled`, and hosted is unchanged: history ends at 123459 and the old function signatures remain. Local and hosted histories now differ by this one migration until it is applied. The local version 20261003131021 is provisional; rename it to the version hosted records. Advisors were not re-run because nothing changed on hosted.

## Plan Change Log

- 2026-10-03, review follow-up (coordinator review findings):
  - **Findings:** receipt replay did not recheck aggregate scope; typed RPC parameters leaked raw PostgREST and SQL errors for malformed envelopes; a non-UUID `sub` and internal cast errors were reported as `validation_failed`; some functions were mis-marked IMMUTABLE; the smoke setup's failure and cleanup were unsafe and its lock holder skipped the docker fallback; coverage was missing for concurrent revocation, `must_be_null`, non-object payloads and the increment validation branches.
  - **Amended:** added the follow-up migration above (kernel signature now `(jsonb, handler, scope, revision_required)`; api now takes one jsonb envelope), the matching tests and the runbook steps.
  - **Avoids:** replay disclosing results after a loss of scope, contract-breaking raw errors, and misclassified internal failures.
  - **KEEP:** lock order (authority FOR SHARE, then receipt reservation, then aggregate FOR UPDATE); receipts only for successes; subtransaction rollback; fixed safe messages.

## Review Triage Log

**Pass 1 (quick lens, independent reviewer), 2026-10-03.** Verdicts: high 1 · medium 2 · low 4 · false 0. All 7 were patched in place through a follow-up migration, because the original migration was already applied on hosted. The parent session chose an in-place amendment over reverting and re-deriving: the plan's intent was right, and only kernel detail was missing.

| # | Finding | Verdict | Route | Evidence / action |
|---|---------|---------|-------|-------------------|
| 1 | Receipt replay rechecks the command grant but not the caller's current scope on the stored aggregate | high | bad_plan → in-place amendment | AD-2 says "Recheck access before replaying a receipt". `cmd_execute` returns the stored result after only `cmd_authorize`, and the receipt's aggregate fields are never read. Fix: a per-command scope-recheck seam on replay, a test, and a runbook step. |
| 2 | Malformed or omitted envelope fields return raw PostgREST/SQL errors (22P02, PGRST202 with parameter hints) | medium | bad_plan → in-place amendment | The reviewer reproduced this on the local stack. It breaks the Consistency Conventions error vocabulary. Fix: validate the envelope inside the function, plus HTTP smoke cases. |
| 3 | A non-UUID `sub` maps to `validation_failed` instead of `unauthenticated`; internal cast errors map to `validation_failed` | medium | patch | Caused by the `invalid_text_representation` branch in the exception map. Fix: resolve the actor defensively, and map unexpected internal errors to `unavailable`. |
| 4 | `cmd_utc` and its callers are marked IMMUTABLE but call STABLE `to_char` | low | patch | Checked `provolatile='s'`. Direct relabel. |
| 5 | The smoke script's `new_actor` failure doesn't abort, and a created user can leak | low | patch | `exit` in the `$(…)` subshell doesn't stop the script. Direct fix. |
| 6 | `hold_lock` bypasses the docker-exec psql fallback | low | patch | It calls host `psql` directly. Direct fix. |
| 7 | Coverage gaps: concurrent revocation under FOR SHARE, `must_be_null`, non-object payload, increment validation | low | patch | The plan's decisions claim these behaviours but no test covers them. Add the tests. |

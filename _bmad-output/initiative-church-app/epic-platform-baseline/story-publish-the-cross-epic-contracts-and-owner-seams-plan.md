---
title: 'Publish the cross-epic contracts and owner seams'
type: 'feature'
ticket: '5'
created: '2026-10-03'
status: 'built'
baseline_revision: '7aa2bd95908705c969681bfafae5853b3d691c28'
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

**Problem:** Feature epics need one agreed wire vocabulary (member/account IDs, actor, source/purpose, revisions, UTC instants, church-local time, exact money, command envelope) and owner seams (module registry, lifecycle and source hooks, reminder-kind registration, policy gates) before they build, or each owner and client will invent incompatible variants and unresolved policy could leak into production.

**Approach:** A new `packages/contracts` holds language-neutral v1 fixtures (valid and invalid, with exact `field_errors`), a Dart mapping and a TypeScript mapping that both pass them. One migration adds the SQL authority: `app.contract_check(kind, value)` passing the same fixtures, a module/prefix/dependency registry with a boundary guard, registration functions for source types, purposes, reminder kinds and lifecycle hooks, dynamic dispatch seams, and fail-closed policy gates with an environment marker.

## Decisions

- Decision (agent, under owner pre-approval): "both client mappings" = Dart (shared by the Flutter mobile app and the Flutter web trial) and TypeScript (the Q10 React/Next.js alternative). App pubspecs are not edited; entry 7 wires client adapters, avoiding cross-lane lockfile conflicts.
- Decision (agent, under owner pre-approval): client checks are shape-only. Registration membership (source_type, purpose, reminder_kind), IANA zone existence and money scale are enforced server-side only.
- Decision (agent, under owner pre-approval): v1 objects are strict (unknown keys → `unknown_field` on that key); additions need a contract version bump. UUIDs are lowercase canonical; integers are 1..2^53−1 (JS-safe); fixtures avoid `1.0`-style numbers that JS cannot distinguish from `1`.
- Decision (agent, under owner pre-approval): a missing `app.platform_environment` row means production behaviour. `seed.sql` marks local only; hosted stays unmarked (fail closed) until entry 8/the owner sets it. Fixture policy values apply only in `local`/`staging`; no migration approves any gate.
- Decision (agent, under owner pre-approval): fixture values are labelled: currency `XTS` (ISO 4217 testing code) scale 2, zone `Etc/UTC`. No church zone or currency is implied.
- Decision (agent, under owner pre-approval): module registry, owner prefixes and allowed dependency edges are copied from the architecture's binding dependency diagram; the guard scans `app` function bodies for literal references to disallowed owners' prefixes. Hooks are called dynamically through registered `regprocedure`s, so an emitter never references an owner.
- Decision (agent, under owner pre-approval): lifecycle events v1 (Identity-owned stub list from AD-14): `access_hold_applied`, `access_hold_released`, `scope_revoked`, `account_deactivated`, `deletion_requested`, `cell_transferred`. The reminder seam returns the AD-8 logical key without persisting a job (Notifications epic replaces it) and requires the Q2 gate.

## Boundaries & Constraints

**Always:** `app` objects with owner prefixes, RLS on new tables, `search_path = ''`, no client grants on anything new; registration is migration-only (no EXECUTE for client roles); errors use the AD-2 vocabulary (`unavailable` for a closed gate); fixtures are the single source for all three implementations; synthetic, labelled values only.

**Never:** Feature business rules or concrete state machines; editing 1.1/1.4 migrations; editing `apps/` or `trials/`; approving a policy gate; real member data; SMS; hosted `apply_migration`.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Valid fixture | any kind, valid value | SQL, Dart and TS all `valid`; Dart/TS decode→encode equals input | — |
| Invalid fixture | wrong type, missing, unknown key, bad UUID/instant/date/money/enum | identical `field_errors` from all three | — |
| Hook registration | owner registers its own prefixed handler | stored; dispatch calls hooks in lock-rank order | — |
| Foreign registration | handler/source of another owner, wrong signature, unknown event | rejected at registration | migration error |
| Hook failure | one hook raises during dispatch | whole dispatch rolled back | caller's transaction |
| Boundary breach | owner function names a disallowed owner's `app.` prefix | guard reports it | test fails |
| Gate unresolved, production | policy read, money scale, reminder key | `unavailable` | fail closed |
| Gate unresolved, local + fixture | same | fixture value labelled `source: fixture` | — |
| Approve without approver | `policy_approve` with blank approver | rejected | exception |

</frozen-after-approval>

## Code Map

- `supabase/migrations/20261003170000_command_foundation_hardening.sql` -- kernel `cmd_execute(jsonb, handler, scope, revision_required)`, envelope validation codes (`required`/`invalid`/`unsupported`/`must_be_null`/`must_be_object`/`unknown_field`) to mirror; do not edit.
- `supabase/migrations/20261003123459_command_foundation.sql` -- `cmd_fail` (SQLSTATE `PCMD1`), `cmd_error_envelope` shape `{request_id, code, message, field_errors, current_revision?}`, `cmd_utc`; reuse.
- `supabase/migrations/20261003112319_platform_status_tracer.sql` -- `app`/`api` schemas, USAGE on `app` for anon/authenticated (so revoke explicitly), `app.platform_status`.
- `supabase/tests/command_api_smoke.sh` -- `pg()` psql/docker fallback to reuse in the fixture runner; `package.json` `db:smoke` chains scripts.
- `.github/workflows/ci.yml` -- `db` job (node + local stack) and `flutter` job (pinned 3.47.6).

## Tasks & Acceptance

**Execution:**
- [x] `packages/contracts/fixtures/v1/*.json` -- per-kind valid/invalid cases with exact `field_errors` -- single source of truth.
- [x] `packages/contracts/dart/` -- `church_contracts` pure-Dart package: validators, typed models, fixture test, locked deps.
- [x] `packages/contracts/ts/` -- `contracts.ts` validators/types plus `contracts.test.ts` (`node --test`).
- [x] `supabase/migrations/<ts>_cross_epic_contracts.sql` -- `contract_check`, registries, guard, registration and dispatch seams, policy gates, environment marker, grants.
- [x] `supabase/seed.sql` -- mark the local environment.
- [x] `supabase/tests/cross_epic_contracts_test.sql` -- pgTAP: privileges, ownership/boundary guard, registration accept/reject, dispatch order and atomicity, source hook, gate behaviour per environment, money scale, zone existence.
- [x] `supabase/tests/contract_fixtures_check.sh` + `package.json` -- run every fixture through `app.contract_check`; `contracts:test` script for TS.
- [x] `.github/workflows/ci.yml` -- Dart package get/analyze/test in `flutter`; TS fixtures in `db`.
- [x] `docs/runbooks/contracts-and-owner-seams.md` -- how an owner registers and how a gate is approved.

**Acceptance Criteria:**
- Given `npx supabase db reset`, when `npm run db:test`, `npm run db:smoke` and `npm run contracts:test` run, then all pass.
- Given `packages/contracts/dart`, when `dart analyze` and `dart test` run, then both pass.
- Given the migration, when gates are listed, then none is `approved`.

## Design Notes

Fixture file: `{"kind": "money", "contract_version": 1, "valid": [{"name", "value"}], "invalid": [{"name", "value", "field_errors": {"amount": "invalid"}}]}`. Root-type errors use path `$`. Every implementation exposes `check(kind, value) → {valid, field_errors}`.

## Verification

**Commands:**
- `npx supabase db reset && npm run db:test && npm run db:smoke && npm run contracts:test` -- expected: all pass.
- `cd packages/contracts/dart && dart pub get --enforce-lockfile && dart analyze && dart test` -- expected: pass.

## Implementation Notes

Implemented 2026-10-03 directly (no subagent tool in this session).

**What landed**
- `supabase/migrations/20261003190000_cross_epic_contracts.sql` (sorts after the renamed 1.4 hardening `20261003131021`; no DROP/TRUNCATE/DELETE statements):
  - `app.contract_check(kind, value)`: SQL authority for the 12 kinds, built on small validators. `app.contract_require` raises the kernel's `validation_failed` (PCMD1) and adds the server-only zone existence check.
  - Registry tables `contract_modules` (AD-2 lock ranks), `contract_module_prefixes` and `contract_module_dependencies` (edges from the architecture diagram). Guards `contract_unowned_objects()` and `contract_boundary_violations()`.
  - Seams: `contract_register_source_type` / `_purpose` / `_reminder_kind` / `_lifecycle_hook` (PCTR1 on refusal); `contract_dispatch_lifecycle`; `contract_check_source`; `contract_reminder_key` (Q2-gated stub). Handlers are stored as signature text, not reg* columns, because those block pg_upgrade.
  - `platform_environment` (absent = production), `policy_gates` (7 gates, all unresolved; labelled fixtures only on Q2 and Q9), `policy_effective` / `policy_is_open` / `policy_approve`. Money helpers `contract_money_amount` / `contract_money_json` (exact, no silent rounding).
  - RLS on every new table. No client role holds any privilege on new tables or functions.
- `supabase/seed.sql`: marks the local environment.
- `supabase/tests/cross_epic_contracts_test.sql`: 77 pgTAP assertions.
- `supabase/tests/contract_fixtures_check.sh`: runs all 168 fixture cases through SQL. Added to `db:smoke`.
- `packages/contracts/`:
  - `fixtures/v1`: 12 files, 168 cases.
  - `dart/`: `church_contracts`, with locked dev dependencies `test` and `lints`, typed models, and `Money.toMinorUnits` (BigInt).
  - `ts/`: erasable TypeScript run by Node type stripping; `npm run contracts:test`.
- `.github/workflows/ci.yml`: the `db` job runs the TS fixtures; the `flutter` job runs Dart pub get (locked), `analyze --fatal-infos` and `test`.
- `docs/runbooks/contracts-and-owner-seams.md`.
- `apps/` and `trials/` are untouched. Entry 7 wires `church_contracts` into the client adapters as a path dependency.

**Surprises**
- The guard immediately found a real edge: `app.cmd_authorize` (platform kernel) reads `app.fixture_command_grants` (fixture). It is recorded as an explicit temporary `platform -> fixture` dependency until the identity epic replaces the authorization seam.
- The coordinator renamed the 1.4 hardening migration and retired its old functions as `retired_*_v0` in `app`. A `retired` module (`retired_` prefix, no lock rank) keeps the ownership guard green; a retired object may reference any owner.
- `jsonb_build_object` is STABLE, so `contract_check` is STABLE, not IMMUTABLE.
- Known cross-runtime limit: JS (and Flutter Web) cannot tell `1.0` from `1`. Producers emit canonical integers, and the fixtures avoid that case.

**Verification (local)**
- `npx supabase db reset`, then `npm run db:test`: 176/176, 77 of them new.
- `npm run db:smoke`: tracer, command smoke and 168/168 SQL fixture cases.
- `npm run contracts:test`: 170/170.
- `dart pub get --enforce-lockfile && dart analyze --fatal-infos && dart test` in `packages/contracts/dart`: no issues, 185/185.
- No Flutter app was touched, so `flutter analyze` / `flutter test` were not needed.

**Hosted: NOT applied (coordinator instruction).** Apply exactly `supabase/migrations/20261003190000_cross_epic_contracts.sql` (sha256 `df81481dc03b3f571d0208d481f2db30b471eb1456741aad06c52accd04e978d`) to `tmurpotfluignacfueki`, after `20261003131021_command_foundation_hardening`. If hosted records a different version, rename the local file to match. Hosted will then behave as production (no environment row), so every gate stays closed. To use fixtures on staging, an operator runs `select app.platform_set_environment('staging', '<operator>');` (entry 8 / owner). After applying, run `get_advisors(security)`; expect only `rls_enabled_no_policy` INFO on the new deny-all tables.

**Matrix audit:** each row is covered, and each covering test ran and passed:
- Valid and Invalid fixture: `contract_fixtures_check.sh`, Dart `fixtures_test.dart` and TS `contracts.test.ts`, all over the same files, including the Dart/TS decode→encode round trip.
- Hook registration, dispatch order, foreign registration, hook-failure atomicity and boundary breach: pgTAP.
- Gate unresolved in production vs local + fixture (policy, money scale and reminder key): pgTAP, unmarked plus marked production and staging.
- Approve without approver: pgTAP.


## Plan Change Log

## Review Triage Log

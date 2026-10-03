---
title: 'Provide bounded system access and restricted operations'
type: 'feature'
ticket: '9'
created: '2026-10-03'
status: 'built'
baseline_revision: 'ea6edb44eb596cebef40093c9243bbb6c795f169'
route: 'full'
route_source: 'auto'
review: ''
review_source: ''
lenses_ran: []
review_loop_iteration: 0
context:
  - '{project-root}/_bmad-output/initiative-church-app/owner-decisions-milestone-1.md'
  - '{project-root}/docs/runbooks/environments-and-promotion.md'
  - '{project-root}/docs/runbooks/command-foundation.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** Automation has no way to act without a member session: there is no environment-bound system principal, no allowlist, no attributable content-free audit or health signal, no named restricted operator procedure and no explicit fail-closed switch for alerting and Q12 thresholds (P8, AD-17, AD-19).

**Approach:** Add one system route (`api.system_command`, PostgREST RPC) that authenticates only a hashed, environment-prefixed system credential sent in a header, derives the system actor from it, permits exactly one synthetic operation (`system.synthetic_probe`) and audits every outcome without content; add operator-only SQL procedures, health/alert status functions, fail-closed gates and config, tests on local and hosted staging, and a support/deploy runbook.

## Boundaries & Constraints

**Always:** credential digest only in the DB (sha256), token never printed or committed; environment = `app.platform_current_environment()` (unmarked = production); user JWT, service_role and any non-anon role are refused on the system route; principal, job id and initiating member come only from the credential/envelope id, never a request field; every outcome writes one content-free audit row; new objects use registered `sys_`/`ops_` prefixes and `search_path = ''`; migration is additive.

**Never:** a scheduler, reminder or notification worker; user-role impersonation or setting JWT claims; SMS; alert dispatch to any destination; edits to merged migrations or to other lanes' files (`apps/`, `packages/`, `trials/`, `tools/auth-harness/`); production project creation.

- Decision (agent, under owner pre-approval): Israel (`israel`) is the only seeded restricted operator; operator procedures have no client grants and run as the DB owner (MCP/psql) with the operator name recorded.
- Decision (agent, under owner pre-approval): restricted alert destination and Q12 thresholds stay unresolved: new gate `ops_alert_destination` plus existing `q12_operations`, no fixtures; `app.ops_alert_status()` reports alerting disabled while either is closed; config `operations.activation.*` must stay false. Recorded as production gates, not blockers.
- Decision (agent, under owner pre-approval): the system route is open in local/staging; in production (or an unmarked DB) it also needs the new `ops_system_access` gate approved by the owner.
- Decision (agent, under owner pre-approval): hosted staging is verified with a DB-registered hashed credential (1.3 operator-token pattern), so no hosted secret store is needed; the token lives only in a gitignored local state dir.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Valid | anon key + `x-system-credential` for this env, probe envelope | `{request_id, data:{actor:{kind:system,…}, probe_revision, environment}, revision}`; audit `succeeded` | — |
| Replay | same request_id + payload | stored result; audit `replayed` | changed payload → `conflict` |
| Wrong environment | `sysc_local_…` on staging or vice versa; credential after env re-marked | `unauthenticated` | audit reason `wrong_environment` |
| Unknown/expired/revoked/missing/malformed | — | `unauthenticated` | audit reason names which |
| User JWT | authenticated session (with or without credential) | `forbidden` | audit `user_session_rejected` |
| Forged actor | extra envelope/payload keys (`actor`, `system_principal_id`, `role`, `member_id`) or header | `validation_failed` `unknown_field`; header ignored | audited, actor unchanged |
| Not allowlisted | other command | `forbidden` | audit `command_not_allowed` |
| Production gate | env production, `ops_system_access` closed | `unavailable` | audit `system_access_gate_closed` |

</frozen-after-approval>

## Code Map

- `supabase/migrations/20261003134340_cross_epic_contracts.sql` -- `platform_current_environment`, `platform_set_environment`, `policy_gates`/`policy_is_open`/`policy_approve`, `contract_check('command_request'|'actor')`, module prefixes registry (`contract_module_prefixes`), guards. Reuse; do not edit.
- `supabase/migrations/20261003123459_command_foundation.sql` -- `cmd_error_envelope`, `cmd_payload_hash`; reuse.
- `supabase/tests/command_foundation_test.sql` -- asserts anon executes no app/api function and authenticated only the fixture pair: extend to the system route pair.
- `supabase/tests/command_api_smoke.sh` -- `pg()` psql/docker fallback and curl style to mirror.
- `tools/env/environments.mjs` (+test), `config/environments/*.json` -- add `operations` block validation.
- `tools/ci/secret-patterns.mjs` (+`ci-tools.test.mjs`) -- add the `sysc_` credential rule.
- `tools/auth-harness/sql/register_operator_token.sql` -- digest-registration pattern (read only).
- `docs/runbooks/environments-and-promotion.md` -- link to new runbook.

## Tasks & Acceptance

**Execution:**
- [x] `supabase/migrations/20261003154040_bounded_system_access.sql` -- prefixes, tables (principals, principal commands, command kinds, credentials, receipts, probe state, audit, operators, operator audit), `sys_execute`, entry + `api.system_command`, operator procedures, `ops_health_snapshot`, `ops_alert_status`, gates, grants.
- [x] `supabase/tests/system_access_test.sql` -- pgTAP for every matrix row, privileges, guards, gates.
- [x] `supabase/tests/command_foundation_test.sql` -- update the two privilege assertions.
- [x] `supabase/tests/system_api_smoke.sh` + `package.json` `db:smoke` -- HTTP evidence with a runtime-minted credential.
- [x] `tools/ops/system-credential.mjs` (+test) + `.gitignore` -- mint (prints digest only), call (reads token from state), env-bound.
- [x] `tools/env/environments.mjs`, `config/environments/*.json`, `tools/ci/secret-patterns.mjs` + tests -- operations config and credential scanning.
- [x] `.github/workflows/ci.yml` -- run `tools/ops` tests in `policy`.
- [x] `docs/runbooks/system-access-and-operations.md` + link from environments runbook -- support/deploy runbook and production gates.
- [x] Hosted staging -- apply migration, rename local to recorded version, register credential digest, run HTTP matrix, advisors, log scan.
- [x] `evidence-1.9/` -- raw local and hosted outputs.

**Acceptance Criteria:**
- Given `supabase db reset`, when `npm run db:test` and `npm run db:smoke` run, then all pass.
- Given hosted staging, when the HTTP matrix runs, then only the valid probe succeeds and audit rows attribute each outcome without content.
- Given any environment, when `ops_alert_status()` runs, then alerting is disabled and names the unresolved gates.

## Implementation Notes

Implemented 2026-10-03 directly (no subagent tool in this session).

**What landed**
- `supabase/migrations/20261003154040_bounded_system_access.sql` (additive; hosted version recorded by `apply_migration`, local file renamed from the provisional `20261003153000`; stored-statement sha256 `30d50641…600a` equals the file):
  - `sys_`/`ops_` prefixes registered to `platform`; gates `ops_alert_destination` and `ops_system_access` (unresolved, no fixture).
  - Tables `ops_operators` (seed `israel`), `ops_operator_actions`, `sys_command_kinds` (only `system.synthetic_probe`), `sys_principals`, `sys_principal_commands`, `sys_credentials` (digest only, TTL ≤ 30 days), `sys_receipts`, `sys_probe_state`, `sys_audit`, `ops_health_events`; RLS on, no client privileges.
  - Kernel `app.sys_execute` (role → credential/environment → production gate → shared `command_request` contract + probe payload → allowlist → receipt → probe), definer `app.sys_command`, invoker `api.system_command`; EXECUTE for `anon` and `authenticated` only (sessions are refused and audited).
  - Operator procedures `sys_create_principal`, `sys_register_credential`, `sys_revoke_credential`, `sys_disable_principal`; `ops_health_snapshot`, `ops_alert_status`.
- Tests: `supabase/tests/system_access_test.sql` (95), `supabase/tests/system_api_smoke.sh` (in `db:smoke`), and the two 1.4 privilege assertions in `command_foundation_test.sql` now name the system route pair.
- Tools: `tools/ops/system-credential.mjs` (+test; mint/digest/forget/matrix, state in gitignored `.ops-state/`), `tools/ops/sql/observe_log_credential_scan.sql`; `system_credential` secret rule; `operations` block in `config/environments/*.json` validated by `validateOperations`; `verify-hosted.sql` also requires alerting disabled; CI `policy` job and `ci:policy-test` run `tools/ops` tests.
- Docs: `docs/runbooks/system-access-and-operations.md` (support/deploy runbook, production gates), linked from `environments-and-promotion.md` step C6.

**Decisions / surprises**
- The probe payload allows an optional `sequence` integer so the matrix's changed-payload `conflict` row is reachable; everything else in the payload is `unknown_field`.
- A JWT carrying `sub` is treated as a user session even if it claims `anon`.
- `db:smoke` leaves audit rows, so the pgTAP file clears the sys/ops counters inside its rolled-back transaction.
- Hosted: deleting the synthetic staging user through MCP timed out at the confirmation step; the user was banned and its password replaced instead (owner cleanup step).
- Risk: unauthenticated callers can grow `sys_audit` (one row per call); retention/rate limits belong to the Q12 thresholds.

**Verification**
- Local: `supabase db reset`, `npm run db:test` 296/296, `npm run db:smoke` exit 0 (15-case matrix + audit checks), rerun `db:test` after smoke passes; `npm run ci:policy-test` 33/33; `env:check`, `check-migrations --base <baseline>`, `ci:secrets`, `contracts:test` 226/226 all pass; `verify-hosted.sql` passes in a rolled-back staging-marked local transaction.
- Hosted staging: migration applied; HTTP matrix 15/15 with a DB-registered hashed credential, a real synthetic user JWT and a real local credential as the wrong-environment case; audit rows 14–26 content-free and attributed; guards 0; anon executes only the route pair; advisors INFO deny-all only (+ pre-existing Auth WARN); platform log scan 0 credential/password/secret hits. Raw evidence: `evidence-1.9/`.

**Matrix audit:** Valid, Replay/conflict, Wrong environment (prefix and row binding, re-marking), Unknown/expired/revoked/missing/malformed, User JWT, Forged actor (envelope, payload, headers), Not allowlisted, Production gate — each covered by pgTAP and (except expired/revoked/production) by the HTTP matrix on local and staging; all ran and passed.

**Review follow-up (2026-10-03)**
- Forward migration `supabase/migrations/20261003155428_system_access_review_fixes.sql`, applied locally and on staging (recorded `20261003155428`, sha256 equal):
  - `sys_disable_principal` revokes the principal's unrevoked credentials, with one operator action each.
  - `ops_health_snapshot` filters the route counters on `environment = v_env`, and counts credentials only for enabled principals.
- Config: flags moved to `operations.activation` (`alerting`, `scheduler`, `production_system_access`, all `false`) plus `operations.activation_gates`; `system_route.access` is `open` in local/staging and `owner_gate` in production. `validateOperations` rejects any other `operations` key and any non-`false` flag; tests updated.
- `system-credential.mjs` matrix always mints unregistered tokens for the wrong-environment cases (new test stubs `fetch` and proves a stored staging token is never sent). The local credential that went to staging had no remaining registration (the local DB was reset), and the stored token was deleted.
- Runbook: both alert gates are needed for `approved_no_dispatcher`, and from then on `verify-hosted.sql` fails promotions; adding an operator also needs `RESTRICTED_OPERATORS`; disabling revokes credentials; `sys_audit` growth is listed as a Q12 production gate.
- pgTAP: `system_access_test.sql` now has 103 assertions (environment-filtered counters, disable cascade, disabled-principal credential counts).

## Plan Change Log

## Review Triage Log

## Verification

**Commands:**
- `npx supabase db reset && npm run db:test && npm run db:smoke` -- all pass.
- `node --test tools/env/*.test.mjs tools/ci/*.test.mjs tools/ops/*.test.mjs && npm run env:check && npm run ci:migrations && npm run ci:secrets` -- pass.
- `node tools/ops/system-credential.mjs matrix --env staging` -- hosted matrix as expected, saved to evidence.
</content>
</invoke>

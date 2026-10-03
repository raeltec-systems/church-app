# Runbook: system access, restricted operations and production gates (story 1.9)

This runbook covers:

- the bounded system route that automation uses instead of a member session
- system credentials: minting, registering, rotating and revoking
- the restricted operator and the operator procedures
- content-free health and audit signals
- activation gates that stay closed, and the production gates the owner must still resolve
- support and deploy checks

Architecture: AD-17 and AD-19. Owner decisions: `_bmad-output/initiative-church-app/owner-decisions-milestone-1.md`. Environments and promotion: `environments-and-promotion.md`. Migrations: `supabase/migrations/20261003154040_bounded_system_access.sql` and the review fixes in `supabase/migrations/20261003155428_system_access_review_fixes.sql`.

## The system route

`POST <api_url>/rest/v1/rpc/system_command` with:

- header `Content-Profile: api`
- header `apikey: <publishable key>`
- header `x-system-credential: <system credential>`
- body `{"version": 1, "command": "system.synthetic_probe", "request_id": "<uuid>", "payload": {}}`

The payload may also carry `{"sequence": <integer 1..2147483647>}`.

| Rule | How it is enforced |
|---|---|
| Only a system credential authenticates | The credential is `sysc_<environment>_<43 base64url chars>`. The database stores only its sha256 digest (`app.sys_credentials`). The publishable key alone gets `unauthenticated`. |
| Environment-bound | The credential's prefix must equal the database marker (`app.platform_current_environment()`; unmarked = production). Its stored row must also belong to that environment. A credential stops working when the database is re-marked. |
| User sessions refused | An `authenticated` JWT, or any JWT carrying `sub`, gets `forbidden`, even with a valid credential. A forged JWT is rejected by PostgREST (401). `service_role` holds no grant. |
| No forged actor | The actor is built from the credential's principal and the envelope `request_id` (job id). `initiating_member_id` is always null. Extra envelope or payload keys (`actor`, `system_principal_id`, `member_id`, `role`, …) give `validation_failed` / `unknown_field`. Headers such as `x-system-principal` are ignored. |
| Allowlist | Exactly one command: `system.synthetic_probe`. It must be in `app.sys_command_kinds`, granted to the principal by purpose, **and** known to the kernel. Anything else gets `forbidden`. |
| Idempotent | Same principal, command and `request_id` returns the stored result. A changed payload gets `conflict`. |
| Production gate | In production (or an unmarked database), the route also needs the owner-approved `ops_system_access` gate; otherwise `unavailable` with `{"policy": "gate_closed"}`. |
| Audited | Every call that reaches the database writes one `app.sys_audit` row: environment, caller role, principal id, credential id, allowlisted command (else null), request id, outcome, error code and reason code. No payload, token, digest, address or free text. |

There is no scheduler, reminder or notification worker, and no way to act as a member or church role.

## Restricted operator

Israel (`israel`) is the only restricted operator (owner decision). Operator procedures have **no client grants**. Run them as the database owner:

- hosted: Supabase MCP `execute_sql`, or the Dashboard SQL editor
- local: `psql`

Each procedure takes the operator name, checks it against `app.ops_operators`, and records the action in `app.ops_operator_actions`.

| Procedure | Effect |
|---|---|
| `app.sys_create_principal(name, purpose, operator)` | Creates a principal in this database's environment, granted every command of its purpose. The only purpose today is `synthetic_probe`. |
| `app.sys_register_credential(principal_id, digest, label, ttl, operator)` | Registers a credential digest. The TTL is between 1 minute and 30 days. |
| `app.sys_revoke_credential(credential_id, operator)` | Revokes a credential immediately. |
| `app.sys_disable_principal(principal_id, operator)` | Disables a principal and revokes every unrevoked credential it has. Each revocation is recorded as an operator action. |
| `app.ops_health_snapshot(window)` | Content-free counts: successes, replays, rejections by reason, probe revision and time, active principals and credentials, credentials expiring within 7 days, system-access state, alert status. |
| `app.ops_alert_status()` | `disabled` while `q12_operations` or `ops_alert_destination` is unresolved. There is no dispatcher in this story. |

To add an operator later, the owner records the decision. Then two changes land together in one reviewed change:

- a migration that inserts the row into `app.ops_operators`
- the operator's name added to `RESTRICTED_OPERATORS` in `tools/env/environments.mjs`, plus `operations.restricted_operators` in the affected `config/environments/*.json`

`env:check` rejects any operator not in that list.

## Credentials

Never print, paste, log or commit a credential. The secret scanner (`tools/ci/secret-patterns.mjs`, rule `system_credential`) fails CI if one appears in the repo or in a client bundle.

1. Mint one into the gitignored `.ops-state/` (mode 0600). Only the digest is printed:

   ```bash
   node tools/ops/system-credential.mjs mint --env staging
   # {"environment":"staging","digest":"<64 hex>","stored_in":".../.ops-state/staging.credential"}
   ```

2. Register the digest as the operator (MCP `execute_sql` against the environment's project):

   ```sql
   select app.sys_register_credential(
     app.sys_create_principal('synthetic-probe', 'synthetic_probe', 'israel'),  -- or an existing principal_id
     '<digest>', 'staging verification', interval '2 days', 'israel');
   ```

3. Verify it with the HTTP matrix. `SYSTEM_MATRIX_USER_JWT` is optional: a synthetic user's access token for the session case.

   ```bash
   SUPABASE_PUBLISHABLE_KEY=<publishable key> node tools/ops/system-credential.mjs matrix --env staging --out /tmp/matrix.jsonl
   ```

4. **Rotate:** mint with `--force`, register the new digest, switch the caller, then `app.sys_revoke_credential(<old id>, 'israel')`.

5. **Compromise:** revoke at once, or disable the principal. Then check `app.ops_health_snapshot()` and the `sys_audit` rows for that `credential_id`.

A future worker (scheduler, notification or deletion) gets its own principal purpose, its own command kinds and its own credential. Purposes are never shared (AD-19). Adding one needs a reviewed migration that extends `app.sys_command_kinds` and the kernel dispatch. Adding one is a later story.

## Support and deploy checks

After every promotion that touches the system route, and when supporting an incident:

1. Run `select app.platform_current_environment();`. The result must be the expected marker.
2. Run `select app.ops_health_snapshot(interval '24 hours');`. Look at:
   - `rejected_by_reason`: spikes in `credential_unknown` or `wrong_environment` mean misconfiguration or probing
   - `credentials_expiring_7d`
   - `system_access`
3. Run the matrix against staging (step 3 above). All cases must pass.
4. `get_advisors(security)`: only the intended `rls_enabled_no_policy` INFO findings on `app.*` deny-all tables.
5. Scan the platform logs for credential leakage with `tools/ops/sql/observe_log_credential_scan.sql` (MCP `query_logs`). Every count must be 0.

Restores and clones keep the source database's marker and credentials. Re-assert the marker, then revoke credentials of the source environment before serving (see `contracts-and-owner-seams.md`).

## Production gates (unresolved; not blockers for milestone 1 staging)

Each gate stays closed. The config flags in `operations.activation` stay `false`, and the database gates stay `unresolved` with no fixture. `env:check` rejects any attempt to enable a flag in config.

| Gate | What the owner must decide | How to open it (owner only) |
|---|---|---|
| `q12_operations` (Q12) | Alert thresholds, support floors, reminder lateness tolerance, RPO/RTO | `select app.policy_approve('q12_operations', '<json thresholds>', 'israel', '<decision note>');` in that environment |
| `ops_alert_destination` (Q12) | The restricted alert destination, for example a private channel or inbox reference. Do not put the destination in the repo. | `select app.policy_approve('ops_alert_destination', '{"destination_ref": "<reference>"}', 'israel', '<note>');` Alerting stays `disabled` until **both** this gate and `q12_operations` are approved. Only then does `ops_alert_status()` report `approved_no_dispatcher`; a later story adds the dispatcher. |
| `ops_system_access` (release) | Whether the system route may run in production | `select app.policy_approve('ops_system_access', '{"commands": ["system.synthetic_probe"]}', 'israel', '<note>');` in the production database, then register a production credential. |
| Scheduler | None in this story. Production scheduling also waits for Q2. | `operations.activation.scheduler` must stay `false`. |
| System audit growth | Every call that reaches the route writes one `app.sys_audit` row, including unauthenticated calls. There is no rate limit or retention yet. | Q12 must set a rate limit and a retention period for `sys_audit` (and `ops_health_events`) before production goes live. A later story implements them. |
| Additional operators | Only Israel is named. | See "Restricted operator" above: a reviewed migration plus the `RESTRICTED_OPERATORS` list in `tools/env/environments.mjs`. |

**Promotion consequence.** As soon as both `q12_operations` and `ops_alert_destination` are approved in an environment, `ops_alert_status()` stops reporting `disabled`. From then on `tools/ci/verify-hosted.sql` fails every promotion to that environment, because it requires alerting to be disabled. This is the same rule as for `private_access` and `outbound_sending`. The later epic that ships the dispatcher must change `verify-hosted.sql` and the validator (`tools/env/environments.mjs`, `operations.activation.alerting`) together.

`config/environments/*.json` → `operations` records the same state:

- `restricted_operators`: `["israel"]`
- `system_route.access`: `open` in local and staging, `owner_gate` in production
- `activation`: `alerting`, `scheduler` and `production_system_access`, all `false`
- `activation_gates`: the database gates that control each flag

The validator is `tools/env/environments.mjs` (`validateOperations`).

## Tests

- `supabase/tests/system_access_test.sql`: pgTAP for every route rule, the operator procedures, the gates, the guards and the privileges. It runs in local, staging and production marker states inside one rolled-back transaction.
- `supabase/tests/system_api_smoke.sh` (part of `npm run db:smoke`): the HTTP matrix through the local stack, with a run-time credential and a real synthetic user session, followed by checks on the audit rows.
- `tools/ops/system-credential.test.mjs`, `tools/env/environments.test.mjs`, `tools/ci/ci-tools.test.mjs`: offline tests in the CI `policy` job.

Evidence: `_bmad-output/initiative-church-app/epic-platform-baseline/evidence-1.9/README.md`.

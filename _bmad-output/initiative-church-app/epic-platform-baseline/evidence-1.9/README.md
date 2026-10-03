# Evidence: story 1.9, bounded system access and restricted operations

Captured 2026-10-03. All principals, credentials, users and data are SYNTHETIC. No credential, password, JWT or key appears in these files. Matrix output is scrubbed by `tools/ops/system-credential.mjs`, and a grep of the tree for the minted tokens and the synthetic password found nothing.

## Hosted staging (`tmurpotfluignacfueki`, marker `staging`)

| File | What it shows |
|---|---|
| `staging-migration-and-advisors.json` | `bounded_system_access` recorded as `20261003154040`. Its stored statements' sha256 equals the local file. The security advisors show only intended deny-all INFO findings plus a pre-existing Auth WARN. Also records the synthetic principal, the credential ids and the user cleanup. |
| `staging-matrix.jsonl` | Raw HTTP matrix against `https://tmurpotfluignacfueki.supabase.co/rest/v1/rpc/system_command`, 15/15 pass (see below). |
| `staging-sql-evidence.json` | The audit rows for that run (ids 14–26), health snapshot, alert status, gates, operator, operator actions, guards, and function/table privileges. |
| `staging-log-credential-scan.json` | Platform logs for the run window: 0 credential-shaped values, 0 synthetic-password values, 0 secret keys. The `x-system-credential` header was never logged. |

Matrix cases and results:

- **Valid staging credential:** HTTP 200. The actor is `{kind: system, system_principal_id: <the principal>, job_id: <request_id>, initiating_member_id: null}`.
- **Replay:** returns the identical body. Audited as `replayed`.
- **Same request_id with a changed payload:** `conflict`.
- **No credential, malformed credential, or well-formed unregistered credential:** `unauthenticated`.
- **Wrong-environment credentials:** `unauthenticated`, audited as `wrong_environment`. Two were tried:
  - the real **local** credential (registered in the local database)
  - a production-prefixed credential
- **Real synthetic user session JWT plus the valid credential:** `forbidden`, audited with caller role `authenticated` and no principal.
- **Unsigned JWT claiming `service_role`:** HTTP 401 from PostgREST.
- **Forged `actor` envelope field:** `validation_failed` `{actor: unknown_field}`.
- **Forged `system_principal_id` / `initiating_member_id` / `member_id` / `role` payload fields:** `validation_failed` on each field.
- **Forged `x-system-principal` / `x-initiating-member` / `x-actor-role` headers:** ignored. The probe ran as the real principal, and the audit carries no forged ids.
- **`fixture_counter.increment`:** `forbidden` `command_not_allowed`. The unlisted command name is not recorded.
- **`app.sys_audit` over the Data API:** HTTP 406 (schema not exposed).

Only the two valid-credential probes succeeded. Every request that reached the database wrote exactly one content-free audit row; the forged-JWT and audit-table requests were stopped by PostgREST first.

## Local stack

| File | What it shows |
|---|---|
| `local-smoke-output.txt` | `supabase/tests/system_api_smoke.sh`, the same 15-case matrix with a run-time credential and a real local user session, then the audit assertions. |
| `local-matrix.jsonl`, `local-audit.json`, `local-health-snapshot.json` | Raw matrix, audit rows and snapshot from that run. |

`npm run db:test` covers the remaining rules in `supabase/tests/system_access_test.sql` (95 assertions):

- revoked, expired and disabled credentials
- re-marking local → staging → production, with the row-binding refusal
- the production `ops_system_access` gate, closed and then owner-approved
- `service_role` and direct callers
- operator checks and TTL bounds
- guards and privileges
- alerting disabled in every environment

## Still open (production gates, not blockers)

- `q12_operations` and `ops_alert_destination` are unresolved, so alerting is disabled.
- `ops_system_access` is unresolved, so the production system route is closed.
- No scheduler exists.
- Israel is the only operator.

See `docs/runbooks/system-access-and-operations.md`.

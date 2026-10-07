# Story 2.11 — staging verification (tmurpotfluignacfueki, 2026-10-07)

Synthetic data only.

## Migration

| Version | Name | How applied |
|---|---|---|
| 20261007174952 | member_deletion | Supabase MCP `apply_migration` (local file renamed from 20261007171500) |
| 20261007175000 | member_deletion_rows | **pending: owner paste** (renamed from 20261007171600 so it sorts after the main file) |

## Function parity

Full join of `md5(pg_get_functiondef)` (CR removed) over every function in `app`, `api` and `public`,
staging against a fresh local reset (which includes the rows file). Differences, all expected:

| Function | Why |
|---|---|
| `app.identity_deletion_purge_rows(uuid)`, `app.identity_deletion_purge_auth_user(uuid)`, `app.cells_deletion_purge_rows(uuid)` | fail-closed stubs until the owner pastes `20261007175000` |
| `app.identity_revoke_auth_sessions(uuid)`, `app.identity_remove_auth_extras(uuid,text)` | stubs until the owner pastes `20261007160100` (2.8) |
| `app.cells_text`, `app.identity_application_name` | known escape transcription by the connector (behaviour verified in 2.5/2.6) |
| `app.identity_reclaim_phone_username` | owner-pasted body (whitespace) |

No function is missing on either side.

## Privileges

The owner of the three purge functions (`postgres`) has DELETE on `auth.audit_log_entries` and
`auth.users` on staging, so the erase step will not fail closed for lack of privilege once pasted.

## Edge Function

`identity-deletion` deployed with the connector (`verify_jwt: false`, files `index.ts` + `logic.mjs`), version 1, ACTIVE.

## API checks (synthetic Admin +12025550150)

| Check | Result |
|---|---|
| `identity_admin_deletions` | 200, `accepting: true`, no deletions |
| `identity_admin_deletions` without a session | 401 |
| `identity_deletion_command` without a session | 401 (no anon grant) |
| `identity_my_membership_status` | 200 |
| Function without a credential | 401 `unauthenticated` |
| Function with a well-formed but unknown credential | 403 `refused` (the system route refuses it) |

The full deletion matrix runs on the local stack (`tools/identity-e2e/deletion.mjs` 12/12). On staging, the
erase steps wait for the owner's paste and the worker for the owner's credential; both are in
`owner-consolidated-test.md`.

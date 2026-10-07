# Story 2.12 — staging verification (tmurpotfluignacfueki, 2026-10-07)

Synthetic data only.

## Migration

| Version | Name | How applied |
|---|---|---|
| 20261007193513 | identity_admin_fallback | Supabase MCP `apply_migration` (local file renamed from 20261007190000) |

## Checks

| Check | Result |
|---|---|
| Retired-and-recreated tables keep every row | `identity_access_audit` 3 = retired copy 3; `ops_operator_actions` 11 = retired copy 11 |
| `app.identity_admin_fallback_grant` and the replaced `app.identity_admin_member_grants` | `md5(pg_get_functiondef)` identical to local (`913ab31c...`, `b487fbf2...`) |
| Client EXECUTE on the fallback command | none (`authenticated` false) |
| `identity_admin_member_grants` as synthetic Admin +12025550150 | 200, 4 members, every row carries `admin_via_fallback` (all false) |
| `identity_my_access` | 200 |

The runbooks rehearsal runs on the local stack (`tools/identity-e2e/runbooks.mjs` 16/16). The owner's staging
rehearsal (`owner-rehearsal.md`) is part of the consolidated owner test. The "Admin by operator fallback"
label ships with the next staff web staging build.

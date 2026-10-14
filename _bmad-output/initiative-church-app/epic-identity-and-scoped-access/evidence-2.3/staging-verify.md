# Staging verification (2026-10-06/07, parent session)

Project `bic-kafue-platform-test` (`tmurpotfluignacfueki`). Migration `20261006234820_identity_grants` applied through the connector; every created/changed function's `md5(pg_get_functiondef)` equals the local reset (49 of 49).

Setup: restricted-operator bootstrap `app.identity_bootstrap_admin(<SYNTHETIC Staging Tracer>, 'israel')` (fictional `+1 202 555 0150`), journalled in `app.ops_operator_actions`.

| Step (API, Admin = +…0150) | Result |
|---|---|
| `identity_my_access` | 200, roles `["admin"]` |
| `identity_admin_member_grants` | 200, two synthetic members, no care/finance fields |
| self-grant `media` | refused `forbidden` (`member_id: unsupported`) |
| grant `lead_pastor` through Admin command | refused `forbidden` (`role: unsupported`) |
| grant `media` to SYNTHETIC Owner Demo (+…0151) | 200, roles `["media"]` |
| revoke `media` | 200, roles `[]` |

Owner device demonstration (Android release build against staging, commit b8fd134), owner-reported:
1. Access tab showed no roles.
2. After the grant, switching tabs and returning showed **Media**, no re-sign-in ("Seen").
3. After the revoke, switching tabs and returning showed no roles, no re-sign-in ("Gone").

Not demonstrated on a device: the staff web Admin "Roles & access" screen (no static host yet; owner step in the environments runbook). The Admin side used the same `api.identity_grant_command` that screen calls.

# Story 2.10 — staging verification (tmurpotfluignacfueki, 2026-10-07)

Synthetic data only.

## Migration

| Version | Name | How applied |
|---|---|---|
| 20261007151523 | membership_lifecycle | Supabase MCP `apply_migration` (local file renamed from 20261007170000) |

## Function parity

All 22 functions this migration creates or replaces (including the replaced 2.8 hold functions, the 2.8
credential queue and the `identity` authorizer) have an identical aggregate of `md5(pg_get_functiondef)`
on staging and local (`276b85bca8ee9809ed50e88936a41eeb`).

## API checks (synthetic Admin +12025550150)

| Check | Result |
|---|---|
| `identity_admin_membership_lifecycle` | 200 (no deactivated members, login holds or handovers yet) |
| `identity_my_membership_status` | 200, `deactivated: false` |
| `identity_admin_credential_queue` (replaced in place) | 200 |
| `identity_admin_recovery_cases` (2.9) | 200, `accepting: true` |
| Lifecycle read without a session | 401 |

Deactivate / restore / login-hold flows are proven on the local stack (`tools/identity-e2e/lifecycle.mjs` 9/9) and are part of
the owner's consolidated staging test. Session revocation on staging needs the owner's paste of `20261007160100`.

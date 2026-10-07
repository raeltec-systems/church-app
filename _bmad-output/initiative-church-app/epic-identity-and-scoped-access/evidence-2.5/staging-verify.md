# Story 2.5 — staging verification (tmurpotfluignacfueki, 2026-10-07)

Synthetic data only. Fictional numbers only (+1 202 555 01xx). No passwords or tokens recorded.

## Migrations

| Version | Name | How applied |
|---|---|---|
| 20261007063340 | membership_review | Supabase MCP `apply_migration` (local file renamed to the hosted version) |
| 20261007131600 | membership_review_reclaim_sessions | Pasted by the owner in the staging SQL Editor (the connector cannot approve SQL containing `delete from`); `schema_migrations` row recorded with version and name only |

## Function parity with a local reset

- 32 of 33 story 2.5 functions: `md5(pg_get_functiondef)` identical to local.
- `app.identity_reclaim_phone_username`: identical after collapsing whitespace
  (`d1aa06de3ae91b9a70bc8e199179f404` on both). The pasted copy carries extra whitespace only.

## Functional checks (API as the bootstrapped synthetic Admin +12025550150)

| Check | Result |
|---|---|
| Admin application queue | 200; one open application (SYNTHETIC Church Member, revision 2) |
| Admin member search | 200; both synthetic members with account state |
| Approve application (`identity_check: in_person`) | 200, `church_status: approved`, member created; audit `application_approved` |
| Reclaim: fictional holder +12025550160 signed up, then reclaimed | 200, `released: true` |
| Holder's existing access token after reclaim | 401 (PT401) |
| Holder password sign-in after reclaim | 400 `invalid_credentials` |
| Holder refresh token after reclaim | 400 `refresh_token_not_found` |
| `auth.users` for the holder | phone released, banned, 0 sessions, 0 live refresh tokens |
| New sign-up on the released number | 200, a different account |
| Audit rows | `phone_username_reclaimed`, `application_approved`; no phone number in audit content |

## Device demo

Pending: applicant +12025550152 sees the approval on the staging APK (v5) after a fresh sign-in.

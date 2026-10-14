# Story 2.7 — staging verification (tmurpotfluignacfueki, 2026-10-07)

Synthetic data only. No passwords, tokens or email addresses recorded.

## Migration

| Version | Name | How applied |
|---|---|---|
| 20261007093323 | recovery_email | Supabase MCP `apply_migration` (local file renamed from 20261007140000 to the hosted version) |

- Staging Auth schema version `20260831180000` (GoTrue v2.197.0) — the version the reset gate was proven against.
- Trigger `identity_email_link_gate` on `auth.users`: present, enabled (`O`).

## Function parity with a local reset

All 29 story 2.7 functions (including the replaced `identity_authorize_command`) have identical
`md5(pg_get_functiondef)` on staging and local.

## Functional checks (API)

| Check | Result |
|---|---|
| Password sign-in for the synthetic Admin after the trigger exists | 200 |
| `identity_admin_recovery_email_queue` as Admin | 200, empty |
| `identity_my_recovery_email` as a granted member | 200, `can_propose: true`, no approved email |
| Admin queue without a session | 401 |

## Pending (owner's consolidated staging test)

- Append the mobile redirect URLs to the staging `uri_allow_list` (owner, Management API).
- Email flows with the owner-approved `israelmuyoba+<tag>@gmail.com` inboxes: verify, approve, reset from
  mobile and web links, the failure cases, and the reset-gate canary (an unapproved address's link is refused).

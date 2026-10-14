# Story 2.8 — staging verification (tmurpotfluignacfueki, 2026-10-07)

Synthetic data only. No passwords, tokens, phone numbers or email addresses recorded.

## Migrations

| Version | Name | How applied |
|---|---|---|
| 20261007111436 | credential_review | Supabase MCP `apply_migration` (local file renamed from 20261007160000) |
| 20261007120810 | open_field_error_vocabulary | Supabase MCP `apply_migration` (contract fix after 2.8; renamed from 20261007160200) |
| 20261007160100 | credential_review_auth_rows | **Pending:** the owner pastes it in the staging SQL Editor (it contains Auth row deletions the connector cannot apply). Until then the two Auth-row helpers are fail-closed stubs and approve-change, lost-device hold, restore and accept answer `unavailable`. |

Triggers `identity_hold_release_epoch` and `identity_recovery_email_pending_change` exist on staging.

## Function parity with a local reset (every function in `app` and `api`)

All functions have identical `md5(pg_get_functiondef)` on staging and local except these six, each explained:

| Function | Why it differs |
|---|---|
| `app.cells_text`, `app.identity_application_name` | Connector transcribed `\uXXXX` escapes as literal characters; behaviour verified identical (2.4, 2.6 evidence) |
| `app.identity_reclaim_phone_username`, `app.rcv_hold_after_restore` | Pasted by the owner (whitespace / CRLF); verified identical after whitespace normalisation (2.5, 1.10 evidence) |
| `app.identity_revoke_auth_sessions`, `app.identity_remove_auth_extras` | Still the fail-closed stubs until `20261007160100` is pasted |

## Pending (owner's consolidated staging test)

Paste `20261007160100_credential_review_auth_rows.sql`, then run the 2.8 scenarios in `owner-consolidated-test.md`.

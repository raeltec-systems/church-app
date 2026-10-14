# Staging verification (2026-10-06, parent session)

Project `bic-kafue-platform-test` (`tmurpotfluignacfueki`). Phone sign-in enabled by the owner via Management API (no SMS provider credentials); public `/auth/v1/settings`: `external.phone=true`, `phone_autoconfirm=true`.

Migrations on staging (list_migrations): … `20261006215306_recovery_journal`, `20261006215400_recovery_journal_hold` (owner-pasted), `20261006215842_identity_live_access`, `20261006223524_identity_session_trust`. Local file `20261006223524_identity_session_trust.sql` content identical; renamed locally to the hosted version.

Checks (fictional `+1 202 555 0150`, synthetic member seeded with `app.identity_seed_synthetic_link`):

| Step | Result |
|---|---|
| phone+password signup | 200 |
| login, JWT amr | `password` |
| summary before link | 403 `not_linked` |
| summary after link | 200, `SYNTHETIC Staging Tracer`, `is_synthetic=true` |
| wrong password | 400 `invalid_credentials` |
| no token | 401 permission denied |
| `/otp` phone | 500 `Unable to get SMS provider` (no SMS) |
| after 2.2: old session after password change | 401 `untrusted_session` |
| after 2.2: fresh sign-in (> 5 s margin) | 200 |
| marker / gates / alerting / recovery hold | `staging` / closed / disabled / none |
| security advisors | RLS-no-policy INFO only + pre-existing leaked-password WARN |

Passwords were random per run and never printed or stored in the repo.

## Owner device demonstration (2026-10-06, Android, release build against staging, commit 70cfa3a)

Owner-reported, with screenshot of the granted summary:
1. Create account with `+1 202 555 0151` (fictional) and a password: landed on "not linked" (owner screenshot of the earlier sign-in-tab attempt showed the generic `invalid_credentials` text; staging Auth log confirms no account existed then).
2. Parent linked it with `app.identity_seed_synthetic_link` → member `SYNTHETIC Owner Demo`.
3. Check again: summary shown ("Church member", "Synthetic test record", "Sign-in username: +12025550151").
4. App fully closed and reopened: still signed in, summary shown, no password prompt (2.2 stored session).
5. Sign out: summary cleared, sign-in requested.

Device finding fixed during the demo: with the on-screen keyboard open the sign-in page went blank (the shell and page Scaffolds both applied the keyboard inset). Fixed in 70cfa3a with a regression test.

Synthetic staging accounts left in place: `+1 202 555 0150` (SYNTHETIC Staging Tracer) and `+1 202 555 0151` (SYNTHETIC Owner Demo). Deleting Auth users needs an approval prompt the owner's app does not receive; remove them from the Supabase dashboard (Authentication → Users) when convenient, or keep them for later demos.

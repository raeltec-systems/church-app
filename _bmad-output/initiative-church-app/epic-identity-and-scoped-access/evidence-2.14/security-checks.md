# Story 2.14: independent security checks on staging (entries 2 and 9)

The epic asks for the alternate-route (entry 2) and stale-grant / reset-race (entry 9) cases to be
repeated by an independent check before production. They were rerun **against staging Auth and
the deployed `identity-assisted-recovery` function**, through the public API with the publishable
key only, by `tools/identity-e2e/staging-suite.mjs` (phases `security` and `recovery`). Results:
`staging-suite.jsonl` (step ids below), summarised in `staging-suite-summary.md`.

The suite holds no owner secret: no service-role or secret key, no system credential, no SQL. So
every case that needs Auth Admin power, the system route, SQL, email or a long wait is listed
below as **owner** (the owner's consolidated test) or **local-only** (already proven on the local
stack by the E2E named), never skipped silently.

## Entry 2: live-session trust across alternate Auth routes

| Case | Local E2E | Staging (this story) |
|---|---|---|
| Generic sign-in errors (wrong password = unknown number) | `run.mjs` E15 | **ran** X10 |
| Duplicate phone username refused | E16 | **ran** X11 (`422 user_already_exists`) |
| Passwordless and anonymous sign-up refused | E17 | **ran** X12 (`anonymous_provider_disabled`) |
| Phone `/otp`: no SMS, no session, access unchanged | E18 | **ran** X13 (500, no token; existing number only, so no new user is created) |
| Signed out: every surface 401 | E20 | **ran** matrix row `anon` (every read 401, every command 401) |
| Direct table query refused | E21 | **ran** X14 (`app` 406, `api` 404) |
| Local sign-out ends only that session | E22 | **ran** X16 |
| Refresh keeps access (password AMR kept) | E30 | **ran** X15 |
| Tampered or unsigned JWT refused | (PostgREST) | **ran** X17 (both 401) |
| Direct phone change through Auth (`PUT /user`): review, then Admin restore | E38/E39 | **ran** X18. Finding (expected, recorded): with `phone_autoconfirm` on and no SMS, Auth **accepts** a direct phone change from a live session; the account then answers `review_required` everywhere (no reason shown, no phone in the own read), the old number no longer signs in, and `identity.restore_credentials` puts the approved number back and revokes every session. No private access at any point. An earlier full run also showed the 2.8 rule C51 on staging: the same persona had changed its password directly (X19) since its last binding approval, so the restore kept a **security hold** (`review_required` after restore) until a staff-assisted reset; the suite now runs X19/X20 on a second persona and heals such a hold with an assisted reset (`S02-heal-*`). |
| Password change ends every session; a sign-in inside the 5 s trust margin is refused | E36 (via reset), 2.2 staging | **ran** X19 |
| Global sign-out revokes all sessions and refresh tokens | E42 | **ran** X20 |
| Pre-approval session refused after approval | 2.5 | **ran** R13 |
| Removed Admin's open tab refused at once | `grants.mjs` G18 | **ran** G11 |
| Signed-out Admin session refused for commands | G22 (magic link) | **ran** G13 (local sign-out) |
| Magic-link, email-OTP and recovery sessions denied | E32-E34 | **owner** (needs email; consolidated test 2.7 incl. the reset-gate canary) / local-only |
| Direct email change → review | E40 | **owner** (needs email) / local-only |
| Ban / unban never revives a session | E43 | local-only (Auth Admin API) |
| Dormant account denied without activity refresh | E44 | local-only (needs SQL to age the fixture) |
| Untrusted (magic-link) Admin session refused | G22 | local-only (Auth Admin link generation) |

## Entry 9: staff-assisted recovery, stale grants and reset races

| Case | Local E2E | Staging (this story) |
|---|---|---|
| Valid grant works once; fresh sign-in; staff never see secret, digest or code | `assisted.mjs` A10, A20 | **ran** A10 (incl. wrong secret refused, replay refused, old session 401) |
| Unknown number gets the same neutral answer | (2.9 staging S2) | **ran** A10b |
| Re-issued grant supersedes the unused one | A11 | **ran** A11 |
| Direct password change after issue kills the grant | A12 | **ran** A12 |
| Unlinked account: grant fails; explicit relink keeps the member id | A13, A17 (relink) | **ran** A13 (relink through a new application and `link_application`, same member id) |
| Two concurrent redemptions: exactly one wins | A14 | **ran** A14 |
| Grant presented with another member's number is burned | A15 | **ran** A15 |
| Holds stay through the reset; release only after the member's own reset, by another Admin | A18 | **ran** A18 (lost-device hold) |
| Deactivation ends an issued grant | A22 | **ran** A22 |
| Per-number limit under concurrency (5/h) | A23 | **ran** A23 |
| Per-client limit (10 per 10 min) | A24 | **ran** A24 |
| Forged `x-forwarded-for` first hop does not escape the per-client bucket | (2.9 Hosted step 4, staging only) | **ran** A24b |
| Uncertain / late completion keeps the account held; reconcile | A16 | local-only (drives the fenced system steps with the system credential) |
| Relink possible after reconcile | A17 | local-only (needs A16) |
| Expired grant (15 min) | A19 | local-only (kept out of the staging run to bound its length) |
| Cancel between begin and dispatch fails closed | A21 | local-only (system credential) |
| Reconciliation's session revocation on staging | 2.9 note | covered by the owner's paste of `20261007160100` (done) and the lost-device / restore checks above, which revoke sessions on staging |

## Stale grants and combined roles (entry 3 cases repeated in passing)

The permission matrix (`M-*` lines, 14 principals x 21 reads and 43 commands) re-proves on staging
that a grant or revocation applies on the next call (G10), that Admin and combined-role members
reach no care or finance fixture (`fixture_scoped_read_*` 403 `not_granted` for every role), and
that the system route refuses every user session.

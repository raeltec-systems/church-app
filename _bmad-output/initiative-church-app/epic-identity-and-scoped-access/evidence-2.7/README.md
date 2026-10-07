# Evidence: story 2.7, recover a password through a verified same-account email

All runs are LOCAL (Supabase CLI stack, GoTrue v2.197.0, Mailpit catching email; nothing left the machine), 2026-10-07, with SYNTHETIC numbers (+44 7700 900270–900289) and `@example.test` addresses. Nothing was run against a hosted project. Staging verification with the owner-approved inboxes is the owner/parent step in `docs/runbooks/identity-access.md` ("Recovery email and forgotten password", Hosted).

| File | What it shows |
|---|---|
| `recovery-e2e.jsonl` | `tools/identity-e2e/recovery.mjs`, 20/20 (after the review fixes), through real GoTrue, PostgREST and Mailpit (redacted: no tokens, codes, links, numbers or addresses) |
| `live-adapter-check.txt` | `tools/identity-e2e/live-recovery-check.sh`, L1–L5: the real Dart adapters (recovery email repository, command gateway, isolated recovery gateway) |
| `local-pgtap.txt` | `npm run db:test`: 996 tests including `recovery_email_test.sql` (75) |
| `local-api-smoke.txt` | `npm run db:smoke` story 2.7 lines (phone provider off, CLI default config) |

## The verify bullet, row by row

| Verify bullet | Evidence |
|---|---|
| Verify and approve a recovery email on the same account | E2E `X10`–`X14` (phone sign-up without email, proposal, `updateUser(email)` on the same user id, Auth email empty until the link, link returns to `zm.bickafue.mobile://callback/auth/email-confirmed`, access waits in review, Admin approves, binding revision 2, pre-approval session refused, fresh sign-in granted with `has_recovery_email`); adapters `L1`–`L3`; pgTAP "Proposing", "Verification", "Admin decision" |
| Reset from the mobile link | E2E `X20`–`X21`; adapters `L4`–`L5` |
| Reset from the web link | E2E `X23` (`http://127.0.0.1:3000/#/auth/recovery`, code before the hash) |
| Unverified address fails neutrally | E2E `X12` (`200 {}`, no reset email); pgTAP "an unverified email cannot be approved" |
| Unapproved address fails neutrally | E2E `X31` (email arrives, link redirects with `error_code=unexpected_failure` and no code; the magic link for it gives no session either); pgTAP redemption refused; smoke |
| Changed address fails neutrally | E2E `X32` (approved address: no email; new address: link gives no code); pgTAP "after a direct Auth email change neither address can redeem" |
| Expired and reused links fail neutrally | E2E `X24`, `X22` (`otp_expired`, no code) |
| Unknown address | E2E `X30`; smoke `200 {}` |
| Recovery session cannot read private data | E2E `X20` (AMR `recovery`; summary `401 untrusted_session`; own recovery-email read `401`); pgTAP |
| Older sessions lose private access | E2E `X21` (an older and an earlier session `401`, refresh refused, old password refused, only the recovery session row remained before its sign-out), `X23`; adapters `L5` |
| An existing hold stays in force | E2E `X33` (reset works, fresh sign-in `403 review_required`, hold still open); pgTAP |
| Redirect allowlist | E2E `X25` (a non-allowlisted `redirect_to` falls back to the site URL; the code is useless without the device's PKCE verifier, `X20` `code_without_verifier: 400`) |
| No SMS | E2E `X34`; smoke |
| Lockout exit (review fix): withdraw from review, reject verified, reject before the link is clicked | E2E `X35`–`X37`; pgTAP "Lockout exit" (auth email and email-change tokens cleared, `one_time_tokens` neutralised, review lifted only without other changes) |
| Approval only after the proposal (review fix) | pgTAP "an email change older than the proposal is not approved" |

## Findings

1. **GoTrue sends reset emails to any address it holds.** `/recover` (and `/otp` magic links) cannot be restricted before sending without a send-email hook, so the gate is at redemption: a verified but unapproved address can receive a reset email, but its link opens no session (`X31`). This is the neutral failure the verify bullet asks for; the email itself is not suppressed.
2. **Redemption is a distinct row update.** GoTrue v2.197.0 redeems a recovery or magic-link token with `UPDATE users SET recovery_token, updated_at`; password updates (native and Admin) clear the token in the same row update as the new password, so the trigger distinguishes them (pgTAP "a password update that clears the token is not a redemption").
3. **Adding an email puts access in review until approval** (AD-3). The member sees why on the Recovery email screen. The Admin's approval, a rejection or the member's own withdrawal ends the review, and each moves the trust epoch, so the member signs in again. A confirmation link opened after a rejection changes nothing (`X37`, GoTrue answers `otp_expired`).
4. **PKCE.** A link works only on the device and browser that asked for it, and only the newest one (the verifier is replaced). The forgot-password copy says so.
5. **Reset gate on hosted Auth.** `tools/ci/verify-hosted.sql` now fails when the Auth schema is not `20260831180000` (GoTrue v2.197.0) or the gate's columns/trigger are missing; the runbook's reset-gate canary repeats `X31` on staging.
6. **Accepted risks** (runbook "Known and accepted risks"): GoTrue `/recover` enumeration via 429/timing (owner decision at entry 14); stolen-session `PUT /user` lockout (entry 8).
7. **Phone switch.** The local phone provider was found off and left off; it was on only for the E2E and adapter runs.

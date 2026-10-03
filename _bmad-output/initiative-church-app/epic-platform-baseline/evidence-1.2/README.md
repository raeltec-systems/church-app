# Evidence 1.2: password-session trust and no-SMS provider behaviour

- **Project:** `bic-kafue-auth-test` (`szfyfezfvxyuvovnnakr`), eu-central-1. This is an isolated Auth test project with synthetic accounts only.
- **Observed:** 2026-10-03.
- **Raw log:** [`harness-log.jsonl`](harness-log.jsonl). There is one redacted JSON line per harness call, keyed by `step`.
  - JWTs are reduced to the header plus the trust claims, with `sub` and `session_id` replaced by digests.
  - Refresh tokens, link tokens, OTPs, passwords and keys are redacted.
  - Owner inbox addresses are masked as `…+bicauth-<tag>@gmail.com`.
- **CI scan:** `tools/auth-harness/scan-evidence.sh` enforces the redaction above.
- **Harness and probe:** [`tools/auth-harness/`](../../../../tools/auth-harness/README.md).

## How to read this file

- **Cite by step.** Every claim below names the `step` values of the log lines that support it.
- **Allowed / denied.**
  - *Allowed*: `public.harness_private_probe()` both inserted and saw the caller's row.
  - *Denied*: RLS hid the row and blocked the insert while `role` was still `authenticated`.
- **The predicate.** `harness.trusted_password_session()` requires both of these:
  - a `password` entry in the verified JWT `amr`;
  - a live `auth.sessions` row for `session_id` and the same user, with `not_after` not passed.
- **Legacy lines (not relied on).** Log lines 5 and 6 (steps `22-verify-signup-link` and `23-probe-signup-link-session`) were written by an earlier, uncommitted harness build. That build put the JWT summary under a key that redaction then blanked. The same session was re-probed with the committed tool at step `24-probe-signup-session-jwt`, and only that line is cited. Step 22 is used only for its HTTP status and redirect shape. The rerun re-captures both steps.
- **Operator notes are not observations.** Steps `68-sql-session-rows-after-password-change` and `94-sql-and-auth-log-observations` are free-text notes with no captured query output, so no claim below depends on them. Raw query output is attached with `run.mjs attach` and a committed query file in `tools/auth-harness/sql/`, as at steps `98` and `99`.
- **"To re-capture"** marks a claim the committed log does not yet support. It is scheduled for the owner-gated rerun.

## Versions

| Item | Value | Source |
|---|---|---|
| Auth (GoTrue) | **v2.197.0** | step `00-provider-info` (`/auth/v1/health`) |
| Postgres | **17.11** (`PostgreSQL 17.11 on x86_64-pc-linux-gnu`) | step `98-hosted-probe-grants-after-004` (`observe_probe_grants.sql`) |
| JWT signing | ES256 with `kid`, 3600 s lifetime | steps `24`, `30` |

## Provider configuration observed (step `00-provider-info`, `/auth/v1/settings`)

| Setting | Value | Meaning |
|---|---|---|
| `external.phone` | **false** | Phone provider is disabled (the project default). This is an owner dashboard gate; see the end of this file. |
| `phone_autoconfirm` | false | Phone confirmations are still on. They must be turned off when phone is enabled. |
| `sms_provider` | `twilio` | Default label only. The harness configured no credentials or hook; the dashboard is not readable here. |
| `external.email` / `mailer_autoconfirm` | true / false | Email provider is on and email confirmation is required. |

- **Email delivery:** mail came from the default Supabase sender `noreply@mail.app.supabase.io` to `…+bicauth-e1@gmail.com`, and the links redirected to the default Site URL `http://localhost:3000` (steps `22`, `41`, `82`).
- **Email throttles:** `/recover` returned 429 `over_email_send_rate_limit` in two forms (steps `51`, `52`, `54`):
  - "only request this after N seconds" (per-address);
  - "email rate limit exceeded" (project-wide).

## Probe deployment (step `98-hosted-probe-grants-after-004`)

- **Applied file:** `sql/001_trusted_session_probe.sql`, applied as migration `auth_harness_004_reconcile_probe`.
- **Hosted grants:** `anon` has no EXECUTE on any harness function and no usage on schema `harness`. RLS is on, and `authenticated` holds only SELECT and INSERT on the probe table.
- **Timing caveat:** steps 00 to 97 ran against migrations 001 to 003. In those, `harness_whoami.session_live` omitted the `not_after` condition, which the predicate already applied. The verdicts come from the predicate, which already checked `not_after`, so they are unaffected. The `session_live` diagnostic column in steps 00 to 97 may differ for a time-boxed session, but `not_after` values were not captured. The rerun uses 004, and `observe_account_sessions.sql` records `not_after`.

## Results (email track, account `…+bicauth-e1`)

| # | Scenario | Steps | Observed in log | Verdict |
|---|---|---|---|---|
| 1 | Login before email confirmation | 21 | 400 `email_not_confirmed` | expected |
| 2 | Signup confirmation link session | 22, 24, 26, 27 | 303 to the Site URL with a session. The JWT has `amr=[otp]`, `aal1` (24). Refresh keeps `otp` (26), and the session is denied (24, 27). | **denied** ✔ |
| 3 | Signup link reused | 25 | redirect `error=access_denied`, `otp_expired` | one-use ✔ |
| 4 | Email/password login | 30, 33 | JWT `amr=[password]`; allowed | **allowed** ✔ |
| 5 | Wrong password vs unknown account | 31, 32 | both 400 `invalid_credentials`, same message | neutral ✔ |
| 6 | Refresh password session | 34, 35 | refreshed JWT keeps `amr=[password]`; allowed | ✔ |
| 7 | Magic link (`/otp` email) | 40–42b | session `amr=[otp]` (fragment type `magiclink`); denied | **denied** ✔ |
| 8 | Password change via `PUT /user` from session B (no reauth or nonce prompted) | 60–67 | See the note after the table. | revocation ✔ for A and the magic-link session; **to re-capture** for the signup-link session |
| 9 | Recovery link (`/recover` → `/verify`) | 81–83 | Fragment type `recovery`, but JWT `amr=[otp]`; denied | **denied** ✔ |
| 10 | Set password from recovery session | 84–87 | 200. The recovery session stays live (85) and refreshable with `amr=[otp]` (86), and stays denied (85, 87). | gate holds ✔ |
| 11 | Pre-reset password sessions C and D after the recovery password set | 88, 88b, 89 | Both C and D show `session_live=false` and are denied. D's refresh failed with `refresh_token_not_found`. **C was never refreshed (to re-capture).** | revocation ✔ (C refresh to re-capture) |
| 12 | Fresh password login after reset | 90–92 | Pre-reset password refused `invalid_credentials`; new login `amr=[password]`; allowed | ✔ |
| 13 | Recovery link reused | 93 | `otp_expired` | one-use ✔ |
| 14 | Explicit logout of recovery session | 95–97 | 204; that JWT then denied (`session_live=false`); session E still allowed | ✔ |
| 15 | `/recover` unknown vs known address | 50–55, 81 | Unknown: always 200 `{}`. Known: 200 `{}` normally, but 429 inside the throttle windows. | neutral except when throttled ⚠ |
| 16 | Phone with provider disabled | 10, 70–72 | See the note after the table. | phone path refused while disabled. **No-SMS row with an existing phone user: to re-capture** |
| 17 | No SMS activity in the run window | 99 | `observe_auth_logs.sql` over 12:00–13:45Z: every path/error group has `sms_mentions = 0` | ✔ for this window |

**Row 8 detail (steps 60–67).**
- **Session A:** `session_live=false` and denied (61a). `/user` returned 403 (67), and refresh failed with `refresh_token_not_found` (62).
- **Magic-link session:** `session_live=false` and denied (61b). It was not refreshed.
- **Session B:** still allowed (61c) and refreshable (63).
- **Passwords:** the old password was refused (64), and a fresh login was allowed (65, 66).
- **Not covered:** the signup-link session (`e1-signup-r`) was not probed or refreshed after the change.

**Row 16 detail (steps 10, 70–72).**
- `/signup` phone: 400 `phone_provider_disabled` (10).
- `/token` phone: 422 `phone_provider_disabled` (72).
- `/verify` with type `sms` and a guessed code: 403 `otp_expired` (71).
- `/otp` phone (70, despite its step name): 422 `otp_disabled` ("Signups not allowed for otp"). The harness sent `create_user:false` for a phone with **no user**, so this is the no-user path, **not** evidence about SMS or the provider.

## Findings for the identity epic (from the rows above)

- **Gate on `password` in `amr`; do not blacklist `recovery`.** Signup-link, magic-link and recovery sessions all carried `amr=[otp]` (rows 2, 7, 9), and setting a password did not upgrade the recovery session (row 10).
- **The live-session check is mandatory.** Deleted sessions' JWTs stayed signed and unexpired. Only the live `auth.sessions` check denied them (rows 8, 11).
- **The recovery session survives the reset.** It remains live and refreshable after setting the password (row 10). The app must sign it out after reset; the AMR gate denies it meanwhile.
- **`/recover` 429 is an existence oracle.** It appeared only for the known address (row 15). The UI must show the same neutral acknowledgement for 200 and 429, and should rate-limit before calling Auth.
- **`PUT /user {password}` asked for no reauthentication (row 8).** Recent-password proof must be enforced by the app. Secure password change could trigger email or SMS nonces, which AD-20 forbids for phone-only accounts.
- **Open operational items (Q1).** The leaked-password advisor is open, and default SMTP is not fit for production recovery.

## To re-capture in the owner-gated rerun (Phone provider ON, Confirm phone OFF, no SMS)

Use the committed harness (`init`, then links piped on stdin, then `cleanup`). Attach raw query output with `attach`.

1. Re-capture steps 22 and 23 (signup link verify and probe) with the committed tool.
2. Phone/password signup and login for a phone account (`amr`, probe allowed), with a wrong password vs an unknown phone.
3. `/otp` with `--phone` for the **existing** phone user (no-SMS path with the provider enabled), plus a direct `/verify` guess.
4. Add an email on the same account with `PUT /user {email}`, then verify the link. Expect the same user id, a confirmed email and no second user.
5. Email/password alias login on that phone user: `amr=[password]`, same user, allowed.
6. After both the password change and the reset, **probe and refresh every other session**. That includes the signup-link and magic-link sessions and every password session.
7. Attach `observe_account_sessions.sql` after each revocation, `observe_auth_logs.sql` for the rerun window, and `observe_probe_grants.sql`.

**Owner action.** In the Supabase dashboard for `bic-kafue-auth-test`, go to **Authentication → Sign In / Providers → Phone**:

1. Turn **Enable Phone provider** on and turn **Confirm phone** off.
2. Leave the SMS provider credentials empty. Add no Send SMS hook, no test OTPs and no phone MFA.
3. Save.

If the dashboard will not save without SMS credentials, report that, because it changes AD-20.

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

## LOCAL run (2026-10-03, local Supabase CLI stack): phone track blocked by the CLI; email gaps closed

Everything in this section is **LOCAL**, not hosted. Raw log: [`local-harness-log.jsonl`](local-harness-log.jsonl). Every line carries `harness_target: "LOCAL"`; steps are prefixed `L`. The script is `tools/auth-harness/scenarios/1.2-local-rerun.sh`.

- **Versions (LOCAL):** Supabase CLI **2.119.0**; Auth **GoTrue v2.197.0** (step `L00`, `/auth/v1/health`, the same version as hosted); Postgres **17.11** (step `L14`).
- **Probe parity:** `001_trusted_session_probe.sql` was applied to the local DB. Its four function definitions have the **same md5** as hosted step `98` (step `L90`). The local PostgREST exposes only the `api` schema, so the RPCs were reached through the pass-through SECURITY INVOKER wrappers in `sql/local/10_local_api_probe_wrappers.sql`. `supabase db reset` removed all harness objects after the run.
- **Temporary local config for the run (reverted; `supabase/config.toml` is unchanged in the commit):** `[auth.sms] enable_signup = true`, `enable_confirmations = false`, every SMS provider disabled, with no test OTPs, no Send SMS hook and no phone MFA. For hosted parity of the email rows, `[auth.email] enable_confirmations = true` was also set. Mail went only to the local Mailpit and was read by `tools/auth-harness/local-mailpit-link.mjs`.

### Phone track: the CLI refuses to enable phone without an SMS provider

Raw capture: [`local-cli-phone-gate.txt`](local-cli-phone-gate.txt).

- On start, CLI 2.119.0 printed `WARN: no SMS provider is enabled. Disabling phone login`. It then set `GOTRUE_EXTERNAL_PHONE_ENABLED=false`, even with `[auth.sms] enable_signup = true`.
- The CLI source condition requires one of `twilio`, `twilio_verify`, `messagebird`, `textlocal` or `vonage` to be **enabled**. Enabling one is exactly what story 1.2 forbids, so it was not configured. A Send SMS hook or test OTPs would not satisfy the condition either.
- **Harness confirmation (LOCAL), all with the provider forced off:**

| Step | Call | Result |
|---|---|---|
| `L00` | settings | `external.phone=false`, `phone_autoconfirm=true`, `sms_provider=""` |
| `L10` | `/signup` phone | 400 `phone_provider_disabled` |
| `L11` | `/token` phone | 422 `phone_provider_disabled` |
| `L12` | `/otp` phone, `create_user:true` | 400 `phone_provider_disabled` ("Unsupported phone provider") |
| `L13` | `/verify` sms guess | 403 `otp_expired` |

- `L14` (`observe_local_sms_state.sql`) found 0 phone users, 0 phone MFA factors and 0 phone one-time tokens. `L91` (local GoTrue log) found `sms_mentions = 0`.
- **Result:** the phone/password rows (matrix rows 1, 3, 4 and the phone-OTP row with an existing phone user) are **not proven**, locally or hosted.
- **The pattern across config surfaces:** both supported Supabase surfaces, the hosted dashboard and the local CLI, refuse to switch on the phone provider without SMS provider credentials. GoTrue itself was not tested with phone enabled and no provider; that would need a direct container override, which was not authorised. **This is an AD-20 risk, not yet a contradiction.** See the plan's blocked reason.

### Email track re-captured on LOCAL Auth (account `…+bicauth-l1`)

| Rerun item | Steps | Observed (LOCAL) |
|---|---|---|
| 1. Legacy steps 22/23 (signup link) | L20–L24b | `email_not_confirmed` before the link (L21). The link gave a 303 with fragment `signup` and JWT `amr=[otp]`, `aal1` (L22). The probe showed `session_live=true` but `trusted_password_session=false`, so it was **denied** (L23). Refresh kept `otp` and was still denied (L24, L24b). |
| Password sessions, neutral errors | L30–L34 | Login gave `amr=[password]` and was **allowed** (L34). Wrong password and unknown account both returned 400 `invalid_credentials` with the same message (L32, L33). |
| Magic link | L40–L42 | Fragment `magiclink`, `amr=[otp]`, **denied** (L42). |
| 6a. Password change from session B: probe and refresh **every** other session | L50, L60–L64 | **A**, the **signup-link** session (refreshed) and the **magic-link** session all showed `session_live=false`, were denied, got `/user` 403 (L61), and their refresh failed with `refresh_token_not_found` (L62). **B** stayed allowed and refreshable. The old password was refused (L63). Live sessions went from 4 to only B (L50 → L64). |
| 6b. Recovery reset: probe and refresh every other session | L70–L80 | Recovery link: fragment `recovery`, `amr=[otp]`, denied (L74, L75). After the password set, **C**, **D** and the post-change **B** were all denied and their refresh failed (L77, L78). The recovery session stayed live and refreshable, still `otp`, and still denied (L77, L78). A fresh login was allowed (L79b). L80 shows only the recovery and fresh sessions. |
| Neutral recovery | L72, L73 | Known and unknown addresses both returned 200 `{}`. There was no local throttle (local email rate limit), so the hosted 429 oracle (row 15) was not exercised here. |
| 7. Observations | L50, L64, L80, L90, L91 | `observe_local_account_sessions.sql` after each revocation; probe grants; GoTrue log summary with **0 SMS mentions**. |

These close the hosted README's "to re-capture" gaps for rows 8 and 11 and the legacy lines 5–6 **on LOCAL GoTrue v2.197.0**. The hosted legacy lines remain marked legacy.

## Still owner-gated (hosted `bic-kafue-auth-test`)

The CLI does not permit the local phone run, so every phone row stays open on hosted:

1. Phone/password signup and login (`amr=[password]`, probe allowed), with a wrong password vs an unknown phone.
2. `/otp --phone` for the **existing** phone user: no SMS, no session. Also a direct `/verify` guess.
3. Add an email on the phone account with `PUT /user {email}`, then verify the link: same user id, no second user.
4. Email/password alias on that phone user.
5. Attach `observe_account_sessions.sql`, `observe_auth_logs.sql` (expect `sms_mentions = 0`) and `observe_probe_grants.sql`.

**Owner action (Management API, since the dashboard refuses).** Run this with your own personal access token. Never paste the token into the repo or chat.

```http
PATCH https://api.supabase.com/v1/projects/szfyfezfvxyuvovnnakr/config/auth
Authorization: Bearer <owner personal access token>
Content-Type: application/json

{
  "external_phone_enabled": true,
  "sms_autoconfirm": true,
  "hook_send_sms_enabled": false,
  "mfa_phone_enroll_enabled": false,
  "mfa_phone_verify_enabled": false
}
```

- **What the body leaves out:** it sets **no** `sms_provider`, no `sms_twilio_*`, `sms_messagebird_*`, `sms_textlocal_*`, `sms_vonage_*` or `sms_twilio_verify_*` field, and no `sms_test_otp`.
- **Check afterwards:** `GET` the same URL. Every `sms_*` credential and `sms_test_otp` must be null or empty, and `/auth/v1/settings` must show `external.phone: true` and `phone_autoconfirm: true`.
- **If the API refuses** (for example, a 4xx that asks for SMS provider credentials): do **not** add credentials. Report the response body. That would be the third Supabase surface to refuse, and AD-20 then needs an architecture decision.

# Evidence 1.2: password-session trust and no-SMS provider behaviour

- **Project:** `bic-kafue-auth-test` (`szfyfezfvxyuvovnnakr`), eu-central-1. This is an isolated Auth test project with synthetic accounts only.
- **Observed:** 2026-10-03.
- **Auth:** GoTrue **v2.197.0**, from `/auth/v1/health`.
- **Postgres:** **17.11** (`17.11.0.002`).
- **Raw log:** [`harness-log.jsonl`](harness-log.jsonl). There is one redacted JSON line per harness call, keyed by `step`. JWTs are reduced to the header plus the trust claims, with `sub` and `session_id` replaced by digests. Refresh tokens, link tokens, OTPs, passwords and keys are redacted.
- **Harness and probe:** [`tools/auth-harness/`](../../../../tools/auth-harness/README.md).

## Provider configuration observed (`00-provider-info`)

These are the values the API reported at `/auth/v1/settings`:

| Setting | Value | Meaning |
|---|---|---|
| `external.phone` | **false** | Phone provider is disabled (the project default). This is an owner dashboard gate; see below. |
| `phone_autoconfirm` | false | Phone confirmations are still on. They must be turned off when phone is enabled. |
| `sms_provider` | `twilio` | Default label only. No credentials or hook were configured, and the harness never configured any. |
| `external.email` / `mailer_autoconfirm` | true / false | Email provider is on and email confirmation is required. |
| `disable_signup`, `anonymous_users` | false / false | |

- **Email sender:** the default Supabase sender `noreply@mail.app.supabase.io` delivered to the owner-approved plus-address `israelmuyoba+bicauth-e1@gmail.com`.
- **Redirects:** links used `redirect_to=http://localhost:3000`, which is the default Site URL. No allowlist is configured.
- **Email rate limit:** the project-wide limit was observed as 2 emails per hour (`over_email_send_rate_limit`, "email rate limit exceeded"). A separate per-address limit of 60 seconds also applies.

## Probe under test

- **Predicate:** `harness.trusted_password_session()` is true only when both of these hold:
  - the verified JWT `amr` has a `password` entry;
  - `session_id` is a live `auth.sessions` row for `auth.uid()`.
- **Where it applies:** in the RLS policies on the synthetic table `harness.private_probe`.
- **"Allowed" below:** `public.harness_private_probe()` both inserted and saw the caller's row.
- **"Denied" below:** RLS hid the row and blocked the insert, and `role` was still `authenticated`.

## Results against GoTrue v2.197.0 (email track, account `+bicauth-e1`)

| # | Scenario | Steps | Observed | Verdict |
|---|---|---|---|---|
| 1 | Login before email confirmation | 21 | 400 `email_not_confirmed` | expected |
| 2 | Signup confirmation link session | 22–27 | 303 to Site URL with session; JWT `amr=[otp]`, `aal1`; refresh keeps `otp` | **denied** ✔ |
| 3 | Signup link reused | 25 | redirect `error=access_denied`, `otp_expired` | one-use ✔ |
| 4 | Email/password login | 30, 33 | JWT `amr=[password]`, ES256 header with `kid`, 3600 s | **allowed** ✔ |
| 5 | Wrong password vs unknown account | 31, 32 | both 400 `invalid_credentials`, identical message | neutral ✔ |
| 6 | Refresh password session | 34–35 | refreshed JWT keeps `amr=[password]` and the same session | allowed ✔ |
| 7 | Magic link (`/otp` email) | 40–42 | session `amr=[otp]` (fragment type `magiclink`) | **denied** ✔ |
| 8 | Password change via `PUT /user` from session B (no reauth or nonce prompted) | 60–68 | Other sessions (A, signup-otp, magic-link) were deleted, and their unexpired JWTs were **denied** (`session_live=false`). `/auth/v1/user` returned 403 `session_not_found` and refresh returned `refresh_token_not_found`. B survived and stayed allowed. The old password was refused; a fresh login with the new password was allowed. | revocation ✔ |
| 9 | Recovery link (`/recover` → `/verify`) | 81–83 | Session fragment type is `recovery`, but JWT `amr=[otp]` (implicit flow labels recovery as otp, matching the research) | **denied** ✔ |
| 10 | Set password from recovery session | 84–87 | 200. The recovery session stays live and refreshable but stays **denied** (`amr=[otp]`). | gate holds ✔ |
| 11 | Pre-reset password sessions C, D | 88–89 | rows deleted, JWTs **denied**, refresh `refresh_token_not_found` | revocation ✔ |
| 12 | Fresh password login after reset | 90–92 | Pre-reset password refused; new login `amr=[password]` **allowed** | ✔ |
| 13 | Recovery link reused | 93 | `otp_expired` | one-use ✔ |
| 14 | Explicit logout of recovery session | 95–97 | 204; that JWT then denied; session E unaffected | ✔ |
| 15 | `/recover` unknown vs known address | 50–55, 81 | Unknown: always 200 `{}`. Known: 200 `{}` normally, but 429 `over_email_send_rate_limit` inside the 60 s per-address window and when the project email quota is hit. | neutral except when throttled ⚠ |
| 16 | Phone signup / phone password login / phone `/otp` / phone `/verify` guess | 10, 70–72 | 400 `phone_provider_disabled` / 422 `phone_provider_disabled` / 422 `otp_disabled` / 403 `otp_expired`; no session. Auth logs 12:00–13:45Z have **0** lines mentioning sms/twilio. | no SMS path ✔ (provider off) |

## Findings for the identity epic

- **Gate on `amr` containing `password`, not on the absence of `recovery`.** Recovery, magic-link and signup-link sessions all carry `amr=[otp]`, and setting a new password does not upgrade them.
- **Revoked sessions keep working JWTs.** Native password change and recovery password set both delete every *other* session, but the deleted sessions' JWTs remain cryptographically valid until expiry (3600 s). Only the live `auth.sessions` check denies them, so the live-session check is mandatory.
- **The recovery session survives the reset.** It stays live and refreshable after it sets the password. The app must sign it out (or `scope=others` from the fresh session) after reset. The AMR gate keeps it out of private data meanwhile.
- **Reset acknowledgements can leak existence when throttled.** The `/recover` 429 returned only for a known address is an existence oracle, so the app must show the same neutral acknowledgement for 429 and 200 responses and should rate-limit before calling Auth.
- **No reauthentication on password change.** `PUT /user {password}` from a password session succeeded with no nonce. The "require recent password" rule must therefore be enforced by the app (current-password check) or by enabling Secure password change. Enabling it could trigger email/SMS nonces, which AD-20 forbids for phone-only accounts.
- **Not under test here.** The leaked-password protection advisor is open (HIBP check is a Pro-plan feature), and the free-plan default SMTP (2 emails per hour) is unfit for production recovery. Both are Q1 operational decisions.

## Not yet observed: owner gate (phone provider)

These rows of the plan matrix need the Phone provider enabled:

- phone/password signup and login (amr, session);
- same-account email added with `PUT /user {email}` and then verified;
- verified-email/password alias on that same phone user;
- phone `/otp` with the provider **enabled** but no SMS provider.

The MCP tools have no Auth-config write. Owner action, in the Supabase dashboard for project `bic-kafue-auth-test`:

1. **Authentication → Sign In / Providers → Phone**: turn **Enable Phone provider** on and turn **Confirm phone** off.
2. In the same panel, leave SMS provider credentials **empty**. Do not add a Send SMS hook, test OTPs or phone MFA. If the dashboard refuses to save without credentials, stop and report that, because it changes AD-20.
3. **Save**.

Then rerun the commands in [`tools/auth-harness/README.md`](../../../../tools/auth-harness/README.md) (phone account `p1`, email `israelmuyoba+bicauth-p1@gmail.com`). This needs at most 2 emails, within the 2-per-hour quota.

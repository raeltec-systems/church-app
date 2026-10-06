# Evidence 1.2: password-session trust and no-SMS provider behaviour

- **Project:** `bic-kafue-auth-test` (`szfyfezfvxyuvovnnakr`), eu-central-1. This is an isolated Auth test project with synthetic accounts only.
- **Observed:** 2026-10-03 (email track, steps `00`–`99`) and 2026-10-06 (hosted phone track after the owner's Management API change, steps `H00`–`H9x`; see [Hosted phone track](#hosted-phone-track-2026-10-06-after-the-owners-management-api-change)).
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
| `external.phone` | **false** | Phone provider was disabled (the project default) on 2026-10-03. The owner enabled it on 2026-10-06 through the Management API; see the hosted phone track section. |
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
| 8 | Password change via `PUT /user` from session B (no reauth or nonce prompted) | 60–67 | See the note after the table. | revocation ✔ for A and the magic-link session; signup-link session re-captured on hosted 2026-10-06 (H90a, H90b) ✔ |
| 9 | Recovery link (`/recover` → `/verify`) | 81–83 | Fragment type `recovery`, but JWT `amr=[otp]`; denied | **denied** ✔ |
| 10 | Set password from recovery session | 84–87 | 200. The recovery session stays live (85) and refreshable with `amr=[otp]` (86), and stays denied (85, 87). | gate holds ✔ |
| 11 | Pre-reset password sessions C and D after the recovery password set | 88, 88b, 89 | Both C and D show `session_live=false` and are denied. D's refresh failed with `refresh_token_not_found`. C was not refreshed in this run; the 2026-10-06 phone run refreshed every pre-reset session (H57b–H59b). | revocation ✔ |
| 12 | Fresh password login after reset | 90–92 | Pre-reset password refused `invalid_credentials`; new login `amr=[password]`; allowed | ✔ |
| 13 | Recovery link reused | 93 | `otp_expired` | one-use ✔ |
| 14 | Explicit logout of recovery session | 95–97 | 204; that JWT then denied (`session_live=false`); session E still allowed | ✔ |
| 15 | `/recover` unknown vs known address | 50–55, 81 | Unknown: always 200 `{}`. Known: 200 `{}` normally, but 429 inside the throttle windows. | neutral except when throttled ⚠ |
| 16 | Phone with provider disabled | 10, 70–72 | See the note after the table. | phone path refused while disabled. Existing phone user with phone enabled: H20, H39, H68 ✔ |
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
- **Result (2026-10-03):** the phone/password rows (matrix rows 1, 3, 4 and the phone-OTP row with an existing phone user) were **not proven**, locally or hosted. They have since been proven on hosted; see the hosted phone track section.
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

These close the hosted README's "to re-capture" gaps for rows 8 and 11 and the legacy lines 5–6 **on LOCAL GoTrue v2.197.0**. The hosted legacy lines were re-captured on hosted on 2026-10-06 (H81–H86).

## Hosted phone track (2026-10-06, after the owner's Management API change)

The former "Still owner-gated" list is now closed on hosted. Raw log: the `H…` steps of [`harness-log.jsonl`](harness-log.jsonl). Scenario files: `tools/auth-harness/scenarios/1.2-hosted-{a-phone,b-email-alias,c-recovery,d-signup-link}.txt` (the few hand-run steps are listed in each file's header).

### Configuration (owner-supplied, then corroborated)

- **Owner-supplied evidence:** [`owner-management-api-readback.txt`](owner-management-api-readback.txt). The owner ran the Management API `PATCH …/config/auth` with the no-SMS body and pasted the `GET` readback: `external_phone_enabled: true`, `sms_autoconfirm: true`, `sms_provider: "twilio"`, `sms_test_otp: null`. The owner set **no** provider credentials. This line is the owner's statement, not a harness capture.
- **Harness corroboration:** `H00` (`/auth/v1/settings`): `external.phone=true`, `phone_autoconfirm=true`, `sms_provider="twilio"`, `mailer_autoconfirm=false`; GoTrue **v2.197.0**. `"twilio"` is Supabase's default provider label (it was already shown at step `00` on 2026-10-03, with phone off).
- **No credentials, proven empirically:** every phone `/otp` (H20, H21, H39, H68) returned 500 `unexpected_failure` "Unable to get SMS provider", and the Auth log records each as `error: "missing Twilio account SID"` (H73).
- **Probe unchanged:** `H71` (`observe_probe_grants.sql`): the four story-1.2 probe functions have the same md5 as step `98`, `anon` has no EXECUTE and no `harness` schema usage, RLS is on. (The listing now also shows story 1.3's `rc_*` objects.)
- **Synthetic phones:** NANP fictional range `+1 202 555 0100–0199` (`+12025550101`, `…0102`, `…0103`, `…0199`). These numbers are reserved for fiction and never assigned. The plan's earlier `+26097…` example is a live Zambian mobile range, so it was not used.

### Results (account `…0101` / `…+bicauth-ph1`)

| # | Matrix row / owner-gated item | Steps | Observed on hosted | Verdict |
|---|---|---|---|---|
| P1 | Phone/password signup, confirmations off, no SMS provider | H10, H11, H25 | 200 with a session: JWT `amr=[password]`, `aal1`, `phone_confirmed=true`, one `phone` identity. Probe **allowed**. H25: `confirmation_sent_at` null, no phone one-time tokens. | ✔ **AD-20 holds** |
| P2 | Phone password login; wrong password vs unknown phone | H12–H18 | Login `amr=[password]`, allowed (H15); refresh keeps `password` and stays allowed (H16, H17). Wrong password (H13) and unknown phone `…0199` (H14) both 400 `invalid_credentials`, same message. | ✔ neutral |
| P3 | `/otp` phone for the **existing** user (no SMS, no session) | H20, H39, H68, H73 | 500 "Unable to get SMS provider" each time (before and after the email alias and after the reset). No session or token in the response. Log: "missing Twilio account SID". | ✔ no SMS |
| P4 | Passwordless phone signup attempts | H21, H22, H24, H25 | `/signup` phone without a password: 400 `validation_failed` "Signup requires a valid password" (H22), no user created for `…0103` (H25). `/otp` with `create_user:true` for new phone `…0102`: 500 "Unable to get SMS provider" (H21), **but see finding F1**. Direct `/verify` sms guess on `…0102`: 403 `otp_expired` (H24). | ✔ no SMS / no client session; ⚠ F1 |
| P5 | Direct `/verify` sms guess, existing user | H23 | 403 `otp_expired` | ✔ |
| P6 | Same-account email: `PUT /user {email}` from phone session B, then verify | H30, H32–H35, H70 | 200 with `new_email` pending (H30). The Supabase mail went only to `…+bicauth-ph1` (subject "Confirm your new email address"). Link → 303, fragment `email_change`, a session with `amr=[otp]` for the **same** `sub` (H32), **denied** (H34). Reused link: `otp_expired` (H33). B remains allowed (H35). H70: one user with identities `[email, phone]`, `email_confirmed=true`; `users_with_ph_alias_email = 1` (no second user). | ✔ same account |
| P7 | Unverified email cannot recover | H31 | `/recover` for the still-pending address: 200 `{}`, and no recovery mail arrived in the inbox (only the email-change mail was present). | ✔ |
| P8 | Email/password alias of the phone user | H36–H38 | Login with the verified email and the **same** password: same `sub`, `amr=[password]`, **allowed**. Wrong password: 400 `invalid_credentials`. | ✔ |
| P9 | Password change from session B: probe **and** refresh every other session | H40–H49b | Signup session, A, email-alias session and email-change session: all `session_live=false`, **denied**, `/user` 403, refresh `refresh_token_not_found` (H41a–H44b). B allowed and refreshable (H45a, H45b). Old password refused on phone (H46); new password works on phone and email, both allowed (H47–H49b). | ✔ |
| P10 | Recovery through the email alias; probe and refresh every other session after the reset | H50–H67 | Known and unknown address both 200 `{}` (H50, H51). Link → fragment `recovery`, JWT `amr=[otp]`, **denied** (H52, H54); reused link `otp_expired` (H53). After setting the password from it (H55): B, C and D all `session_live=false`, denied, refresh `refresh_token_not_found` (H57a–H59b). The recovery session stays live and refreshable, still `otp`, still **denied** (H56a–H56c). Pre-reset password refused on phone and email (H60, H61). Fresh phone and email logins allowed (H62–H64b). Logout of the recovery session: 204, then `session_live=false` (H65, H66); the fresh session stays allowed (H67). | ✔ |
| P11 | Observations | H25, H70, H71, H72, H73 | `observe_phone_sms_state.sql` (H25 ran the version before the `users_with_ph_alias_email` field was added; H70 the committed one): 0 phone one-time tokens, 0 phone MFA factors, no `confirmation_sent_at`/`phone_change_sent_at`/`reauthentication_sent_at`. `observe_auth_logs.sql` over 16:55–17:03:30Z (H72): the only SMS-mentioning request lines are the 4 `/otp` 500s. `observe_auth_sms_attempts.sql` (H73): every SMS-channel request ended in status 500 "missing Twilio account SID"; **0 successful SMS sends**. | ✔ |

### Findings for the identity epic (hosted phone track)

- **AD-20 holds on hosted GoTrue v2.197.0.** With the phone provider on, `sms_autoconfirm` on and no SMS credentials, phone+password signup and login work, issue `amr=[password]` sessions, and pass the trusted-session predicate (P1, P2). No SMS can be sent (P3, P4, P11). The only blocker was the configuration surface: the dashboard and the local CLI refuse this setting, while the Management API accepts it. **Production needs the same Management API step** (record it in the environment runbook).
- **F1: `/otp {phone, create_user:true}` creates a confirmed phone user even though the send fails.** H21 returned 500, but H25 shows user `…0102` created with `phone_confirmed=true`, a `phone` identity, and a live session whose AMR is recorded as `password`. No tokens reached the client, so nobody can use that session, and the probe gate is unaffected. But anyone can **pre-register (squat) any phone number** through `/otp` or `/signup`, with no proof of possession. That is inherent to AD-20 with `sms_autoconfirm` (the same is true of `/signup`). The identity epic must therefore treat the Auth phone as an unverified login handle: binding to a member happens only through the staff-approved claim (AD-3), and a squatted number needs a staff recovery path. `/otp` itself cannot be switched off while the phone provider is on; Auth rate limits or CAPTCHA are the levers if abuse appears.
- **Auth audit log labels phone `/otp` as `user_recovery_requested` with channel `sms`** (H73), even though nothing was sent. Monitoring must key on the request status and error, not on the audit action.
- **The email alias is the recovery channel for phone accounts.** Same user id, same password, and recovery through it revokes every other session (P6–P10). An unverified (pending) address does not recover (P7).
- **The phone-track results match the email-track findings above:** gate on `password` in `amr`, keep the live-session check, and sign the recovery session out after reset.

### Hosted legacy lines 5–6 and the row-8 signup-link gap (account `…+bicauth-e2`)

Paced past the default SMTP limit (2 emails per hour, project-wide): the first attempt at 17:03Z was refused 429 `over_email_send_rate_limit` "email rate limit exceeded" (H80); the retry at 18:02Z sent the mail (H81).

| Item | Steps | Observed on hosted | Verdict |
|---|---|---|---|
| Login before confirmation | H82 | 400 `email_not_confirmed` | ✔ |
| Signup confirmation link (replaces legacy 22/23) | H83–H86 | 303, fragment `signup`, JWT `amr=[otp]`, `aal1`; `session_live=true` but **denied**; refresh keeps `otp` and stays denied | ✔ |
| Signup-link session after a password change (row-8 gap) | H87–H91 | Password session A allowed (H88). After `PUT /user {password}` from A (H89), the refreshed signup-link session is `session_live=false`, denied, `/user` 403, refresh `refresh_token_not_found` (H90a, H90b); A stays allowed (H91). | ✔ |
| No SMS activity in the part-D window | H92 | `observe_auth_sms_attempts.sql` over 17:03:30–18:10Z: no SMS-mentioning Auth line | ✔ |

With this, the hosted log no longer depends on legacy lines 5–6, and rows 8 and 11 above are now covered on hosted as well (row 11's C/D refresh: H57b–H59b for the phone account).

### Cleanup (H93, H94)

- **H93 (operator note):** this run's synthetic users only (`…0101`, `…0102`, `…+bicauth-e2`; 3 users) and their 2 `harness.private_probe` rows were deleted through the Supabase MCP. No user was created for `…0103` or `…0199`. The story 1.2 `e1` account and the story 1.3 accounts were left alone.
- **H94 (`observe_phone_sms_state.sql`):** 0 users in the range, 0 users with any phone, 0 alias users, 0 phone one-time tokens, 0 phone MFA factors.
- The harness state directory (live tokens and generated passwords) was removed with `run.mjs cleanup`; the emailed links were held only in scratch files outside the repo and deleted after use.

## Former owner gate (closed 2026-10-06)

The owner applied this with their own personal access token (the token never entered the repo or chat). It is kept as the reproducible production step.

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
- **Check afterwards:** `GET` the same URL (every `sms_*` credential and `sms_test_otp` null or empty), then `/auth/v1/settings` (`external.phone: true`, `phone_autoconfirm: true`), then one phone `/otp` must fail with "Unable to get SMS provider".

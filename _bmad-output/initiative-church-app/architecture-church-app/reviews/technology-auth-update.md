# Supabase no-SMS authentication evidence

Checked 2026-10-03. Research only: no project was provisioned or configured, and no running Auth flow was tested. Official documentation and current upstream Auth source support the proposed contract. Deployed-project API tests remain a launch gate.

## Viable native sequence

1. Enable the Phone provider for phone/password authentication and turn phone confirmation **off**. For the local CLI configuration this is `auth.sms.enable_signup = true`, `auth.sms.enable_confirmations = false`; leave all SMS providers disabled and do not configure an SMS delivery hook or test-OTP map. Hosted settings must be checked in the actual project rather than assuming a local config deploys them.
2. Register using `supabase.auth.signUp(phone: normalizedPhone, password: password)`. The Auth signup request accepts a phone OR email, not both. The phone is an unverified username: the provider may mark it confirmed automatically, but that is not evidence of possession.
3. Sign in using `supabase.auth.signInWithPassword(phone: normalizedPhone, password: password)`.
4. After that phone account exists, optionally add an email with authenticated `updateUser(UserAttributes(email: candidateEmail))` on the **same Auth user ID**. Complete Supabase's email-change confirmation before treating it as a recovery address. Do not run a separate email signup or auto-merge people by matching contact fields. Keep secure email changes enabled for replacement addresses; adding the first address necessarily has no old address to confirm.
5. Recover through `resetPasswordForEmail(previouslyVerifiedEmail, redirectTo: allowlistedRecoveryURL)` and, after the recovery link establishes a recovery session, `updateUser(UserAttributes(password: newPassword))`. Require a fresh password sign-in before app-private access. Use neutral request responses whether or not the email exists; Supabase's reset method already deliberately hides account existence.
6. No verified email means no native email recovery path. Identity-checked staff-assisted recovery needs an application-controlled, expiring, one-use reset process. The trusted server can set the new password using the supported Auth Admin API after approved proof; clients never receive a service credential. Do not write password hashes or auth tables directly. The member chooses the replacement password; staff do not obtain or retain it. One-use grants must be bound to the existing account and recovery revision, consumed atomically, expire, and never become general app sessions. Session revocation and current application holds remain separate from password replacement.

Sources:
- https://supabase.com/docs/guides/auth/passwords#with-phone
- https://supabase.com/docs/guides/local-development/cli/config#auth.sms.enable_confirmations
- https://supabase.com/docs/reference/dart/auth-updateuser
- https://supabase.com/docs/reference/dart/auth-resetpasswordforemail
- https://supabase.com/docs/reference/dart/auth-admin-updateuserbyid
- https://github.com/supabase/auth/blob/ce9a8eee0cc042be8c7a42981a7ddae631e41d91/internal/api/signup.go (one identifier; `Sms.Autoconfirm` skips SMS)
- https://github.com/supabase/auth/blob/ce9a8eee0cc042be8c7a42981a7ddae631e41d91/internal/api/user.go (email update on existing user; normal permanent users verify email changes; phone auto-confirm permits direct phone changes)

## Provider limits that the specification must preserve

**A recovery email is also a native Auth credential.** Supabase supports email/password and email OTP/magic links for an email identity. There is no verified documented setting that labels a linked email “recovery-only” while retaining native recovery. Keep the application's login screen phone-first, but acknowledge that the same confirmed email/password may authenticate the same underlying account through native APIs. All authorization gates apply equally. Do not describe a hidden email login UI as provider-level enforcement. Reject non-password sessions from private app data, as below.

**Turning phone confirmation off does not turn phone OTP off.** Current `/otp` source still processes phone OTP requests and calls SMS sending even with `Sms.Autoconfirm = true`. Keep SMS providers, SMS hooks and test OTP values absent. Native phone endpoints remain addressable while the Phone provider is enabled; the contract must require that they cannot produce a usable private-app session or send SMS, verified by direct `/otp` and `/verify` tests. A known test OTP is a bypass, not an acceptable production no-SMS solution. No phone/SMS MFA should be enabled as a hidden dependency. Do not solve this by turning off the entire Phone provider and thereby breaking phone/password.

**Native account changes bypass the application form.** With phone auto-confirm enabled a signed-in user can directly change their Auth phone number. Server-side matching of current approved account bindings, credential revision/hold state and current Auth credentials must detect unreviewed changes. User metadata, a prior JWT phone claim and UI-only restrictions are insufficient. Phone number changes do not transfer membership or grants, and shared/recycled numbers do not claim an existing member record.

Sources:
- https://supabase.com/docs/guides/auth/auth-email-passwordless
- https://supabase.com/docs/guides/auth/passwords
- https://supabase.com/docs/guides/local-development/cli/config#auth.sms.test_otp
- https://github.com/supabase/auth/blob/ce9a8eee0cc042be8c7a42981a7ddae631e41d91/internal/api/otp.go
- https://github.com/supabase/auth/blob/ce9a8eee0cc042be8c7a42981a7ddae631e41d91/internal/api/user.go

## Password versus recovery sessions: trusted AMR

Supabase-issued, signature-validated JWTs contain `amr` entries with an authentication method and timestamp. Official JWT fields list `password`, `otp`, `recovery`, `magiclink`, `email_change`, `email/signup`, `anonymous` and other methods. The MFA guide explicitly says `password` is **any password-based sign-in**, and demonstrates enforcing authentication recency via AMR in RLS. The JWT-fields table's shorthand “Email/password” should not be read as excluding phone/password: the same password grant path handles both identifiers.

**Do not blacklist only `recovery`.** The inspected current Auth source shows implicit GET and POST `/verify` routes issue an `OTP` authentication method even when verifying a recovery token. PKCE stores the specific flow authentication method and can expose `recovery`. Therefore, allow private human-user operations only for a trusted **password-authenticated current session** with the current live account/member binding, approval, hold, credential-revision, scope and session checks. Missing AMR or a session established solely by OTP, recovery, signup, magic link or email change must deny private app records even when `role = authenticated`. Never accept AMR supplied via user metadata or decode an unverified token as proof.

Password update itself does not upgrade the recovery session to a password sign-in. Keep that session restricted; complete reset, revoke superseded sessions and require a fresh password authentication before private app access. Signed AMR establishes authentication method, not current permission or automatic recovery approval. Holds, changed credentials and compromised-account restrictions still apply to new password sessions. A live `session_id` check against `auth.sessions`, performed through the protected server authorization layer, prevents a revoked session's still-unexpired JWT from retaining private access. The application must also reject sessions older than its current credential/recovery revision when required; do not rely solely on client logout.

The narrow reset interface must be able to complete password replacement without granting church/private records to the recovery session. Direct `/verify`, refresh, Data API, Storage, Realtime and privileged command paths must be tested, not only the rendered reset screen.

### Password-change session revocation: verified source behavior

At the inspected upstream commit, native authenticated `updateUser(password)` calls `User.UpdatePassword(tx, currentSessionID)`. That method clears outstanding one-time tokens and calls `LogoutAllExceptMe`, preserving the current session while deleting all other sessions. The Auth Admin password update calls `UpdatePassword(tx, nil)`, which calls `Logout` for all sessions. Both logout implementations delete the corresponding `auth.sessions` rows. This covers direct native `/user` password changes as well as the app UI, but is source evidence, not a guarantee of the managed project's deployed build: verify it against the foundation project's API.

The current password-change/recovery session can remain alive. Thus the trusted password-AMR gate remains essential for recovery sessions, and native revocation alone does not impose fresh sign-in on a surviving already-password-authenticated session. If the application requires that stronger rule, enforce a trusted credential/recovery epoch or explicit revocation with a tested server change-detection mechanism. Bind the invariant and foundation verification; do not invent an unverified hook or mirror password hashes into application tables. Supabase Auth remains the sole password store. Already-issued JWTs of deleted sessions remain usable until expiry unless the application checks live `session_id` existence.

The password-security guide also distinguishes current-password checks from email/phone nonce reauthentication. Do not blindly add the nonce `reauthenticate()` flow for a no-email/no-SMS account: it can introduce a messaging dependency. Use a verified current-password change path and the separate approved recovery path, and test the actual deployed settings.

Sources:
- https://supabase.com/docs/guides/auth/jwt-fields#authentication-methods-amrmethod
- https://supabase.com/docs/guides/auth/auth-mfa#frequently-asked-questions
- https://supabase.com/docs/guides/auth/sessions
- https://github.com/supabase/auth/blob/ce9a8eee0cc042be8c7a42981a7ddae631e41d91/internal/api/token.go (`PasswordGrant` for the password endpoint)
- https://github.com/supabase/auth/blob/ce9a8eee0cc042be8c7a42981a7ddae631e41d91/internal/api/verify.go (implicit verification issues `OTP`)
- https://github.com/supabase/auth/blob/ce9a8eee0cc042be8c7a42981a7ddae631e41d91/internal/models/sessions.go (AMR belongs to the session, methods ordered by timestamp)
- https://github.com/supabase/auth/blob/ce9a8eee0cc042be8c7a42981a7ddae631e41d91/internal/models/user.go (`UpdatePassword` revocation branches)
- https://github.com/supabase/auth/blob/ce9a8eee0cc042be8c7a42981a7ddae631e41d91/internal/models/sessions.go (`Logout`/`LogoutAllExceptMe` delete session rows)
- https://github.com/supabase/auth/blob/ce9a8eee0cc042be8c7a42981a7ddae631e41d91/internal/api/admin.go (admin password changes revoke all)
- https://supabase.com/docs/guides/auth/password-security

## Email delivery and changelog check

Optional email recovery still requires operational email delivery. Official SMTP documentation says the default Supabase sender is for nonproduction testing, only delivers to organization team addresses, is currently limited to two messages per hour, and has no delivery SLA. Configure production SMTP, sender identity, rate limits and allowlisted mobile/web recovery redirects before enabling email recovery for members. Provider selection/budget/owner remains an operational decision; it must not revive the removed SMS launch gate.

Fetched and scanned https://supabase.com/changelog.md. The directly relevant breaking notice is the 2026-06-03 restriction on email template customization for new Free projects using default SMTP; custom SMTP removes that restriction. The 2026-06-18 self-hosted `API_EXTERNAL_URL` change is not a managed Supabase phone/password incompatibility. No applicable changelog entry removes native phone/password or requires SMS with phone confirmation disabled.

Sources:
- https://supabase.com/docs/guides/auth/auth-smtp
- https://supabase.com/changelog/46599-changes-to-email-template-customisation-on-free-tier
- https://supabase.com/docs/guides/auth/redirect-urls

## Required implementation acceptance checks

- Phone/password registration and login work with no SMS provider, hook or test-OTP map; normalizing equivalent phone formats cannot create duplicate usernames.
- Signup without email works; optional email verifies on the same Auth UUID; a pending/failed/reused email confirmation never becomes recovery authority.
- Phone/password authentication and native confirmed-email/password alias obey the same current member binding and permissions.
- Direct phone OTP/verify and email OTP/magic-link/recovery sessions cannot read private app data, including through Storage/Realtime/commands; missing AMR fails closed. No SMS is sent.
- Recovery request responses are neutral; redirects are allowlisted; expired/replayed links and one-use staff reset grants fail; no-email users receive the assisted route without exposing member existence.
- Successful password reset still requires fresh password sign-in; old sessions, holds and credential-change mismatches remain denied until their respective checks are satisfied.
- Direct Auth phone/email/password changes cannot relink members, clear holds or inherit grants; staff-assisted recovery is audited without storing passwords or reset secrets.

These are design-level acceptance obligations, not claims that a deployed Supabase project has already passed them.

# Identity epic — owner's consolidated staging test (collected while building 2.6–2.13)

Run once, after 2.13, on staging (`tmurpotfluignacfueki`) with the staging APK and staff web.

## Owner settings to apply first

1. **Redirect allowlist (2.7).** In the Supabase Management API, first `GET https://api.supabase.com/v1/projects/tmurpotfluignacfueki/config/auth` and note `uri_allow_list`, then
   `PATCH https://api.supabase.com/v1/projects/tmurpotfluignacfueki/config/auth` with
   `{"uri_allow_list":"<existing>,zm.bickafue.mobile://callback/auth/recovery,zm.bickafue.mobile://callback/auth/email-confirmed"}`.

2. **Paste in the staging SQL Editor (2.8).** Open `supabase/migrations/20261007160100_credential_review_auth_rows.sql` on branch `ccr-93e730dd-89lbvg` on GitHub, click **Raw**, copy everything, paste it in a new query in the staging SQL Editor and run it. (It revokes sessions and removes extra sign-in factors for one account at a time; the connector cannot apply statements that delete rows.)

## Scenarios

- **2.6 Cells:** as Admin on staff web, make a synthetic member leader of SYNTHETIC Market Cell; as that leader confirm the waiting join request; request a change to another cell on mobile and confirm it as that cell's leader; check My cell on mobile.
- **2.7 Email recovery:** add a recovery email `israelmuyoba+<tag>@gmail.com` on mobile, confirm it from the email, approve it as Admin, then use Forgot password from mobile and web and set a new password; sign in fresh. Also: withdraw a pending email; Admin rejects one; an unapproved address's reset link is refused (canary). The built-in sender allows about 2 emails per hour — spread these out.

- **2.8 Credential changes and holds:** on mobile, request a new phone username in the fictional range (+1 202 555 01xx); approve it as Admin on staff web and sign in with the new number. As Admin, place a hold on a synthetic member: their app shows only the generic "Access review required" screen; release it (another Admin is needed, so use the Admin account on the other member). Place a lost-device hold: every session ends; it can be released only after the member resets the password from the recovery email.
- **Refusal messages (contract fix):** refusals such as "last Admin" or "password reset needed first" show their own message, not "unknown outcome".

## Decisions for the owner at 2.14

- GoTrue `/recover` can reveal whether an email is registered through its rate-limit and timing replies (platform behaviour; the app itself stays neutral). Decide with the production email sender/SMTP settings.

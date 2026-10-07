# Owner rehearsal on staging (story 2.12, hitl)

**Who:** Israel, as the restricted operator. Until entry 14 names them, Israel also stands in for both named recovery owners.

**Where:** staging `tmurpotfluignacfueki`, the staging APK and staff web.

**Records:** SYNTHETIC only. Names start with `SYNTHETIC `. Numbers are `+1 202 555 0170` to `0179` only. For RB3, use an `israelmuyoba+rb<tag>@gmail.com` inbox. Never use a real person, number or address.

Follow each runbook in `docs/runbooks/identity-support.md` as written. Write nothing down except the case note RB8 asks for.

## Before you start

- [ ] The parent session has applied `20261007190000_identity_admin_fallback.sql` to staging.
- [ ] The consolidated-test settings 1-4 are done (`../owner-consolidated-test.md`).
- [ ] Two synthetic Admins exist: A (`+1 202 555 0170`) and B (`+1 202 555 0171`), each signed in once with their own password. If not, do RB1 first: the operator seeds A, bootstraps A, then A grants B Admin in **Roles & access**.

## Checklist

1. [ ] **RB2.**
   - `0172` creates an account on mobile and applies. A approves it after an identity check, and `0172` signs in again.
   - A adds a member record with no login for `SYNTHETIC RB Accountless`.
   - `0173` registers first as a "squatter"; A reclaims `0173`.
   - The accountless person signs up with `0173` and applies; A links them to the existing record.
2. [ ] **RB3.** `0174` adds a recovery email and opens the confirmation from the inbox. B approves it. `0174` uses **Forgot password?** and sets a new password from the email, with no staff involved.
3. [ ] **RB5 + RB4.**
   - A places a `lost_device` hold on `0175`; the phone is signed out.
   - B tries to release it: refused, "password reset needed first".
   - `0175` uses **I need help accessing my account** and reads the code to A. A opens a case and issues the grant. `0175` sets a password on the phone.
   - B releases the hold, and `0175` signs in.
4. [ ] **RB5 dispute.** A places `ownership_dispute` on `0176`; the app shows only **Access review required**. B releases it after an identity check.
5. [ ] **RB6.** A deactivates `0177` (**Membership status**); the app shows **Church membership not active**. B restores it; `0177` signs in fresh, with no roles.
6. [ ] **RB7.** `0178` deletes their own account on mobile. Run the deletion worker once (consolidated test, 2.11 command). **Member deletions** shows it completed, and `0178` cannot sign in.
7. [ ] **RB8, last-Admin fallback.**
   1. A removes B's Admin role, then signs out everywhere. Pretend A forgot the password.
   2. Operator: `select app.identity_usable_admin_count();` returns `1`. `select app.identity_bootstrap_admin('<member id of 0172>', 'israel');` is refused.
   3. Case note with a case reference such as `RB8-2026-10-xx-01`: date, RB8, `0172`'s member id, `admins_unreachable`, `in_person`, both owners, operator. Pick a short identifier for the second (stand-in) owner, for example `owner-two`; it must not be `israel`.
   4. Before the command, run this in the SQL editor and keep the result on screen. It shows a fingerprint, not the password:

      ```sql
      select md5(encrypted_password), updated_at, last_sign_in_at,
             (select count(*) from auth.sessions s where s.user_id = u.id) as sessions,
             (select count(*) from auth.refresh_tokens r where r.user_id = u.id::text) as refresh_tokens
        from auth.users u where phone = '12025550172';
      ```

   5. Operator: `select app.identity_admin_fallback_grant('<member id of 0172>', 'in_person', 'admins_unreachable', 'owner-two', '<case reference>', 'israel');`. It returns ids and codes only. Try it once with `'israel'` as the confirming owner first: it must be refused.
   6. Run the same query again. Every column must be unchanged.
   7. `0172` already has Admin on their next call; if they are not signed in, they sign in on staff web with **their own** password. **Roles & access** shows them with the label **Admin by operator fallback**.
   8. `0172` helps A back with RB4 (A's phone shows the code; A chooses the new password on the phone). A signs in and is Admin again.
8. [ ] **Admin only.** Signed in on staff web as an Admin-only account (B before step 7, or `0172` after it), the menu shows no care, finance, prayer or cell-private destination. Ask the assistant to run the server check against staging and confirm `403 not_granted` for that account. It is the `fixture_scoped_read` and `cells_private_fixture_read` check from `tools/identity-e2e/runbooks.mjs` R02/R62.

## Confirm (verify bullet)

- [ ] No step showed a password, a grant secret, a reset or confirmation link, or a request code to anyone but its holder. Staff screens and operator outputs held none of them.
- [ ] Admin-only support reached no care or finance fixture (item 8).
- [ ] The fallback restored Admin access with no credential shortcut (item 7: Auth columns unchanged, own-password sign-in, A back through RB4).

## Clean up

Only through the product, never with SQL:

- For each synthetic member you want gone, use RB7. The member deletes their own account on mobile (**Account, Delete my account**), or an Admin uses **Member deletions** on staff web for one who cannot (after another Admin's login hold or deactivation).
- Then run the deletion worker once (consolidated test, 2.11 command). **Member deletions** shows each one completed, and those numbers can register again.
- Keep at least one synthetic Admin: the last usable Admin cannot be deleted.
- Anything you do not delete this way may simply stay on staging. Staging records are synthetic, and leftovers are harmless.

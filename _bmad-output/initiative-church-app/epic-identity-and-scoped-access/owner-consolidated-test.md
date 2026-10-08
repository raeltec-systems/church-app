# Identity epic — owner's consolidated staging test (stories 2.1–2.14)

One session on staging (`tmurpotfluignacfueki`) with the 2.14 builds. Synthetic data only. Do the parts
in order; tell the assistant which boxes passed and anything that looked wrong.

| Part | What | Time | Numbers |
|---|---|---|---|
| 0 | One setting | 2 min | — |
| 1 | Demonstration: mobile + staff web, no email (2.2–2.11, 2.14) | ~45 min | +1 202 555 0151/0152 (your Admins), 0172–0174 |
| 2 | Email recovery and the lost-device hold (2.7, 2.8) | ~30 min, spread out | 0175 |
| 3 | Run the deletion worker once (2.11) | 5 min | — |
| 4 | Support runbook rehearsal as restricted operator (2.12) | ~60 min | +44 7700 900 800–809 |

## Part 0 — setting to apply first

1. **Redirect allowlist (2.7).** Supabase dashboard → staging project → **Authentication → URL Configuration → Redirect URLs** → **Add URL**, add both:
   `zm.bickafue.mobile://callback/auth/recovery` and `zm.bickafue.mobile://callback/auth/email-confirmed`. Keep the existing entries.

Already done (2026-10-07): the 2.8 and 2.11 SQL pastes (verified identical to local) and the deletion-worker credential (expires 2026-11-06).

## Part 1 — demonstration

Follow `evidence-2.14/owner-demonstration.md` (A registration and review, B roles and cells, C credential change / holds / deactivate-restore, D staff-assisted recovery, E deletion, F what you must never see). Before you start, tell the assistant to give Admin to your demo accounts +1 202 555 0151 and 0152 (or create two new ones as that file says).

Also check: refusals such as "last Admin" or "password reset needed first" show their own message, not "unknown outcome".

## Part 2 — email recovery and the lost-device hold (built-in sender: about 2 emails per hour)

- [ ] Mobile, a new member `+1 202 555 0175` (apply; the assistant or your Admin approves): **Sign-in details → recovery email** `israelmuyoba+<tag>@gmail.com`, confirm it from the email, approve it as Admin on staff web.
- [ ] **Forgot password?** on mobile, then on staff web, and set a new password from the email; sign in fresh.
- [ ] Withdraw a pending email; Admin rejects another; an unapproved address's reset link is refused.
- [ ] Lost-device hold: Admin places `lost_device` on 0175; every session ends; the other Admin cannot release it until 0175 resets the password from the recovery email; then it can be released.

## Part 3 — deletion worker

In your local clone (where you minted the credential):

```
SUPABASE_URL=https://tmurpotfluignacfueki.supabase.co SUPABASE_PUBLISHABLE_KEY=sb_publishable_B7rxJq4-D4PBNohOgz3qmg_SfbQWRSY IDENTITY_DELETION_CREDENTIAL_FILE=.ops-state/identity-deletion/staging.credential node tools/identity-deletion/worker.mjs run
```

- [ ] Staff web **Member deletions** shows the Part 1 deletions completed; those members cannot sign in, and their numbers can register again.

## Part 4 — support runbook rehearsal

Follow `evidence-2.12/owner-rehearsal.md` with `docs/runbooks/identity-support.md`, numbers +44 7700 900 800–809 only (moved from 0170–0179 so they do not clash with Part 1). It covers applications and linking, email and assisted recovery, holds and disputes, deactivation, deletion and the last-Admin fallback (second owner and case reference required). For its item 8, ask the assistant to run the Admin-only server check.

## Reminders

- Rotate the staging deletion-worker credential before 2026-11-06 (`OPS_STATE_DIR=.ops-state/identity-deletion node tools/ops/system-credential.mjs mint --env staging --force`, send the new fingerprint).
- Rotate the staging assisted-recovery credential before 2026-11-06 (mint with `--force`, send the new fingerprint, update the Edge Function secret).

## Production: your decisions and steps (story 2.14 stays open until these)

Exact ordered steps: `docs/runbooks/production-promotion-identity.md` (gates G1–G11; every gate stays closed unless you approve it).

- Create the production Supabase project and the GitHub `production` environment (platform runbook steps A and C).
- Email sender: set up SMTP (Resend, decided 2026-10-07); the send-email hook is still to be built before production.
- First real Admin: production has no path yet to link the first real Admin (applications need an Admin; synthetic seeding refuses production). Choose one of the procedures in the promotion runbook; it needs to be built and reviewed.
- Per gate, approve or leave closed: dormancy, password policy, live personal data (and with it public sign-up, G11), deletion retention, system access.
- GoTrue `/recover` can reveal whether an email is registered through its rate-limit and timing replies (platform behaviour; the app stays neutral). Decide with the SMTP settings.

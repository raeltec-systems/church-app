# Runbook: identity live access (story 2.1)

Architecture: AD-3, AD-4, AD-13, AD-20. Migration: `supabase/migrations/20261006215842_identity_live_access.sql`.
Evidence: `_bmad-output/initiative-church-app/epic-identity-and-scoped-access/evidence-2.1/`.

## What exists

- **Identity records** (non-exposed `app` schema, RLS on, no client privileges):
  - `identity_members`: the stable person (`member_id`), membership state, `is_synthetic`.
  - `identity_account_links`: member to Auth account, with the approved credential binding (E.164 phone username, optional recovery email, `binding_revision`). There is at most one live link per member, per account and per phone.
  - `identity_binding_history`: every approved binding revision.
  - `identity_holds`: an open hold denies every session.
  - `identity_settings`: versioned Q1 settings. Only `dormancy_days` exists so far.
- **The one predicate**, `app.identity_access_evaluate()`. It returns `granted` only when all of these hold:
  1. The signed JWT `amr` contains `password`, and there is a live `auth.sessions` row for its `session_id` and subject, with `not_after` not passed.
  2. The Auth user is neither deleted nor banned.
  3. The account has a live link to an `approved` member.
  4. The link is `active`.
  5. The current `auth.users` phone and email equal the approved binding.
  6. The member has no open hold.
  7. The last member activity is inside the effective dormancy setting. This is checked **before** any refresh.
  8. The release gate allows it (see below).

  Otherwise it returns `unauthenticated`, `untrusted_session`, `not_linked`, `review_required` or `unavailable`.

  Story 1.2 finding F1 (phone `/otp` can leave a `password`-AMR session for any number) is why AMR alone never grants access.
- **Helpers for later owners**:
  - `app.identity_current_member_id()` is meant for RLS policies.
  - `app.identity_require_access()` raises the HTTP-mapped denial.
  - `app.identity_record_activity(link_id)` records activity. Call it only after access was granted.

  Grants and scopes extend the predicate in entry 3.
- **The tracer read**: `POST /rest/v1/rpc/identity_my_member_summary` with `Content-Profile: api`.
  - Success returns 200 with `{member_id, display_name, membership_state, phone_username, has_recovery_email, is_synthetic}`, and records activity.
  - A denial returns 401 or 403 with `message` set to `unauthenticated`, `forbidden` or `unavailable` and `details` set to the caller's own reason.
  - Signed-out callers have no EXECUTE.

## Release gate and settings

- Private member data is served when `app.policy_is_open('private_access')`.
- Exception: a `SYNTHETIC` member (`is_synthetic`) in a database marked `local` or `staging` that is not a held restore. This lets staging demonstrate the tracer while `verify-hosted.sql` keeps the gate itself closed.
- `dormancy_days` has a labelled fixture: `TEST FIXTURE - proposed 90-day dormancy, not church policy`. It is honoured only in `local` and `staging`.
- Production has no approved row, so access there is `unavailable` until the owner approves the Q1 values (entry 14). An approved row is a new `version` with `source = 'approved'`.

## Sign-in on the clients (no SMS)

- Both apps have an **Account** destination (`/account`), plus `/sign-in` and `/create-account`, from `packages/client_core`.
- The phone username is any country code, normalized to E.164 by `normalizePhoneUsername`. +260 is only the picker's initial value.
- The clients use native `signUp(phone, password)` and `signInWithPassword(phone, password)` only. They have no OTP, code entry or resend.
- Errors are generic.
- Story 2.2: only the Auth session persists (mobile: Keystore/Keychain via `flutter_secure_storage`, "after first unlock, this device only"; staff web: the tab's `sessionStorage`, so a reload keeps it and closing the tab ends it). Protected member data stays in memory. See [Session trust (story 2.2)](#session-trust-story-22).
- Sign-out (local scope) ends this device's session and clears protected state.

## Local runs

- Run the pgTAP tests with `npm run db:test`. Run the HTTP checks with `npm run db:smoke`, which includes `supabase/tests/identity_api_smoke.sh`. Both work with the CLI's default config: phone is off, so the smoke signs in through the verified-email alias of a phone account.
- Phone sign-in end to end:
  1. `node tools/auth-harness/local-phone-auth.mjs on`. This is **local only**. It recreates the CLI auth container with `GOTRUE_EXTERNAL_PHONE_ENABLED=true` and `GOTRUE_SMS_AUTOCONFIRM=true`, and refuses if any SMS provider, credential, hook, test OTP or phone MFA is present.
  2. `node tools/identity-e2e/run.mjs [--evidence file.jsonl]`.
  3. `node tools/auth-harness/local-phone-auth.mjs off`. This restores the exact values the CLI had for both keys, which `on` recorded in a container label. `supabase stop && supabase start` also restores the CLI's config.
- To exercise the real client adapters, run `packages/client_core/tool/live_identity_check.dart`. See its header.

## Seeding a synthetic approved member (restricted operator only)

There is no Admin linking UI yet (entry 5). For tracer runs in `local` or `staging` only, use:

```sql
select app.identity_seed_synthetic_link(
  (select id from auth.users where phone = '12025550150'),  -- Auth stores digits without '+'
  'SYNTHETIC Staging Member', 'israel');
```

The function refuses in these cases:

- the database is not marked `local` or `staging`;
- the name does not start with `SYNTHETIC `;
- the phone is outside the reserved fictional ranges (`+1 202 555 0100–0199`, `+44 7700 900000–900999`);
- the email is not synthetic.

It binds the account's **current** Auth phone and email.

## Owner steps for the hosted staging demonstration

The staging project is `bic-kafue-platform-test`, ref `tmurpotfluignacfueki`.

1. **Apply the pending migrations in version order.** Staging ends at `20261003155428`, so apply `20261006215306_recovery_journal (+ 20261006215400_recovery_journal_hold)` (pending since story 1.10) first, then `20261006215842_identity_live_access`.
   - Use either the `promote` workflow, or the Supabase connector's `apply_migration` with the exact file contents and names.
   - Then run `tools/ci/verify-hosted.sql` with `expected_env=staging`.
2. **Enable phone sign-in without SMS.** Use the same Management API call already used on `bic-kafue-auth-test` (the dashboard refuses it). Use your own personal access token, and never paste it into the repo or the chat:

   ```http
   PATCH https://api.supabase.com/v1/projects/tmurpotfluignacfueki/config/auth
   Authorization: Bearer <owner personal access token>
   Content-Type: application/json

   {"external_phone_enabled": true, "sms_autoconfirm": true, "hook_send_sms_enabled": false,
    "mfa_phone_enroll_enabled": false, "mfa_phone_verify_enabled": false}
   ```

   - The body sets no `sms_provider`, no SMS credential fields and no `sms_test_otp`.
   - Check with `GET` on the same URL, then `GET https://tmurpotfluignacfueki.supabase.co/auth/v1/settings`. Expect `external.phone: true` and `phone_autoconfirm: true`.
3. **Build the clients against staging.** Pass `--dart-define=SUPABASE_URL=https://tmurpotfluignacfueki.supabase.co --dart-define=SUPABASE_PUBLISHABLE_KEY=<staging sb_publishable_…>`:
   - for a native target: `flutter run` / `flutter build apk` in `apps/mobile`;
   - for staff web: `flutter build web` in `apps/staff`.
4. **Demonstrate the flows.**
   1. On mobile: **Account**, then **Create account** with `+1 202 555 0150` and a password you choose. The screen shows **No member access yet**.
   2. Seed the link as above (SQL editor or connector).
   3. On mobile: **Check again** shows the summary.
   4. On staff web: **My account**, then **Sign in** with the same number and password. It shows the same summary with no re-approval.
   5. Unlinked account: create `+1 202 555 0151`. It shows **No member access yet**.
   6. Signed out: **Sign out**. The screen returns to the sign-in prompt and the summary is gone.
   7. Direct table query: `GET /rest/v1/identity_members` with `Accept-Profile: app` returns 406, and with `Accept-Profile: api` returns 404.
   8. No SMS: `POST /auth/v1/otp {"phone":"+12025550152"}` returns 500 "Unable to get SMS provider", and no message is sent.
      - This probe is the F1 path. Besides the 500, it **creates a phone-confirmed Auth user for `+1 202 555 0152`**, and that user can end up with a live session whose AMR is `password`. It has no member link, so step 4.6's denial still applies. You must delete it in step 5.
5. **Clean up.** Delete the synthetic links and members, then the Auth users for `+1 202 555 0150–0152`. Include `0152`, the user the `/otp` probe created; deleting an Auth user also ends its sessions. Use the same statements as `tools/identity-e2e/run.mjs` `cleanup`, then check that `select count(*) from auth.users where phone in ('12025550150','12025550151','12025550152')` returns 0.

## Session trust (story 2.2)

Migration: `supabase/migrations/20261006220500_identity_session_trust.sql`. Evidence: `_bmad-output/initiative-church-app/epic-identity-and-scoped-access/evidence-2.2/`. Not applied to hosted: it is the owner's promotion step, after `20261006215842_identity_live_access`.

### What changed in the predicate

`app.identity_access_evaluate()` keeps its signature. In addition to the 2.1 checks it now requires:

- `password` in the **server's** session AMR record (`auth.mfa_amr_claims`) as well as in the signed JWT `amr`. Magic-link, email-OTP, signup-link and recovery sessions carry `otp` and stay denied, also after refresh.
- a non-anonymous Auth user;
- an approved recovery email only while Auth holds it **confirmed**;
- no pending **binding review** (`binding_review_required`);
- a session created more than **5 s** (`app.identity_epoch_margin()`) after the link's **trust epoch** (`sessions_valid_after`); otherwise `untrusted_session` (sign in again).

Order: session/JWT, link and member, link state, binding, holds, trust epoch, dormancy (on the stored activity, before any refresh), release gate. Denials never write activity.

### Trusted detection of direct Auth changes (the 1.3 mechanism, owned by Identity)

Triggers run inside GoTrue's own transaction and act only on accounts with a live link (unlinked accounts are ignored):

| Auth change | Effect on the link |
|---|---|
| phone, email, soft delete, hard delete (`auth.users`); identity added, removed or re-pointed to another user/provider id (`auth.identities`); MFA factor added, changed or removed (`auth.mfa_factors`; no-op updates ignored) | `binding_review_required` set (whatever the link state; survives reverts, suspension and unsuspension), an `active` link → `review_required`, generation +1, trust epoch moved |
| password (native `PUT /user`, recovery, Auth Admin), ban or unban | generation +1, trust epoch moved (every earlier session must sign in again, including the one that changed the password) |
| hold placed (`identity_holds` insert); any `link_state` change, including re-approval | trust epoch moved, event recorded |
| a new link for an account or member that had one (relink after `ended`) | starts with a trust epoch and the next generation; a first link has none |

`app.identity_credential_events` records each change by **kind only** (no phone, email or secret values). If a trigger fails, GoTrue's write fails too (fail closed).

Re-approving a link after review (entries 5/8) records a new `binding_revision` (which alone clears `binding_review_required`) and sets `link_state = 'active'`; that moves the epoch again, so only sessions created after the approval pass. Until those workflows exist, a restricted operator does it in SQL for synthetic accounts only.

Known limits:

- GoTrue's lock order around the triggers is not under our control (1.3 limit F).
- The epoch (database clock, stamped inside the changing transaction) is compared with GoTrue's session `created_at` plus a 5 s margin. A GoTrue clock **ahead** of the database by more than the margin, or a session created while the changing transaction is held open longer than the margin, can still be admitted (fail open); keep Auth and database clocks synchronised. A GoTrue clock behind only delays a fresh sign-in (fail closed).

### Clients

- Only the Auth session persists (see "Sign-in on the clients"). Reopening the app restores it and the SDK refreshes it; the server re-checks it on every read.
- When the predicate answers `untrusted_session` (signed out or revoked elsewhere, a credential change, a hold, a pre-approval session), the client ends the session on the device, removes the stored session, clears protected state and shows **Please sign in again**. `review_required`, `not_linked` and `unavailable` keep the session and withhold only the data. A JWT that PostgREST itself rejects (`PGRST301`/`PGRST303`, expired or invalid) is refreshed once and retried; it never ends the session by itself.
- Returning to the foreground asks the server again before the summary is relied on.
- Staff web also keeps the SDK's PKCE code-verifier store (browser `localStorage`, from supabase_flutter); no sign-in flow here uses it and it never holds tokens or member data.

### Local runs

- `npm run db:test` includes `supabase/tests/identity_session_trust_test.sql`; `npm run db:smoke` adds refresh, magic-link and recovery sessions and a direct email change through the real API (CLI default config).
- With `node tools/auth-harness/local-phone-auth.mjs on`: `node tools/identity-e2e/run.mjs` (steps `E30`–`E45`), then `FLUTTER_ROOT=<flutter sdk> bash tools/identity-e2e/live-adapter-check.sh` for the real client adapters (refresh, reopen from the stored session, revocation from another device, sign-out). Then `node tools/auth-harness/local-phone-auth.mjs off`.
- Cleanup of synthetic accounts must delete `app.identity_credential_events` rows before their links (foreign key); the E2E and smoke scripts do.

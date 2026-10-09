# Evidence 2.2: live session trust across alternate Auth routes

Everything here is **LOCAL** (Supabase CLI 2.119.0, GoTrue v2.197.0, Postgres 17), synthetic data only, observed on 2026-10-06 after merging the integration branch (migrations `…215306`, `…215400`, `…215842`, then this story's `20261006223524_identity_session_trust`). Nothing was applied to a hosted project, and no hosted Auth check was needed: every route was driven through native GoTrue endpoints locally.

- **Phone numbers:** reserved fictional ranges only (`+1 202 555 0100–0199`, `+44 7700 900000–900999`). **Emails:** `@example.test` only.
- **SMS:** none configured at any point; the local phone switch (`tools/auth-harness/local-phone-auth.mjs`) was turned `off` after the runs.
- **Email:** none sent. Magic-link, email-OTP and recovery tokens came from Auth Admin `generate_link` and were redeemed at the native `/auth/v1/verify` endpoint.

## Files

| File | What it shows |
|---|---|
| [`local-pgtap.txt`](local-pgtap.txt) | After the review fixes: `identity_session_trust_test.sql` (83) and the adjusted `identity_live_access_test.sql` (74), from a fresh `db reset`. Before them the whole suite ran 488/488. |
| [`local-api-smoke.txt`](local-api-smoke.txt) | `identity_api_smoke.sh` with the CLI's default config (phone off, as CI): adds refresh, magic-link and recovery sessions, and a direct Auth email change. |
| [`local-e2e-log.jsonl`](local-e2e-log.jsonl) | `tools/identity-e2e/run.mjs` with the local phone switch on: 30 checks pass (2.1's `E10`–`E23` plus `E30`–`E45`). Every denial route (`E35`, `E36`, `E38`–`E40`, `E42`, `E43`, `E44`) asserts unchanged activity; fresh sign-ins after an epoch wait out the 5 s margin. Status codes, reasons, AMR names and change kinds only. |
| [`local-client-adapter-check.txt`](local-client-adapter-check.txt) | The real Dart adapters both apps use: refresh, reopen from the stored session, revocation from another device, sign-out. |

## Results against the plan's I/O matrix

| Matrix row | Evidence | Observed |
|---|---|---|
| Refresh / reopen | E2E `E30`, `E44` (refresh succeeds); smoke "a refreshed password session keeps access"; adapter `S2`, `S3`; Flutter `session_trust_test` (restored session, same-account refresh keeps state), both app shells | Refreshed JWT keeps `amr=[password]` and is granted. A new client restoring the persisted session JSON reads with no sign-in call. |
| OTP / magic link / recovery | E2E `E32`, `E33` (also after refresh), `E34`; smoke; pgTAP "JWT says password but the server recorded otp", "otp session", "no server AMR record" | All `amr=[otp]`, 401 `untrusted_session`. `E35`: no activity written. |
| Recovery then new password | E2E `E36`, `E45`; pgTAP "password change" rows | Password set (200); the recovery session stays denied; the pre-reset password session is denied; the old password fails; a fresh sign-in is granted; the link stays `active` with `auth_users:password` recorded. |
| Email/password alias | E2E `E37`; pgTAP alias rows | Same `sub`, `amr=[password]`, same `member_id`, granted. An approved email that Auth holds unconfirmed → `review_required`. |
| Direct Auth phone/email change | E2E `E38`–`E41`; smoke; pgTAP phone/email/identity/MFA/delete rows | Stale token → 403 `review_required`; changing the phone back and a fresh sign-in are still in review. After simulated re-approval, both the pre-change token and a session opened **during** review are `untrusted_session`; a fresh sign-in is granted. Events: `auth_users:phone, auth_users:phone, auth_identities:identity_added, auth_users:email`. |
| Revoked / signed out | E2E `E22`, `E42` (global sign-out), `E43` (ban/unban); adapter `S4`–`S6`; Flutter tests (untrusted answer ends the session on both app shells) | 401 `untrusted_session`; revoked refresh fails; unbanning does not revive the old session. The client ends its local session, removes the stored session and clears protected state. |
| Dormant fixture | E2E `E44`; pgTAP dormancy rows | `TEST FIXTURE - proposed 90-day dormancy, not church policy`; activity set 91 days back; sign-in and refresh succeed at Auth, the read is 403 `review_required`, activity unchanged. |
| Hold placed then released | pgTAP hold rows | Denied while open; after release, pre-hold sessions stay `untrusted_session`; a fresh sign-in is granted. |

## Review fixes (second pass)

- **Durable binding review.** `binding_review_required` is set by every detected binding change whatever the link state, survives value reverts, suspension and unsuspension, and is cleared only by a re-approval that records a new `binding_revision` (pgTAP: suspend → change → revert → unsuspend → fresh sign-in → `review_required`; a direct reset of the flag is refused).
- **Relink after `ended`.** A new link for an account or member that had one starts with a trust epoch at its creation and the next credential generation; sessions from the old link or from while unlinked are refused (pgTAP). A first link for a fresh signup has none.
- **Epoch margin.** A session must be created more than 5 s (`app.identity_epoch_margin()`) after the epoch. Known limits: a GoTrue clock ahead of the database by more than the margin, and a session created while the changing transaction is held open longer than the margin, can still be admitted (fail open); a GoTrue clock behind only delays a fresh sign-in.
- **Change guards and moves.** A no-op `auth.mfa_factors` update records nothing; an `auth.identities` row re-pointed to another user or provider id is recorded for both accounts (pgTAP).
- **Link-state events.** Review, suspension, end, re-approval and relink each write an `identity_account_links` event (pgTAP; visible in `E41` and the smoke).
- **PostgREST JWT rejections** (`PGRST301`/`PGRST303`) are no longer treated as an untrusted session: the adapter refreshes once and retries; a second rejection is a failure that keeps the session; a refused refresh is signed out by the SDK. Only the predicate's `untrusted_session` ends the session (Flutter adapter and controller tests).
- **2.1 tests** now exercise the predicate's value comparison by changing only the approved binding, and use fresh sessions after real epoch moves instead of clearing the epoch.
- **Persistence wiring.** `test/identity/persisted_session_wiring_test.dart` runs supabase_flutter's own persistence with `AuthSessionStorage` over a scripted Auth: sign-in and refresh write the session, a restart restores it without a sign-in call, sign-out removes it.

## Findings

1. **Value comparison was not enough.** Under 2.1 a direct phone change followed by a revert restored access. The triggers now keep the link in review until the authorised workflow accepts it (`E38`).
2. **Re-approval must move the epoch too.** The first E2E run showed a session opened while the link was in review being granted after re-approval (`E39`, failed run). Every link state change now moves the epoch, as 1.3's reconcile did; the rerun passes and pgTAP covers it.
3. **An Auth Admin email change also inserts an `email` identity** (`auth_identities:identity_added`, `E41`), so it is detected twice.
4. **Staff web bundle:** with a configured build, the Auth session key appears only with `sessionStorage`. `localStorage` references come from supabase_flutter's PKCE verifier store, unused by password sign-in.

## Not done here

- Hosted apply of `20261006223524_identity_session_trust` and a hosted repeat (owner promotion; staging is owner-gated).
- Mobile secure storage was exercised through `flutter_secure_storage`'s test mock and the SDK restore path; it was not run on a physical device or emulator.

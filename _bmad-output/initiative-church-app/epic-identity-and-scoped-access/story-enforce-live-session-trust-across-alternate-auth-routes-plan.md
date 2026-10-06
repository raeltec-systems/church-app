---
title: 'Enforce live session trust across alternate Auth routes'
type: 'feature'
ticket: '2'
created: '2026-10-06'
status: 'built'
baseline_revision: '19d0441408aa4bb47daf63eb8e313c6abda8f804'
route: 'full'
route_source: 'auto'
review: ''
review_source: ''
lenses_ran: []
review_loop_iteration: 0
context:
  - '{project-root}/_bmad-output/initiative-church-app/owner-decisions-milestone-1.md'
  - '{project-root}/_bmad-output/initiative-church-app/epic-platform-baseline/evidence-1.2/README.md'
  - '{project-root}/_bmad-output/initiative-church-app/epic-platform-baseline/evidence-1.3/README.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** The 2.1 predicate compares the current Auth phone/email by value, so a direct Auth change that is later reverted silently restores access, sessions from before a change, hold or review come back to life once it clears, and the AMR it trusts lives only in the JWT. Clients keep the session only in memory (a restart asks for the password) and do not end a session the server has stopped trusting.

**Approach:** Port the 1.3 trusted-detection mechanism into Identity: triggers on Auth credential tables record each change on the linked account, advance a credential generation, move the link to review for binding changes and set a session trust epoch, and the predicate additionally requires the server-side session AMR, a session created after the epoch, and a verified approved email. Clients persist the Auth session in platform-secured storage, end the local session when the server answers `untrusted_session`, and keep protected state in memory.

## Boundaries & Constraints

**Always:**
- Fail closed: OTP, magic-link, signup-link and recovery sessions (all `amr=[otp]` per 1.2), revoked/signed-out sessions, sessions older than the trust epoch, and any direct Auth phone/email/identity/MFA change deny private access; a verified approved email/password alias resolves to the same `sub` under the same checks.
- Dormancy is evaluated on the previously stored activity before any refresh; login, token refresh and every denial never write activity.
- Trigger functions take only the Identity link lock inside GoTrue's transaction, store change kinds (never phone/email values or secrets), and do nothing for unlinked accounts.
- Protected domain state stays in memory, scoped to the account generation; only Auth tokens persist (mobile Keystore/Keychain; staff web per-tab `sessionStorage`).
- Test numbers only in `+1 202 555 0100–0199` / `+44 7700 900000–900999`; emails `@example.test`.

**Decisions:**
- Decision (agent, under owner pre-approval): every detected Auth credential change (password included) advances the generation and sets the trust epoch, so even the session that changed the password must sign in again; GoTrue's own revocation of other sessions (1.2 P9) is then enforced, not assumed (AD-20).
- Decision (agent, under owner pre-approval): identity insert/delete and any MFA factor change count as binding changes needing review, as in 1.3; banning, unbanning and soft delete set the epoch.
- Decision (agent, under owner pre-approval): the predicate requires `password` both in the signed JWT `amr` and in the server's `auth.mfa_amr_claims` for that session, so a custom access-token hook cannot mint trust.
- Decision (agent, under owner pre-approval): an approved recovery email counts only while `auth.users.email_confirmed_at` is set.
- Decision (agent, under owner pre-approval): staff web keeps the session in per-tab `sessionStorage` (survives reload, ends when the tab closes); mobile uses `flutter_secure_storage` (Keystore/Keychain). Closes the 2.1 persistence deferral.
- Decision (agent, under owner pre-approval): re-approval after review is entries 5/8; tests simulate it as restricted-operator SQL. The epoch compares GoTrue's session `created_at` with DB `clock_timestamp()` (1.3 model); clock skew is a documented limit.

**Never:** SMS, SMS provider, Send SMS hook, test OTP, SMS MFA; hosted migration apply; destructive SQL; editing platform migrations; re-approval/relink UI (entries 5/8), email-recovery UI (7), number reclaim (5); persisting member data on the client.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Refresh / reopen | password session refreshed, or app restarted with stored session | still `granted`, no password prompt | refresh failure ends the local session |
| OTP / magic link / recovery | native `/verify` session (`amr=[otp]`) | `untrusted_session`, no activity write | generic "sign in again" |
| Recovery then new password | password set from recovery session | recovery session still denied; pre-change sessions denied; fresh password sign-in granted | — |
| Email/password alias | verified, approved email + same password | same member, `granted`; unverified email → `review_required` | — |
| Direct Auth phone/email change | Auth Admin or native change on a linked account | `review_required` even after revert; after staff re-approval, pre-change tokens `untrusted_session`; fresh sign-in granted | generic access-review screen |
| Revoked / signed out | logout (local/global), ban | `untrusted_session`; client clears state and local session | sign-in prompt |
| Dormant fixture | prior activity > 90 days (labelled fixture) | `review_required` after sign-in and refresh; activity unchanged | — |
| Hold placed then released | security hold | denied while open; pre-hold sessions stay denied after release | — |

</frozen-after-approval>

## Code Map

- `supabase/migrations/*_identity_live_access.sql` (2.1; renamed to `20261006215842_` on the integration branch while this was built) -- 2.1 predicate `app.identity_access_evaluate()`; replace with `create or replace` in a NEW migration (same signature). Do not edit.
- `tools/auth-harness/sql/002_recovery_fence.sql`, `004_review_fixes.sql` -- 1.3 trigger model (auth.users/identities/mfa_factors) to port; harness-only, never copy wholesale.
- `supabase/tests/identity_live_access_test.sql` -- 2.1 pgTAP; fixtures need `auth.mfa_amr_claims` rows and explicit session `created_at`; binding/hold rows change meaning (persistent review, epoch).
- `supabase/tests/command_foundation_test.sql` -- exact allowlist of functions `authenticated` may execute; new functions grant nothing.
- `tools/identity-e2e/run.mjs` -- extend (cleanup must also remove credential events).
- `packages/client_core/lib/composition.dart` (`persistSession:false`), `account_controllers.dart`, `providers.dart` (`AccountController`), `account_screen.dart`, adapters, `tool/live_identity_check.dart`, `lib/testing.dart` fakes.
- Local: postgres has TRIGGER on `auth.users/identities/mfa_factors`; GoTrue v2.197.0; inbucket stopped, so magic-link/recovery links come from Auth Admin `generate_link` and are redeemed at native `/verify`.

## Tasks & Acceptance

**Execution:**
- [x] `supabase/migrations/20261006220500_identity_session_trust.sql` -- link columns `credential_generation`, `sessions_valid_after`; `app.identity_credential_events`; triggers on auth.users (password/email/phone/deleted_at/banned_until, delete), auth.identities (insert/delete), auth.mfa_factors; link/hold triggers set the epoch; predicate hardening.
- [x] `supabase/tests/identity_session_trust_test.sql` -- pgTAP for the matrix plus privileges; adjust `identity_live_access_test.sql` fixtures.
- [x] `tools/identity-e2e/run.mjs` -- real-API scenarios: refresh, magic link, email OTP, recovery + password set, alias, direct phone/email change + revert + re-approval, global logout, ban, dormant fixture, activity unchanged on denials.
- [x] `packages/client_core` -- secure session storage adapter (mobile `flutter_secure_storage`, web `sessionStorage`), persistence on, `sessionEnded` account change, controller ends local session on `untrustedSession`, resume revalidation; tests; live check `session` mode (refresh, simulated restart via `recoverSession`, sign-out, server revocation).
- [x] `apps/{mobile,staff}/test` -- app-shell tests: refresh keeps summary, sign-out clears, untrusted answer ends session.
- [x] `docs/runbooks/identity-access.md`, `evidence-2.2/README.md`, `deferred-work.md` (close persistence entry reference).

**Acceptance Criteria:**
- Given the local stack with the phone switch on, when the E2E and live adapter check run, then every alternate route is denied without an activity write and refresh/restart keep access.
- Given CI, when db:test, db:smoke, flutter analyze/test run, then all pass and no SMS config exists.

## Implementation Notes

- Built directly (no subagent tool in this session). Files: migration `20261006220500_identity_session_trust.sql`; pgTAP `identity_session_trust_test.sql` (60) and `identity_live_access_test.sql` (fixtures gain server AMR rows and an explicit session `created_at`; a `reapprove` helper simulates re-approval where 2.1 rows now hit persistent review/epoch); smoke `identity_api_smoke.sh` (+6 checks); `tools/identity-e2e/run.mjs` (`E30`-`E45`, cleanup of credential events/holds, more redacted keys) and `live-adapter-check.sh`; client_core adapters `auth_session_storage*.dart`, `composition.dart` (persistence on), `providers.dart` (`AccountChange.sessionEnded`, `endUntrustedSession`), `account_controllers.dart`, `account_screen.dart` (session-ended banner, resume revalidation), `boundaries_test.dart` (persistence allowed only in the Auth-session adapter files), `session_trust_test.dart`, `tool/live_identity_check.dart` (`session` mode); app-shell tests on mobile and staff; CI scans `evidence-2.2`; runbook section; evidence README; deferred-work entry.
- Decision (agent, under owner pre-approval): every `link_state` change (including back to `active`) moves the trust epoch. The first E2E run (`E39`) showed a session opened during review being granted after re-approval; 1.3's reconcile rule (only sessions after the epoch) is now applied to re-approval too.
- Decision (agent, under owner pre-approval): the client ends its local session (and stored session) only on `untrusted_session`; `review_required`, `not_linked`, `unavailable` keep the session and withhold data, so the generic review screen stays reachable.
- Dependencies: `flutter_secure_storage` 10.0.0 and `web` 1.1.1 (pinned) in client_core; app lockfiles and the mobile Linux plugin registrant updated by `pub get`.
- Surprise: the integration branch renamed migrations mid-build (`20261006215306/215400/215842`); this story's migration was renamed from `20261006180000_` to `20261006220500_` and the branch re-merged cleanly.
- Surprise: an Auth Admin email change also inserts an `email` identity (detected twice). The local stack was reset once by the parent session during the build; all evidence was re-run after the merge.
- Staff web: with a configured build the session key is used only with `sessionStorage`; supabase_flutter's own PKCE verifier store still references `localStorage` (unused by password sign-in, no tokens).
- Not done: hosted apply/repeat (owner promotion), device/emulator run of the Keystore/Keychain restore (deferred-work.md).
- Review fixes (parent review, second pass): durable `binding_review_required` (cleared only by a new `binding_revision`); relink after `ended` starts with an epoch and the next generation; 5 s epoch margin (`app.identity_epoch_margin()`) with the residual fail-open cases documented in the migration header, runbook and evidence; guarded `auth.mfa_factors` update trigger; `auth.identities` move trigger (both users); link-state and relink events; PGRST301/303 refresh-once-and-retry in `SupabaseMemberAccessRepository` (only the predicate's `untrusted_session` ends the session); 2.1 pgTAP now exercises the value comparison via the approved side and re-signs in after real epoch moves; E2E asserts unchanged activity on every denial route and waits out the margin; new `persisted_session_wiring_test.dart` covers supabase_flutter's persistence through `AuthSessionStorage`.

## Verification

**Commands:**
- `npm run db:test && npm run db:smoke` -- expected: pass
- `node tools/auth-harness/local-phone-auth.mjs on && node tools/identity-e2e/run.mjs --evidence … && node tools/auth-harness/local-phone-auth.mjs off` -- expected: all checks pass
- `flutter analyze && flutter test` in `packages/client_core`, `apps/mobile`, `apps/staff` -- expected: pass
- Results (2026-10-06, local, after merging the integration branch): `db:test` 488/488 (session trust 60, live access 71); `db:smoke` all ok, phone off (identity 19); E2E 30/30 with the phone switch on; live adapter check PASS (signup + `session` S1-S6); client_core 136, mobile 15, staff 15 tests pass, analyze clean; staff web build (with and without dart-defines) + bundle scan clean; `ci:migrations --base origin/main` ordered and non-destructive; `ci:secrets`, `ci:policy-test` (49), `env:check`, `recovery:rehearse`, harness node tests (36), `scan-evidence` on evidence-2.2 clean. Phone switch turned off afterwards; synthetic users cleaned up.

- Results after the review fixes (2026-10-06, local, targeted): `db reset` + identity pgTAP 157/157 (live access 74, session trust 83); `identity_api_smoke.sh` 19 ok (phone off); E2E 30/30 (phone on, then off); live adapter check PASS; client_core analyze clean, `identity_adapters_test` + `persisted_session_wiring_test` 25, `session_trust_test` + `boundaries_test` 29 pass; `ci:migrations --base origin/main` clean.

## Review Triage Log

| Finding | Verdict | Route | Evidence |
|---|---|---|---|
| binding change on a non-active link laundered by suspend/revert/unsuspend | high | patch | `binding_review_required` flag; pgTAP suspend-change-revert-unsuspend row |
| relink after `ended` re-admitted old sessions | high | patch | `identity_on_link_insert`; pgTAP relink rows |
| epoch comparison fails open on clock skew / open transaction | medium | patch | 5 s margin + documented residual limits |
| MFA update trigger without change guard | low | patch | WHEN guard; pgTAP no-op update |
| identity re-pointed by UPDATE not detected | medium | patch | `identity_credential_identity_moved`; pgTAP |
| link-state epoch moves without events | low | patch | events from `identity_on_link_update` / `_inserted`; pgTAP |
| PGRST301/303 signed the user out | medium | patch | adapter refresh-and-retry; adapter + controller tests |
| 2.1 `reapprove` cleared the epoch (impossible path) | medium | patch | value comparison via approved side; fresh sessions after epochs |
| E2E denials did not assert unchanged activity | low | patch | `E36`, `E38`-`E40`, `E42`, `E43` |
| persisted-session wiring untested | medium | patch | `persisted_session_wiring_test.dart` |

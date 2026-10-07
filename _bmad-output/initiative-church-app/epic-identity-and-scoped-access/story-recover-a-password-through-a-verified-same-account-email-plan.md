---
title: 'Recover a password through a verified same-account email'
type: 'feature'
ticket: '7'
created: '2026-10-07'
status: 'done'
blocked_reason: ''
baseline_revision: 'f967132c1b11489ec3f12a9b73083c8fcde627fe'
route: 'full'
route_source: 'auto'
review: ''
review_source: ''
lenses_ran: []
review_loop_iteration: 0
context:
  - '{project-root}/_bmad-output/initiative-church-app/owner-decisions-milestone-1.md'
  - '{project-root}/docs/runbooks/identity-access.md'
  - '{project-root}/_bmad-output/initiative-church-app/epic-platform-baseline/story-prove-fenced-staff-recovery-across-the-auth-boundary-plan.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** A member who forgets the password has no self-service route: there is no way to attach a recovery email to the same Auth account, no Admin approval of it into the credential binding, and nothing stops GoTrue's public `/recover` and magic-link routes from resetting a password through an email that Identity never approved (I7, AD-20, AC-06).

**Approach:** Identity records a member's recovery-email proposal (recent password sign-in), the member verifies it through native `updateUser` on the same account, and an Admin approves it into a new binding revision after an identity check. A trigger on GoTrue's recovery-link redemption lets a reset proceed only to that approved, still-current, confirmed email. Mobile and staff web get forgot-password (neutral), allowlisted PKCE deep links, an isolated recovery session that can only set the password, and a required fresh sign-in.

## Boundaries & Constraints

**Always:** reuse `app.identity_access_evaluate()`, the trust epoch and credential detection (2.2), holds, the 1.4 envelope with the registered `identity` authorizer, and content-free audit. A reset never clears a hold, approves a binding, relinks or creates an account. Recovery and email-link sessions never pass the predicate. Older sessions lose private access (GoTrue sign-out of other sessions plus the 2.2 password epoch). Errors and acknowledgements never reveal whether an account or email exists. Personal data stays behind `identity_applications_open()`; while Q4 is unapproved the email must be synthetic (local: `@example.test`/`.com`/`.invalid`; staging also `israelmuyoba+<tag>@gmail.com`). Main migration later than `20261007131600` with no `delete from`; Unicode format characters only as `\uXXXX`.

**Decisions:**
- Decision (agent, under owner pre-approval): `identity.propose_recovery_email {email}` needs a granted session whose own password sign-in is at most 10 minutes old, and is allowed only while the approved binding has no recovery email (replacing or removing one is entry 8). At most 5 proposals per link per 24 h; a new proposal supersedes the pending one.
- Decision (agent, under owner pre-approval): verification is GoTrue's own email-change link (PKCE, allowlisted redirect). Until approval the 2.2 detection keeps the account in access review, because AD-3 says an unapproved email change blocks private access; the member's own read `api.identity_my_recovery_email()` explains the wait. Approval records binding revision n+1 and returns the link to `active`, so the member signs in again.
- Decision (agent, under owner pre-approval): `identity.approve_recovery_email {proposal_id, identity_check}` (Admin, proposal revision) requires: not the Admin's own account; current Auth email equal to the proposal and confirmed; Auth phone equal to the approved phone; no MFA factor; Auth identities only `phone`/`email`; and no phone, delete, identity-removed/moved or MFA change since the proposal. Otherwise `conflict`, and the case goes to the entry 8 review. `identity.reject_recovery_email {proposal_id, reason?}` records the decision only; a verified email then keeps the account in review until entry 8 removes it.
- Decision (agent, under owner pre-approval): the reset gate is an `auth.users` trigger on recovery-token redemption (`recovery_token` cleared with the password unchanged; this also covers magic links). It refuses unless: live `active` link with no binding review; approved member; approved email equal to the current, confirmed Auth email; Auth phone equal to the approved phone; account not deleted or banned; email recovery open (`q1_auth_recovery` approved, or local/staging, never a held restore). Holds and dormancy do not block the reset and stay in force. A redemption is recorded as credential event `email_link_redeemed`, with no epoch move.
- Decision (agent, under owner pre-approval): the recovery session lives in a separate in-memory Auth client used only to exchange the code and update the password, then it signs out; the app's own session is never replaced. Allowlisted links: mobile `zm.bickafue.mobile://callback/auth/recovery` and `…/auth/email-confirmed`; staff web `<origin>/#/auth/recovery` and `#/auth/email-confirmed`. Only `code` and error parameters are read.
- Decision (agent, under owner pre-approval): staging Auth settings (redirect allowlist) are an owner Management API PATCH, recorded in the runbook. The tests use synthetic local inboxes only.

**Never:** SMS or any phone OTP; hosted applies; sending to the staging owner inboxes; recovery to an unapproved, unverified or changed email; a recovery session that reads private data; replacing or removing an approved email (entry 8); assisted recovery (entry 9); custom auth PINs or fake emails.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Add + verify + approve | granted member, fresh password sign-in, synthetic email | proposal → email-change link → Admin approves → binding rev 2 with email; fresh sign-in granted | stale sign-in → `forbidden {"session": "reauthenticate"}` |
| Reset (mobile, web) | approved email, PKCE `/recover` with allowlisted redirect | link → code → recovery session sets password; old sessions untrusted; recovery session denied; fresh sign-in granted | — |
| Unknown / unverified address | no account, or email still pending | 200, neutral, no mail | — |
| Unapproved / changed | verified but not approved; approved then changed in Auth | redemption refused, no session; neutral "link can't be used" | — |
| Expired / reused | link older than OTP expiry; second click | GoTrue `otp_expired`; neutral | — |
| Hold | open hold, reset | password set; fresh sign-in `review_required` | — |
| Non-Admin approve / self | member, own proposal | `forbidden` / `forbidden {"proposal_id": "unsupported"}` | — |

</frozen-after-approval>

## Code Map

- `supabase/migrations/20261006223524_identity_session_trust.sql` -- `identity_note_credential_change`, `auth.users` trigger pattern, link update trigger (binding revision clears review; state change moves epoch), predicate. Do not edit.
- `supabase/migrations/20261007063340_membership_review.sql` -- review command pattern (`identity_review_errors`, `identity_check_value`, `identity_command_actor`, `cmd_current_request_id`, `api.*_command` wrapper, `identity_authorize_command` Admin branch, which this story replaces again with all commands kept), audit table style, privileges block.
- `…/20261007050512_membership_applications.sql` -- `identity_applications_open`, `identity_authorize_application_command` (member-branch template).
- `app.policy_is_open('q1_auth_recovery')`, `app.platform_current_environment()`, `app.rcv_serving_hold()`.
- Tests: `supabase/tests/membership_review_test.sql` helpers, `command_foundation_test.sql` allowlist, `identity_api_smoke.sh` (magic-link/recovery for a seeded account with an approved email must still work).
- E2E: `tools/identity-e2e/review.mjs` (helpers, bootstrap, cleanup), `run.mjs` (`redact`, `assertLocalOrigin`), Mailpit API at `127.0.0.1:54324` (`tools/auth-harness/local-mailpit-link.mjs`).
- Client: `packages/client_core` `composition.dart` (Supabase init, `detectSessionInUri: false`), `shell_routing.dart`, `sign_in_screen.dart` (Forgot password button), `account_screen.dart`, `review_controllers.dart` (command pattern), `supabase_api_reader.dart`, `testing.dart` fakes; `apps/staff/lib/app.dart` destinations; `apps/mobile/android/.../AndroidManifest.xml`, `ios/Runner/Info.plist`.
- Spike results (local GoTrue v2.197.0): email change of a phone user keeps `email` empty until the GET verify, which confirms it, adds an `email` identity and redirects `?code=`. `/recover` returns 200 for unknown emails. Redemption is `UPDATE users SET recovery_token, updated_at` alone; password updates clear the token in the same row update. A recovery exchange gives AMR `recovery`. A password update from it deletes every other session. A reused link redirects with `error_code=otp_expired`. A web redirect with a fragment becomes `/?code=…#/auth/recovery`. A non-allowlisted redirect falls back to `site_url`.

## Tasks & Acceptance

**Execution:**
- [x] `supabase/migrations/20261007093323_recovery_email.sql` -- proposals and credential audit tables, redemption gate trigger, eligibility helper, member/Admin commands, `api.identity_recovery_email_command`, `api.identity_my_recovery_email`, `api.identity_admin_recovery_email_queue`, authorizer, grants.
- [x] `supabase/tests/recovery_email_test.sql` + allowlist in `command_foundation_test.sql`; `identity_api_smoke.sh` anon/unlinked checks.
- [x] `supabase/config.toml` -- mobile redirect entries.
- [x] `tools/identity-e2e/recovery.mjs` (+ `recovery.test.mjs`) -- the verify bullet against local GoTrue and Mailpit.
- [x] `packages/client_core` -- recovery domain and ports, Supabase adapters (isolated recovery client, recovery-email repository), controllers, Forgot password, recovery and email-confirmed screens, the member Recovery email screen, the Admin Recovery emails screen, routes, fakes, widget tests.
- [x] `apps/mobile` (deep-link intent filter, iOS URL type), `apps/staff` (Admin destination) + tests.
- [x] `docs/runbooks/identity-access.md`, `evidence-2.7/README.md`, CI wiring.

**Acceptance Criteria:**
- Given the local stack, when `recovery.mjs` runs, then every matrix row passes against real GoTrue and Mailpit, and cleanup leaves no synthetic rows.
- Given CI, when db:test, db:smoke, flutter analyze and flutter test run, then all pass.

## Implementation Notes

- Built directly (no subagent tool in this session). Checkpoint 1 is pre-approved by the owner decisions. The plan is above the 1600-token guide because one Identity change spans the DB, two clients and evidence; it was kept whole, as in the epic's lane decision.
- Files:
  - Migration `supabase/migrations/20261007093323_recovery_email.sql`: one file, no `delete from`, non-destructive.
    - New: the proposal and credential-audit tables, the `identity_email_link_gate` trigger on `auth.users`, the commands and reads.
    - `create or replace` of `identity_authorize_command`, with every earlier command kept.
  - pgTAP `supabase/tests/recovery_email_test.sql` (57), the allowlist in `command_foundation_test.sql` (+6), and `identity_api_smoke.sh` (+10 lines).
  - `supabase/config.toml`: the two mobile redirect entries.
  - E2E `tools/identity-e2e/recovery.mjs` (+ `recovery.test.mjs`); adapter check `tools/identity-e2e/live-recovery-check.sh` + `packages/client_core/tool/live_recovery_check.dart`.
  - client_core:
    - domain: `password_recovery.dart` (link allowlist, redirects, ports) and `recovery_email.dart`;
    - adapters: `supabase_password_recovery_gateway.dart` (its own GoTrueClient), `recovery_verifier_storage*.dart` and `supabase_recovery_email_repository.dart`;
    - `application/recovery_controllers.dart`;
    - `presentation/recovery_screens.dart` (Forgot password, Set a new password, Email confirmed, Recovery email, Recovery emails) and `page_address_*.dart`;
    - routes, the Forgot password link, the account-page links, fakes, the boundary test and tests (`password_recovery_test.dart` 25, `recovery_adapters_test.dart` 5).
  - Apps:
    - Android intent filter (scheme `zm.bickafue.mobile`, host `callback`, path prefix `/auth/`) and `flutter_deeplinking_enabled`; iOS URL type;
    - the staff `Recovery emails` destination (Admin);
    - tests.
  - Docs: the runbook section, `evidence-2.7/README.md`, the CI evidence scan.
- Spike before the plan (local GoTrue, with a temporary spy trigger that was removed): it confirmed the email-change, recovery, PKCE, magic-link and token-clearing behaviour recorded in the Code Map. It is the basis of the redemption trigger condition.
- Decision (agent, under owner pre-approval): an allowed redemption records `email_link_redeemed` without moving the epoch or generation.
  - Moving it there would end the sessions of Admins whose magic link is merely redeemed (2.3 E2E `G22`, which uses A's session afterwards).
  - The password update that follows moves it through the 2.2 trigger.
- Decision (agent, under owner pre-approval): forgot password returns the same acknowledgement for any server answer except a transport failure. This covers GoTrue's per-address `429`, which happens only for addresses it knows.
- Decision (agent, under owner pre-approval): addresses are plain ASCII; internationalised addresses are refused as `invalid`.
- Decision (agent, under owner pre-approval): the recovery verifier lives in secure storage on mobile and in `localStorage` on staff web, under its own prefix. The email link opens in a new tab, while the app session stays in the tab's store. The boundary test pins both stores.
- Surprise: issuing a second reset from the same device replaces the PKCE verifier, so only the newest link works. The copy says so, and the adapter check uses a separate client for its unknown-address request.
- Environment:
  - The stack was restarted from this worktree with Mailpit (the `-x` list given) and reset several times.
  - The phone switch was found off, was on only for the E2E, adapter and regression runs, and is off again.
  - Every synthetic user, row, flow state and caught message was removed.
- Owner and parent steps:
  - staging apply of `20261007093323`;
  - the staging redirect-allowlist PATCH (runbook, Hosted step 2);
  - the staging demonstration with the owner inboxes (about 2 emails per hour on the built-in sender).
  - None of these blocks the build.

## Plan Change Log

- 2026-10-07, independent review (coordinator; not a step-04 loop). No takeover path was found; five findings.
  - **Findings:**
    - Lockout: a rejected or abandoned address left the account in review, with no exit.
    - The reset gate is version-dependent and unchecked on hosted Auth.
    - Approval did not check that the proposal came before the email change.
    - The email-confirmed page showed success without a code.
    - Enumeration through GoTrue `/recover`.
  - **Amended:**
    - `20261007093323` was edited in place (not on main or staging), still without `delete from`, DROP or TRUNCATE:
      - `app.identity_revert_recovery_email` is called by reject and by the new member command `identity.withdraw_recovery_email`, which works from the review state;
      - recency at approval;
      - the `withdrawn` state and the `_withdrawn`/`_reverted` audit actions;
      - leftover email identities of reverted addresses are tolerated.
    - `tools/ci/verify-hosted.sql` gets the Auth schema, column and trigger assertion.
    - Other files: the runbook (canary, accepted risks); the pgTAP lockout and recency tests; E2E `X35`–`X37`; the client withdraw action, the missing-code fix and widget tests.
  - **Avoids:**
    - a member stuck in review by their own or a rejected address;
    - a confirmation click after rejection re-adding it;
    - a silent gate bypass after a GoTrue upgrade.
  - **KEEP:**
    - the redemption gate;
    - the isolated recovery client;
    - the neutral in-app answers;
    - review lifted only when nothing else changed.
- Known risk carried to entry 8: a stolen live session can call GoTrue `PUT /user` directly to change the email or the password and lock the real member out of password sign-in. Private access never follows. The exits are withdraw/reject and staff-assisted recovery; reauthentication and credential-change review are entry 8.
- Accepted platform risk, owner decision at entry 14 (with the Q1 sender/SMTP and Auth rate-limit settings): GoTrue `/recover` is directly callable with the publishable key, and its `429`/timing reveal known addresses. No wrapper is built; in-app answers stay neutral.
- The proposal's 10-minute password check is advisory on its own: GoTrue's `updateUser(email)` does not re-check it. The binding still changes only through the Admin approval, which now also requires the email change to come after the proposal.

## Review Triage Log

## Verification

**Commands:**
- `npx supabase db reset && npm run db:test && npm run db:smoke` -- expected: pass
- `node tools/auth-harness/local-phone-auth.mjs on && node tools/identity-e2e/recovery.mjs --evidence …; node tools/auth-harness/local-phone-auth.mjs off` -- expected: all pass
- `flutter analyze && flutter test` in `packages/client_core`, `apps/mobile`, `apps/staff` -- expected: pass
- Results (2026-10-07, local, each after a reset):
  - Database: `db:test` 978/978 (recovery 57); `db:smoke` exit 0, 114 ok.
  - Story E2E and adapters: `recovery.mjs` 17/17; adapter check L1–L5.
  - After the review fixes: `db:test` 996/996 (recovery 75); `db:smoke` exit 0, 114 ok; `recovery.mjs` 20/20; adapter check L1–L5; `run` 30, `grants` 18, `review` 18, `apply` 27, `cells` 13 (all pass); client_core 250, mobile 21, staff 19; analyze clean; `ci:migrations`, `ci:secrets`, node tool tests (66) and the evidence scan clean.
  - Regressions: `run.mjs` 30/30, `grants.mjs` 18/18, `review.mjs` 18/18, `apply.mjs` 27/27, `cells.mjs` 13/13.
  - Clients:
    - client_core 248 tests, mobile 21, staff 19;
    - analyze and format clean;
    - staff `flutter build web` ok.
  - CI checks:
    - `ci:migrations --base ccr-93e730dd-89lbvg`: 17 migrations, ordered and non-destructive;
    - `ci:secrets` clean;
    - node tool tests 48/48;
    - `scan-evidence` on evidence-2.7 and `tools/identity-e2e`: clean.
  - Evidence: `evidence-2.7/README.md`.
- Matrix audit: every I/O row has a passing pgTAP assertion and an E2E step. The non-Admin and self rows are covered by pgTAP and E2E `X14`; the stale sign-in row by pgTAP and a widget test.

## Hosted verification

Staging apply, parity and API checks: `evidence-2.7/staging-verify.md`. Email flows on staging with the owner inboxes: `owner-consolidated-test.md`.

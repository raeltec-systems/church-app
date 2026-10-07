---
title: 'Recover a password through a verified same-account email'
type: 'feature'
ticket: '7'
created: '2026-10-07'
status: 'in-progress'
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
- [ ] `supabase/migrations/20261007140000_recovery_email.sql` -- proposals and credential audit tables, redemption gate trigger, eligibility helper, member/Admin commands, `api.identity_recovery_email_command`, `api.identity_my_recovery_email`, `api.identity_admin_recovery_email_queue`, authorizer, grants.
- [ ] `supabase/tests/recovery_email_test.sql` + allowlist in `command_foundation_test.sql`; `identity_api_smoke.sh` anon/unlinked checks.
- [ ] `supabase/config.toml` -- mobile redirect entries.
- [ ] `tools/identity-e2e/recovery.mjs` (+ `recovery.test.mjs`) -- the verify bullet against local GoTrue and Mailpit.
- [ ] `packages/client_core` -- recovery domain and ports, Supabase adapters (isolated recovery client, recovery-email repository), controllers, Forgot password, recovery and email-confirmed screens, the member Recovery email screen, the Admin Recovery emails screen, routes, fakes, widget tests.
- [ ] `apps/mobile` (deep-link intent filter, iOS URL type), `apps/staff` (Admin destination) + tests.
- [ ] `docs/runbooks/identity-access.md`, `evidence-2.7/README.md`, CI wiring.

**Acceptance Criteria:**
- Given the local stack, when `recovery.mjs` runs, then every matrix row passes against real GoTrue and Mailpit, and cleanup leaves no synthetic rows.
- Given CI, when db:test, db:smoke, flutter analyze and flutter test run, then all pass.

## Implementation Notes

## Plan Change Log

## Review Triage Log

## Verification

**Commands:**
- `npx supabase db reset && npm run db:test && npm run db:smoke` -- expected: pass
- `node tools/auth-harness/local-phone-auth.mjs on && node tools/identity-e2e/recovery.mjs --evidence …; node tools/auth-harness/local-phone-auth.mjs off` -- expected: all pass
- `flutter analyze && flutter test` in `packages/client_core`, `apps/mobile`, `apps/staff` -- expected: pass

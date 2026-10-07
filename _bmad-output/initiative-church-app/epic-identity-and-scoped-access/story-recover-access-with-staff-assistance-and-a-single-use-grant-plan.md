---
title: 'Recover access with staff assistance and a single-use grant'
type: 'feature'
ticket: '9'
created: '2026-10-07'
status: 'in-progress'
blocked_reason: ''
baseline_revision: 'eb7d20128c935c577948c570c6203bde3c033d7c'
route: 'full'
route_source: 'auto'
review: ''
review_source: ''
lenses_ran: []
review_loop_iteration: 0
context:
  - '{project-root}/_bmad-output/initiative-church-app/owner-decisions-milestone-1.md'
  - '{project-root}/docs/runbooks/identity-access.md'
  - '{project-root}/docs/runbooks/system-access-and-operations.md'
  - '{project-root}/_bmad-output/initiative-church-app/epic-platform-baseline/story-prove-fenced-staff-recovery-across-the-auth-boundary-plan.md'
  - '{project-root}/_bmad-output/initiative-church-app/epic-identity-and-scoped-access/story-change-credentials-under-review-and-hold-access-plan.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** A member without a usable approved recovery email has no way back into their account, and 2.8's `password_reset_required` holds (lost device, restore after an unreviewed password) can only be released after an email reset. AD-20's staff-assisted route (I9, AC-06) is missing: a recorded case, a single-use generation-bound grant, a member-chosen password applied only by server-side Auth Admin, and fenced external operations.

**Approach:** Port the 1.3 proven mechanism into Identity. The member's phone creates the grant secret and sends only its digest; an Admin opens a case with identity evidence and binds that digest into a short-lived grant; the member then chooses a password that an Edge Function (the only holder of Auth Admin power) applies between fenced database steps it reaches only through the AD-19 system route with its own purpose-bound credential.

## Boundaries & Constraints

**Always:** reuse the 2.2 generation/trust epoch/credential events, 2.8 holds (`password_reset_required_since`), `identity_revoke_auth_sessions`, lifecycle dispatch, the `identity` authorizer and 1.4 envelope, the 1.9 system route and credentials. Store only the grant digest; staff screens, responses, audit and logs never hold a password, secret or digest. Main migration later than `20261007160100`, ASCII only, no `delete from`. Phones `+1 202 555 0100–0199` / `+44 7700 900000–900999`; emails `@example.test`. Local stack only; hosted applies, secrets and deploys are parent/owner steps.

**Decisions:**
- Decision (agent, under owner pre-approval): the Edge Function `identity-assisted-recovery` (`verify_jwt = false`; the grant authenticates the member) holds Auth Admin through the platform-provided `SUPABASE_SERVICE_ROLE_KEY` and talks to the database only through `api.system_command` with a credential of the new purpose `identity_assisted_recovery` (secret `IDENTITY_RECOVERY_SYSTEM_CREDENTIAL`). The 1.9 kernel gains a command registry (payload check + handler per kind); the probe behaves as before. No new anon grant.
- Decision (agent, under owner pre-approval): member actions through the function: `request {phone_username, grant_digest}` (neutral; returns a non-secret 8-character request code; 5 per number per hour, 60 per 10 min overall, 30 min expiry), `status {grant_digest}`, `redeem {phone_username, grant_secret, password}` (password 8–72 bytes checked before the grant is used).
- Decision (agent, under owner pre-approval): Admin commands (`api.identity_recovery_command`): `identity.open_recovery_case {member_id, identity_check, evidence[]}`, `identity.issue_recovery_grant {case_id, request_code}` (15 min; supersedes every earlier grant of the account), `identity.cancel_recovery_case {case_id, reason}`, `identity.reconcile_recovery_operation {case_id, identity_check}`; read `api.identity_admin_recovery_cases()`. The reviewer is an Admin other than the member (Q1 names real reviewers later). Refused for `access_review`/`login` holds, links in review, a changed Auth phone, and while an operation is unresolved.
- Decision (agent, under owner pre-approval): begin (consume + pending op) and dispatch (generation fence, op-owned security hold with `password_reset_required_since`, sessions counted) precede the Admin call; completion succeeds only with exactly one `password` change since dispatch, generation +1 and no pre-dispatch session alive, then releases only the op's own hold and records the evidence that `identity_member_reset_since` and `identity_password_unreviewed` now accept. Anything else is `uncertain` (hold stays) or, when Auth refused and nothing changed, `failed`. A wrong phone at redemption burns the grant. A new link for the account or member is refused while an op is unresolved; unlink stays possible. Reconcile revokes every session and keeps the hold.

**Never:** SMS/OTP; staff choosing, seeing or sending a password or usable grant; writing password hashes; clearing a pre-existing hold by a reset; fault-injection code in the function; hosted applies or handling secrets.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Happy | case, grant issued, member redeems | op succeeded, all sessions gone, fresh password sign-in granted; grant replay rejected | — |
| Reissue | G1 then G2 | G1 rejected, G2 works | — |
| Direct change | grant issued, member `PUT /user` password | generation moved; redeem rejected | — |
| Relink / unlink | grant issued, link ended or relinked | rejected; relink refused while op unresolved | `conflict {"member_id":"recovery_unresolved"}` |
| Concurrent | N parallel redeems | exactly one op | others rejected |
| Cross-member | grant redeemed with another phone | rejected and burned | — |
| Uncertain / late | Auth result unknown, or applied after completion | held; late result recorded; reconcile needed | — |
| Hold | lost-device hold, assisted reset | hold stays; release now allowed | dispute hold refuses issue |
| Leakage | staff reads, responses, logs | no password, secret or digest | — |

</frozen-after-approval>

## Code Map

- `supabase/migrations/20261003154040_bounded_system_access.sql` -- `app.sys_execute` (replace with registry dispatch; probe unchanged), `sys_command_kinds`, `sys_create_principal`.
- `…/20261006223524_identity_session_trust.sql` -- generation, epoch, `identity_credential_events`, hold/link triggers. Do not edit.
- `…/20261007111436_credential_review.sql` -- holds columns, `identity_member_reset_since`, `identity_password_unreviewed` (replace), `identity_bump_member`, `identity_dispatch_lifecycle`, `identity_lock_reviewed_member`, `identity_authorize_command` (replace, keep all), command endpoint pattern; `20261007160100` session revocation.
- `…/20261007063340_membership_review.sql` -- `identity_check_value`, admin member search.
- Tests: `supabase/tests/credential_review_test.sql`, `system_access_test.sql`, `command_foundation_test.sql` allowlist, `identity_api_smoke.sh`; E2E helpers `tools/identity-e2e/credentials.mjs`, `run.mjs`; 1.3 `tools/auth-harness/functions/harness-recovery`.
- Clients: `packages/client_core` credential review files (domain/adapter/controllers/screens), `shell_routing.dart`, `sign_in_screen.dart`, `recovery_screens.dart`, `testing.dart`, `composition.dart`; apps `mobile`/`staff` `app.dart` and tests.

## Tasks & Acceptance

**Execution:**
- [ ] `supabase/migrations/20261007170000_assisted_recovery.sql` -- tables, sys registry + kernel, system handlers, Admin commands, read, relink trigger, replaced helpers, grants.
- [ ] `supabase/functions/identity-assisted-recovery/{index.ts,logic.mjs,logic.test.mjs}`, `supabase/config.toml` -- the function.
- [ ] `supabase/tests/assisted_recovery_test.sql`, allowlist, smoke -- pgTAP for the matrix and privileges.
- [ ] `tools/identity-e2e/assisted.mjs` (+ test) -- the verify bullet against local GoTrue, PostgREST and the served function; log/response leak scan.
- [ ] `packages/client_core` + apps -- domain, adapter, controllers, mobile help route and password setup, staff case screens, fakes, widget tests.
- [ ] `docs/runbooks/identity-access.md`, `system-access-and-operations.md`, `evidence-2.9/README.md`, CI.

**Acceptance Criteria:**
- Given the local stack and the served function, when `assisted.mjs` runs, then every matrix row passes and no synthetic rows remain.
- Given CI, when db:test, db:smoke, node tests, flutter analyze and test run, then all pass.

## Implementation Notes

## Plan Change Log

## Review Triage Log

## Verification

**Commands:**
- `npx supabase db reset && npm run db:test && npm run db:smoke` -- expected: pass
- `node tools/auth-harness/local-phone-auth.mjs on && node tools/identity-e2e/assisted.mjs --evidence …; node tools/auth-harness/local-phone-auth.mjs off` -- expected: all pass
- `node --test supabase/functions/identity-assisted-recovery/*.test.mjs tools/identity-e2e/*.test.mjs` -- expected: pass
- `flutter analyze && flutter test` in `packages/client_core`, `apps/mobile`, `apps/staff` -- expected: pass

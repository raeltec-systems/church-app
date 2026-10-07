---
title: 'Change credentials under review and hold access'
type: 'feature'
ticket: '8'
created: '2026-10-07'
status: 'in-progress'
blocked_reason: ''
baseline_revision: '76f8b95c6edbfbe779b56fc484798be19c7daf6f'
route: 'full'
route_source: 'auto'
review: ''
review_source: ''
lenses_ran: []
review_loop_iteration: 0
context:
  - '{project-root}/_bmad-output/initiative-church-app/owner-decisions-milestone-1.md'
  - '{project-root}/docs/runbooks/identity-access.md'
  - '{project-root}/_bmad-output/initiative-church-app/epic-identity-and-scoped-access/story-recover-a-password-through-a-verified-same-account-email-plan.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** A member cannot change the phone username or replace/remove an approved recovery email; there is no Admin path for 2.7's `other_changes` (phone, MFA, other identities) or for a direct Auth change that leaves an account in review; holds can only be written by an operator in SQL; nothing handles a lost or compromised device; and the stolen-session `PUT /user` email-change lockout carried from 2.7 has no exit except staff-assisted recovery (I8, AD-3, AD-20, AC-05).

**Approach:** One Identity credential-review lane on the existing predicate, holds, trust epoch, 2.2 detection, 1.4 envelope (`identity` authorizer) and 1.5 lifecycle dispatch: member change requests (fresh password) that an Admin approves after an identity check and that Identity then applies to Auth server-side; Admin holds (dispute, security, lost device) with identity-checked release; Admin restore/accept of a reviewed account; and a generic "Access review required" help screen that is the only private screen a held or reviewed session reaches on both clients.

## Boundaries & Constraints

**Always:** reuse `app.identity_access_evaluate()`, `identity_note_credential_change` triggers, `binding_review_required`, the trust epoch, `identity_require_grant`, `identity_command_actor`, `cmd_execute`, `app.contract_dispatch_lifecycle`, content-free audit. A binding changes only through an Admin decision after an identity check, recorded as a new `binding_revision`. Direct Auth changes, `/recover`, login, reset and email verification never clear a hold or approve a binding. Only an Admin other than the member places or releases a hold. Main migration later than `20261007131600` with no `delete from`; Auth row deletions only in a second small migration; Unicode format characters only as `\uXXXX`. Phones `+1 202 555 0100–0199` / `+44 7700 900000–900999`; emails `@example.test`.

**Decisions:**
- Decision (agent, under owner pre-approval): member command `identity.request_credential_change {change_kind, phone_username? | email?}` with kinds `phone_username`, `recovery_email_replace`, `recovery_email_remove`; needs a granted session whose password sign-in is ≤10 min old (2.7 window), one pending change or 2.7 proposal per account, 5 requests per 24 h, Q4 synthetic values only. `identity.withdraw_credential_change` works also in review.
- Decision (agent, under owner pre-approval): a phone or removal request leaves Auth untouched until approval. Approval (`identity.approve_credential_change {change_id, identity_check}`) writes `auth.users` server-side (phone + `phone_confirmed_at`, or email cleared with its change tokens neutralised), records binding n+1 (link `active`, epoch moved) and revokes every Auth session of the account. A taken number is `conflict {"phone_username": "taken"}`; nothing is overwritten (reclaim stays the 2.5 path). No SMS, no OTP.
- Decision (agent, under owner pre-approval): `double_confirm_changes` stays on, so a replacement cannot rely on the old address. A replacement request removes the old address from Auth at once (the account enters review, as 2.7's add does), the client then runs native `updateUser(new)` (one link, to the new address), and the Admin approves only a confirmed new address. Reject/withdraw restore the approved address (confirmed) and lift the review when nothing else changed.
- Decision (agent, under owner pre-approval): holds: `identity.place_hold {member_id, reason_code}` (`ownership_dispute` → kind `access_review`; `security_concern`, `lost_device` → kind `security`); `lost_device` also revokes every Auth session. `identity.release_hold {member_id, hold_id, identity_check}`. Both expect the member revision, bump it, and dispatch `access_hold_applied` / `access_hold_released`. Releasing moves the trust epoch, so sessions opened during the hold must sign in again. No new lifecycle event: device-registration owners hook `access_hold_applied` (a contract change is deferred); tests prove it with the SYNTHETIC `app.fixture_record_lifecycle`.
- Decision (agent, under owner pre-approval): `identity.restore_credentials {member_id, identity_check}` returns Auth to the approved binding (phone, email, change tokens; deletes MFA factors and non-phone/email identities), revokes every session and records binding n+1: the exit for a stolen-session email change and for `other_changes`. `identity.accept_credentials {member_id, identity_check}` records the current Auth phone and confirmed email as binding n+1 only when there is no MFA factor or foreign identity and the values are permitted and free. Both refuse while a change or proposal is pending.
- Decision (agent, under owner pre-approval): reads `api.identity_my_credentials()` (own, granted or review_required: generic `access`, approved values, the pending change or 2.7 proposal, church contact from `operational_contact` or null) and `api.identity_admin_credential_queue()` (Admin: pending changes, accounts in review with change kinds and current Auth values, open holds). The help screen never states a reason.
- Decision (agent, under owner pre-approval): clients: shared route `/access-review` (help screen: generic text, church contact, current request with withdraw, sign out); both shells show it instead of any private destination while `api.identity_my_access` answers `review_required`; mobile `/sign-in-details` (change number, replace/remove email); staff web Admin `/admin/credential-reviews`.

**Never:** SMS, OTP, phone verification or SMS MFA; hosted applies; writing password hashes; changing a password for the member (entry 9); deactivation/login holds (entry 10); a new contract event or contract version; self-approval of a change or hold.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Phone change | fresh sign-in, free fictional number; Admin approves | Auth phone replaced, binding n+1, sessions revoked; new number + same password granted | taken → `conflict`; stale sign-in → `forbidden {"session":"reauthenticate"}` |
| Email replace | approved email; request; confirm new | review until approval; approval → binding with new email | unconfirmed → `validation_failed {"recovery_email":"unverified"}` |
| Email remove | approved email; Admin approves | Auth email cleared, binding without email | — |
| Hold | dispute hold on a member | session gets `review_required` (help screen); `/recover`, reset, login, direct Auth change, email verification leave it open | release needs identity check, another Admin |
| Lost device | `lost_device` hold | every session revoked (401), hook called in the same transaction; new sign-in `review_required` | — |
| Stolen-session email change | direct `PUT /user email` | review; Admin restore → address gone, sessions revoked, fresh sign-in granted | pending change → `conflict` |
| Self / non-Admin | own change or hold; member calls Admin command | `forbidden {"…":"unsupported"}` / `forbidden` | — |

</frozen-after-approval>

## Code Map

- `supabase/migrations/20261006223524_identity_session_trust.sql` -- detection triggers (`identity_note_credential_change`), `identity_on_link_update` (binding revision clears review; state change moves epoch), `identity_on_hold_placed`. Do not edit.
- `…/20261006234820_identity_grants.sql` -- `identity_account_standing`, `identity_require_grant`, `identity_command_actor`, `cmd_current_request_id`, `identity_church_setting('operational_contact')`.
- `…/20261007063340_membership_review.sql` -- `identity_review_errors`, `identity_check_value`, member-revision commands (`identity_unlink_account` pattern, lifecycle dispatch), `identity_admin_member_search` (Admin picks a member for a hold).
- `…/20261007093323_recovery_email.sql` -- proposals, `identity_session_recent_password`, `identity_recovery_email_permitted`, `identity_revert_recovery_email` (Auth write pattern, token neutralising), `identity_authorize_command` (replace again, keep every command).
- `…/20261007131600_membership_review_reclaim_sessions.sql` -- session-row deletion pattern for the second file.
- `…/20261007075946_cell_membership.sql` -- `app.fixture_record_lifecycle`, `app.fixture_lifecycle_calls`.
- Tests: `supabase/tests/recovery_email_test.sql` helpers; `command_foundation_test.sql` allowlist; `identity_api_smoke.sh`. E2E: `tools/identity-e2e/recovery.mjs` (helpers, Mailpit, cleanup).
- Client: `packages/client_core` `recovery_email.dart`, `supabase_recovery_email_repository.dart` (password re-check, `updateUser`), `recovery_controllers.dart` (command/notice pattern), `shell_routing.dart`, `account_screen.dart`, `access_controllers.dart` (`myAccessProvider`), `testing.dart` fakes; `apps/staff/lib/app.dart`, `apps/mobile/lib/app.dart`.

## Tasks & Acceptance

**Execution:**
- [ ] `supabase/migrations/20261007160000_credential_review.sql` -- tables (changes, review audit), hold columns, release-epoch trigger, 2.7 proposal guard, commands, authorizer, reads, grants; session/factor helpers as fail-closed stubs.
- [ ] `supabase/migrations/20261007160100_credential_review_auth_rows.sql` -- the stubs replaced with the Auth row deletions only.
- [ ] `supabase/tests/credential_review_test.sql`, allowlist, `identity_api_smoke.sh`.
- [ ] `tools/identity-e2e/credentials.mjs` (+ `.test.mjs`) -- the verify bullet against local GoTrue, PostgREST and Mailpit.
- [ ] `packages/client_core` -- domain, adapter, controllers, help/sign-in-details/Admin screens, routes, review gate, fakes, tests; `apps/mobile`, `apps/staff` destinations and tests.
- [ ] `docs/runbooks/identity-access.md`, `evidence-2.8/README.md`, CI evidence scan, deferred-work entry.

**Acceptance Criteria:**
- Given the local stack, when `credentials.mjs` runs, then every matrix row passes against real GoTrue and leaves no synthetic rows.
- Given CI, when db:test, db:smoke, node tests, flutter analyze and test run, then all pass.

## Implementation Notes

## Plan Change Log

## Review Triage Log

## Verification

**Commands:**
- `npx supabase db reset && npm run db:test && npm run db:smoke` -- expected: pass
- `node tools/auth-harness/local-phone-auth.mjs on && node tools/identity-e2e/credentials.mjs --evidence …; node tools/auth-harness/local-phone-auth.mjs off` -- expected: all pass
- `flutter analyze && flutter test` in `packages/client_core`, `apps/mobile`, `apps/staff` -- expected: pass

---
title: 'Change credentials under review and hold access'
type: 'feature'
ticket: '8'
created: '2026-10-07'
status: 'done'
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
- [x] `supabase/migrations/20261007111436_credential_review.sql` -- tables (changes, review audit), hold columns, release-epoch trigger, 2.7 proposal guard, commands, authorizer, reads, grants; session/factor helpers as fail-closed stubs.
- [x] `supabase/migrations/20261007160100_credential_review_auth_rows.sql` -- the stubs replaced with the Auth row deletions only.
- [x] `supabase/tests/credential_review_test.sql`, allowlist, `identity_api_smoke.sh`.
- [x] `tools/identity-e2e/credentials.mjs` (+ `.test.mjs`) -- the verify bullet against local GoTrue, PostgREST and Mailpit.
- [x] `packages/client_core` -- domain, adapter, controllers, help/sign-in-details/Admin screens, routes, review gate, fakes, tests; `apps/mobile`, `apps/staff` destinations and tests.
- [x] `docs/runbooks/identity-access.md`, `evidence-2.8/README.md`, CI evidence scan, deferred-work entry.

**Acceptance Criteria:**
- Given the local stack, when `credentials.mjs` runs, then every matrix row passes against real GoTrue and leaves no synthetic rows.
- Given CI, when db:test, db:smoke, node tests, flutter analyze and test run, then all pass.

## Implementation Notes

- Built directly (no subagent tool in this session); checkpoint 1 pre-approved by the owner decisions. The plan is above the 1600-token guide because one Identity change spans the DB, two clients and evidence; kept whole, as 2.7 was.
- Files:
  - `supabase/migrations/20261007111436_credential_review.sql` (no `delete from`): `identity_credential_changes`, `identity_credential_review_audit`, hold columns, release-epoch trigger, 2.7 proposal guard trigger, member/Admin commands, `api.identity_credential_command`, `api.identity_my_credentials`, `api.identity_admin_credential_queue`, `identity_authorize_command` replaced (every earlier command kept), 2.7 `identity_recovery_email_other_changes` replaced to tolerate email identities of previously approved/reviewed addresses; fail-closed stubs `identity_revoke_auth_sessions` / `identity_remove_auth_extras`.
  - `supabase/migrations/20261007160100_credential_review_auth_rows.sql`: the two helpers with the Auth row deletions only.
  - Tests: `supabase/tests/credential_review_test.sql` (102); allowlist in `command_foundation_test.sql`; `identity_session_trust_test.sql` expectation (a release is now an event); `identity_api_smoke.sh` (+7).
  - E2E `tools/identity-e2e/credentials.mjs` (+ `.test.mjs`); live adapter check `tools/identity-e2e/live-credentials-check.sh` + `packages/client_core/tool/live_credentials_check.dart`.
  - client_core: `domain/credential_review.dart`, `adapters/supabase_credential_review_repository.dart`, `application/credential_controllers.dart`, `presentation/credential_screens.dart` (help screen, `AccessReviewGate`, sign-in details, Admin screen), routes and gate in `shell_routing.dart`, links in `account_screen.dart`, provider, composition, exports, fakes; `test/identity/credential_review_test.dart` (23).
  - Apps: staff `Access reviews` destination (Admin); mobile and staff shell tests.
  - Docs: runbook section (and the 2.7 carried-risk line), `evidence-2.8/`, CI evidence scan, two deferred-work entries.
- Decision (agent, under owner pre-approval): the help screen answers only `granted`/`review_required` and the church contact from the unset-by-default Q1 `operational_contact` setting; no reason is ever sent to the member.
- Decision (agent, under owner pre-approval): restore/accept also revoke every Auth session (the thief's included) besides moving the epoch; approve of any change revokes sessions too.
- Surprise: the sandbox disk filled up (ext4 reserved blocks) and hung the first flutter run; removed the unused excluded Docker images (studio, logflare; re-pullable) to continue.
- Environment: the stack was reset several times from this worktree; the phone switch was found off, on only for the E2E and live check, and is off again; every synthetic row, hook registration and caught message was removed.
- Owner and parent steps: staging apply of `20261007111436` (parent); `20261007160100` by hand (owner) — until then approvals, lost-device holds, restore and accept answer `unavailable` on staging. No Auth setting change. None blocks the build.
- Known residual risk (deferred-work): a stolen live session can still change the password via `PUT /user`; exits are the approved-email reset, staff-assisted recovery (entry 9) and a lost-device hold.

## Plan Change Log

- 2026-10-07, independent review (coordinator; not a step-04 loop). One HIGH, three MEDIUM, five LOW findings; all patched in place in `20261007111436` (both 2.8 files are on neither main nor staging; still no `delete from` in the main file, ASCII only).
  - **HIGH (takeover):** restore and the reverts left a reset link usable. New `app.identity_neutralise_auth_links`: recovery (overwritten with an unusable value, never cleared, so the 2.7 gate does not fire), confirmation, reauthentication and change tokens, in `auth.users` and `auth.one_time_tokens`. Called by approve, restore, accept, the replacement request and both reverts; the 2.7 `identity_revert_recovery_email` is replaced here by `create or replace`.
  - **MEDIUM 1 (fail-closed rule):** a password change since the last binding approval that was not preceded by the member's own email-link redemption is "unreviewed" (`app.identity_password_unreviewed`). Restore then keeps (or places) a security hold with `password_reset_required_since`; accept is refused `password_unreviewed`. A lost-device hold sets the same field. Such holds are released only after a member's own reset after that time (`app.identity_member_reset_since`: redemption then a new password), else `conflict {"hold_id": "password_reset_required"}`. Members without an approved email wait for entry 9.
  - **MEDIUM 2:** approve and accept refuse `conflict {"member_id": "held"}` while any hold is open; restore stays allowed.
  - **MEDIUM 3:** a new contract v1 lifecycle event `sessions_revoked` (SQL list, shared fixture, Dart enum and list, TypeScript list, cross-epic test) is dispatched with every session revocation in the same transaction. This supersedes the frozen-block decision "no new contract event" at the reviewer's instruction (which allowed "a dedicated event if cleaner"). Tests prove a raising hook rolls back the lost-device hold and the restore; the change-approval path dispatches the same way.
  - **LOW:** (a) held/in-review own reads (`identity_my_credentials`, 2.7 `identity_my_recovery_email` replaced) carry only access, contact and the own pending request id/revision/state; (b) withdraw (2.7 and 2.8) refused while held, via the replaced 2.7 withdraw authorizer; (c) accept needs `identity_email_recovery_open()` to bind an email; (d) a phone username is also taken by another account's pending `phone_change`; (e) pgTAP for the fail-closed stub path and for refresh tokens revoked on lost device.
  - **Avoids:** a pre-restore reset link reopening a hijacked account; a thief's password surviving a restore or a lost-device release; changes applied to held accounts; device registrations outliving revoked sessions; reviewed accounts leaking their approved details.
  - **KEEP:** the reviewed-change flow, the server-side Auth writes, the release epoch, the generic help screen.
  - **Found, not changed (reported):** the shared v1 contract allows only 11 field-error codes, so the real Dart client turns refusals with domain codes (2.5/2.7/2.8) into unknown outcomes.

## Review Triage Log

## Verification

**Commands:**
- `npx supabase db reset && npm run db:test && npm run db:smoke` -- expected: pass
- `node tools/auth-harness/local-phone-auth.mjs on && node tools/identity-e2e/credentials.mjs --evidence …; node tools/auth-harness/local-phone-auth.mjs off` -- expected: all pass
- `flutter analyze && flutter test` in `packages/client_core`, `apps/mobile`, `apps/staff` -- expected: pass
- Results (2026-10-07, local):
  - `db:test` 1098/1098 (credential review 102); `db:smoke` exit 0, 121 ok.
  - `credentials.mjs` 13/13; live adapter check C1–C4.
  - client_core 273 tests, staff 21, mobile 23; analyze clean in all three; format clean; staff `flutter build web --no-web-resources-cdn` ok.
  - Node tool tests 50/50; `ci:migrations --base ccr-93e730dd-89lbvg` (19, ordered, non-destructive); `ci:secrets` clean; `scan-evidence` on evidence-2.8 and `tools/identity-e2e` clean.
- Results after the review fixes (2026-10-07, local): `db:test` 1121/1121 (credential review 125); `db:smoke` exit 0 (121 ok, 224 fixture cases); `credentials.mjs` 15/15; regressions `run` 30, `grants` 18, `review` 18, `apply` 27, `cells` 13, `recovery` 20; live check C1–C4; client_core 274, staff 21, mobile 23, contracts Dart 244 and TS 227; analyze clean; node tool tests 50; `ci:migrations`, `ci:secrets`, `scan-evidence` clean.
- Matrix audit: phone change (pgTAP + E2E C10 + live C1–C2 + widgets), email replace (pgTAP + C20–C21), remove (pgTAP + C22), hold (pgTAP + C30–C32), lost device (pgTAP + C40–C41 + live C3–C4), stolen-session (pgTAP + C50), self/non-Admin (pgTAP + C10/C30 + widgets): every row has a passing test.

## Hosted verification

Staging apply and full function parity: `evidence-2.8/staging-verify.md`. Owner paste of `20261007160100` and device/staff-web scenarios: `owner-consolidated-test.md`.

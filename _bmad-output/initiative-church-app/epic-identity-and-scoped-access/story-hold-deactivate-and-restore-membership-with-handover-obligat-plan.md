---
title: 'Hold, deactivate and restore membership with handover obligations'
type: 'feature'
ticket: '10'
created: '2026-10-07'
status: 'done'
blocked_reason: ''
baseline_revision: '011ff888a7d6e9fee61d0cc4e09b2bf2ccae8d47'
route: 'full'
route_source: 'auto'
review: ''
review_source: ''
lenses_ran: []
review_loop_iteration: 0
context:
  - '{project-root}/_bmad-output/initiative-church-app/owner-decisions-milestone-1.md'
  - '{project-root}/docs/runbooks/identity-access.md'
  - '{project-root}/docs/runbooks/contracts-and-owner-seams.md'
  - '{project-root}/_bmad-output/initiative-church-app/epic-identity-and-scoped-access/story-change-credentials-under-review-and-hold-access-plan.md'
  - '{project-root}/_bmad-output/initiative-church-app/epic-identity-and-scoped-access/story-recover-access-with-staff-assistance-and-a-single-use-grant-plan.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** Identity has holds (2.8) but no login hold, no church deactivation and no reviewed restoration (I10, AD-14, AC-22). Nothing records handover obligations for later owners' work, and nothing stops an Admin from deactivating the last usable Admin or a last responsible staff member.

**Approach:** Login hold = a 2.8 hold of kind `login` placed through `identity.place_hold` (machinery reused, functions replaced in place). Deactivation and restoration are new Admin lifecycle commands that, in one transaction, deny access, revoke sessions, end grants and recovery grants, collect handover obligations from registered owner handover hooks, and dispatch lifecycle events; the clients get a staff web lifecycle screen and a mobile "membership not active" state.

## Boundaries & Constraints

**Always:** reuse `identity_access_evaluate`, 2.8 holds/`place_hold`/`release_hold`, `identity_revoke_auth_sessions`, `identity_end_grant` (2.3 path), `identity_usable_admin_count`, 2.9 `identity_recovery_end_grants`, `identity_dispatch_lifecycle`, the `identity` authorizer and 1.4 envelope. Migration later than `20261007160100`, ASCII only, no `delete from`, SECURITY DEFINER sets `search_path`, nothing to anon; replaced functions keep signature and privileges. Phones `+1 202 555 0100–0199` / `+44 7700 900000–900999`; emails `@example.test`. Local stack only.

**Decisions:**
- Decision (agent, under owner pre-approval): login hold: `identity.place_hold {member_id, reason_code: "login_disabled"}` -> hold kind `login`, stored with `reason = 'login_disabled'` and `reason_code` null (the 2.8 CHECK cannot be widened without a DROP); every Auth session revoked; `access_hold_applied` + `sessions_revoked`; refused for the last usable Admin (`forbidden {"member_id": "last_admin"}`); released with `identity.release_hold`. Membership, links, grants, cells and owner facts are untouched.
- Decision (agent, under owner pre-approval): `identity.deactivate_membership {member_id, reason_code}` (`member_request`, `moved_away`, `church_decision`; expected = member revision). Order: last-Admin check (before the self check, so a sole Admin deactivating themselves gets `last_admin`), self refused, approved only, owner handover hooks collected; any `last_responsible` obligation refuses with `conflict {"member_id": "handover_required"}` and writes nothing. Then: every grant ended (2.3 path), link `suspended` (epoch moves), every Auth session revoked, issued recovery grants ended (`cancelled`/`stale`), pending recovery operations `obsolete` (dispatched/uncertain ones and their holds stay), `membership_state = 'deactivated'`, obligations recorded `pending`, audit, `membership_deactivated` (+ `sessions_revoked`) dispatched. Cells memberships, holds and history are kept.
- Decision (agent, under owner pre-approval): `identity.restore_membership {member_id, identity_check}` by another Admin: `approved` again, link back to `active` (or `review_required` with a pending binding review), epoch moves (fresh sign-in), grants NOT restored, obligations stay pending, `membership_restored` dispatched.
- Decision (agent, under owner pre-approval): contract v1 gains `membership_deactivated` and `membership_restored` (SQL list, shared fixture, Dart, TS), following 2.8's `sessions_revoked` precedent; `account_deactivated` stays the unlink event.
- Decision (agent, under owner pre-approval): owner handover hooks: `app.identity_register_handover_hook(module, handler)`; handler `(jsonb lifecycle event) -> jsonb {"obligations": [{"kind", "subject_id", "last_responsible"}]}`, called in lock order; a malformed answer or missing handler raises (fail closed). Owners resolve with `app.identity_resolve_handover_obligation(module, obligation_id)`. Only SYNTHETIC fixture hooks (`app.fixture_report_handover`, `app.fixture_duties`) exist, registered only by tests/E2E.
- Decision (agent, under owner pre-approval): additive lifecycle events stay v1 (server-only consumers); 2.8 `sessions_revoked` and 2.10 `membership_deactivated`/`membership_restored` are covered.
- Decision (agent, under owner pre-approval): reads `api.identity_admin_membership_lifecycle()` (Admin: deactivated members with obligations, open login holds) and `api.identity_my_membership_status()` (trusted own session: `{deactivated, church_contact}`).

**Never:** full deletion (entry 11); restoring grants automatically; clearing a hold, an uncertain recovery operation or an obligation by deactivation or restore; blocking security holds (2.8) by handover; SMS; hosted applies.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Login hold | Admin holds member with two live sessions | both 401 at once; fresh sign-in `review_required`; membership, cell, fixture duty rows unchanged | last Admin -> `last_admin` |
| Deactivate | member with grants, sessions, fixture duty, issued recovery grant | sessions 401, grants ended, grant `cancelled`, obligation `pending`, fresh sign-in `not_linked` + status `deactivated` | hook raises -> nothing changes |
| Last responsible | fixture duty marked sole responsible | `conflict {"member_id":"handover_required"}`, nothing written | — |
| Last Admin | sole Admin deactivates self | `forbidden {"member_id":"last_admin"}` | — |
| Restore | deactivated member, identity check | approved, old sessions dead, fresh sign-in granted, no grants, obligations kept | not deactivated -> `conflict {"member_id":"not_deactivated"}` |
| Uncertain recovery | dispatched/uncertain op at deactivation | op and its hold stay | — |

</frozen-after-approval>

## Code Map

- `supabase/migrations/20261007111436_credential_review.sql` -- `identity_lock_reviewed_member`, `identity_place_hold` (replace both, same signatures), `identity_review_audit_add`, `identity_dispatch_lifecycle`, `identity_bump_member`, command endpoint pattern.
- `…/20261007140729_assisted_recovery.sql` -- `identity_recovery_end_grants`, `identity_recovery_audit_add`, operations table, latest `identity_authorize_command` (replace, keep every command).
- `…/20261007063340_membership_review.sql` -- unlink (last-Admin + end-grant loop pattern), `identity_member_account_label`, admin member search.
- `…/20261006234820_identity_grants.sql` -- `identity_end_grant`, `identity_usable_admin_count`, `identity_command_actor`, `identity_church_setting('operational_contact')`.
- `…/20261003134340_cross_epic_contracts.sql` -- `contract_validate_handler`, `contract_dispatch_lifecycle`, event list; `20261007075946` -- fixture lifecycle hook pattern.
- Contracts: `packages/contracts/fixtures/v1/lifecycle_event.json`, `dart/lib/src/{models,check}.dart`, `dart/test/fixtures.g.dart` (regenerate), `ts/contracts.ts`, `supabase/tests/cross_epic_contracts_test.sql`.
- Tests: `supabase/tests/credential_review_test.sql` helpers, `command_foundation_test.sql` allowlist, `identity_api_smoke.sh`; E2E helpers `tools/identity-e2e/credentials.mjs`.
- Clients: `packages/client_core` credential review files (domain/adapter/controllers/screens), `account_screen.dart`, `account_controllers.dart`, `shell_routing.dart`, `testing.dart`, `composition.dart`, providers; `apps/staff/lib/app.dart`, `apps/mobile/lib/app.dart` and their tests.

## Tasks & Acceptance

**Execution:**
- [x] `supabase/migrations/20261007151523_membership_lifecycle.sql` -- tables (lifecycle audit, obligations, handover hooks, fixture duties), events, hook registry, replaced hold functions, commands, reads, authorizer, grants.
- [x] contracts (fixtures, Dart, TS, cross-epic test) -- the two new v1 events.
- [x] `supabase/tests/membership_lifecycle_test.sql`, allowlist, smoke -- the matrix and privileges.
- [x] `tools/identity-e2e/lifecycle.mjs` (+ test) -- the verify bullet against local GoTrue/PostgREST.
- [x] `packages/client_core` + apps -- domain, adapter, controller, staff lifecycle screen, login-hold reason, mobile deactivated state, fakes, widget tests.
- [x] `docs/runbooks/identity-access.md`, `contracts-and-owner-seams.md`, `evidence-2.10/README.md`.

**Acceptance Criteria:**
- Given the local stack, when `lifecycle.mjs` runs, then every matrix row passes and no synthetic rows remain.
- Given CI, when db:test, db:smoke, node tests, contracts tests, flutter analyze and test run, then all pass; earlier identity E2Es still pass.

## Implementation Notes

- Built directly (no subagent tool in this session); checkpoint 1 pre-approved by the owner decisions. Above the 1600-token guide for the same reason as 2.7-2.9: one Identity change spans the DB, contracts, two clients and evidence.
- Files:
  - `supabase/migrations/20261007151523_membership_lifecycle.sql` (no `delete from`, ASCII only, every function pins `search_path`, nothing granted to anon): events, `identity_membership_lifecycle`, `identity_handover_hooks`, `identity_handover_obligations`, SYNTHETIC `fixture_duties` + `fixture_report_handover`; `identity_register_handover_hook`, `identity_collect_handover`, `identity_resolve_handover_obligation`, `identity_is_last_admin`, `identity_hold_reason_code`; replaced in place (same signatures, privileges re-revoked): `identity_lock_reviewed_member`, `identity_place_hold`, `identity_member_holds_json`, `identity_authorize_command` (every earlier command kept); commands on `api.identity_lifecycle_command`; reads `api.identity_admin_membership_lifecycle`, `api.identity_my_membership_status`.
  - Contracts: `fixtures/v1/lifecycle_event.json`, Dart `models.dart`/`check.dart` + regenerated `fixtures.g.dart`, TS `contracts.ts`, `cross_epic_contracts_test.sql`.
  - Tests: `supabase/tests/membership_lifecycle_test.sql` (76), allowlist in `command_foundation_test.sql`, `identity_api_smoke.sh` (+6); E2E `tools/identity-e2e/lifecycle.mjs` (+ `.test.mjs`).
  - client_core: `domain/membership_lifecycle.dart`, `adapters/supabase_membership_lifecycle_repository.dart`, `application/membership_lifecycle_controllers.dart`, `presentation/membership_lifecycle_screen.dart`, `HoldReason.loginDisabled` (+ kind fallback), `CredentialReviewNotice.lastAdmin`, route `/admin/membership-status` (gated), deactivated state on the account page, provider, composition, exports, fakes; `test/identity/membership_lifecycle_test.dart` (15). Apps: staff `Membership status` destination (Admin) + 2 tests; mobile 2 tests.
  - Docs/CI: runbook section, contracts runbook (events, handover hooks), `evidence-2.10/`, CI evidence scan, two deferred-work entries.
- Decision (agent, under owner pre-approval): restoration needs an identity check but any other Admin may restore (also the one who deactivated): requiring a second Admin could lock a one-Admin church out of the reviewed route.
- Decision (agent, under owner pre-approval): open recovery cases are left open at deactivation (their grants end; the 2.9 cancel reasons have no fitting value and widening the CHECK needs a DROP); a grant cannot be issued while the member is not approved (2.9 `not_approved`).
- Decision (agent, under owner pre-approval): pending 2.7/2.8 credential requests are left pending (approval already requires an approved member); Cells memberships and requests are kept as facts.
- Environment: the stack was reset from this worktree; the phone switch was found off, on only for the E2E runs, and is off again; no image pulled; every synthetic row and hook registration was removed.
- Owner and parent steps: parent applies `20261007151523` to staging. No owner-only step.

## Plan Change Log

- 2026-10-07, independent review (coordinator; not a step-04 loop). No HIGH; one MEDIUM, four LOW; all patched in place in `20261007151523` (still no `delete from`, ASCII only, `search_path` set, nothing to anon).
  - **MEDIUM (contract rule):** the contracts runbook said a new lifecycle event needs a new version. Amended: event names are additive within v1 while every consumer is a server-side registered hook; removing/renaming one or adding the first client-visible consumer needs a new version. Frozen-block decision recorded. New `client_core` boundary test fails if client or app code consumes lifecycle events (the shared Dart/TS packages carry the list for fixture parity only).
  - **LOW (deadlock):** deactivation, restoration and `place_hold` (replaced, latest 2.8 body) now lock the live link before the member (`app.identity_lock_payload_member_link`), the 2.9 order.
  - **LOW (login hold reason):** `identity_release_hold` (audit) and `identity_admin_credential_queue` replaced in place with their latest 2.8 bodies using `identity_hold_reason_code`; the queue's EXECUTE re-granted. pgTAP asserts both name `login_disabled`.
  - **LOW (last Admin):** the login-hold check is described as defence in depth (migration and runbook); `identity_is_last_admin` tested directly (two usable Admins, non-Admin, held Admin).
  - **LOW (tests):** E2E `L40` (the last two Admins deactivate each other in parallel: exactly one succeeds); pgTAP: dispatched assisted reset completed after deactivation is `uncertain`, hold kept, access denied; atomicity tests also assert grants, recovery grant state, `link_state` and obligations unchanged.
  - **Accepted:** restoring by the same Admin who deactivated (matches the ticket and the 2.8 release pattern; the identity check makes it reviewed).
  - **KEEP:** the handover-hook preflight, the one-transaction deactivation, the 2.9 recovery rules.

## Review Triage Log

## Verification

**Commands:**
- `npx supabase db reset && npm run db:test && npm run db:smoke` -- expected: pass
- `node tools/auth-harness/local-phone-auth.mjs on && node tools/identity-e2e/lifecycle.mjs --evidence …; node tools/auth-harness/local-phone-auth.mjs off` -- expected: all pass
- regressions `assisted`, `credentials`, `recovery`, `cells`, `review`, `grants`, `apply`, `run` -- expected: pass
- `flutter analyze && flutter test` in `packages/client_core`, `apps/mobile`, `apps/staff`; `dart test` in `packages/contracts/dart`; `npm run contracts:test` -- expected: pass
- Results (2026-10-07, local):
  - `db:test` 1320/1320 (membership lifecycle 76) after a fresh reset; `db:smoke` exit 0 (132 ok).
  - `lifecycle.mjs` 8/8 (`evidence-2.10/lifecycle-e2e.jsonl`); regressions `run` 30, `grants` 18, `apply` 27, `review` 18, `cells` 13, `recovery` 20, `credentials` 15, `assisted` 16.
  - client_core 326 tests, staff 24, mobile 26; analyze clean in all three; format clean; staff `flutter build web --no-web-resources-cdn` ok; contracts Dart 255 and TS pass.
  - Node tool tests 71/71, policy tests 49/49; `ci:migrations --base ccr-93e730dd-89lbvg` (22, non-destructive); `ci:secrets` clean; `scan-evidence` on evidence-2.10 and `tools/identity-e2e` clean.
- Results after the review fixes (2026-10-07, local): `db:test` 1330/1330 (membership lifecycle 86) after a fresh reset; `db:smoke` exit 0; `lifecycle.mjs` 9/9 (new `L40`); regressions `run` 30, `grants` 18, `apply` 27, `review` 18, `cells` 13, `recovery` 20, `credentials` 15, `assisted` 16; client_core 327, staff 24, mobile 26, analyze and format clean; contracts Dart 255, TS 238; node tool tests 71, policy 49; `ci:migrations` (22, non-destructive), `ci:secrets`, `scan-evidence` clean. Phone switch off again.
- Matrix audit: login hold (pgTAP + E2E L10/L11 + widgets), deactivate (pgTAP + L20 + widgets), last responsible (pgTAP + L21 + widget notice), last Admin (pgTAP + L01 + widget notice), restore (pgTAP + L30 + widget), uncertain recovery (pgTAP): every row has a passing test.

## Hosted verification

Staging apply, parity and API checks: `evidence-2.10/staging-verify.md`. Device and staff-web scenarios: `owner-consolidated-test.md`.

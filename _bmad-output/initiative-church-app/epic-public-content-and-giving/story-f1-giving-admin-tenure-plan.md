---
title: 'Require 14 days of Admin tenure for giving verification'
type: 'feature'
ticket: ''
created: '2026-10-22'
status: 'built'
baseline_revision: '938de3f75b9f022eda2432e9914d7e131f38b89f'
route: 'full'
route_source: 'auto'
review: ''
review_source: ''
lenses_ran: []
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/_bmad-output/initiative-church-app/epic-public-content-and-giving/codex-handoff-prompt.md'
  - '{project-root}/_bmad-output/initiative-church-app/epic-public-content-and-giving/story-publish-verified-giving-methods-and-show-how-to-give-to-gues-plan.md'
  - '{project-root}/docs/runbooks/content.md'
  - '{project-root}/docs/runbooks/contracts-and-owner-seams.md'
  - '{project-root}/docs/design-handoff/README.md'
  - '{project-root}/.agents/skills/design-taste-frontend/references/app-screens.md'
  - '{project-root}/.agents/skills/design-taste-frontend/references/tells.md'
warnings: []
deferred: []
---

<intent-contract>

## Intent

**Problem:** A recently granted Admin can verify a giving method immediately, weakening the second-Admin safeguard. The Verify dialog also does not show when the verifier became Admin or who granted that role.

**Approach:** Expose the current Admin's grant time and grantor through Identity's self-access projection, enforce a 14-day elapsed-time minimum in the server giving verify command, and show the grant context in the staff Verify dialog.

## Boundaries & Constraints

**Always:** Content uses Identity's registered self-read contract and never reads Identity tables directly; server enforcement is authoritative; expose only the verifier's own context; keep the existing verification saver rule and all widget keys.

**Never:** Change production policy gates, publish or notify on staging, disclose another member's grant context, or use the client clock as the authorization check.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Recent Admin | Active Admin grant less than 14 elapsed days old | Verify command refused; dialog shows Admin since date and grantor | Stable field error and plain staff explanation |
| Eligible Admin | Active Admin grant exactly 14 days old or older | Verify proceeds when all existing checks pass | Existing verification errors remain unchanged |
| Missing self context | Admin self-read has no active Admin grant metadata | Verify fails closed | Same tenure refusal; dialog explains context needs refresh |

</intent-contract>

## Code Map

- `supabase/migrations/20261006234820_identity_grants.sql` -- Identity owns `app.identity_my_access` and `app.identity_member_grants_json`; return tenure only from the self-read, not the Admin roster.
- `supabase/migrations/20261022011438_content_giving_methods.sql` -- `app.content_giving_verify` is the command handler; add a migration that updates this owner function and consumes Identity's self-read contract.
- `supabase/tests/identity_grants_test.sql` and `supabase/tests/content_giving_test.sql` -- extend the self-read contract and exercise under-14-day refusal plus the exact 14-day boundary.
- `packages/client_core/lib/src/domain/access_grants.dart` and `application/access_controllers.dart` -- parse the additive self-read field for the current actor.
- `packages/client_core/lib/src/presentation/giving_staff_screens.dart` -- `_VerifyDialog` already uses `myAccessProvider` patterns elsewhere; display the current verifier's tenure without changing existing keys.
- `packages/client_core/test/identity/grants_test.dart` and `test/content/content_giving_test.dart` -- cover the new wire shape and dialog copy.
- `tools/identity-e2e/content-giving.mjs` -- exercise a newly granted Admin refusal through the HTTP command path.
- `docs/runbooks/content.md` and `docs/runbooks/production-promotion-content.md` -- record the 14-day rule and the additive Identity contract migration.

## Tasks & Acceptance

**Execution:**
- [x] Add an ASCII-only migration that extends Identity's current-user projection with Admin grant timestamp, Lusaka grant date and grantor display name, then refuses giving verification until 14 elapsed days have passed.
- [x] Extend pgTAP, identity parser/widget tests and the content-giving HTTP E2E for refusal, eligibility boundary and verifier context.
- [x] Update the giving runbooks and record the decision to use an elapsed-time threshold, with the Lusaka date used only for display.
- [x] Complete an independent fresh-pass review against this plan and K16 before staging deployment.
- [x] Apply the migration verbatim to confirmed staging and verify function hashes and module guards.

**Acceptance Criteria:**
- Given an active Admin grant younger than 14 days, when the Admin verifies a different Admin's saved giving method, then the server refuses without changing the revision.
- Given an active Admin grant exactly 14 days old, when all existing verification checks pass, then the server records verification.
- Given an Admin opens Verify, when their active grant metadata is available, then the dialog shows “Admin since <date>, granted by <name>”.
- Given the fresh local reset, when pgTAP, the E2E and all four Flutter package checks run, then all pass without changing protected or public reads.

## Implementation Notes

Route: full, because this change crosses the Identity self-read contract, the giving server command, client parsing, staff UI and independent server/client checks.

Work on branch `epic6/f1-giving-admin-tenure`, based on `story/5.8-meetings-held`, then merge it back without pushing. The only permitted staging project is `tmurpotfluignacfueki`; its migration history was just confirmed at `20261022012809_content_rights_banners`. Re-list migrations before applying. Never use production. Do not send staging notifications.

## Plan Change Log

- 2026-10-22: Implemented F1 as an additive Identity self-access contract and a server-side 14 elapsed-day check for giving verification. The Lusaka grant date is display-only. Missing or malformed self-context fails closed; public reads and policy gates are unchanged.

## Review Triage Log

- Independent fresh-pass review against this plan and K16: PASS. The reviewer initially found that malformed display metadata could pass alongside an old grant timestamp. Fixed the helper to validate string fields, a real canonical Lusaka date matching the grant timestamp, and a parseable timestamp; added pgTAP cases for malformed values. Follow-up review passed with no remaining findings or deferred items.

## Verification

- Local database: `npx supabase db reset --local`, then `npx supabase test db` — PASS, 61 files / 4,961 tests; giving suite 183/183.
- HTTP E2E: `node tools/identity-e2e/content-giving.mjs --evidence _bmad-output/initiative-church-app/epic-public-content-and-giving/evidence-6.3/f1-giving-admin-tenure-e2e.jsonl` — PASS, 12/12. Offline E2E tests — PASS, 7/7.
- Flutter: `flutter analyze` and `flutter test` passed in `packages/design_system`, `packages/client_core`, `apps/mobile`, and `apps/staff`.
- Migration and hygiene: `node tools/ci/check-migrations.mjs --base origin/main` — PASS (69 migrations); `git diff --check` — PASS. Migration is ASCII-only and contains no backslashes.
- Independent review: fresh review of the implementation diff against this plan and K16 — PASS after the malformed-metadata fix.
- Staging (`tmurpotfluignacfueki`, confirmed `staging`): migration recorded as `20261022100601` / `f1_giving_admin_tenure`. Local reset and staging hashes match: `api.identity_my_access` `22c28650d7a8ba1e9bf9919713735481`; `app.identity_my_access` `f90ed5aeb6ec2ba9fafdd8a737838a36`; `app.content_giving_admin_tenure_eligible` `382cc887bc002b5b17a7af3ceb4ca5c3`; `app.content_giving_verify` `85f6fa143142ab4444b07f1fb90f554f`. `app.contract_boundary_violations()` = 0; `app.contract_unowned_objects()` = 0.
- Staging signed-out read, executed as `anon`: `api.content_public_giving_methods()` returned `{"sample":true,"methods":[],"truncated":false}`, matching the closed-gate staging expectation.

**Commands:**
- `npx supabase db reset --local` and `npx supabase test db` -- expected: full suite passes.
- `node tools/identity-e2e/content-giving.mjs --evidence <file>` and `node --test tools/identity-e2e/content-giving.test.mjs` -- expected: all cases pass.
- `flutter analyze` and `flutter test` in `packages/design_system`, `packages/client_core`, `apps/mobile` and `apps/staff` -- expected: clean and passing.
- `node tools/ci/check-migrations.mjs --base origin/main` -- expected: pass.
- Staging function hashes, `app.contract_boundary_violations()` and `app.contract_unowned_objects()` -- expected: hashes match local reset and both counts are zero.

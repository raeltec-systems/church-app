---
title: 'Do not require Q5 approval for church-owned images'
type: 'feature'
ticket: ''
created: '2026-10-22'
status: 'built'
baseline_revision: '17f0b7e7e349726b9cafeb33c433df8ba6a073bf'
route: 'full'
route_source: 'auto'
review: 'quick'
review_source: 'pinned'
lenses_ran: ['quick']
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/_bmad-output/initiative-church-app/epic-public-content-and-giving/epic-public-content-and-giving.md'
  - '{project-root}/_bmad-output/initiative-church-app/epic-public-content-and-giving/story-publish-home-banners-with-validated-images-through-the-publi-plan.md'
  - '{project-root}/docs/runbooks/content.md'
  - '{project-root}/docs/runbooks/production-promotion-content.md'
warnings: []
deferred: []
---

<intent-contract>

## Intent

**Problem:** Story 6.2 applies the Q5 source list to every image, including artwork the church owns. The owner decided that church-owned images do not need Q5 approval; only third-party material does.

**Approach:** Keep the verified rights record and its per-use clearance, but let a live `church_owned` record clear Q5's source-list check. Keep unlisted third-party sources fail-closed through both publication and public reads, and explain the exemption in the staff rights UI.

## Boundaries & Constraints

**Always:** Q5 remains required for every non-church-owned source; the rights record must be in force and explicitly clear the requested use; production Q5 gate and fixture stay unchanged; public reads recheck rights.

**Never:** Let a draft, withdrawn, archived or use-uncleared record pass; weaken third-party checks; approve a gate or add real church content on staging.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Church-owned use | Live `church_owned` record with the requested use cleared and a source absent from Q5 | Rights check and banner publication succeed | No Q5 approval required |
| Third-party use | Live non-church-owned record with source absent from Q5 | Rights check and banner publication remain refused | `source_not_cleared` |
| Uncleared use | Live `church_owned` record with requested use flag false | Rights check and publication remain refused | `use_not_cleared` |

</intent-contract>

## Code Map

- `supabase/migrations/20261022012809_content_rights_banners.sql` -- `app.content_rights_clear` owns the Q5 check; `content_banner_publish` and public-file desired/read helpers reuse it. Preserve verification and per-use checks.
- `supabase/tests/content_banners_test.sql` -- existing church-owned `synthetic` fixture and unlisted third-party cases; add an unlisted church-owned source and publication regression.
- `tools/identity-e2e/content-banners.mjs` and `.test.mjs` -- real HTTP command flow for banner rights and publication, with fictional identities only.
- `packages/client_core/lib/src/domain/content_banners.dart`, `presentation/banner_screens.dart`, and `test/content/content_banners_test.dart` -- explain the church-owned exemption in rights status and image selection.
- `docs/runbooks/content.md` and `docs/runbooks/production-promotion-content.md` -- correct the Q5 rule and deployment guidance; epic Notes carry the implementation decision.

## Tasks & Acceptance

**Execution:**
- [x] Add a migration updating only the registered rights check so a verified church-owned record bypasses Q5 while all use flags and lifecycle checks remain required.
- [x] Extend pgTAP and the content-banners HTTP E2E for unlisted church-owned success, unlisted third-party refusal and a church-owned uncleared-use refusal.
- [x] Update the existing staff rights labels, widget tests and runbooks to show Q5 is not required for church-owned content.
- [x] Apply verbatim to confirmed staging and compare changed function hashes, module guards and signed-out reads.

**Acceptance Criteria:**
- Given a verified church-owned banner image whose display flag is clear and whose source is not on Q5, when an editor publishes it, then the server accepts it and the signed-out public read can name it after sync.
- Given an otherwise identical third-party record whose source is not on Q5, when an editor publishes, then the server refuses with `source_not_cleared` and public reads keep it absent.
- Given a church-owned record with the requested use flag false, when a caller checks or publishes it, then the server refuses with `use_not_cleared`.
- Given the staff Banners or Rights screen, when an image uses a church-owned record, then its status says Q5 approval is not required.

## Implementation Notes

Route `full`: the server policy helper, public-file lifecycle, staff domain/UI, HTTP E2E, tests and operator guidance all need to stay aligned. The exemption is for the rights record's `church_owned` basis; it does not clear a use whose record flag is false.

The existing `app.content_rights_clear` function was replaced in place in migration `20261022102525_f2_church_owned_q5_exemption.sql`; no registry, fixture or gate value changed. The HTTP check uses only the local stack and cleans its synthetic users and Storage objects. The local phone-auth setting was restored after the run.

## Plan Change Log

## Review Triage Log

### 2026-10-22 — Review pass
- verdicts: 0 findings — high 0, medium 0, low 0, false 0, maybe-false 0
- findings: none

## Verification

**Commands:**
- `npx supabase db reset --local` -- passed; reset applied all local migrations through F2.
- `npx supabase test db` -- passed: 61 pgTAP files, 4,963 tests.
- `node --test tools/identity-e2e/content-banners.test.mjs` -- passed: 3/3 tests.
- `node tools/identity-e2e/content-banners.mjs --evidence evidence-6.2/f2-church-owned-images-e2e.jsonl` -- passed: 16/16 local HTTP checks; [evidence](evidence-6.2/f2-church-owned-images-e2e.jsonl).
- `flutter analyze` and `flutter test`: `packages/design_system` clean / 19 passed; `packages/client_core` clean / 886 passed; `apps/mobile` clean / 65 passed; `apps/staff` clean / 56 passed.
- `node tools/ci/check-migrations.mjs --base origin/main` -- passed: 70 migrations ordered, unique and non-destructive. `git diff --check` passed. Migration is ASCII-only with no backslashes.

**Staging checks (project `tmurpotfluignacfueki`):** Migration list confirmed latest `20261022102525_f2_church_owned_q5_exemption`, after the required `20261022012809_content_rights_banners`. Staging function hash `f6967934d6f108892ad7eaab8cd07600` matched the fresh local reset. `app.contract_boundary_violations()` = 0 and `app.contract_unowned_objects()` = 0. Both `q3_giving` and `q5_content_rights` remain `unresolved`; as anon, `api.content_public_banners()` returned `{"banners": [], "truncated": false}`. No staging content or notifications were created.

## Auto Run Result

Implemented the church-owned Q5 exemption while preserving the live rights lifecycle and per-use checks.

Files changed:
- `supabase/migrations/20261022102525_f2_church_owned_q5_exemption.sql` -- updates the registered rights helper in place.
- `supabase/tests/content_banners_test.sql` and `tools/identity-e2e/content-banners.mjs` -- cover absent-Q5 church-owned success, unlisted third-party refusal and uncleared-use refusal.
- `packages/client_core/lib/src/domain/content_banners.dart` and `presentation/banner_screens.dart` -- reflect the exemption in image eligibility and staff status copy.
- `packages/client_core/test/content/content_banners_test.dart` -- verifies the eligibility, basis display and refusal copy.
- `docs/runbooks/content.md`, `docs/runbooks/production-promotion-content.md` and `epic-public-content-and-giving.md` -- record the owner rule and operating checks.
- `evidence-6.2/f2-church-owned-images-e2e.jsonl` -- redacted local HTTP evidence.
- This plan -- acceptance, review and staging evidence.

Review findings: quick review reported 0 findings; no patches, deferred items or rejected findings. Follow-up review recommendation: false (0 patched findings).

Verification: fresh local database reset; full pgTAP 61 files / 4,963 tests; banner E2E 3/3 offline tests and 16/16 local HTTP checks; Flutter analyze clean and tests passed (design_system 19, client_core 886, mobile 65, staff 56); migration validation passed for 70 migrations; diff check passed. Staging project `tmurpotfluignacfueki` recorded version `20261022102525`, the changed function hash matched local, both module guards were 0, both policy gates remained unresolved, and signed-out banners were empty.

Residual risk: third-party material still requires Q5 approval; this migration does not change the production gate or add staging content. The reviewed diff will be committed on this feature branch and merged to `story/5.8-meetings-held` without pushing.

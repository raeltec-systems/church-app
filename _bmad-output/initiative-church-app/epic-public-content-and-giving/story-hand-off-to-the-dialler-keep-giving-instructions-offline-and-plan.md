---
title: 'Hand off to the dialler, keep giving instructions offline and warn about unsafe methods'
type: 'feature'
ticket: '5'
created: '2026-10-22'
status: built
baseline_revision: 'c664148a7b8e57b5f3cb153b6341453539b52c60'
route: 'full'
route_source: 'auto'
review: 'quick'
review_source: 'pinned'
lenses_ran: [quick]
review_loop_iteration: 0
followup_review_recommended: true
context:
  - '{project-root}/_bmad-output/initiative-church-app/epic-public-content-and-giving/epic-public-content-and-giving.md'
  - '{project-root}/_bmad-output/initiative-church-app/epic-public-content-and-giving/story-keep-published-public-content-readable-offline-with-honest-s-plan.md'
  - '{project-root}/docs/runbooks/content.md'
warnings: []
deferred: []
---

<intent-contract>

## Intent

**Problem:** Giving instructions require a network read, show no unsafe-method warning, and leave the starting USSD code as copy-only text. People can lose last-verified instructions offline or mistake an unsafe destination for normal guidance.

**Approach:** Add an Android dialler handoff that leaves instructions visible, cache the last public giving list for offline detail reads, and add an Admin-controlled unsafe flag surfaced in public and cached projections. Support an optional rights-checked provider logo through Content's existing asset path.

## Boundaries & Constraints

**Always:** Public reads stay anonymous and function-only; cache only published giving projections and eligible asset bytes in the mobile adapter; preserve verification date and honest offline/stale states; hide methods only after a successful fresh read; unsafe state sends no notification; keep SAMPLE giving data and production Q3 closed; reuse the command envelope and Content asset/right checks.

**Never:** Process or record a gift, claim payment success, store payer data, expose drafts or verifier details, use unapproved real destinations, add another persistence implementation, bypass asset rights, publish or push sample content on staging, or change production gates. iOS and unsupported handoff retain copyable code and manual steps; entry 15 checks device behavior.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Android handoff | Published mobile-money method has a valid starting code | Open external dialler; return to same instructions without a payment claim | If launch fails, keep code, copy action and manual steps available |
| Offline detail | Successful public list was cached, then the read fails | Show matching published instructions, verified date, unsafe warning if set, and offline label | Without a snapshot, keep unavailable state; never show a fresh-looking empty list |
| Hidden method refresh | Successful public list omits a cached method | Remove it so offline reads cannot resurrect it | Failed refresh retains prior snapshot as stale |
| Unsafe flag change | Admin sets or clears flag; device refreshes | Warning follows server state and updated snapshot | No push; failed refresh remains visibly stale |
| Optional logo | Published revision has a logo cleared for requested use | Show its revision-keyed logo; omit absent or ineligible assets | Rights or image failure leaves text usable |

</intent-contract>

## Code Map

- supabase/migrations/20261022011438_content_giving_methods.sql -- giving tables, Admin commands, public list/detail JSON and staff projection. Add method-level unsafe state and audited commands without changing revision verification.
- supabase/migrations/20261022012809_content_rights_banners.sql -- Content revision files, asset publication, rights checks and public-file helpers. Reuse this path for provider logos; add no giving-specific bucket.
- supabase/tests/content_giving_test.sql, command_foundation_test.sql, cross_epic_contracts_test.sql, and tools/identity-e2e/content-giving.mjs -- command permissions, public projection, unknown-key and local HTTP E2E coverage. Scope assertions to giving.
- packages/client_core/lib/src/domain/content_giving.dart -- strict public/staff wire models; application/giving_controllers.dart -- public readers and Admin commands; adapters/supabase_content_repository.dart -- RPC reads.
- packages/client_core/lib/src/domain/public_content_cache.dart -- current events/banner allowlist; application/content_controllers.dart -- save/fallback/reconcile pattern; apps/mobile/lib/offline/public_content_cache_adapter.dart -- sole file store. Staff keeps NoPublicContentCache.
- packages/client_core/lib/src/presentation/give_screens.dart -- public detail copy rows, steps, verified date and request states; giving_staff_screens.dart -- Admin actions and editor. Existing routes already exist.
- apps/mobile/lib/contact/url_contact_launcher.dart and pinned url_launcher -- external tel: pattern. Keep copy/manual flow on every platform.
- packages/client_core/test/content/content_giving_test.dart, public_content_cache_test.dart, apps/mobile/test/offline/public_content_cache_adapter_test.dart, and tools/identity-e2e/content-giving.test.mjs -- extend model, UI, cache, adapter and API coverage.
- docs/runbooks/content.md and docs/runbooks/production-promotion-content.md -- unsafe, logo-rights, offline-giving and owner manual-check guidance.

## Tasks & Acceptance

**Execution:**
- [ ] `supabase/migrations/` and `supabase/tests/` -- add audited Admin unsafe commands, public/staff fields and optional logo projection via registered Content asset helpers; test permissions, Q3 gate, anonymous shape and refusal paths.
- [ ] `packages/client_core/lib/src/domain/content_giving.dart`, `adapters/supabase_content_repository.dart`, `application/giving_controllers.dart` and tests -- parse unsafe/logo fields and extend cache fallback to the published list.
- [ ] `packages/client_core/lib/src/domain/public_content_cache.dart`, `application/providers.dart`, `content_controllers.dart` and `apps/mobile/lib/offline/public_content_cache_adapter.dart` -- allow published giving snapshots and offline-cleared logos; successful refresh evicts hidden methods and files.
- [ ] `packages/client_core/lib/src/presentation/give_screens.dart` -- add Android handoff, manual fallback, unsafe warning, optional logo and honest offline state with no payment-success state.
- [ ] `packages/client_core/lib/src/application/giving_controllers.dart` and `presentation/giving_staff_screens.dart` -- add Admin unsafe controls and notices without notification delivery.
- [ ] `tools/identity-e2e/content-giving.mjs` and `.test.mjs` -- cover unsafe visibility and hide reconciliation using SAMPLE values and local-only mutations.
- [ ] `docs/runbooks/content.md` and `docs/runbooks/production-promotion-content.md` -- record migration, owner manual checks, Android handoff limits and no-payment-claim rule.

**Acceptance Criteria:**
- Given a published SAMPLE mobile-money method with a starting code on Android, when the giver opens the dialler and returns, then the same instructions remain and the app makes no payment claim.
- Given cached published instructions, when connectivity is lost, then detail shows its verification date and offline label, plus the unsafe warning when applicable.
- Given a hidden method or changed unsafe flag, when a successful refresh completes, then offline reads reflect fresh state; failed refresh retains an explicitly stale last-good snapshot.
- Given a provider logo not cleared for the requested use, when its method is read, then omit the logo while keeping text usable.

</intent-contract>

## Implementation Notes

- The giving cache keeps the previous committed snapshot while refreshing, reuses byte-identical cached logos, removes hidden method assets only after a successful refresh, and bounds logo workers at four.
- Public asset reads use an abortable request, enforce the byte limit while streaming, and cancel the response subscription for rejected headers. A timeout and an oversized-header regression test cover both cleanup paths.
- The forward migration explicitly removes an open draft's logo file-slot association when the editor clears the logo.
- The staging identity validator is configured to permit real names for owner-led live testing. Build fixtures remain synthetic; production stays gated.


## Plan Change Log

- 2026-10-22: Added a forward migration for explicit logo clearing and hardened optional-logo caching after review. Added bounded four-worker fetch, abortable/size-limited HTTP streaming, and response cancellation on rejected headers after follow-up review. Staging permits ordinary member names by owner decision; production is untouched.


## Review Triage Log

### 2026-10-22 — Review pass
- verdicts: 5 findings — high 0, medium 5, low 0, false 0, maybe-false 0; all findings resolved and re-reviewed
- findings:
  - `[medium]` `[patch]` Clearing a logo on an existing giving draft left its file-slot row attached, allowing the staff projection and a later publication to show the logo again — Verified: the save path handled explicit null IDs but only called `content_file_attach` for a non-null asset. Added the forward logo-clear migration to delete only the open draft's `logo` slot when the request explicitly clears it; pgTAP verifies the row is removed and stays absent after publication.
  - `[medium]` Serial optional-logo downloads blocked the Give list refresh and the refresh removed the previous snapshot before downloading — Verified: the public read controller awaited cache persistence, the adapter fetched each eligible logo in a serial loop, and the old snapshot was cleared before fetch. The adapter now keeps the prior snapshot until commit, fetches eligible logos concurrently, and reuses unchanged cached bytes; a regression test covers concurrency, last-good availability, and reuse.
  - `[medium]` Launching one future per logo could start up to 50 image downloads and allocate a large amount of memory — Fixed with a four-worker pool and a regression test that asserts the active download ceiling.
  - `[medium]` `Future.timeout` did not cancel the HTTP request or stop a buffered body from remaining in flight, so timed-out logo reads could exceed the worker bound — Fixed with `http.AbortableRequest`, streamed byte-limit enforcement, cancellation on timeout, and a regression test for a timed-out response stream.
  - `[medium]` Rejected response headers (status, media type, or declared size) returned without cancelling the response stream — Fixed by cancelling the response subscription before aborting; a regression test verifies oversized responses trigger stream cancellation. Follow-up review confirmed the fix.


## Design Notes

Keep the Give detail hierarchy and place the safety message beside instructions and before-confirm guidance. The dialler action is secondary to copying the code and only opens an external intent. Offline status uses the existing semantic status component and preserves verifiedOn. Display-only logo bytes never enter the offline snapshot.

## Verification

**Commands:**
- npx supabase db reset --local then npx supabase test db -- fresh local schema and full pgTAP suite pass.
- node --test tools/identity-e2e/content-giving.test.mjs and local content-giving.mjs -- contract checks and synthetic API E2E pass; cleanup leaves no records.
- flutter analyze and flutter test in packages/design_system, packages/client_core, apps/mobile and apps/staff -- clean analysis and passing package suites.
- node tools/ci/check-migrations.mjs --base origin/main -- migrations are ASCII, ordered, unique and satisfy cleanup rules.
- Staging tmurpotfluignacfueki -- list migrations before applying; compare changed function hashes, check boundary/unowned counts are zero and verify signed-out projections.

## Auto Run Result

- Branch: `epic6/5-giving-dialler-offline-unsafe`, based on `story/5.8-meetings-held` at `d9b876eb`.
- PostgreSQL: fresh local reset and full pgTAP suite passed (5,021 tests). E2E contract tests passed (7) and local API E2E passed (14); E2E cleanup left no records.
- Flutter: `packages/design_system` (19), `packages/client_core` (905), `apps/staff` (56), and `apps/mobile` (77) passed; analysis was clean in all four packages.
- Migration checker: 78 ordered, unique migrations; 40 new since `origin/main`. `git diff --check` clean.
- Staging: latest versions `20261022153240` and `20261022154622`; required baseline `20261022012809_content_rights_banners` present before applying. Function hashes match, boundary and unowned-object counts are zero. Ordinary names validate on staging; `q4_personal_data` remains closed and production was not used.
- No SAMPLE giving method was published and no staging notification was sent. Owner manual test for dialler/offline/unsafe behavior still requires a SAMPLE method; stories 15 and 17 remain owner decisions.
- Android arm64 release APK built against staging at `apps/mobile/build/app/outputs/flutter-apk/app-arm64-v8a-release.apk`.

**Manual checks:**
- Android staging-configured emulator: open/return from dialler, copy fallback code, then read cached instructions offline and refresh after hiding/flagging SAMPLE methods. No staging notifications or real giving details.

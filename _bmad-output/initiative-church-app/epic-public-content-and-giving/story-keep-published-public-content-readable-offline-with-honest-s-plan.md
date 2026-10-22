---
title: 'Keep published public content readable offline with honest saved and withdrawn states'
type: 'feature'
ticket: '4'
created: '2026-10-22'
status: built
baseline_revision: 'f9fe3da7c916ca9a59b5b65e821a620d20a62501'
route: 'full'
route_source: 'pinned'
review: 'quick'
review_source: 'pinned'
lenses_ran: [quick]
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/_bmad-output/initiative-church-app/epic-public-content-and-giving/epic-public-content-and-giving.md'
  - '{project-root}/_bmad-output/initiative-church-app/architecture-church-app/architecture-church-app.md'
  - '{project-root}/docs/design-handoff/README.md'
  - '{project-root}/.agents/skills/design-taste-frontend/references/app-screens.md'
  - '{project-root}/.agents/skills/design-taste-frontend/references/tells.md'
warnings: []
deferred: []
---

<intent-contract>

## Intent

**Problem:** Home banners and Calendar events exist only in memory, so they disappear offline and can leave no honest indication of what was last saved. A cached withdrawal must be removed when a fresh public read observes it.

**Approach:** Add one mobile-only file cache for the allowlisted public Home banner and Calendar list reads, including only projections marked `offline_allowed` and their publication/rights revisions. Refresh and reconcile it on reconnect, and label saved or offline content with its last successful save time.

## Boundaries & Constraints

**Always:** Keep public reads anonymous and function-only; never persist protected domain records; check server-provided offline rights for every banner and its image; retain only the two list reads this story allowlists; staff web keeps a no-op cache; preserve Home/Calendar design tokens and existing navigation; display-only content stays online under the unresolved Q5 rule.

**Never:** Cache event detail, staff reads, drafts, giving records, private uploads or non-offline-cleared banner images; use a browser/service-worker cache; claim an empty result after a failed first read; send staging notifications or use production.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|----------------------------|----------------|
| Online public read | Calendar/banner list includes offline-cleared and display-only rows | Show the complete public result; persist only `offline_allowed` rows and revision metadata; cache eligible banner bytes | A failed image fetch omits that banner from the offline snapshot; online content remains visible |
| Offline after save | Network read fails; valid snapshot exists | Show only saved public rows and images, with saved/offline state and timestamp | Retain a visible refresh-failed notice; never present it as a fresh server read |
| First read fails | Network read fails; no snapshot exists | Show the existing unavailable/error state, not an empty list | Retry remains available |
| Reconnect after withdrawal or rights change | Fresh server list omits an item or marks it not offline-allowed | Replace the snapshot and evict its old revision files | If refresh fails, keep the prior snapshot clearly marked saved/stale |
| Unsupported or protected read | Caller requests a key outside the allowlist or submits a non-public row | Cache refuses it; no file or manifest entry is written | Return a typed refusal without weakening the online read |

</intent-contract>

## Code Map

- `supabase/migrations/20261021233523_content_events_tracer.sql` and `supabase/migrations/20261022012809_content_rights_banners.sql` define the anonymous JSON projections. Add `offline_allowed` to both; events are church-authored, while banners require the live rights record to clear `offline` through `app.content_rights_clear`. Banner JSON already carries both revisions.
- `packages/client_core/lib/src/domain/content_events.dart` and `content_banners.dart` parse public projections; add the flag and safe JSON mapping. `supabase/tests/content_events_test.sql` and `content_banners_test.sql` own pgTAP expectations for signed-out reads and public shapes.
- `packages/client_core/lib/src/application/content_controllers.dart` and `banner_controllers.dart` use `PublicReadController`; add cache fallback/save metadata only to the two list controllers. `src/application/providers.dart` is the cache port seam; `composition.dart` is shared by mobile and staff.
- `packages/client_core/lib/src/adapters/supabase_banner_repository.dart` builds the public object URL and owns HTTP access; reuse that URL to fetch only eligible banner image bytes. Event detail and all staff reads remain unchanged.
- `apps/mobile/lib/main.dart` is the mobile composition root. Add one file-backed adapter at `apps/mobile/lib/offline/public_content_cache_adapter.dart`; `apps/staff` must keep the no-op implementation. Pin the storage package and format in the plan notes and mobile lockfile.
- `packages/client_core/test/boundaries_test.dart` currently forbids persistence beyond Auth/recovery stores; expand its scan to permit only the new mobile adapter. `home_banners.dart` and `calendar_screens.dart` own the existing public surfaces and already distinguish failed reads from empty results.
- `tools/identity-e2e/content-events.mjs`, `content-banners.mjs` and their `.test.mjs` files are the local API-level patterns. Add focused offline/cache unit coverage without staging content or notification delivery.

## Tasks & Acceptance

**Execution:**
  - [x] Add and test offline eligibility fields in the two anonymous Postgres projections, filtering banner eligibility through current rights; do not touch another module's data.
  - [x] Add an allowlisted cache port, immutable JSON manifest plus revision-keyed image files under mobile Application Support, and reconnect refresh. Keep the adapter mobile-only and staff web no-op; reject unknown reads and rows not explicitly eligible.
  - [x] Use cache fallback for Calendar and Home, evict withdrawn/hidden/revised banner files after successful refresh, and show saved/offline timestamp labels using existing BIC Kafue components and copy.
  - [x] Extend boundary, model, controller, adapter and E2E coverage for rights rejection, unsupported reads, withdrawal eviction, offline fallback and first-read failure.
  - [x] Record the storage/package choice in this plan and the epic Notes; add the migration and owner manual check to both content runbooks.

**Acceptance Criteria:**
- Given a successful staging public read, when the app goes offline, then Calendar and Home show only eligible saved items with their last saved time.
- Given a withdrawn or newly ineligible banner, when reconnect refresh succeeds, then the item and its revision files are removed from the local snapshot.
- Given an unsupported read or protected/non-eligible projection, when the adapter is asked to persist it, then it refuses and writes nothing.
- Given a signed-out app, when public cache contents are inspected, then they contain only allowlisted public projections and eligible image files.

## Implementation Notes

- The hosted migration version is `20261022123202_content_public_offline_rights.sql`; it replaces only the current public JSON projections and leaves all grants and Q5 gate values unchanged.
- Pinned dependencies are `path_provider 2.1.6` and `connectivity_plus 7.3.2`. Only `apps/mobile/lib/offline/public_content_cache_adapter.dart` imports persistence APIs; staff web gets `NoPublicContentCache`.
- The adapter removes a read's old manifest entry before writing a successful new server snapshot. If local I/O fails during replacement, the app may lose that offline snapshot, but it cannot later read the observed-withdrawn or newly ineligible old projection. A failed server refresh leaves the last valid snapshot untouched.
- Tests use the existing content event and banner local E2E scripts for public contract/rights behavior, plus dedicated client controller, widget, HTTP adapter, file adapter and persistence-boundary tests for offline behavior. No staging rows or notifications were created.

## Plan Change Log

- 2026-10-22: Reused the existing `content-events` and `content-banners` E2E scripts instead of introducing a third script; together with the new mobile/client cache tests, they cover the planned server and cache paths.
- 2026-10-22: Aligned the migration filename and runbooks to the version recorded by staging (`20261022123202`).

## Review Triage Log

### 2026-10-22 — Review pass
- verdicts: 1 finding — high 0, medium 1, low 0, false 0, maybe-false 0
- findings:
  - `[medium]` `[patch]` Keep an earlier in-memory public list after a failed refresh when the disk snapshot is unavailable — preserved the last successful result, `asOf`, `savedAt`, and `offlineSnapshot` after a cache miss; added a regression test that clears the cache and fails the next network read, then verified the prior value and timestamps remain.

## Design Notes

Use a versioned JSON manifest and binary images in the mobile app's private Application Support directory, via pinned `path_provider`; keep the single persistence implementation in mobile code so Flutter Web receives no local cache. Use `connectivity_plus` only as a reconnect signal, and still treat request failures as authoritative because network presence does not guarantee internet access. Key banner files by banner id, publication revision and rights revision; a successful replacement is the withdrawal/rights-change eviction boundary. The current Home/Calendar screens already follow the design handoff, so this change adds a single saved/offline line using their existing typography and semantic status component rather than redrawing either screen.

## Verification

**Commands:**
- `npx supabase db reset --local` followed by `npx supabase test db` -- passed after a fresh local reset (4,988 pgTAP tests).
- `node --test tools/identity-e2e/content-events.test.mjs tools/identity-e2e/content-banners.test.mjs` -- passed (9/9).
- Local API E2Es `content-events.mjs` and `content-banners.mjs` -- passed (10/10 and 16/16); synthetic local data and Storage objects were removed.
- `flutter analyze` and `flutter test` in `packages/design_system`, `packages/client_core`, `apps/mobile`, and `apps/staff` -- all analyze passes cleanly; all 19, 894, 70 and 56 tests passed, respectively.
- `node tools/ci/check-migrations.mjs --base origin/main` -- passed (72 migrations ordered and unique, with existing approved cleanup markers accounted for).
- Staging project `tmurpotfluignacfueki`: migration `20261022123202` applied; all five relevant function hashes matched fresh local reset; Content boundary/unowned/exposed-table counts were zero; signed-out event and banner projections returned zero rows and correct eligibility shape.

**Manual checks:**
- Owner check still due: on an Android staging-configured emulator, load Calendar/Home, disable network, confirm saved labels and cached banner image, then reconnect and confirm both lists refresh. Use only synthetic content, never publish a notification, and do not claim withdrawals are removed until a successful reconnect read observes them. Automated local coverage and staging public-read checks passed; physical/emulator airplane-mode behavior was not run in this session.

## Auto Run Result

- **Summary:** Added an allowlisted mobile file cache for public Calendar and Home banner list projections, with server-provided offline eligibility, image revision/right checks, honest saved/offline states, reconnect refresh, and safe withdrawal eviction. Staff web keeps the no-op cache. The quick review's one medium finding was patched; nothing was deferred or rejected. One medium patch was applied, so no follow-up review is recommended.
- **Files changed:**
  - `_bmad-output/initiative-church-app/epic-public-content-and-giving/epic-public-content-and-giving.md` — records entry 4 decisions and notes.
  - `_bmad-output/initiative-church-app/epic-public-content-and-giving/story-keep-published-public-content-readable-offline-with-honest-s-plan.md` — records implementation, review triage, and verification.
  - `_bmad-output/initiative-church-app/epic-public-content-and-giving/evidence-6.4/content-events-e2e.jsonl` — records the synthetic public-events API run.
  - `_bmad-output/initiative-church-app/epic-public-content-and-giving/evidence-6.4/content-banners-e2e.jsonl` — records the synthetic banners and rights API run.
  - `_bmad-output/initiative-church-app/epic-public-content-and-giving/evidence-6.4/local-verification.md` — records local reset and verification evidence.
  - `_bmad-output/initiative-church-app/epic-public-content-and-giving/evidence-6.4/staging-verify.md` — records staging migration and projection checks.
  - `supabase/migrations/20261022123202_content_public_offline_rights.sql` — adds offline eligibility to public event and banner projections.
  - `supabase/tests/content_events_test.sql` — checks event eligibility and projection contracts.
  - `supabase/tests/content_banners_test.sql` — checks banner offline eligibility against current rights.
  - `packages/client_core/lib/src/domain/public_content_cache.dart` — defines the allowlisted cache port and snapshot types.
  - `packages/client_core/lib/src/application/content_controllers.dart` — saves and restores Calendar snapshots and preserves prior results after failed refreshes.
  - `packages/client_core/lib/src/application/banner_controllers.dart` — saves eligible banners and their cached image bytes.
  - `packages/client_core/lib/src/application/providers.dart` — wires the cache and reconnect signal into public reads.
  - `packages/client_core/lib/src/domain/content_events.dart` — parses event offline eligibility.
  - `packages/client_core/lib/src/domain/content_banners.dart` — parses banner eligibility, truncation, and cached bytes.
  - `packages/client_core/lib/src/adapters/supabase_banner_repository.dart` — supplies public banner image reads to the cache adapter.
  - `packages/client_core/lib/src/presentation/calendar_screens.dart` — shows the Calendar saved/offline state.
  - `packages/client_core/lib/src/presentation/home_banners.dart` — shows cached banner images and Home saved/offline state.
  - `packages/client_core/lib/church_client_core.dart` — exports the public cache contract.
  - `packages/client_core/lib/testing.dart` — exposes cache test doubles.
  - `packages/client_core/test/content/public_content_cache_test.dart` — tests cache fallback, rights filtering, and failed refresh retention.
  - `packages/client_core/test/content/content_events_test.dart` — tests event eligibility and UI states.
  - `packages/client_core/test/content/content_banners_test.dart` — tests banner eligibility, image bytes, and UI states.
  - `packages/client_core/test/content/banner_adapter_test.dart` — tests public banner image fetching for cache persistence.
  - `packages/client_core/test/boundaries_test.dart` — permits the single mobile persistence adapter and protects other boundaries.
  - `apps/mobile/lib/offline/public_content_cache_adapter.dart` — implements the versioned file-backed mobile cache.
  - `apps/mobile/test/offline/public_content_cache_adapter_test.dart` — tests snapshot files, image eviction, and manifest replacement.
  - `apps/mobile/lib/main.dart` — wires mobile-only persistence and connectivity hints.
  - `apps/mobile/test/mobile_app_test.dart` — allows the specific offline adapter at the persistence boundary.
  - `apps/mobile/pubspec.yaml` — pins the mobile path and connectivity packages.
  - `apps/mobile/pubspec.lock` — locks resolved mobile dependencies.
  - `tools/identity-e2e/content-events.mjs` — verifies public event projection and rights behavior locally.
  - `tools/identity-e2e/content-events.test.mjs` — checks event E2E offline contract assertions.
  - `tools/identity-e2e/content-banners.mjs` — verifies public banner rights and image behavior locally.
  - `tools/identity-e2e/content-banners.test.mjs` — checks banner E2E contract assertions.
  - `tools/auth-harness/local-phone-auth.mjs` — uses a Windows-compatible timer when toggling local phone auth.
  - `docs/runbooks/content.md` — documents cache behavior and the entry 4 owner manual check.
  - `docs/runbooks/production-promotion-content.md` — records the migration and production promotion checks.
- **Verification:** A fresh local reset applied migration `20261022123202`; pgTAP passed (62 files, 4,988 tests); the focused review regression passed (4 tests); Node contract tests passed (9/9); local content E2Es passed (events 10/10, banners 16/16); Flutter analysis was clean and tests passed (design system 19, client core 894, mobile 70, staff 56); migration checker passed (72 ordered/unique migrations). Staging `tmurpotfluignacfueki` still has `20261022123202` latest; all five public projection function hashes match the fresh local reset; boundary and unowned-object counts are 0; exposed Content tables are 0. Signed-out staging list reads returned zero rows, with no staging content or notifications created.
- **Residual risk / owner step:** Complete the Android staging-configured emulator airplane-mode check recorded under **Manual checks** above using synthetic content.

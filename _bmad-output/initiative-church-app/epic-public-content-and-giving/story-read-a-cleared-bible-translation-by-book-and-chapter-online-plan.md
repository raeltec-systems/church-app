---
title: 'Read a cleared Bible translation by book and chapter, online and offline'
type: 'feature'
ticket: '6'
created: '2026-10-23'
status: built
baseline_revision: 'fd15fe2b73bd3a865d6f7af971d6c62e3b485be2'
route: 'full'
route_source: 'auto'
review: 'quick'
review_source: 'pinned'
lenses_ran: [quick]
review_loop_iteration: 3
followup_review_recommended: false
context:
  - '_bmad-output/initiative-church-app/epic-public-content-and-giving/codex-handoff-prompt.md'
  - '_bmad-output/initiative-church-app/spec-church-app/functional-requirements.md'
  - '_bmad-output/initiative-church-app/spec-church-app/design-contract.md'
  - 'docs/design-handoff/README.md'
warnings: []
deferred:
  - summary: >-
      Physical phone acceptance remains due in the entry 15 pilot.
    evidence: |-
      Staging has published WEB across 66 books and 1,189 chapters with offline clearance, and 14 signed-out HTTP checks pass. Local KJV/WEB fixture navigation, private-draft and display-only checks pass. Physical translation switching and reopening a saved chapter after relaunch in airplane mode have not been witnessed by this agent. No production clearance is implied.
    location: >-
      docs/runbooks/content.md, Story 6.6 owner manual check
    severity: medium (unverified)
---

<intent-contract>

## Intent

**Problem:** Guests and pending applicants cannot read Bible chapters in the app. Translation text must stay unpublished until display rights clear, and cached chapters must additionally have offline rights.

**Approach:** Add Bible translations to the shared Content lifecycle, install a bundled source-checked WEB package into a private draft, and expose only rights-cleared chapter projections. Add a Bible reader to the Bible & Hymns tab and a typed offline-cache path that requires explicit offline clearance. The owner chose WEB as the staging candidate; Q5 production approval remains separate.

## Boundaries & Constraints

**Always:** Reuse the Content command, publication and rights helpers. Keep draft/import state private and revisioned. Public reads are anonymous-safe. WEB publication and public/offline reads must match a verified public-domain eBible.org rights revision. KJV and WEB are staging verification sources; Q5 still blocks production distribution. Preserve the cache rule that already-downloaded copies cannot be remotely erased.

**Never:** Replace shared Content lifecycle or rights functions, grant client table access, cache display-only text, expose unpublished translations, or imply Q5 production clearance.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Valid import | Staff selects the bundled eBible.org WEB package; source references match the trusted manifest | A private, complete draft revision is available to editors | Progress and completion state remain truthful across chunked requests |
| Invalid import | Missing/duplicate verse, invalid book/chapter/verse or empty text | Import is rejected with row/field feedback; no partial revision is publishable | Keep the current published translation and prior draft rows intact |
| Display rights | Draft translation has display-cleared rights | Authorized editor can publish; anonymous chapter reads return only the published projection | Refuse publication and keep the translation invisible if clearance is absent |
| Offline rights | Published chapter has offline clearance, or does not | Offer/save/download only when cleared; saved chapters remain readable offline | No download/cache write when offline clearance is absent |
| Navigation | Last chapter in a book or a translation without that chapter | Previous/next follows canonical book order and selected translation | Disable unavailable direction and explain unavailable chapter |
</intent-contract>

## Code Map

- `supabase/migrations/20261021233523_content_events_tracer.sql` -- reuse `app.content_command`, lifecycle helpers, and kind/command/erase-part registries; do not replace shared dispatch.
- `supabase/migrations/20261022012809_content_rights_banners.sql` -- use `app.content_rights_clear(rights_id, use)` for display publication and offline eligibility.
- `supabase/tests/content_events_test.sql` and `content_banners_test.sql` -- copy scoped lifecycle, privilege, projection, and rights test patterns into Bible-specific pgTAP coverage.
- `packages/client_core/lib/src/adapters/bible_package_source.dart`, `apps/staff/assets/bible/engwebp_vpl.txt`, and `apps/staff/pubspec.yaml` -- load the owner-selected WEB package from the staff app bundle; keep the image file picker scoped to banners and do not ask Bible editors to upload CSV.
- `packages/client_core/lib/src/presentation/content_screens.dart`, `banner_screens.dart`, and `banner_controllers.dart` -- reuse staff Content layout, command-state handling, and explicit publish actions.
- `packages/client_core/lib/src/presentation/shell_routing.dart` and `apps/mobile/lib/app.dart` -- add Bible reader routing and the Bible & Hymns tab between Home and Give.
- `packages/client_core/lib/src/domain/public_content_cache.dart` and `apps/mobile/lib/offline/public_content_cache_adapter.dart` -- add a typed chapter key/projection, strict allowlist validation, and offline-rights checks.
- `packages/client_core/test/content/`, `apps/mobile/test/offline/public_content_cache_adapter_test.dart`, `apps/mobile/test/mobile_app_test.dart`, and `tools/identity-e2e/content-events.mjs` -- extend unit, adapter, navigation, and staging HTTP E2E coverage.

## Tasks & Acceptance

**Execution:**
- [x] Add a Bible translation migration, private revision/verse storage, bounded import commands, rights-aware publication and anonymous chapter reads; add `supabase/tests/content_bible_test.sql` for validation, revision preservation, lifecycle, rights, RLS/privileges, and signed-out projections.
- [x] Replace the staff-facing CSV picker with a bundled, source-checked WEB install flow. Validate against the trusted manifest, send bounded revision-scoped batches, and leave incomplete imports private and unpublishable. Keep the CSV parser utility for future approved packages, but do not require staff to download or format files.
- [x] Add Bible domain/repository/controller/read screen, route it from the new Bible & Hymns tab, and implement book/chapter/cleared-translation selection, chapter heading, numbered 18px/1.6 verses, and previous/next navigation.
- [x] Extend the public-content cache with a validated Bible chapter projection and offline-rights gate; wire providers, fakes, and package exports as needed.
- [x] Enforce the WEB source-rights match in database publication and public/offline projections; add a pgTAP regression that rejects an unrelated church-owned record.
- [x] Add a local HTTP E2E script for KJV and WEB imports/publication, anonymous visibility, denied offline rights, and translation/book-boundary navigation. Staging signed-out REST reads are verified; the interactive phone flow remains an owner manual check and redacted evidence will be recorded after it.

**Acceptance Criteria:**
- Given the bundled WEB source, when an editor installs it with a matching public-domain rights record, then the complete translation is a private draft and an anonymous reader cannot see it.
- Given a re-import, when the editor starts a new revision, then the earlier draft rows are preserved and no rows are deleted.
- Given a translation without display clearance, when an editor publishes it, then publication is refused and anonymous chapter reads remain empty.
- Given a WEB draft or published revision, when its rights record does not identify the World English Bible and cite eBible.org as a public-domain source, then publication and public/offline reads fail closed even if another record clears display.
- Given a published translation with display clearance, when a signed-out phone opens a book and chapter, then it reads the published verses and can switch to another cleared translation.
- Given an offline-cleared chapter, when a user downloads it and goes offline, then the saved chapter remains readable; given display-only rights, then no download is offered and the cache rejects the projection.
- Given the last chapter of one book, when the reader advances, then it opens the next available book in canonical order; unavailable chapters never appear as blank text.

## Implementation Notes

Review loop 1 requirements for re-derivation; the intent contract above is unchanged:

- Re-import always opens the next revision after `last_revision_no`; preserve prior draft and published verse rows.
- A translation may omit a canonical chapter. Expose only chapters present in its complete published revision, and navigate to the next available chapter in canonical order.
- A present chapter is complete only when its verses match the trusted, version-specific chapter verse-count manifest and are contiguous from verse 1. Seed supported KJV and WEB counts; refuse imports for a translation code without a registered manifest. Keep the manifest data versioned and test a missing terminal verse.
- Offline reader startup must recover an offline-cleared saved chapter after a cold launch with no network. Persist enough validated index data to restore its translation, book, chapter and saved time; show a truthful offline state and keep online catalog reads separate.
- Bible editors follow epic requirement K1: Media, Pastor and Admin.
- Render verse numbers as accent superscripts in the body text.
- The official WEB VPL source contains five intentionally blank slots (Luke 17:36; Acts 8:37, 15:34, 24:7; Romans 16:25). Version the omissions in the trusted manifest, preserve their verse numbers, and never invent text for them.
- WEB display and offline decisions must match a verified public-domain rights revision identifying the World English Bible and citing eBible.org; enforce this in database command/read boundaries as well as the staff candidate filter.
- WEB display and offline decisions must match a verified public-domain rights revision identifying the World English Bible and citing eBible.org; apply this rule in the database at publish and public projection boundaries, not only in the staff candidate filter.
- Reuse one verified eBible.org source record for WEB across installs. The public-domain basis does not require a licence or permission, while the explicit display and offline flags keep app uses clear. Explain this as one-time setup in the staff flow.
- The local HTTP E2E remains local-only. Staging verification is a separate signed-out E2E run and must leave redacted evidence.

Changed-file inventory:

- Mobile reader/tab/cache: `apps/mobile/lib/app.dart`, `apps/mobile/lib/offline/public_content_cache_adapter.dart`, `apps/mobile/test/mobile_app_test.dart`, `apps/mobile/test/offline/public_content_cache_adapter_test.dart`.
- Staff navigation: `apps/staff/lib/app.dart`, `apps/staff/test/staff_app_test.dart`.
- Shared Bible domain, repository, controllers, reader/install screens, package source, provider wiring, exports and test fakes: `apps/staff/assets/bible/engwebp_vpl.txt`, `apps/staff/pubspec.yaml`, `packages/client_core/lib/church_client_core.dart`, `packages/client_core/lib/composition.dart`, `packages/client_core/lib/src/adapters/bible_package_source.dart`, `packages/client_core/lib/src/adapters/supabase_bible_repository.dart`, `packages/client_core/lib/src/application/bible_controllers.dart`, `packages/client_core/lib/src/application/providers.dart`, `packages/client_core/lib/src/domain/content_banners.dart`, `packages/client_core/lib/src/domain/content_bible.dart`, `packages/client_core/lib/src/domain/public_content_cache.dart`, `packages/client_core/lib/src/presentation/bible_screens.dart`, `packages/client_core/lib/src/presentation/shell_routing.dart`, `packages/client_core/lib/supabase_adapters.dart`, `packages/client_core/lib/testing.dart`, `packages/client_core/test/content/bible_test.dart`.
- Database, source and E2E coverage: `supabase/migrations/20261023020507_content_bible_translations.sql`, `supabase/migrations/20261023020509_content_bible_staff_read_gate.sql`, `supabase/migrations/20261023033756_content_bible_manifest_registry.sql`, `supabase/migrations/20261023100446_content_bible_web_omitted_verses.sql`, `supabase/migrations/20261023120311_content_bible_web_source_rights_guard.sql`, `supabase/tests/content_bible_test.sql`, `tools/content/build_web_bible_package.py`, `docs/content-sources/world-english-bible.md`, `tools/identity-e2e/content-bible.mjs`, `tools/identity-e2e/content-bible.test.mjs`.

Verification completed (2026-10-26):

- Fresh local replay of all 85 migrations passes. The full pgTAP suite passes all 5106 assertions across 64 files. Every test file ran exactly once; timing fixtures ran first, with no assertions, thresholds or application code changed to accommodate timing. Earlier alphabetical runs exposed pre-existing load-sensitive Duties timings; the ordered fresh run passed them.
- Focused Bible pgTAP: 83/83, including unknown/incomplete manifest responses, source matching, publisher-only deletion references and anonymization of all four attribution columns.
- Full Flutter analysis is clean in all four packages. Actual test cases pass: client_core 929, mobile 81, staff 59, design_system 19; these counts exclude hidden harness/load events. Focused Bible regressions pass 22/22.
- Local HTTP E2E: 7/7; helper tests: 5/5. Fictional UK accounts are removed and the cleanup read confirms 0 remain; phone auth is restored to its original off state. Evidence: `evidence-6.6/local-bible-20261026.jsonl`.
- Staging `tmurpotfluignacfueki` records all six Bible migrations through `20261026151013_content_bible_review_hardening.sql`. All 28 relevant function hashes match fresh local; boundary and unowned-object counts are 0. Q3, Q4 and Q5 remain unresolved.
- Existing published staging WEB has 66 books, 1,189 chapters and offline clearance. Fourteen signed-out HTTP checks pass, recorded without tokens or verse text in `evidence-6.6/staging-public-read-20261026.jsonl`. This agent published no staging content, changed no rights record or policy gate, sent no notification and accessed no production.
- Both staging-only release builds pass. The staff preview returns HTTP 200 at `http://127.0.0.1:8767/`; the Android arm64 APK is `apps/mobile/build/app/outputs/flutter-apk/app-arm64-v8a-release.apk` (25.1 MB).
- Migration ordering/ASCII/destructive-statement checks and `git diff --check` pass. Independent review found four defects; all were fixed, tested and rechecked with no remaining actionable findings.

Remaining owner device verification:

- Entry 15's physical-phone pilot must witness translation switching and saving/reopening a cleared chapter after app relaunch in airplane mode. Local tests and staging HTTP evidence are not presented as physical-device acceptance.

## Design Notes

The full Bible is too large for a single command payload. Keep import rows revision-scoped and private while bounded batches arrive; only a server-finalized complete revision may be published. Validate the bundled source against the trusted manifest before sending batches. Staff no longer need a CSV download or editor; the parser remains useful for future approved package tooling. Shape the tab so Entry 7 can add the Hymn book segment without changing Bible routing or cache semantics.

## Verification

**Commands:**
- `flutter analyze` and `flutter test --reporter=json` in each of `packages/client_core`, `apps/mobile`, `apps/staff`, and `packages/design_system` -- expected: clean analysis and all tests pass.
- `npx supabase db reset --local` then `npx supabase test db --local` -- expected: the fresh migration chain, including the WEB rights source guard, applies and all pgTAP files pass.
- `node --test tools/identity-e2e/content-bible.test.mjs` -- expected: local E2E helper tests pass.
- `node tools/auth-harness/local-phone-auth.mjs on`, `node tools/identity-e2e/content-bible.mjs`, then `node tools/auth-harness/local-phone-auth.mjs off` -- expected: local signed-out Bible flow passes and phone auth is restored to off.
- `node tools/ci/check-migrations.mjs --base origin/main` -- expected: migrations are ASCII-only, ordered, unique and free of unapproved destructive statements.

**Manual checks:**
- On staging, import and publish a synthetic KJV fixture using its verified synthetic rights record. WEB publication must use a verified public-domain eBible.org record with matching display clearance; an unrelated church-owned record must fail with `source_mismatch`. Then use a signed-out phone to select a chapter, switch translations, cross a book boundary, and reopen an offline-cleared saved chapter after relaunching with the network off. Confirm a translation lacking offline rights has no download action and an unpublished one is invisible. Record the redacted steps and observed results. Staging schema and signed-out empty reads are verified; the interactive check remains due.

## Plan Change Log

### 2026-10-23 — Review loop 1

- Trigger: independent review found the importer can publish truncated chapters and the offline reader cannot recover a saved chapter when launched without network access.
- Amended: implementation notes now require translation-specific chapter verse counts, partial-corpus support, next-revision semantics, cold-start cache recovery, the K1 editor-role matrix, superscript styling, and separate local versus staging E2E steps.
- Known-bad state avoided: a revision declared complete solely because its submitted rows match a client-provided total, and a cold-start offline reader that fails before looking in local storage.
- KEEP: preserve private revision-scoped batches, the shared Content registries and rights checks, anonymous-only projections, the explicit offline-rights cache gate, and the full existing unit/security coverage.

### 2026-10-23 — Review loop 2

- Trigger: independent review found that only KJV and WEB can be imported because the database constraints and client validators hardcode those two codes, despite the implementation notes requiring any translation with a registered trusted manifest to be supported.
- Amended: implementation notes now state that KJV and WEB are only the seeded staging manifests; the data model and client validation must accept other syntactically valid translation codes only when a complete trusted manifest is registered for them. Preserve display and offline rights checks and the unresolved Q5 production gate.
- Known-bad state avoided: an owner-cleared translation with a complete trusted manifest remaining impossible to register or import because its code is absent from a hardcoded allowlist.
- KEEP: preserve private revision-scoped batches, the shared Content registries and rights checks, anonymous-only projections, the explicit offline-rights cache gate, the full existing unit/security coverage, KJV and WEB as public-domain staging fixtures only, fail-closed display/offline rights, truthful read-error states, and the existing cached chapter after a failed refresh. Do not approve Q5, publish staging Bible text, or send staging notifications.

### 2026-10-23 — Owner-selected WEB staging package

- Trigger: the owner chose eBible.org's World English Bible as the built-in staging candidate after reviewing the staff CSV import screen.
- Amended: the staff flow now installs the bundled, source-checked WEB VPL as a private draft and attaches a matching eBible.org rights record; display publication and offline use remain separately gated.
- Known-bad state avoided: asking church staff to source and format a Bible CSV, or treating an import choice as production rights approval.
- KEEP: retain all five source-declared omitted verse slots without inventing text, keep Q5 unresolved for production, and do not publish Bible text or send staging notifications.

## Review Triage Log

### 2026-10-23 — Review pass

- verdicts: 7 findings — high 0, medium 5, low 1, false 0, maybe-false 1
- findings:
  - `[medium]` `[patch]` Re-import collides with the current draft revision — the staff controller calls `beginRevision` for existing translations, while `content_item_draft_no` returns the existing draft number and the Bible revision insert has no conflict handling. The clean re-derivation must allocate a new revision and retain old rows.
  - `[medium]` `[patch]` Missing canonical chapters are rejected — the parser and finalizer require all 66 books even though the intent matrix explicitly covers a translation without a chapter. The clean re-derivation must expose only available chapters and preserve canonical navigation.
  - `[medium]` `[bad_plan]` A truncated chapter can be finalized — the parser and finalizer accept a contiguous sequence ending at any verse, and the pgTAP fixture treats one verse per chapter as complete. The plan change adds trusted, version-specific chapter counts and requires a new incomplete-tail test.
  - `[medium]` `[bad_plan]` Cold-start offline recovery is unreachable — reload returns after the online translation request fails and the cache exposes only keyed reads, so a relaunched reader cannot discover a saved chapter. The plan change requires a persisted lookup/index and a cold-start offline test.
  - `[medium]` `[patch]` Pastor editors are blocked — epic K1 and the functional permission matrix allow Pastor or Admin to manage church content, but the Bible registry and navigation admit only Admin and Media. The clean re-derivation must honor the existing Content role model.
  - `[maybe-false]` `[defer]` Staging E2E evidence is outstanding — the script is local-only, while the plan calls for a separate signed-out staging flow. Running that staging flow and recording redacted evidence will settle whether the manual check covers the requested staging E2E.
  - `[low]` `[patch]` Verse numbers are inline rather than superscript — the design handoff requires accent superscripts; the current 12px inline span is visibly different. The clean re-derivation must use superscript placement.

### 2026-10-23 — Review pass

- verdicts: 5 findings — high 0, medium 4, low 0, false 0, maybe-false 1
- findings:
  - `[medium]` `[patch]` Chapter read failures look like unavailable chapters — `bible_screens.dart:167` ignores the controller's recorded chapter error and displays the unavailable-chapter message for failed reads; re-derive a truthful read-error state.
  - `[medium]` `[patch]` Staff catalog failures look like an empty catalog — `bible_screens.dart:565` handles access denial but treats `AccessReadFailed` as no translations; re-derive a truthful load-error state.
  - `[medium]` `[bad_plan]` Translation codes are hardcoded to KJV and WEB — SQL constraints and client validation prevent registering/importing any other code even with its own complete trusted manifest; amended implementation notes require extensible codes bound to a registered manifest.
  - `[medium]` `[patch]` Replacing an offline chapter can erase the prior copy on write failure — `public_content_cache_adapter.dart:423` removes the saved read before committing its replacement; re-derive replacement so a failed save preserves the already-cleared copy.
  - `[maybe-false]` `[defer]` Staging phone acceptance remains outstanding — carried from the prior triage row; interactive staging editor publication and signed-out phone checks remain owner manual verification.

### 2026-10-23 — Review pass

- verdicts: 4 findings — high 0, medium 2, low 0, false 1, maybe-false 1
- findings:
  - `[medium]` `[patch]` An empty catalog hides an offline-saved Bible chapter — `BibleReaderController._start` clears the restored projection after a successful empty catalog read; retain and label the cached chapter while the device copy remains stored, per the intent contract.
  - `[false]` `[reject]` The final manifest-registry migration lacks full-chain pgTAP verification — a fresh `npx supabase db reset --local` replayed the complete chain including the manifest-registry migration, and `npx supabase test db --local` passed all 64 files and 5,082 tests, including `content_bible_test.sql`.
  - `[maybe-false]` `[defer]` Staging phone acceptance remains outstanding — no authenticated staging editor imported synthetic chapters and no signed-out physical phone tested chapter reading, translation switching, navigation, and cold-start offline reopening; the owner's walkthrough will settle the acceptance criterion.
  - `[medium]` `[patch]` The staging runbook says already-applied migrations are pending — `docs/runbooks/content.md` tells the owner to hand-apply 20507 and 20509 as well as 20510, while staging migration history records 20507 and 20509; the runbook should identify only 20510 as pending.
- Follow-up patch resolution: the empty-catalog offline snapshot and regression test are in place; both content runbooks now show the verified staging state and hosted manifest-registry version `20261023033756`. The physical staging phone acceptance remains deferred.

### 2026-10-23 — Review pass

- verdicts: 4 findings — high 0, medium 3, low 0, false 0, maybe-false 1
- findings:
  - `[medium]` `[patch]` WEB could publish under an unrelated display-cleared rights record — database publication and public/offline projections now require a verified public-domain record that identifies WEB/World English Bible and cites eBible.org; pgTAP covers a rejected church-owned mismatch.
  - `[medium]` `[patch]` A failed refresh could label a memory-only chapter as saved offline — the reader now confirms the exact chapter exists in persistent storage before showing the saved state, and names an unsaved in-memory copy honestly.
  - `[maybe-false]` `[defer]` Physical staging phone acceptance remains outstanding — carried from the existing staging walkthrough defer; no new duplicate defer was added.
  - `[medium]` `[defer]` The latest WEB source-rights migration lacks fresh local pgTAP/hash verification — Docker Desktop's Linux engine pipe is absent, and the prepared migration remains unapplied to staging pending the owner's decision.
- Follow-up patch resolution: focused Bible tests pass 18/18; full Flutter analysis is clean and all four package suites pass (982 client_core, 86 mobile, 60 staff, 21 design_system). Staging migration history was confirmed read-only through `20261023100446`; the local source-rights migration has not been applied there. Full pgTAP and live staging verification remain outstanding.
  - Subsequent staging action: after the owner authorized the staging apply, Supabase recorded `20261023120311_content_bible_web_source_rights_guard`; the local migration filename was renamed to match. Read-only staging checks show 0 boundary violations, 0 unowned objects, an empty anon translation list, and a null unknown chapter. The local full-chain pgTAP/hash comparison and owner phone demonstration remain outstanding.
### 2026-10-23 — Review pass

- verdicts: 1 finding — high 0, medium 1, low 0, false 0, maybe-false 0
- findings:
  - `[medium]` `[patch]` Published WEB projections lacked regression coverage for a live rights-source change — the earlier test rejected a mismatched rights record before publication but did not exercise a previously published translation. Added a case in `supabase/tests/content_bible_test.sql` that changes the live revision, checks display/offline `source_mismatch`, expects an empty public catalog and a null chapter projection; the reviewer confirmed the new assertions close the gap. The pgTAP test remains unrun because Docker Desktop's local PostgreSQL engine is unavailable.


### 2026-10-26 - Resumed review and verification

- Resolved the prior environment deferrals: Docker is available; a fresh local reset replays the complete migration chain, and all 28 Bible/staging-phone function hashes match staging. The previously load-sensitive Duties scale test passes in the current full suite without changing its threshold.
- The first fresh run exposed the omitted-verse migration's missing null-manifest guard and stale test setup that tried to create WEB twice. The additive hardening migration restores the API contract; the regression fixture now repairs the first WEB draft into a new revision and verifies all prior rows remain. The HTTP fixture now uses a matching eBible.org public-domain source record and the current public projection fields.
- Existing staging content now includes published WEB. This run performed only read-only public-content verification; it did not install or publish staging text, approve Q3/Q5, change rights records, send a notification, or access production.
- Automatic approval review initially rejected the connector migration after confusing ordinary staging migrations with owner-only `_rows` files. The handoff's explicit connector authorization and the absence of row deletion were checked; the same connector then accepted the verbatim migration. Hosted version: `20261026151013`.
- Current client analysis is clean in all four packages. Full Flutter test cases pass: client_core 929, mobile 81, staff 59, design_system 19 (these exclude hidden harness/load events). Focused Bible regressions pass 22/22. E2E helper tests pass 5/5; the local HTTP run passes 7/7; signed-out staging HTTP checks pass 14/14. Final full-chain database and release-build results are recorded below when complete.

### 2026-10-26 - Review pass

- verdicts: 4 findings - high 1, medium 3, low 0, false 0, maybe-false 0
- findings:
  - `[high]` `[patch]` Publication attribution survived account deletion - the hardening migration clears and counts both saved and published member/account columns; the pgTAP fixture isolates publication-only attribution and asserts both anonymized publisher columns.
  - `[medium]` `[patch]` An offline reader could not resume browsing - the controller listens to the existing reconnect signal and the screen offers an online retry while keeping the saved copy readable.
  - `[medium]` `[patch]` A slow save could label another chapter or account as saved - completion is checked against the original read epoch and account generation, with a navigation-during-write regression.
  - `[medium]` `[patch]` Withdrawn translations required re-import to republish - staff now exposes Publish for a withdrawn live revision without a draft; archived and incomplete-draft cases stay unavailable.
- Recheck: the independent reviewer inspected all four fixes and reported no remaining actionable findings. Follow-up review recommendation: false after the successful recheck.


## Auto Run Result

Implemented the bundled WEB draft installer, registered complete translation manifests and source omissions, rights-gated public chapter reads, Bible tab and canonical navigation, and the single allowlisted mobile chapter cache. Recovery now refreshes on reconnect, retains the selected reference on reload and prevents obsolete save confirmations. Staff can republish a withdrawn live revision; account deletion anonymizes both draft and publication attribution.

The changed-file inventory above covers the implementation. The final additional migration is `20261026151013_content_bible_review_hardening.sql`; focused controller/screen and SQL tests cover its corrections. Owner feedback in this same branch also includes grouped staff navigation, event date/time pickers, full-width Home banners, and the already-staged real-phone membership exception with clearer field feedback. Automated data remains synthetic.

Review: 4 patches (1 high, 3 medium); independent recheck found no remaining actionable finding. Prior environment/hash/security-regression deferrals are resolved. The single remaining deferral is physical phone acceptance in entry 15. Follow-up review recommendation: false after the successful recheck.

Verification: pgTAP 64 files/5106 assertions; local HTTP 7/7; helper tests 5/5; staging public HTTP 14/14; Flutter 929/81/59/19 and clean analysis; both release builds; 28 identical function hashes; boundary/unowned counts 0. The prior timing failures are recorded above rather than omitted. No owner-only `_rows` file is due for this entry.

---
title: 'Publish and browse sermons with the YouTube player and safe notes'
type: 'feature'
ticket: '9'
created: '2026-10-26'
status: in-progress
baseline_revision: '7eb4f866864806ff7baefcb23f2c351786bd93f8'
route: 'full'
route_source: 'auto'
review: 'quick'
review_source: 'pinned'
lenses_ran: []
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '_bmad-output/initiative-church-app/epic-public-content-and-giving/codex-handoff-prompt.md'
  - '_bmad-output/initiative-church-app/epic-public-content-and-giving/epic-public-content-and-giving.md'
  - 'docs/design-handoff/README.md'
warnings: [oversized]
deferred: []
---

<intent-contract>

## Intent

**Problem:** Guests and members cannot browse or watch published sermons in the app, and Media has no series/sermon editor.

**Approach:** Register sermon series and sermons in Content's revisioned lifecycle, offer published-only browse/search and a staff editor, add the fifth mobile tab and a privacy-enhanced YouTube player, and retain eligible public lists in the existing offline cache.

## Boundaries & Constraints

**Always:** Media, Pastor and Admin edit through `api.content_command`; anonymous reads exclude drafts, editor identities and private provenance. Reuse existing registries, file pipeline, rights checks and single cache adapter. Notes use the epic's restricted Markdown: paragraphs, headings, emphasis, lists and exact-host HTTPS links; reject HTML, embedded images and unsupported link forms. Preserve the last published revision until replacement. Store only public offline-eligible projections; failed reads stay visibly failed/stale. Synthetic fixture names and fictional UK E2E phones only. Record every migration and owner check.

**Never:** Replace shared lifecycle/dispatch/deletion helpers, grant client table access, persist protected records or YouTube media, poll YouTube from the server, send a staging notification, approve policy gates or access production. Audio is entry 10; creating duty-sourced drafts is entry 18. This staff list must accept all normal sermon drafts without filtering by creator/source.

## I/O & Edge-Case Matrix

| Scenario | Input / state | Expected outcome | Failure handling |
|---|---|---|---|
| Publication | Valid editor draft and cleared attached uses | Current published revision is anonymously readable | Incomplete/uncleared drafts remain private |
| Notes | Supported Markdown or HTML/image/unsafe URL | Supported notes render; unsupported/unsafe input is refused by server | Field error preserves editor input |
| Video | Valid ID; private/removed/unreachable video | Embedded player or unavailable message, with scripture/notes readable | Errors never replace the detail page |
| Offline | Last public catalog, then network loss | Saved-time label, local title/series/speaker filtering | No cache becomes an honest failure; successful refresh evicts withdrawn rows |
| Series | Published series withdrawn while sermons remain published | Series title/poster disappear from public sermon projections; sermon teaching remains readable | Never leak private series metadata |

</intent-contract>

## Code Map

- `supabase/migrations/20261021233523_content_events_tracer.sql`: register `sermon_series`/`sermon` kinds, commands and erase parts; reuse `content_command_actor`, item open/lock/draft/save/publish/withdraw/archive/outcome helpers. Revision tables need immutable publication guards and saved/published attribution anonymization.
- `supabase/migrations/20261022012809_content_rights_banners.sql`, `20261022102525_f2_church_owned_q5_exemption.sql`: register `sermon_series_poster` in `content_asset_purposes`; reuse rights/file attach/public-file/sync helpers. Existing `supabase/functions/content-assets/index.ts` is purpose-driven and should need no replacement.
- `packages/client_core/lib/src/application/content_controllers.dart`: subclass `PublicReadController` for canonical public catalog/detail. `banner_controllers.dart`: reuse `StaffCatalogController`, command reconciliation and asset sync. Its private screen frame is a reference, not an export.
- Add domain `content_sermons.dart`, adapter `supabase_sermons_repository.dart`, controller `sermon_controllers.dart`, public/staff sermon screens and a presentation-only player-builder seam. Wire `providers.dart`, `composition.dart`, `church_client_core.dart`, `supabase_adapters.dart`, `testing.dart`.
- `public_content_cache.dart` and `apps/mobile/lib/offline/public_content_cache_adapter.dart`: extend the single strict allowlist/interface/default/fake with a canonical sermon-list snapshot; never overwrite it with a filtered search result. Strict serializers reject private/extra fields; serialize writes and preserve prior cache on failure.
- `shell_routing.dart`, `apps/mobile/lib/app.dart`, `apps/staff/lib/app.dart`: add root/detail/editor routes, Sermons between Bible and Give, Content navigation and detail back-bar behavior. Update exact-order assertions in both app test files without losing existing keys.
- `apps/mobile/lib/main.dart` and new `sermons/youtube_sermon_player.dart`: platform implementation of the shared presentation builder, pinned player dependency and controller/error lifecycle. Shared tests use a fake player and import no platform plugin.
- `supabase/tests/content_banners_test.sql`: scope broad negative-list assertions to its own kinds; `command_foundation_test.sql` needs additive public endpoints. New sermon tests should assert only their own grants/registrations.

## Tasks & Acceptance

**Execution:**
- Implementation delegation writes code and runs targeted local checks; the parent completes full verification, staging application, independent review, status changes and Git finalization. Leave implementation uncommitted for that review.
- [ ] `supabase/migrations/*_content_sermons.sql` -- create with CLI, add series/sermon revisions, input validation, publication/rights/asset commands, bounded public/staff reads and all-four-column attribution erase parts. No row deletes; migrations ASCII with no backslashes.
- [ ] `packages/client_core/lib/src/{domain,adapters,application,presentation}/*sermon*.dart` -- typed strict models, safe Markdown render/link handling, complete staff forms/poster picker/lifecycle actions, public filters/search/detail and retry/stale/offline states.
- [ ] Mobile composition/player/pubspec/lock and both shells -- real privacy-enhanced player plus fifth tab, editor permission navigation and safe detail back bars.
- [ ] Existing cache interface/adapter/fakes -- eligible canonical catalog and posters, publication/rights revisions, safe refresh replacement and withdrawal eviction; no thumbnail/video download without offline clearance.
- [ ] SQL, HTTP helper/live E2E, Flutter/core/app/cache tests and operations/promotion runbooks -- cover the matrix, role/read/table boundaries, stale revisions, rights changes and deletion attribution. Keep automated fixtures synthetic.

**Acceptance Criteria:**
- Given draft/revised/withdrawn/archived sermons and three editor roles, when anonymous/Pending/member callers read or edit, then only current published projections are public and all unauthorized commands/table reads are refused.
- Given two published synthetic series and sermons, when a signed-out user chooses Latest/Series/Speaker or searches a title, then the correct public rows open into readable notes, scripture and the embedded player.
- Given script/image markup, unsafe schemes, disguised hosts, reference links or unallowlisted HTTPS URLs, when notes are saved, then server validation refuses them and no unsafe link reaches the renderer/cache.
- Given a video error or no network, when detail opens, then a clear player state leaves notes readable; given a saved catalog, then offline browsing is labelled with its saved time and reconnect refresh removes withdrawn content.
- Given deleted save/publish actors, when Content's registered erase/check runs, then no attribution remains in either new revision table.

## Implementation Notes

- Full-route delegation: the implementing coordinator owns client domain/adapters/controllers/screens, cache, routing, player/dependencies and Flutter tests. Its two focused children own migration/SQL tests/scoped SQL assertions and HTTP/helper tests/runbooks respectively. All changes remain uncommitted until the coordinator returns, the parent verifies, and independent review completes.

## Plan Change Log

## Review Triage Log

## Design Notes

Use the established church palette, Outfit/Figtree typography and grouped rows. The main question is "Which sermon shall I watch/read?" A current-series poster hero leads, followed by the three filter pills and 16:9 rows. Detail keeps the player separate from scripture/notes. Staff asks what to publish next, with explicit draft/live revisions and human rights labels.

Carry forward the owner's form feedback: sermon dates use a date picker. The video field accepts a pasted HTTPS YouTube watch/shorts/embed/youtu.be link or an existing ID; client normalization produces the strict ID sent to the server. Rights selectors display record names rather than requiring UUID entry.

Choose `youtube_player_iframe: 6.0.2`, verified from current official package docs, with `privacyEnhancedMode: true`, no autoplay and error fallback; read installed pinned source before using its API. Keep that plugin only in mobile. Notes remain church-authored; attached posters and video uses cite existing verified rights records, and production third-party use still follows Q5. A missing/withdrawn video clearance omits the playable ID while leaving church-authored notes readable. Drafts allow incomplete video/speaker data for entry 18; publication validates required title/speaker/date/scripture and any supplied series/video. Withdrawing a series hides only its public metadata/poster; published sermons remain readable without that series metadata. Notes initially allow exact HTTPS hosts `ebible.org`, `biblegateway.com`, `www.biblegateway.com`, `youtube.com`, `www.youtube.com`, `youtu.be`; no userinfo or alternate ports. Reject reference/autolink/HTML/image Markdown paths instead of guessing how they render. Use readable notes input with formatting help; never require JSON entry.

## Verification

- Fresh local reset, then the full pgTAP suite (all files exactly once, timing fixtures first to control the observed local test-order sensitivity); migration checker; zero boundary/unowned counts. Never weaken timing assertions.
- New local HTTP sermon E2E and its offline helper tests; existing contracts and relevant Content regressions.
- Clean analysis and full Flutter tests in all four packages; format only changed Dart files. Build staging staff web and Android arm64 release.
- Before staging apply, list migrations on `tmurpotfluignacfueki` and confirm `20261022012809`. Apply verbatim; rename to hosted version, compare every new/changed function hash, check boundaries and signed-out reads. No notification or policy approvals.
- Independent quick review and recorded triage. Physical playback, unavailable-video and offline device checks belong in the entry 15 pilot if a physical device cannot be exercised here; record what is actually verified, without claiming that API/widget tests prove device playback.

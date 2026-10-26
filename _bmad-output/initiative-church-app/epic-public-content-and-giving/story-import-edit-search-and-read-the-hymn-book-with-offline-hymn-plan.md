---
title: 'Import, edit, search and read the hymn book with offline hymn text'
type: 'feature'
ticket: '7'
created: '2026-10-26'
status: 'in-progress'
baseline_revision: '7eb4f866864806ff7baefcb23f2c351786bd93f8'
route: 'full'
route_source: 'auto'
review: ''
review_source: ''
lenses_ran: []
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '_bmad-output/initiative-church-app/epic-public-content-and-giving/codex-handoff-prompt.md'
  - '_bmad-output/initiative-church-app/epic-public-content-and-giving/story-read-a-cleared-bible-translation-by-book-and-chapter-online-plan.md'
  - '.agents/skills/design-taste-frontend/references/app-screens.md'
  - 'docs/design-handoff/README.md'
warnings: ['oversized']
deferred: []
---

<intent-contract>

## Intent

**Problem:** Guests and members cannot find or read hymns in the app, and Media has no way to load, correct or publish a hymn book. Hymn text is third-party material until proven otherwise, so it must stay private until its rights clear display, and only offline-cleared hymns may be stored on a phone.

**Approach:** Add hymns as a new Content kind on the shared lifecycle (one item per hymn number, revisioned, rights-checked), a staff web CSV or plain-text import with line-level validation and a preview that loads private drafts, a staff editor with publish/withdraw/archive, anonymous list/search/detail reads, and the Hymn book segment of the Bible & Hymns tab with a user-started offline save of the offline-cleared hymn texts that can be searched locally.

## Boundaries & Constraints

**Always:** Reuse `api.content_command`, the lifecycle helpers, `app.content_rights_clear` and the kind/command/erase-part registries; public reads are security-definer functions returning only published hymns whose live revision clears display now; a re-import or edit never deletes a row (re-import opens revision `last_revision_no + 1`); editors are Media, Pastor and Admin (K1); the offline cache stays the single entry 4 adapter with an explicit allowlist key; members never see internal process; staging and tests use SYNTHETIC or public-domain hymn text only; migrations are ASCII with no backslashes.

**Never:** Replace a shared Content function, grant a client role any table privilege, cache a hymn that is not offline-cleared, show a draft/withdrawn/archived/uncleared hymn to anonymous callers, imply Q5 production clearance, add favourites or the Sunday chip (entry 8) or audio (entry 10), or send any notification.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| CSV import | Valid `number,title,key,part,text` file and a rights record | Preview lists each hymn (new or new draft revision); Load creates private drafts in batches of at most 50 | Anonymous reads stay empty until publication |
| Plain-text import with a bad line | `Hymn N: Title` file with one malformed line | Preview reports the line number and reason; that hymn is excluded, the rest load | Nothing is sent for the excluded hymn; server re-validates every field |
| Re-import | A number that already has a hymn (any state but archived) | New draft revision `last_revision_no + 1`; earlier revision rows and the live revision unchanged | Duplicate numbers inside one batch are refused (`duplicate`) |
| Publish | Draft whose rights record clears display (and Q5 unless church-owned) | Hymn appears in anonymous list, search and detail | Uncleared rights: `validation_failed {hymn_id: <reason>}`; nothing becomes public |
| Search | Number prefix, title words or first-line words (online server read; offline local) | Matching published hymns, exact number first then by number | No match: an honest "No hymns match" state, never an error |
| Offline | Signed-out phone saves the hymn book, then loses connection | Only offline-cleared hymns are stored with publication and rights revisions; list, local search and detail work offline with a saved label | Display-only hymns are excluded by the server read and refused by the cache; a failed save keeps the previous copy |
| Removal | Hymn withdrawn/archived or its rights withdrawn | Gone from every anonymous read and from the saved book on the next online refresh | A detail read answering null never falls back to the saved copy |
| Authority | Anonymous, Pending or plain member | Every hymn command refused; staff reads PT403 | No table privilege for any client role |

</intent-contract>

## Code Map

- `supabase/migrations/20261021233523_content_events_tracer.sql` -- lifecycle helpers (`content_item_open/lock/draft_no/saved/publish/withdraw/archive/outcome`), `content_free_text`, registries, erase hook. Reuse; never replace.
- `supabase/migrations/20261022012809_content_rights_banners.sql`, `20261022102525_f2_church_owned_q5_exemption.sql` -- `app.content_rights_clear(rights_id, use)`, `content_payload_int/uuid`, `content_require_editor(kind)`; q5 staging fixture lists source `synthetic` for display/offline/audio.
- `supabase/migrations/20261023020507_content_bible_translations.sql`, `20261026151013_content_bible_review_hardening.sql` -- the closest model: kind row, revision table + immutability trigger, commands, public/staff reads, erase part, revoke/grant block.
- `supabase/tests/content_bible_test.sql`, `content_banners_test.sql`, `command_foundation_test.sql` -- test patterns; the last two hold shared anon/authenticated/kind/command/erase-part lists that must be extended additively (banners test: exclude `%hymn%` names and kind `hymn` like it excludes events/giving/announcements; command foundation: add the new public and staff functions).
- `tools/identity-e2e/content-bible.mjs` (+ `.test.mjs`), `harness.mjs`, `tools/auth-harness/local-phone-auth.mjs` -- local HTTP E2E style.
- `packages/client_core/lib/src/domain/content_bible.dart`, `application/bible_controllers.dart`, `presentation/bible_screens.dart`, `adapters/supabase_bible_repository.dart` -- client model for domain/controller/screen/adapter; keep every Bible key and behaviour.
- `packages/client_core/lib/src/domain/public_content_cache.dart`, `apps/mobile/lib/offline/public_content_cache_adapter.dart` -- add the hymn book key, `readHymnBook()`, strict key sets and the offline refusal; `NoPublicContentCache` and the testing fake follow.
- `packages/client_core/lib/src/domain/content_banners.dart` (`ContentFilePicker`, `PickedFile`), `adapters/content_file_picker*.dart` -- add `pickTextImport()` (accept `.csv,.txt,text/csv,text/plain`); keep `pickCsv`/`pickImage`.
- `packages/client_core/lib/src/presentation/calendar_screens.dart` (`staleNotice`, `publicSavedStatus`), `staff_announcements_screen.dart`, `packages/design_system/lib/src/{staff,controls,components}.dart` -- offline copy, staff page/table/section pieces, `RadioSegments`, `ChurchCard`, `RequestStateBanner`.
- Shared files, additive edits only: `shell_routing.dart` (routes `/bible/hymns/:hymnId`, `/content/hymns`, `ClientPaths.contentHymns`, `ClientPaths.hymn(id)`), `apps/mobile/lib/app.dart` (guests get the back bar, not the top bar, under `/bible/`), `apps/staff/lib/app.dart` (Content group: `Hymns` after `Bible`, `editsContent`), `providers.dart`, `composition.dart`, `supabase_adapters.dart`, `church_client_core.dart`, `testing.dart`.

## Tasks & Acceptance

Two parallel lanes share only the contract in Design Notes. Lane A edits only `supabase/` and `tools/`; lane B edits only `packages/` and `apps/`. Neither lane creates a branch, commits, merges, pushes, touches staging or production, or runs `dart format` on a whole folder (format only the files it changed); the orchestrating session does those. Windows: write scripts to files instead of quoted shell heredocs; Bash and PowerShell are both available.

**Execution:**
- [ ] Lane A: `supabase/migrations/20261026210709_content_hymns.sql` -- kind `hymn` (admin, pastor, media); `app.content_hymn_keys(item_id pk, hymn_number 1..9999, retired_at)` with a unique index on `hymn_number where retired_at is null`; `app.content_hymn_revisions(item_id, revision_no, title, first_line, hymn_key, verses text[], chorus, rights_id, saved_by_*, saved_at, published_at, published_by_*)`; immutability triggers (published revision content and keys' number); RLS on + revoke all; a shared field validator; commands `content.import_hymns` (creates), `content.save_hymn`, `content.publish_hymn`, `content.withdraw_hymn`, `content.archive_hymn` (archive also sets `retired_at`); public `content_public_hymns(query)`, `content_public_hymn(hymn_id)`, `content_public_hymn_book()`; staff `content_staff_hymns()`, `content_staff_hymn(hymn_id)`; erase part `hymn_revisions`; grants exactly like the Bible block -- the contract.
- [ ] Lane A: `supabase/tests/content_hymns_test.sql` -- registry rows, no table privilege, exact anon/authenticated function lists for `%hymn%`, role matrix (Media/Pastor/Admin allowed; plain member, Pending, anonymous refused), every field error code, batch limits and in-batch duplicates, re-import revision preservation, edit in place, publish refusals (`required`, `use_not_cleared`, `not_in_force`, `source_not_cleared` with a closed gate value), public list/search/detail/book projections and ordering, withdrawn/archived/rights-withdrawn invisibility, retired number reuse, staff read PT403, erase part anonymisation; plus additive updates to `command_foundation_test.sql` and `content_banners_test.sql` -- full suite must pass.
- [ ] Lane A: `tools/identity-e2e/content-hymns.mjs` + `content-hymns.test.mjs` -- local HTTP flow with phones +44 7700 900571-900579 only: Media imports SYNTHETIC hymns, re-imports one, edits, publishes; a plain member is refused; signed-out list/search (number, title words, first line)/detail with chorus; a draft and an uncleared hymn never appear; the book read carries only offline-cleared hymns; cleanup removes the Auth identities and restores phone auth.
- [ ] Lane B: `packages/client_core/lib/src/domain/content_hymns.dart` -- public summary/list/detail/book models (strict parsing, cache JSON round trip), staff models, `HymnCommands`, `HymnRepository` (+ `UnconfiguredHymnRepository`), import parsers for CSV and plain text with line-level errors, the shared normalisation and `matchesHymnQuery` search mirroring the server rules.
- [ ] Lane B: `packages/client_core/lib/src/adapters/supabase_hymn_repository.dart` -- `SupabaseApiReader` calls for the five reads (public ones `public: true`).
- [ ] Lane B: `packages/client_core/lib/src/application/hymn_controllers.dart` -- `HymnBookController` (saved book restored first, online list, debounced server search with local fallback, save/refresh offline copy, reconnect reload), `hymnDetailProvider` family (online first, saved copy only when the read fails), `StaffHymnsController` (list, detail load, import preview, batched load with progress, save, publish/withdraw/archive, publish all drafts, unknown-outcome recheck like the Bible staff controller).
- [ ] Lane B: `packages/client_core/lib/src/presentation/hymn_screens.dart` and `bible_screens.dart` -- `BibleAndHymnsScreen` (RadioSegments "Bible / Hymn book" above the unchanged Bible reader; `?view=hymns` opens the hymn book), `HymnBookView`, `HymnDetailScreen`, `StaffHymnsScreen`; route and destination wiring in the shared files above.
- [ ] Lane B: cache -- `PublicContentCacheKeys.hymnBook = 'content_public_hymn_book'`, `readHymnBook()` on the interface, adapter, `NoPublicContentCache` and `FakePublicContentCache`; writeRead refuses a book holding any hymn not offline-cleared; reads validate exact key sets.
- [ ] Lane B: tests -- `packages/client_core/test/content/hymns_test.dart` (models, both parsers incl. the malformed-line case, search rules, controllers, screens: list, empty, no match, error with retry, offline saved label and local search, detail with chorus and key, staff import preview/load/publish/denied), `apps/mobile/test/offline/public_content_cache_adapter_test.dart` (hymn book round trip, refusal of a non-offline hymn and of an unknown key, wholesale replacement), `apps/mobile/test/mobile_app_test.dart` (segment, hymn detail back bar for guests), `apps/staff/test/staff_app_test.dart` (Hymns destination for editors only).

**Acceptance Criteria:**
- Given a SYNTHETIC CSV and a plain-text file with one malformed line, when Media previews and loads them on staff web, then the malformed line is reported with its number, every other hymn becomes a private draft, and a signed-out caller sees none of them.
- Given a published hymn whose rights clear display, when a signed-out phone searches by its number, a title word or a first-line word, then the hymn is listed and its detail shows the number in the header, title, key, numbered verses and the italic chorus in 19/1.55 text.
- Given the hymn book saved offline on a phone, when the connection drops, then the list, local search and detail keep working from the saved copy with an honest saved/offline label, and only offline-cleared hymns are present.
- Given a hymn whose rights record does not clear display, when an editor publishes it, then publication is refused with the rights reason and the hymn stays invisible to anonymous callers.

## Design Notes

Contract (both lanes implement exactly this; JSON keys are exact, timestamps via `app.cmd_utc`):

- Commands (kind `hymn`, editors admin/pastor/media, through `api.content_command`):
  - `content.import_hymns` (creates: expected_revision null) `{rights_id, hymns: [{hymn_number, title, first_line?, key?, verses, chorus?}]}`; 1..50 hymns, distinct numbers. For each number (ascending): a non-retired existing hymn gets draft revision `last_revision_no + 1` (item must not be archived; existing draft rows stay), otherwise a new item + key with revision 1. Outcome aggregate: the lowest-numbered hymn item; `data: {hymns: [{hymn_id, hymn_number, revision, state, draft_revision_no, created}]}` in number order. A unique-index race fails as `conflict`.
  - `content.save_hymn` (expected = item revision) `{hymn_id, title, first_line?, key?, verses, chorus?, rights_id}`: writes the open draft in place or opens the next revision (events pattern). `content.publish_hymn`, `content.withdraw_hymn`, `content.archive_hymn` `{hymn_id}`; publish takes the draft, or a withdrawn item's live revision, and first checks `content_rights_clear(rights_id,'display')` -> `validation_failed {hymn_id: <reason>}`; a revision published again keeps its first publication.
  - Validation (one shared helper; import keys errors as `hymns.<index>.<field>`, save as `<field>`): `rights_id` required uuid of a non-archived `rights` item (`unknown`); `hymns` `required`/`batch_size`/`invalid_hymn`; `hymn_number` JSON integer (`invalid`), 1..9999 (`out_of_range`), `duplicate`; `title` single line 1..120; `first_line` single line <= 200, derived when absent from verse 1's first line with trailing `,;:` and spaces removed; `key` optional, max 12, `^[A-G](#|b|U+266D|U+266F)?(m| major| minor)?$` (`invalid`); `verses` array 1..40 (`required`/`too_many`) of multiline strings (`invalid` for non-string/blank/control characters, `too_long` above 1500 characters, 30 lines or a 200-character line, `blank_line` for an empty inner line); `chorus` optional with the same text rules. Unicode spaces normalise as in `content_free_text`; each line is trimmed; CRLF becomes LF.
- Public reads (security definer `app.` body + invoker `api.` wrapper, both granted to anon and authenticated), only `published` items whose live revision clears display now:
  - `api.content_public_hymns(query text)` -> `{hymns: [{hymn_id, hymn_number, title, first_line, offline_allowed}], truncated}`; at most 2000 rows. Null/blank query lists all. Search: lower-case, every character outside `[a-z0-9]` becomes a space, at most 8 tokens from the first 100 characters; a hymn matches when every token either is all digits and prefixes `hymn_number::text`, or is contained in the normalised `title || ' ' || first_line`. Order: hymns whose number equals a digit token first, then `hymn_number`.
  - `api.content_public_hymn(hymn_id uuid)` -> `{hymn: {hymn_id, hymn_number, title, first_line, key, verses, chorus, publication_revision, rights_revision, published_at, offline_allowed} | null}` (`rights_revision` = the rights item's live revision number).
  - `api.content_public_hymn_book()` -> `{hymns: [<detail object, offline-cleared only>], truncated, online_only}` ordered by number, at most 2000; `online_only` counts published display-cleared hymns not cleared offline.
- Staff reads (authenticated; `content_require_editor('hymn')`, PT403 otherwise): `api.content_staff_hymns()` -> `{capacity, hymns: [{hymn_id, hymn_number, revision, state, last_revision_no, draft_revision_no, live_revision_no, title, first_line, rights_id, updated_at, published_at, display_rights_error, offline_allowed}], truncated}` (text fields from the draft if any, else live; `display_rights_error` for the revision a publish would use, else null; archived last, then by number; at most 2000). `api.content_staff_hymn(hymn_id uuid)` -> `{capacity, hymn: <summary + live: rev|null, draft: rev|null> | null}`, rev = `{revision_no, title, first_line, key, verses, chorus, rights_id, saved_at, saved_by}`.

Import formats (client parsers; errors carry the 1-based physical line):
- CSV header (any order, case-insensitive): required `number,title,part,text`, optional `key,first_line`; one row per part; `part` is a verse number or `chorus`/`refrain`; title/key/first_line must agree across a hymn's rows; verses must be 1..n with no gaps; quoted multi-line text allowed.
- Plain text: heading `Hymn <number>: <title>` (also `.` or ` - `); optional `Key:` and `First line:` lines right after; blocks split by blank lines; a block starting `Chorus`/`Refrain` (optional colon, text may follow) is the chorus, a label-only repeat is ignored, a different second chorus is an error; an optional leading `1`, `1.` or `Verse 1` line must follow the verse order; text before the first heading is an error; a repeated number is an error at its second heading.
- Preview: valid hymns marked New or "New draft revision" against the staff list; hymns with any error are excluded and listed with their lines.

Mobile UI (handoff screen 5 + taste rules): RadioSegments track at the top of the tab; search field "Number, title or first line" (debounced ~300 ms); one `ChurchCard` list with line-split rows (number 20/700 Outfit brand, 40 wide; title 16/600; first line 14 muted, one line); detail with back bar "Hymn N", title 30/700 brand, "Key of D" muted, verses with accent numbers (22 wide) in 19/1.55 text, chorus after each verse indented with a sentence-case muted "Chorus" label and italic 19/1.55 text. "Save for offline" only when the list has offline-cleared hymns; saved status "Saved for offline at HH:MM"; offline banner like `staleNotice`; online-only hymns count shown plainly. Once a book is saved, every successful online list load (start, retry, reconnect) refreshes it from `content_public_hymn_book` in the background and replaces it wholesale (withdrawn and no-longer-cleared hymns disappear); a failed refresh keeps the previous copy. Signing out keeps the public saved book. Empty: "No hymns yet" / "When the church publishes its hymn book, it will show here." No match: 'No hymns match "q".' Failed read never looks empty.

Staff UI: `ChurchPageScaffold` + `StaffSection`s; import card (rights record dropdown of non-archived records with its cleared uses, Choose file, Paste text, format help, preview, Load N drafts with progress); hymns table (number, title + first line, state, rights) with filter pills (All/Drafts/Published/Withdrawn) and search; editor (title, first line, key, verses as one text area split by blank lines, chorus, rights) with Save draft, Publish, Withdraw, Archive (confirm) and Publish all drafts.

## Verification

**Commands:**
- Lane A, holding the shared local-database lock (two other agents use the same local database): in PowerShell `while (-not (New-Item -ItemType Directory C:\gtmp\church-localdb.lock -ErrorAction SilentlyContinue)) { Start-Sleep 30 }`, write `6.7` into a file inside it, then `npx supabase db reset --local`, `npx supabase test db`, `node tools/auth-harness/local-phone-auth.mjs on`, `node tools/identity-e2e/content-hymns.mjs`, `node tools/auth-harness/local-phone-auth.mjs off`, and always release with `Remove-Item -Recurse -Force C:\gtmp\church-localdb.lock`, also after a failure; hold it only while using the database -- expected: every pgTAP file passes (`duties_owner_decisions_test` 32 is a known load-sensitive timing case: rerun it alone before treating it as a failure); E2E passes and cleans up.
- `node --test tools/identity-e2e/content-hymns.test.mjs` -- expected: pass.
- `node tools/ci/check-migrations.mjs --base origin/main` -- expected: ASCII, ordered, no destructive statement.
- Lane B: `flutter analyze` and `flutter test` in `packages/client_core`, `packages/design_system`, `apps/mobile`, `apps/staff` -- expected: clean analysis, all tests pass.

**Manual checks:**
- On staging (owner manual check): import a SYNTHETIC hymn book from CSV and from plain text with one malformed line reported, edit and publish a hymn, then on a signed-out phone find hymns by number, title words and first line online and offline and open one with its chorus.

## Implementation Notes

## Plan Change Log

## Review Triage Log

---
title: "Search and read the church's Tonga hymn book, built into the app"
type: 'feature'
ticket: '7'
created: '2026-10-26'
status: 'in-progress'
baseline_revision: '77f4632bc5d61da1d26a5417969bda1d3d852ded'
route: 'full'
route_source: 'auto'
review: ''
review_source: ''
lenses_ran: []
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '_bmad-output/initiative-church-app/epic-public-content-and-giving/codex-handoff-prompt.md'
  - '.agents/skills/design-taste-frontend/references/app-screens.md'
  - 'docs/design-handoff/README.md'
warnings: []
deferred: []
---

<intent-contract>

## Intent

**Problem:** Guests and members cannot read or search the church's hymn book in the app. The owner decided (2026-10-27) that the book is the official Brethren in Christ Church Tonga hymn book, part of the app itself: no database rows, rights record, staff import, editing or publication for hymn text.

**Approach:** Ship the book as one checked-in JSON asset in the shared `church_client_core` package with a strict model and loader, produce it from Israel's manuscript with a repo converter that refuses gaps, repeated numbers, empty verses and unplaceable lines, carry a small clearly labelled SAMPLE book until the manuscript arrives, and add the Hymn book segment of the Bible & Hymns tab with on-device search and the hymn detail, all offline and without sign-in.

## Boundaries & Constraints

**Always:** One source file (`packages/client_core/assets/hymn_book/hymn_book.json`) readable by both apps; strict parsing that fails loudly instead of showing a partial book; parsing large files off the UI thread; on-device search that ignores case, punctuation and apostrophes, folds diacritics (and `ŋ` to `ng`) and matches number prefixes with the exact number first; a load failure shows an error with Try again, never an empty list; guests read without signing in; the taste rules and handoff screen 5; additive edits to shared files; every existing Bible key and behaviour kept.

**Never:** Invent Tonga hymn text or present the sample as the real book; add a migration, table, rights record, Content command, staff screen, E2E, staging step or offline-cache key for hymns; add favourites or the Sunday chip (entry 8) or audio (entry 10); add persistence (an asset read is not persistence).

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Shipped book | `hymn_book.json` in the package | Numbers run 1..N with no gap or repeat; every hymn has a title and at least one verse; the sample says it is a sample | A malformed file throws `FormatException`; the view shows "The hymn book could not be opened" with Try again |
| Converter, clean | Plain-text manuscript (number + title heading, blank-line blocks, chorus marker, optional key line) | Writes the book JSON and prints the hymn count | No output file on any problem; exit code 1 |
| Converter, faulty | Manuscript with a gap, a repeated number, an empty verse or an unplaceable line | Each problem reported with its line or hymn number | Refused; nothing written |
| Search by number | `1`, `12` | Number-prefix matches, exact number first, then ascending | No match: 'No hymns match "q".' |
| Search by words | Title or first-line words in any case, with or without apostrophes or diacritics (`nganda` vs `ng'anda`, `ŋanda`) | Hymns whose folded title or first line contains every word | Same no-match sentence; never an error |
| Detail | `/bible/hymns/<number>` on a signed-out phone, offline | Back bar "Hymn N", title, key, numbered verses, italic chorus in 19/1.55 | Unknown number: "This hymn is not in the hymn book." with a way back |

</intent-contract>

## Code Map

- `packages/client_core/lib/src/presentation/bible_screens.dart` (`BibleReaderScreen`) -- unchanged; the new `BibleAndHymnsScreen` hosts it under a `RadioSegments` track.
- `packages/client_core/lib/src/presentation/shell_routing.dart` -- `/bible` builds `BibleAndHymnsScreen` (`?view=hymns` opens the hymn book); child route `hymns/:number`; `ClientPaths.hymn(int)`, `ClientPaths.hymnBook`.
- `apps/mobile/lib/app.dart` (`_showsTopBar`) -- guests get the detail's back bar, not the top bar, under `/bible/`.
- `packages/client_core/lib/church_client_core.dart`, `testing.dart` (`ClientTestHarness`) -- exports; `FakeHymnBookSource` and its override.
- `packages/client_core/lib/src/adapters/bible_package_source.dart` -- asset-loading model (`rootBundle`, injectable `AssetBundle`). The hymn source defaults to the bundled asset in the application layer because the book must work in every build; `boundaries_test` restricts only Supabase/http/adapters and persistence APIs.
- `packages/design_system/lib/src/{controls,components,tokens}.dart` -- `RadioSegments`, `ChurchCard`, `RequestStateBanner`, `ChurchType` (`dateNumber` 20/700 for the list number, `mobileScreenTitle` for the hymn title, `itemTitle`, `secondary`).
- `.github/workflows/ci.yml` -- add `tools/hymn-book/*.test.mjs` to the node test step.

## Tasks & Acceptance

**Execution:**
- [ ] `tools/hymn-book/convert.mjs` + `convert.test.mjs` + `fixtures/` -- converter with an adaptable `DEFAULT_LAYOUT` (heading, key line, chorus marker, optional verse label), NFC and quote normalisation (`ʼ` to `’`, missing from Figtree), limits matching the model; reports gaps, repeats, out-of-order numbers, empty verses, missing verses, over-long lines and unplaceable lines with line numbers; refuses (exit 1, writes nothing) on any problem; `--check`, `--sample`, `--edition`, `--title`, `--language`, `--out`.
- [ ] `tools/hymn-book/sample-manuscript.txt` -> `packages/client_core/assets/hymn_book/hymn_book.json` -- four SAMPLE hymns ("Sample hymn 1".."Sample hymn 4", plain placeholder lines, keys, choruses), produced by the converter; declare the asset in `packages/client_core/pubspec.yaml`.
- [ ] `packages/client_core/lib/src/domain/hymn_book.dart` -- `Hymn` (number, title, key, verses, chorus, derived first line), `HymnBook` (format, edition, title, language, sample, hymns, `byNumber`, `search`), strict `parseHymnBookJson`, `foldHymnText`, `HymnBookSource`.
- [ ] `packages/client_core/lib/src/application/hymn_controllers.dart` -- `BundledHymnBookSource` (`compute` above 64 KiB), `hymnBookSourceProvider`, `hymnBookProvider` (no automatic retry), the remembered segment `bibleHymnsViewProvider`.
- [ ] `packages/client_core/lib/src/presentation/hymn_screens.dart` -- `BibleAndHymnsScreen`, `HymnBookView` (search field, sample line, lazily built line-split list card, no-match and error states), `HymnDetailScreen`.
- [ ] Wiring in `shell_routing.dart`, `apps/mobile/lib/app.dart`, `church_client_core.dart`, `testing.dart`, `ci.yml`.
- [ ] Tests: `packages/client_core/test/content/hymn_book_test.dart` (parser strictness, first line, folding and ordering, the shipped asset's 1..N/title/verse/sample checks, widgets: segment, list, search, no match, error + retry, detail with key/verses/italic chorus at 19/1.55, unknown number); `apps/mobile/test/mobile_app_test.dart` (signed-out tab → Hymn book → search → detail with back bar; the real bundled asset loads and its count shows); `packages/design_system/test/fonts_test.dart` (Figtree and Outfit map `ŋ Ŋ ’ ‘` and the accented vowels).
- [ ] Runbooks: `docs/runbooks/content.md` (converter use, replacing the sample, owner manual check), `docs/runbooks/production-promotion-content.md` (no migration; the real book must replace the sample before production).

**Acceptance Criteria:**
- Given a signed-out phone with no connection, when the user opens Bible & Hymns, chooses Hymn book and searches by number, by title words and by first-line words, then matching hymns are listed (exact number first) and opening one shows its key, numbered verses and the italic chorus.
- Given a test manuscript with a gap, a repeated number and an empty verse, when the converter runs, then it reports each problem and writes no book.
- Given the shipped book, when the app loads it, then the hymn count shown equals the converted file's count and the sample is labelled as a sample.

## Design Notes

Book JSON (format 1, keys exact; `key` and `chorus` are null when absent): `{format: 1, edition, title, language, sample, hymns: [{number, title, key, verses: [string], chorus}]}`. Verses keep line breaks (`\n`); no blank line inside a verse; limits: number 1..9999 contiguous from 1, title <= 120 characters on one line, at most 40 verses, at most 40 lines of at most 200 characters per verse or chorus. The first line is verse 1's first line without trailing `,;:`. Keys are stored in ASCII (`G`, `Bb`, `F#m`, `Eb major`): the bundled fonts have no `♭`/`♯` (U+266D/266F) and staff web builds without the CDN font fallback, so "Key of Bb" is shown as written.

Fonts (checked from the TTF cmap tables): Figtree and Outfit cover `ŋ Ŋ ’ ‘`, acute/grave/circumflex/macron vowels and the combining marks U+0300-0304 and U+0308; Figtree lacks `ʼ` (U+02BC), so the converter writes `’`. Anything else falls back to the platform font on the phone.

Search: fold = lower-case; drop apostrophes (`' ’ ‘ ʼ` and backticks) and combining marks; map Latin-1/Extended-A letters to ASCII (`ŋ` -> `ng`, `æ` -> `ae`); every other character outside `[a-z0-9]` becomes a space. At most 8 tokens from the first 100 characters; a hymn matches when every token is a prefix of its number (digit tokens) or appears in its folded `title + first line`; exact-number hits first, then by number.

Mobile UI (handoff screen 5, taste rules): the segment track sits at the top of the tab; the hymn book view has the search field ("Number, title or first line"), a quiet muted line on the sample book, then one `ChurchCard`-style frame (`DecoratedSliver`) of two-line rows split by 1 px rules (number 20/700 Outfit brand in a 40-wide column, title 16/600, first line 14 muted on one line); the detail has the back bar "Hymn N", the title in brand 24/700 Outfit, "Key of G" muted, each verse with its accent number in a 22-wide column and 19/1.55 text, and the chorus after every verse, indented, under a sentence-case muted "Chorus" label, italic 19/1.55. No offline, saved or online-only labels: the book is always on the phone.

## Verification

**Commands:**
- `node --test tools/hymn-book/convert.test.mjs` -- expected: pass.
- `node tools/hymn-book/convert.mjs tools/hymn-book/sample-manuscript.txt --sample --edition sample-2026-10-27 --title "Sample hymn book" --language en --check` -- expected: clean, 4 hymns.
- `flutter analyze` and `flutter test` in `packages/client_core`, `packages/design_system`, `apps/mobile`, `apps/staff` -- expected: clean, all pass.

**Manual checks:**
- Owner, on a signed-out Android phone in airplane mode: Bible & Hymns -> Hymn book, search by a number, a title word and a first-line word, open a hymn and see its key and chorus; when the real manuscript is converted, the count in the app matches the converter's.

## Implementation Notes

## Plan Change Log

### 2026-10-27 — Owner rescope (replaces the 2026-10-26 plan)

- Trigger: owner decision 2026-10-27 (commit 4cb7fa2): the hymn book is the official Brethren in Christ Church Tonga hymn book, supplied by Israel as a manuscript and built into the app; staff never import, edit or publish hymn text. Entry 7's title, description, verify, covers (K8, K5) and risk (low) changed.
- Amended: the whole plan. Dropped the `hymn` Content kind, migration, tables, commands, public and staff reads, rights records, staff Hymns screens, CSV/plain-text import parsers, local E2E, staging apply and the `content_public_hymn_book` offline-cache key. Added the checked-in book asset with a strict model and loader, the manuscript converter with fixtures, the labelled sample book, on-device search with Tonga-aware folding and the font check. The plan file was renamed with `git mv` to the name derived from the new title.
- Known-bad state avoided: hymn text in the database or behind a rights gate that the owner has ruled out, a staff editor nobody should use, and an offline save step for a book that is always on the phone.
- KEEP: the handoff screen 5 layout (segment, search, list rows, detail with numbered verses and the italic 19/1.55 chorus), the taste rules, additive shared-file edits, unchanged Bible behaviour, honest error states, and the `quick` review.
- No code from the earlier plan had been written: both implementation agents stopped at the account usage limit while still reading, and the only stray changes (line-ending churn in generated Linux plugin files) were restored.

## Review Triage Log

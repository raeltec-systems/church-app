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
warnings: ['oversized']
deferred: []
---

<intent-contract>

## Intent

**Problem:** Guests and members cannot read or search the church's hymn book in the app. The owner decided (2026-10-27) that the book is the official Brethren in Christ Church Tonga hymn book, "Inyimbo zya Bakristo", part of the app itself: no database rows, rights record, staff import, editing or publication for hymn text. Israel's copy arrived as a PDF of the 2012 reprint (pdftotext reads 220 pages of text from it).

**Approach:** Convert the printed book, through its checked-in text extraction and a small reviewed corrections file, into one JSON asset in the shared `church_client_core` package (hymns 1..199, then choruses 1..67, each with its section, English title, hymnal reference, key, verses and chorus), cross-checked against the book's own indexes; read it with a strict model; and add the Hymn book segment of the Bible & Hymns tab with on-device search and the item detail, all offline and without sign-in.

## Boundaries & Constraints

**Always:** One source file (`packages/client_core/assets/hymn_book/hymn_book.json`) readable by both apps; a reproducible conversion (the PDF's SHA-256, the exact extraction command and its text are checked in; every glitch fix is a reviewed line in `corrections.json` that the converter lists); the source text kept as printed; strict parsing that fails loudly, large books parsed off the UI thread; on-device search that ignores case, punctuation, apostrophes and quotation marks, folds diacritics (and `ŋ` to `ng`) and matches number prefixes, exact number first and the hymn before the chorus; a load failure shows an error with Try again, never an empty list; guests read without signing in; the taste rules and handoff screen 5; additive shared-file edits; every Bible key and behaviour kept.

**Never:** Invent or silently change hymn text; add a migration, table, rights record, Content command, staff screen, E2E, staging step or offline-cache key for hymns; add favourites or the Sunday chip (entry 8) or audio (entry 10); add persistence (an asset read is not persistence); commit the downloaded PDF.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Shipped book | `hymn_book.json` | Hymns 1..199 then choruses 1..67, no gap or repeat; every item has a section, a title and a verse | A malformed file throws `FormatException`; the view shows "The hymn book could not be opened" with Try again |
| Converter, real book | Pinned extraction + 26 corrections | Zero problems; 199 + 67 items; asset and report regenerate byte for byte | A text that does not match the pinned hash is refused (exit 2) |
| Converter, faulty | A gap, a repeated number, an empty verse, a stray line, a stale correction or an unexplained title difference | Each reported with its line | Refused (exit 1); nothing written |
| Search by number | `24` | Hymn 24, chorus 24, then other prefix matches in book order | No match: 'No hymns match "q".' |
| Search by words | Title, first-line or English-title words, with or without apostrophes, quotation marks or diacritics | Items whose folded text contains every word, as a flat list; choruses marked "Chorus" | Same no-match sentence |
| Detail | `/bible/hymns/hymn-1` (or `chorus-24`) signed out, offline | Back bar "Hymn 1", Tonga title, English title and key in muted lines, verses (numbered when more than one), the italic chorus after each verse in 19/1.55 | Unknown or malformed id: "This hymn is not in the hymn book." with a way back |

</intent-contract>

## Code Map

- `tools/hymn-book/convert.mjs`, `corrections.json`, `manuscript/inyimbo_zyabakristo.txt`, `manuscript/provenance.json`, `conversion-report.txt` -- the converter, its reviewed fixes, the pinned input and its committed report.
- `packages/client_core/lib/src/domain/hymn_book.dart` -- `Hymn`, `HymnKind`, `HymnChorus`, `HymnBook` (strict reader, `byId`, `search`), `foldHymnText`, `HymnBookSource`.
- `packages/client_core/lib/src/application/hymn_controllers.dart` -- `BundledHymnBookSource` (`compute` above 64 KiB), `hymnBookProvider` (no automatic retry), `bibleHymnsViewProvider`.
- `packages/client_core/lib/src/presentation/hymn_screens.dart` -- `BibleAndHymnsScreen`, `HymnBookView`, `HymnRow`, `HymnDetailScreen`; `bible_screens.dart` drops its own "Bible" heading (the segment names the view).
- Shared, additive: `shell_routing.dart` (`/bible` builds the tab with `?view=hymns`; child `hymns/:id`; `ClientPaths.hymn(id)`, `ClientPaths.hymnBook`), `apps/mobile/lib/app.dart` (guests get the back bar under `/bible/`), `church_client_core.dart`, `testing.dart` (`FakeHymnBookSource`, `testHymnBook`), `packages/client_core/pubspec.yaml` (asset), `.github/workflows/ci.yml` (converter tests).

## Tasks & Acceptance

**Execution:**
- [x] Converter for the printed layout: front matter, running headers and page numbers dropped; topical, hymn and chorus indexes read; headings by the expected next number of each sequence, confirmed by index title similarity or the parenthesised line under them; verses by their numbers (blank lines ignored); `Ciindululo:` choruses kept once per change; reviewed corrections by line with exact-text checks; titles cross-checked against the indexes (differences of one or two letters noted, larger ones need an explanation); refuses on any problem.
- [x] `manuscript/` input with the PDF's SHA-256 and extraction command; `corrections.json` (26 reviewed fixes); `conversion-report.txt`; the converted asset.
- [x] Dart model, loader, providers, screens, routes and shared-file wiring.
- [x] Tests: `tools/hymn-book/convert.test.mjs` (small printed books, faulty book, corrections, explanations, the real book pinned to 199/67 and the PDF and text hashes, CLI); `packages/client_core/test/content/hymn_book_test.dart` (shipped book counts and sections, font coverage of every character, strict reader, search order and folding, bundled source, screens); `apps/mobile/test/mobile_app_test.dart` (signed-out real book through the asset bundle).
- [x] Runbooks: `docs/runbooks/content.md`, `docs/runbooks/production-promotion-content.md`.

**Acceptance Criteria:**
- Given a signed-out phone with no connection, when the user opens Bible & Hymns, chooses Hymn book and searches by a number, title words or first-line words, then matching items are listed (exact number first, hymn before chorus) and opening one shows its key, English title, verses and chorus.
- Given a test manuscript with a gap, a repeated number and an empty verse, when the converter runs, then it reports each problem and writes no book.
- Given the converted book, when the app loads it, then it holds 199 hymns and 67 choruses, matching the converter's report.

## Design Notes

Book JSON (format 1, keys exact): `{format, edition, title, language, items: [{id, kind, number, section, title, original, reference, key, verses, choruses: [{from_verse, text}]}]}`; `id` is `hymn-N` or `chorus-N`; hymns 1..N precede choruses 1..M; a chorus is sung after `from_verse` and every later verse until the next one (chorus 24 prints a second chorus after verse 2). Keys are words ("A flat", "A flat or D"): the fonts have no flat sign. U+201F (used as an apostrophe, 274 times, missing from both fonts) becomes U+2019; every other character in the book is in Figtree and Outfit (tested from their cmap tables).

Owner-visible choices to confirm with Israel:
- Sections come from the book's topical index (Makani Aanyimbo), which names every hymn's section; the running page headers lag behind where a section starts mid-page and are wrong on the last pages. With no search the list follows the printed order (hymn numbers) with a group header wherever the section changes, so a section can appear more than once (Christmas hymns 9-10 and 181-193). Headers use the index's own mixed-case wording.
- The choruses (Ziindululo) are their own group after the hymns; a number search lists the hymn before the chorus, and search results mark choruses "Chorus".
- The detail shows the English title or tune name as printed (capitals, as in the book) under the Tonga title, then "Key of F". The hymnal reference (Z.H./M.H.) is kept in the data but not shown.
- The chorus label is "Chorus" (the app's language), shown after every verse; the "(Cila)" marks stay in titles as printed; search also matches the English title, so "amazing grace" finds the Tonga hymn.
- The PDF is not committed: it is a downloaded file, its text and SHA-256 make the build reproducible, and the owner keeps the original.

## Verification

**Commands:**
- `node --test tools/hymn-book/convert.test.mjs` -- expected: pass.
- `node tools/hymn-book/convert.mjs --check` -- expected: 199 hymns and 67 choruses; no problems.
- `flutter analyze` and `flutter test` in `packages/client_core`, `packages/design_system`, `apps/mobile`, `apps/staff` -- expected: clean, all pass.

**Manual checks:**
- Owner, on a signed-out Android phone in airplane mode: search by a number, a title word and a first-line word; open hymns 1, 3, 32, 106 and choruses 24 and 34 and compare them with the printed book.

## Implementation Notes

- 2026-10-27: built in the main session (the coordinator asked for no extra building agents after the usage limit stopped the first two). No database, staging or E2E work: none applies.
- Converter run on the real book: 219 non-empty pages, 266 items, 26 corrections applied, 0 problems, 72 notes (12 titles differing from an index by one or two letters, kept as printed; 59 hymns whose page header differs from their topical-index section; chorus 24's second chorus).
- Corrections cover: numbers glued to titles (56, 87) or split ("2 6" for chorus 26), the "(Cila)" mark wrapped onto the line under two headings (29, 82), keys split across lines (32, 42, 106, 122, 127), hymn 164's number extracted onto its page header, hymn 178's title missing "Te", chorus 34's verse numbers extracted as a column, and the topical index printing hymn 167 as 16.

## Plan Change Log

### 2026-10-27 — Owner rescope (replaces the 2026-10-26 plan)

- Trigger: owner decision 2026-10-27 (commit 4cb7fa2): the hymn book is the official Brethren in Christ Church Tonga hymn book, supplied by Israel as a manuscript and built into the app; staff never import, edit or publish hymn text. Entry 7's title, description, verify, covers (K8, K5) and risk (low) changed.
- Amended: the whole plan. Dropped the `hymn` Content kind, migration, tables, commands, public and staff reads, rights records, staff Hymns screens, CSV/plain-text import parsers, local E2E, staging apply and the `content_public_hymn_book` offline-cache key. Added the checked-in book asset with a strict model and loader, the manuscript converter with fixtures, the labelled sample book, on-device search with Tonga-aware folding and the font check. The plan file was renamed with `git mv` to the name derived from the new title.
- Known-bad state avoided: hymn text in the database or behind a rights gate that the owner has ruled out, a staff editor nobody should use, and an offline save step for a book that is always on the phone.
- KEEP: the handoff screen 5 layout (segment, search, list rows, detail with numbered verses and the italic 19/1.55 chorus), the taste rules, additive shared-file edits, unchanged Bible behaviour, honest error states, and the `quick` review.
- No code from the earlier plan had been written: both implementation agents stopped at the account usage limit while still reading, and the only stray changes (line-ending churn in generated Linux plugin files) were restored.

### 2026-10-27 — The manuscript arrived

- Trigger: the coordinator sent Israel's PDF (`inyimbo_zyabakristo.pdf`, SHA-256 0733124a...1139) with its layout findings: two number sequences, topic sections, parenthesised English titles with references and keys, `Ciindululo:` choruses, indexes at the end and extraction glitches.
- Amended: the converter now reads the printed layout instead of a plain-text template; the sample book, its manuscript and the plain-text fixtures are gone; the model gained kinds, ids, sections, English titles, references, word keys and per-verse choruses; the list groups by section and the detail shows the English title; the sample label is gone.
- Known-bad state avoided: a placeholder book presented in place of the real one, hymn and chorus numbers mixed in one sequence, glitch fixes hidden in code.
- KEEP: strict reading, on-device search rules, honest error state, the 19/1.55 reading type and every earlier KEEP.

## Review Triage Log

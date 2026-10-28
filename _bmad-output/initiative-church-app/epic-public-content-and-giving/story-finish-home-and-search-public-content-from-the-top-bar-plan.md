---
title: 'Finish Home and search public content from the top bar'
type: 'feature'
ticket: '14'
created: '2026-10-28'
status: built
baseline_revision: 'b0ad33f9b46a85efcebd04fab9b5c762d9486e0c'
route: 'full'
route_source: 'auto'
review: 'deferred'
review_source: 'owner process change 2026-10-27: review is deferred to the epic PR review'
lenses_ran: []
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/docs/runbooks/content.md'
  - '{project-root}/docs/design-handoff/README.md'
  - '{project-root}/.agents/skills/design-taste-frontend/references/app-screens.md'
warnings: []
deferred:
  - 'The verify on a signed-out staging phone (theme, Join card, pinned announcement with See all, Sunday hymn chips, Coming up posters; search online for a hymn, sermon, event and announcement and offline for a hymn; a Pending applicant''s two chips; a member''s cards) is the owner manual check in content.md, story 6.14: it needs a device with this build and published SYNTHETIC content, and the agent publishes nothing on staging.'
---

<intent-contract>

## Intent

**Problem:** Home lacks the handoff's guest Join card and the Pending applicant's request card, its Coming up is a plain event list without posters or the current sermon series, and the top bar has no search, so nobody can find a hymn, sermon, event or announcement by its words (K5, K6).

**Approach:** One bounded anonymous read, `api.content_public_search(query)`, answers the published sermons, events and announcements that match, each through its kind's existing public projection (at most 10 per kind). The phone searches the built-in hymn book on the device (entry 7) as the user types, online or offline, and asks the server a moment later. Home gains the Join card (guests), the Pending card with church approval and cell as two separate chips, and Coming up as poster cards that open the original poster; the pinned announcements with See all (6.13) and Hymns for this Sunday (6.8) stay as they are.

**Decisions:**
- Decision (agent): one read for the three server kinds, returning the kinds' own projections (`content_public_sermon_json`, `content_public_event_json`, `content_public_announcement_json`), so search can never show more than the lists and details; no new projection, table, command or erase part.
- Decision (agent): matching is every word as a plain substring (`strpos` on lower-cased text; `%` and `_` match themselves), at most the first 8 words, query 2-100 characters after trimming and folding spaces (else 22023 `invalid`). Text searched: sermon title, speaker, scripture, notes and published series title; event title, description and location; announcement title and body. Ranking per kind: whole query in the title, then every word in the title, then the rest; ties keep each kind's own order (sermons newest, events soonest, announcements pinned then newest). Page size 10 per kind with one `truncated` flag. Bible text is not searched (epic Notes).
- Decision (agent): hymns are searched on the device with entry 7's `HymnBook.search` from the first character (a hymn number is often one digit); the server is asked only from 2 characters, 350 ms after typing stops (or at once on Search). The first 10 hymns are listed with how many more match. An answer to an older query never replaces a newer one.
- Decision (agent): a failed server read shows "No connection" (or "Couldn't search") with Try again beside the hymns and never "nothing found"; "Nothing matches" shows only when the hymn book and the server both answered with nothing. Search results are not cached offline (no new cache key).
- Decision (agent): Home order follows the handoff: banners, then the guest's Join card or the applicant's request card, or the member's greeting and cards, then pinned announcements, Hymns for this Sunday, Coming up. The "Welcome" heading and guest line are gone for guests and Pending (the card leads instead); members keep the greeting. Join opens the Account page (Sign in and Create account), like the top bar's Sign in.
- Decision (agent): the Pending card shows only when the server answers the applicant's request (`api.identity_my_application`): church chip (amber "Awaiting church approval" / "The church asked for more details"; neutral for decided states) and cell chip (amber "<cell> · Awaiting confirmation"; neutral "Not sure · office will follow up" / "Not in a cell yet"), handoff copy; it opens the request. Without a request, or while it cannot be read, the plain line stays.
- Decision (agent): Coming up cards: the next 3 events, each a card with its 16:9 poster (when public) above the title and when · where; the poster opens the original poster (`/home/posters/events/<id>`, zoomable, alt text, See event), the text opens the event; an event without a poster keeps its date badge. The current sermon series (`PublicSermons.currentSeries`) gets a card after the events only when its poster can be shown (online, or saved offline bytes); its poster opens `/home/posters/series/<id>`, its text the Sermons tab. A failed sermons read just leaves the series card out (the events' own state is reported).
- Decision (agent): the search button sits in the top bar for everyone (handoff), before the inbox and initials or the Sign in pill; the search screen has its own back bar and search field, so the top bar is hidden there. The Sign in pill may shorten at very large text sizes so the bar never overflows.

## Boundaries & Constraints

**Always:** Content owns the read (`content_` prefix), `security definer` body with `search_path = ''` and an invoker `api` wrapper, granted to anon and authenticated only; the module boundary and unowned checks stay 0; ASCII migration without backslashes; shared Dart files get additive registrations (routes, exports, providers, fakes); every existing Home key kept except the guest "Welcome" heading (layout change); SYNTHETIC data only; church time in the UI; taste rules (one status mark per row, rows split by lines, honest states).

**Never:** hymn or Bible text on the server; drafts, withdrawn, archived or ended items, editors, names or member ids in an answer; a change to another kind's projection or to a shared Content function; offline caching of search answers; staging content or notifications; production; edits to entry 18's sermon screens or duty detail.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Search, one word | `harvest`, anon/Pending/member | the same `{query, sermons, events, announcements, truncated}` for everyone, each item byte-identical to its public projection | |
| Not public | draft, withdrawn, archived, ended event | never found | |
| Many matches | 12 announcements match | 10 listed, `truncated: true` | |
| Bounds | 1 char, blank, null, 101 chars | | 400, 22023 `invalid` (`query`) |
| Literal | `100%`, `welcome_all`, `h%t` | matched as text, no wildcard | |
| Phone, online | typing `24` | hymn 24 and others at once; server results after the pause | |
| Phone, offline | server unreachable | hymns listed; "No connection" with Try again; not "nothing found" | |
| Phone, one char | `3` | hymns only, "Type at least 2 letters…"; no server call | |
| Hymn book fails | load error | "The hymn book could not be opened" with Try again | |
| Home, guest | signed out | Join card after the banners; Join opens Sign in / Create account | |
| Home, Pending | request awaiting approval, cell chosen | two chips; the card opens the request | no request / read failed: plain line |
| Home, member | live access | greeting, Needs attention, My duties, My follow-ups, My cell kept | |
| Coming up | event with poster / without / current series with poster | poster card opens the original poster; badge card; series card | events read failed: "No connection…", not empty |

</intent-contract>

## Code Map

- `supabase/migrations/<v>_content_public_search.sql` -- `app.content_public_search(text)` and `api.content_public_search(text)`.
- `supabase/tests/content_public_search_test.sql` (new), `command_foundation_test.sql` (anon and authenticated ledgers).
- `tools/identity-e2e/content-search.mjs` + `.test.mjs` (+44 7700 900575-900578).
- Dart, new: `domain/content_search.dart`, `adapters/supabase_content_search_repository.dart`, `application/search_controllers.dart` (provider for the port, controller), `presentation/search_screens.dart`, `presentation/home_coming_up.dart` (Coming up moved here from `calendar_screens.dart`, poster cards, `HomePosterScreen`).
- Dart, changed: `home_screen.dart` (Join and Pending cards, order), `shell_routing.dart` (`/search`, `/home/posters/...`, `ClientPaths.search|eventPoster|seriesPoster`), `church_client_core.dart`, `supabase_adapters.dart`, `composition.dart`, `testing.dart` (`FakeContentSearch`, `publicSearchData`), `apps/mobile/lib/app.dart` (search button, no top bar on `/search`, top bar never overflows).
- Tests: `packages/client_core/test/content/home_search_test.dart` (new); copy/layout updates in `content_events_test.dart`, `content_banners_test.dart` and `apps/mobile/test/mobile_app_test.dart` (the guest/Pending "Welcome" heading is gone).

## Tasks & Acceptance

**Execution:**
- [x] Migration, pgTAP and ledger updates.
- [x] E2E with its offline unit tests.
- [x] Dart domain, adapter, controller, search screen, Home cards, Coming up posters and poster screen, routes, top-bar button, fakes and tests.
- [x] Runbooks: `docs/runbooks/content.md` (story 6.14), `production-promotion-content.md`.
- [x] Staging apply and verification.

**Acceptance Criteria:**
- Given published SYNTHETIC content with a shared word and a draft and a withdrawn item with it, when a guest, a Pending account and a member search, then each gets the same answer holding exactly the published sermon, event and announcement as their public projections, and nothing private.
- Given a signed-out phone without a connection, when the user searches a hymn number or words, then hymns are listed from the device and the server's failure is said plainly.
- Given a guest, a Pending applicant and a member, when Home opens, then the guest sees the Join card, the applicant the two status chips and the member their cards, and everyone the pinned announcements with See all, Hymns for this Sunday and Coming up poster cards.

## Verification

**Commands:**
- `npx supabase db reset --local` then `npx supabase test db` -- expected: every file passes.
- `node --test tools/identity-e2e/content-search.test.mjs`; `node tools/identity-e2e/content-search.mjs` (local phone auth on) -- expected: all checks pass.
- `node tools/ci/check-migrations.mjs --base origin/main` -- expected: pass.
- `flutter analyze` and `flutter test` in `packages/client_core`, `packages/design_system`, `apps/mobile`, `apps/staff` -- expected: clean, all pass.

**Manual checks:**
- Owner, on staging with a phone running this build: content.md, story 6.14, "Owner manual check on staging".

## Implementation Notes

- 2026-10-28: built by one agent in a worktree from `b0ad33f` (entries 1-13 and 19 merged), with entry 18 running in parallel on sermons and duty detail; no sermon screen or duty file was touched. `ComingUpSection` moved from `calendar_screens.dart` to `home_coming_up.dart` (same name and keys).
- Migration `supabase/migrations/20261028072741_content_public_search.sql` (local `20261028120000` until staging recorded its version). pgTAP `content_public_search_test.sql` (42); `command_foundation_test.sql` ledgers gain the anon and authenticated pair.
- Verification: fresh reset, full pgTAP suite 71 files, 5,716 tests, all pass; E2E `content-search.mjs` 8/8 (evidence `evidence-6.14/content-search-e2e.jsonl`) and its unit tests 5/5; `check-migrations` passes. Flutter: `flutter analyze` clean in all four; `flutter test` client_core 1,156 (22 new in `home_search_test.dart`), mobile 96, staff 61, design_system 19.
- Test changes (layout, not behaviour): the guest and Pending "Welcome" heading checks in `content_events_test.dart`, `content_banners_test.dart` and `mobile_app_test.dart` now check the Join card / applicant line.
- The 2x-text no-overflow test found that the top bar overflowed for a signed-in account before its access answered (search + the "Account" pill at 2x); the pill is now Flexible with an ellipsis.
- Staging (2026-10-28): applied verbatim after entry 18's `20261028071717`, recorded as `20261028072741`; both function hashes equal the fresh local reset, boundary/unowned 0, signed-out reads answer as the tests expect (`evidence-6.14/staging-verify.md`). Nothing published, no notification.

## Review Triage Log

Review is deferred to the epic PR review (owner process change 2026-10-27); no review pass, reviewer agent or external check was run for this entry.

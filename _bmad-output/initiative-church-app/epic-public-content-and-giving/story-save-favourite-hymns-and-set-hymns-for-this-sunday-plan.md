---
title: 'Save favourite hymns and set Hymns for this Sunday'
type: 'feature'
ticket: '8'
created: '2026-10-27'
status: built
baseline_revision: '4773ea0cec14faa5b8dfd7ee2f7d5ea08dd30fb0'
route: 'full'
route_source: 'auto'
review: 'none'
review_source: 'pinned'
lenses_ran: []
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '_bmad-output/initiative-church-app/epic-public-content-and-giving/codex-handoff-prompt.md'
  - '_bmad-output/initiative-church-app/epic-public-content-and-giving/story-search-and-read-the-church-s-tonga-hymn-book-built-into-the-plan.md'
  - '.agents/skills/design-taste-frontend/references/app-screens.md'
  - 'docs/design-handoff/README.md'
warnings: ['oversized']
deferred:
  - summary: >-
      Independent review deferred to the epic PR review (owner process change 2026-10-27).
    evidence: |-
      The owner asked that no per-entry reviews or reviewer agents run; a separate agent reviews the epic PR at the end. A reviewer started earlier was stopped by the usage limit before reporting and its partial output holds no findings.
    location: >-
      the whole entry
    severity: medium (unreviewed)
  - summary: >-
      The staging `_rows` file is an owner step; until applied every staging member deletion waits at its erase step.
    evidence: |-
      supabase/migrations/20261027182300_content_hymn_lists_rows.sql; instructions in docs/runbooks/content.md (Story 6.8, Owner step).
    location: >-
      staging tmurpotfluignacfueki
    severity: low
  - summary: >-
      The physical two-phone and Saturday Home checks remain owner manual checks (entry 15 pilot).
    evidence: |-
      Widget tests cover the Friday/Saturday/Sunday/Monday boundary with a test clock; the E2E covers two sessions of one member over HTTP.
    location: >-
      docs/runbooks/content.md, Story 6.8 owner manual check
    severity: low
---

<intent-contract>

## Intent

**Problem:** Members cannot keep favourite hymns, and nobody can tell the church which hymns of the built-in Tonga book (entry 7) are sung on Sunday. The owner decided (2026-10-21) that Media and members given a worship-leader scope set Hymns for this Sunday; the brief adds Admin. The book lives only in the apps (2026-10-27), so the server may hold item numbers, never hymn text.

**Approach:** One Content kind `hymn_book` with a server-side edition record (`bicc-tonga-2012`: 199 hymns, 67 choruses) that every write is checked against; member-only favourites (save and remove are state changes) through the one command envelope; the church's single Sunday-list record that a Content `worship_leader` scope (2.3) targets, with immutable per-Sunday revisions of item numbers; public, member and staff reads; the favourites erase part (row deletion in a `_rows` file) and the Sunday attribution erase part; mobile Save pill, Saved hymns, the Sunday chip and Home chips (Saturday 00:00 to Sunday 23:59 Lusaka, client clock); a staff web Sunday hymns editor with Admin's worship-leader grants.

## Boundaries & Constraints

**Always:** numbers only (`hymn-N`/`chorus-N` plus edition), refused outside the edition's counts; favourites readable only by their member through a live-access read with no member parameter; no client role on any Content table; commands through `api.content_command`; shared Content functions replaced at most once each and made registry-driven (member commands as in entry 11, kind scopes, replay scopes) so later kinds add rows; no row deletion outside the `_rows` file; ASCII migrations with no backslashes; SYNTHETIC data; E2E phones +44 7700 900641-900649; taste rules; additive edits in shared files.

**Never:** hymn text, titles or first lines on the server; a staff read of anyone's favourites; Pastor or a plain member setting the list; applying the `_rows` file on staging; a notification; an offline-cache key (not asked for); changing entry 7's book, search or reader behaviour.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Save favourite | approved member, `{edition, item: "hymn-12"}` | row `saved`; read lists it; same again is a no-op | `hymn-200`, `chorus-68`, `hymn-0`, unknown edition: `validation_failed {item or edition}` |
| Remove favourite | saved row | state `removed` (row kept) | never saved: `not_found` |
| Favourite as guest, Pending, held | anon / no link / hold | anon cannot execute; Pending and held refused `forbidden`; app shows Sign in or "for approved church members" | read: PT401/PT403 |
| Another member, staff | member B, Admin, Media | read returns only their own rows; no read takes a member id | n/a |
| Set Sunday list | Media, Admin or worship leader; `{sunday, edition, items[1..12]}`, expected = list revision | new revision for that Sunday; public read shows it for this Sunday | not a Sunday, past Sunday, over 52 weeks, duplicate, more than 12, bad item: `validation_failed`; stale: `conflict`; plain member, Pastor, Pending: `forbidden` |
| Clear Sunday list | a set Sunday | an empty revision | not set: `validation_failed {sunday: not_set}` |
| Worship leader scope | Admin `identity.grant_scope {worship_leader, list_id}` | holder may set the list at once; revoked: refused at once, replay refused | other scope_id: `validation_failed` |
| Home chips | client clock Friday 23:59 / Saturday 00:00 / Sunday 23:59 / Monday 00:00 (Lusaka) | hidden / shown / shown / hidden | read failed on Sat/Sun: inline error with Try again |
| Member deletion | member with favourites and Sunday revisions | erase deletes favourites, anonymises revisions; check answers 0 | staging before `_rows`: erase answers `unavailable` (fail closed) |

</intent-contract>

## Code Map

- `supabase/migrations/20261021233523_content_events_tracer.sql` -- registries, lifecycle, `content_authorize_command`, `content_in_scope`, `content_editor_capacity`, `content_command`, erase handler; copy the three replaced bodies from here.
- Entry 11 (unmerged, `epic6/11-event-posters-rsvp`, `20261027010000_*`) -- defines `app.content_member_commands`, `app.content_register_member_command(text)`, `app.content_member_actor(uuid)`; reuse the same names and definitions so whichever lands second deletes its duplicate block.
- `supabase/migrations/20261006234820_identity_grants.sql` -- `identity_register_scope_kind`, `identity_member_has_scope`, grants; `20261013220239_duties_department_tracer.sql` -- scope target hook, Admin candidates with `grants_revision`, fail-closed `_rows` stub.
- `packages/client_core/lib/src/domain/hymn_book.dart`, `application/hymn_controllers.dart`, `presentation/hymn_screens.dart` -- book, `Hymn.id`, `HymnRow`, `HymnDetailScreen` (shared file: additive params only).
- `presentation/home_screen.dart` (one additive line), `shell_routing.dart`, `apps/staff/lib/app.dart`, `church_client_core.dart`, `providers.dart`, `composition.dart`, `supabase_adapters.dart`, `testing.dart` -- additive wiring.
- Patterns: `announcement_controllers.dart` (command states), `content_controllers.dart` (`PublicReadController`), `duties_controllers.dart` (`GrantCommands.grantScope`), `tools/identity-e2e/content-announcements.mjs` (E2E).

## Tasks & Acceptance

**Execution:**
- [ ] `supabase/migrations/<ts>_content_hymn_lists.sql` -- edition table and row; kind `hymn_book` (admin, media); member-command, kind-scope and replay-scope registries; replaced `content_editor_capacity`, `content_authorize_command`, `content_in_scope`; favourites table, commands, member read; Sunday-list record, revisions, items, guards, commands, public and staff reads; scope kind `worship_leader` and target hook; erase parts with the fail-closed purge stub; privileges.
- [ ] `supabase/migrations/<ts+1>_content_hymn_lists_rows.sql` -- the purge body (owner hand-applies on staging).
- [ ] `supabase/tests/content_hymn_lists_test.sql` -- structure, privileges (own kind), every matrix row, races by revision, replay, erase and check; additive lines in `command_foundation_test.sql` lists.
- [ ] `tools/identity-e2e/content-hymn-lists.mjs` (+ `.test.mjs`) -- two sessions of one member, a second member, guest, Pending, Media, worship leader (granted by Admin), plain member and Pastor refused, deletion check.
- [ ] Client: `domain/hymn_lists.dart`, `adapters/supabase_hymn_lists_repository.dart`, `application/hymn_list_controllers.dart` (clock provider), `presentation/hymn_list_screens.dart` (Save pill, Saved hymns, Home section, chips), `presentation/sunday_hymns_staff_screen.dart`; wiring; tests `test/content/hymn_lists_test.dart`, mobile and staff app tests.
- [ ] Runbooks `docs/runbooks/content.md`, `docs/runbooks/production-promotion-content.md`, `docs/runbooks/identity-access.md` (scope kind); epic Notes.

**Acceptance Criteria:**
- Given two signed-in sessions of one member, when one saves and the other reloads, then both list the hymn, and another member's read never shows it.
- Given a guest on a hymn, when they tap Save, then they are offered Sign in and nothing is sent.
- Given a worship leader and a Media member, when each sets next Sunday's list on staff web, then the public read shows it and a plain member's identical command is refused.
- Given a test clock, when Home renders on Friday and on Saturday with a list for that Sunday, then the chips are hidden on Friday and shown on Saturday.
- Given a member with favourites locally, when the deletion hooks erase and check, then Content answers 0.

## Design Notes

- Sunday list: setting is publishing (numbers of a church-owned book, visible only as "this Sunday"); each set or clear is an immutable attributed revision; the list record's revision is the expected revision of both commands (few editors; a conflict reloads).
- "This Sunday" in church time: today on a Sunday, else the coming Sunday. The public read answers the server's this-Sunday list; the client shows Home chips only on Saturday or Sunday (its clock) when that date matches, and the hymn-list chip all week (the choir practises midweek).
- Favourites aggregate per row (`favourite_id`); save and remove take no expected revision (idempotent state changes), replay rechecks ownership and live access.

## Verification

**Commands:**
- `npx supabase db reset --local` then `npx supabase test db` -- expected: all files pass.
- `node tools/identity-e2e/content-hymn-lists.mjs --evidence ...` -- expected: every check passes.
- `node --test tools/identity-e2e/content-hymn-lists.test.mjs`, `node tools/ci/check-migrations.mjs --base origin/main` -- expected: pass.
- `flutter analyze` and `flutter test` in the four packages -- expected: clean, pass.

## Implementation Notes

- Branch `epic6/8-hymn-favourites-sunday`, from 4773ea0 (6.9 merged), later merged with 15918d5.
- Decisions: one kind `hymn_book` (Admin, Media) plus the `worship_leader` Content scope on a single Sunday-list record; Pastors do not set the list (owner decision names Media and worship leaders; the brief adds Admin). Setting a Sunday's list is its publication (item numbers of the church-owned book, shown only as "this Sunday"); each set or clear is an immutable attributed revision. Home shows the list Saturday 00:00 to Sunday 23:59 by the device clock (injectable `hymnClockProvider`); the hymn-book Sunday chip shows all that week. Favourites are not audited (private member state) and not cached offline (not asked for). The staff entry is last in the Content group so existing order tests stay.
- Staging: 6.11 was applied (`20261027140149`) minutes before; the first apply failed atomically, the migration now keeps 6.11's member-command registry and RSVP replay branch, and staging records `20261027182223` (rows file `20261027182300`, not applied).
- Tests: pgTAP `content_hymn_lists_test.sql` 145, full suite 66 files / 5,388 on a fresh reset (one duties timing test passed alone, as noted in memory); E2E 13/13; Flutter client_core 1047, mobile 92, staff 61.
- Review: none per the owner's process change; deferred to the epic PR review.

## Plan Change Log

## Review Triage Log

## Auto Run Result

Built hymn favourites (member-only, private, removal as a state change, guests asked to sign in, Pending told it is for members) and Hymns for this Sunday (Admin, Media and worship leaders on staff web; the `worship_leader` scope granted by an Admin through 2.3; Home chips Saturday to Sunday, Lusaka; the Sunday chip in the hymn book), with the edition record refusing numbers outside hymns 1-199 / choruses 1-67, the favourites erase part with its `_rows` file and the Sunday attribution erase part. On staging as `20261027182223`; hashes match fresh local (purge stub pending the owner's rows file); boundary/unowned 0. Review deferred to the epic PR review.

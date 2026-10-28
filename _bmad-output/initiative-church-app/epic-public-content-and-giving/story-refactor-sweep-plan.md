---
title: 'Refactor sweep'
type: 'refactor'
ticket: '16'
created: '2026-10-28'
status: built
baseline_revision: 'cc8dd51beaec6c9348a400e2d16845e02cb52d8d'
route: 'full'
route_source: 'auto'
review: 'deferred'
review_source: 'owner process change 2026-10-27: review is deferred to the epic PR review'
lenses_ran: []
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/_bmad-output/initiative-church-app/epic-cell-meetings-and-programmes/story-refactor-sweep-plan.md'
  - '{project-root}/_bmad-output/initiative-church-app/epic-public-content-and-giving/codex-handoff-prompt.md'
warnings:
  - 'Entry 15 (hitl pilot) is in this entry''s after list and is not built; the owner directed the sweep to run before it. Nothing here changes what the pilot exercises.'
deferred:
  - 'Review is deferred to the epic PR review (owner process change 2026-10-27); no review pass or reviewer agent ran for this entry.'
---

<intent-contract>

## Intent

**Problem:** Epic 6's Content kinds (events, banners and rights, giving, announcements, Bible, hymns, sermons, search) were built one after another, often in parallel worktrees, and later kinds copied shared client helpers instead of reusing them. Two findings were deferred to this sweep.

**Approach:** Review the epic 6 plans' deferred items and the client code across the kinds. Apply only behaviour-preserving cleanups (plus the small real defects found on the way), one commit per theme, and rerun every suite.

## Boundaries & Constraints

**Always:** no change to a public read, command contract, migration or function; every widget key and test kept; tests changed only where code moved; each bug fix listed.

**Never:** a migration whose only purpose is tidying a hosted function; new scope; absorbing deferred behaviour that needs an owner decision.

</intent-contract>

## Findings reviewed

| Finding (source) | Decision |
|---|---|
| Six Content domain libraries each carried a private non-blank text reader; banners, giving and sermons also copied the optional text, positive integer and editor-capacity readers (6.1-6.9) | **Applied** (`3f7c9c9`): `wireText`, `wireOptText`, `wirePositive`, `wireEditorCapacity` in `wire_json.dart`, aliased under the libraries' short names as Duties and Follow-ups did in 4.14. Same checks, same `FormatException` messages. |
| Three copies of the pick-and-upload controller: banners (6.2), sermon-series posters (6.9), event posters (6.11) | **Applied** (`43db442`): `ContentImageUploadController` with a `purpose` per kind; provider names, class names and states unchanged. The series purpose moves from `SermonCommands.posterPurpose` to `ContentPurposes.sermonSeriesPoster` beside the others. **Bug fixed:** the banner and event copies lacked the series copy's epoch guard, so an upload answer arriving after an account change was written into the new account's (rebuilt) state. New tests: each kind's purpose, and the late answer dropped for all three. |
| Five staff editors (banners/rights, events, giving, sermons, announcements) carried the same "Keep it" confirm dialog | **Applied** (`159caab`): `confirmContentChange` in the internal `content_staff_widgets.dart`, called with each editor's key prefix; every key, label and the mounted check unchanged. |
| Staff nav highlights no item on `/content/sermons/<id>`, `/content/sermon-series/<id>` (6.9, deferred to this entry) and `/cells/meetings/<id>/plan` (5.3); a deep link opens with the group folded | **Applied as a bug fix** (`5bdfc92`): `staffNavPathFor` selects the longest destination path the location is under, by whole segments; exact pages behave as before. New tests: the matcher, and a sermon editor deep link opening with Content open and Sermons selected. |
| `StaffEventsController` replaces the list with the failure when a refresh fails (6.1 deferred) | **Not applied:** every staff controller (Duties, Cells, Giving, Announcements) behaves the same; keeping the last good answer is a user-visible change for a staff-wide pass, not a behaviour-preserving cleanup. |
| Staff Content controllers: banners, rights, sermons and series share `StaffCatalogController`; events, giving, announcements and Sunday hymns are their own notifiers | **Not applied:** their states differ (RSVP and duty links, verification, notices, Sunday lists); moving them onto one base is a rewrite with risk and no defect. |
| Each staff editor's field-error and status-mark tables (`_fieldError`, `_mark`) look alike | **Not applied:** the wording differs per kind on purpose; a shared table would only add parameters. |
| Large presentation files (`giving_staff_screens.dart` 2,180 lines, `banner_screens.dart` 2,160, `content_screens.dart` 1,950) | **Not applied:** splitting only moves code; the shared pieces above already left them. |
| Content E2E scripts each clean up their own kind | **Not applied:** unlike the cells scripts in 5.11 their cleanup SQL is kind-specific, not one copied block. |
| Server: shared SQL between kinds | **Not applied:** the registries already share one command envelope, one deletion hook and one public-read pattern; a tidy-only migration is excluded. No SQL change, so staging is untouched. |
| Other deferred items in the epic 6 plans (owner manual checks, Q3/Q5, giving residual risks, 6.12/6.18/6.11 behaviour notes) | **Not applied:** owner checks or behaviour decisions, outside a refactor. |

## Verification

- `story/5.8-meetings-held` was still at `cc8dd51` (this entry's baseline) when the suites ran, so there was nothing new to merge.
- Fresh local reset, full pgTAP suite: 72 files, 5,764 tests; all pass except the known load flake `duties_owner_decisions_test.sql` #32 (the 3 s board timing), which passes when its file runs alone, as recorded since 4.4. No SQL changed.
- Flutter: `flutter analyze` clean in all four packages; `flutter test` client_core 1,148 (+2), design_system 19, mobile 96, staff 63 (+2).
- No E2E rerun: no server, Edge function or wire change.

## Implementation Notes

- 2026-10-28: built by one agent in a worktree from `cc8dd51` (entries 1-14, 18, 19 and F1-F3 merged). Client-only: no migration, Edge function or staging change.
- Test changes: two tests added in `content_banners_test.dart` (image uploads) and two in `apps/staff/test/staff_app_test.dart` (nav selection); no existing test changed.

## Review Triage Log

Review is deferred to the epic PR review (owner process change 2026-10-27); no review pass, reviewer agent or external check was run for this entry.

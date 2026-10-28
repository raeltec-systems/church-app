---
title: 'Link duties to published events and flag their review when an event changes'
type: 'feature'
ticket: '12'
created: '2026-10-27'
status: built
baseline_revision: 'b4de38db3cb04d5d91a8393a9ee2c63b427181bc'
route: 'full'
route_source: 'auto'
review: 'deferred'
review_source: 'owner process change 2026-10-27: review is deferred to the epic PR review'
lenses_ran: []
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/docs/runbooks/contracts-and-owner-seams.md'
  - '{project-root}/docs/runbooks/content.md'
  - '{project-root}/docs/runbooks/duties.md'
  - '{project-root}/.agents/skills/design-taste-frontend/references/app-screens.md'
warnings: ['multiple-goals']
deferred:
  - 'The new-series form (duties.create_series) has no event picker; a series is linked from a date with "This and later dates". The server accepts and checks event_ref on create_series too.'
  - 'Re-publishing a withdrawn event at the same time and place flags nothing (its duties were already flagged cancelled; the open flag stays until the leader reviews it).'
---

<intent-contract>

## Intent

**Problem:** Duties stored `event_ref` as an opaque uuid (4.3) and nothing told a department when a linked event moved or was cancelled. K13 needs a duty to name only a published event, without exposing the rota publicly, and a time, place or cancellation change to flag the linked duties for their leaders' review (4.16 notice), with the editor seeing how many duties are linked first.

**Approach:** A Duties contract change validates `event_ref` through the 1.5 source registry (`app.contract_check_source`) only; Content registers `content_event` (source type, check hook, Duties `event` link source) and calls the 4.11 `duties_owner_flag_review` inside its own publish, withdraw and archive commands after locking its item row; editors read counts through `duties_owner_event_links`. Clients: a published-event picker and event line on the staff rota, the event on the mobile duty detail, the linked-duty count on staff Events. The 4.11 guide is corrected (flags notify since 4.16).

**Decisions:**
- Decision (agent): Duties validates through `contract_check_source`, never by reading Content (epic Notes source conflict). The event source's check hook answers its live revision number while published and `revision: null` otherwise (the announcements pattern); Duties asks once at revision 1, and again at the reported revision, so a published event is current. Recorded in the 4.11 guide as point 10.
- Decision (agent): the check runs in two `BEFORE INSERT OR UPDATE OF event_ref` triggers (occurrences and series) rather than in every rota command, so every path (revise_duty, revise_series, create_series, owner put_part) is covered without replacing large command bodies. It checks only a reference being set or changed; clearing is always allowed; a stored link is never re-checked (a later withdrawal never blocks other edits); an occurrence a series generates with the series' own reference is not re-checked.
- Decision (agent): "time" is start or end, "place" is location; a title or description change flags nothing. Cancellation is withdraw or archive of a published event (`cancelled`). The flag for a cancellation is raised before the state change, while the event is still published at its live revision, in the same transaction (the item row is already locked), because the 4.11 operation rechecks the source as current.
- Decision (agent): Content calls Duties only when the Q4 personal-data gate is open (`app.identity_applications_open()`); with it closed no duty can exist and the Duties operations would refuse, which must never block an event publish.
- Decision (agent): the editors' count is counts only (`linked_duties` = published department duties that have not started; `reviews_open`); Media, Pastor and Admin read it, nobody else. It shows on the opened event before Edit/Publish/Withdraw/Archive and in the withdraw and archive questions.
- Decision (agent): the staff picker lists the public calendar's published events (rota editors are department leaders, who may not be Content editors); the mobile duty detail and the rota line read the public event read, so Duties exposes nothing new.
- Decision (brief): no notification on staging; the 4.16-style notice is proven locally only (pgTAP and the E2E queue notices; the worker is never run).

## Boundaries & Constraints

**Always:** Duties reaches Content only through the 1.5 registry; Content reaches Duties only through the 4.11 operations inside its own command after its item lock (lock order: role grants -> receipt -> item -> Duties departments/occurrences -> flags -> Notifications); replaced bodies copied from their latest versions; ASCII migration without backslashes; SYNTHETIC data; boundary/unowned 0.

**Never:** a Content table read by Duties; a duty republished or an answer reset by an event change; a duty, rota, department or person in a public projection or the count read; a notification on staging; production.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Link | leader revises a date with a published event id | `change: reference`, no notice to the member | draft, withdrawn, archived, unknown or foreign id: `validation_failed {"event_ref": "not_published"}` |
| Clear | `event_ref: null` | allowed | |
| Time change | editor publishes a revision with a new start or end | each linked department's duty flagged `time` once; one notice per reachable leader/deputy (not the editor, Admin or members); answers and revisions unchanged | |
| Place change | new location | flags merge (`place+time`), fresh notice per department | |
| Title only | new title | nothing flagged | |
| Withdraw / archive | published event | linked duties flagged `cancelled`; link kept; new links refused | withdrawn then archived: nothing more |
| Count | editor opens the event | `{linked_duties, reviews_open, truncated}` | member or leader 403 `not_granted`; anon refused; unknown event `linked_duties: null` |
| Public read | anon | no duty, rota, department or review key | |

</intent-contract>

## Code Map

- `supabase/migrations/20261015035112_duties_owner_operations.sql` (4.11: link sources, flag_review, event_links), `20261015190139_duties_owner_decisions.sql` (4.16 notice, flag_review latest), `20261014023442_duties_rota_series.sql` (event_ref), `20261021211830_duties_special_assignments.sql` (my_assignment_json latest).
- `supabase/migrations/20261021233523_content_events_tracer.sql` (withdraw, archive), `20261027140149_content_event_posters_rsvp.sql` (publish latest, staff read pattern).
- Dart: `domain/duties.dart` (`MyDuty`, `RotaOccurrence`, `RotaEdit`), `domain/content_events.dart` (`EventDutyLinks`, repository), `adapters/supabase_content_repository.dart`, `application/content_controllers.dart`, `presentation/duties_rota_screens.dart`, `presentation/duties_screens.dart`, `presentation/content_screens.dart`, `testing.dart`.

## Tasks & Acceptance

**Execution:**
- [x] `supabase/migrations/20261027192013_content_event_duty_links.sql` -- the Duties contract change (check function, two triggers, My duties `event_ref`), `content_event` source and link source, flags in publish/withdraw/archive, the count read, privileges.
- [x] `supabase/tests/content_event_duty_links_test.sql` (47) + scoped ledger and key-list updates in five existing files.
- [x] `tools/identity-e2e/content-event-duty-links.mjs` + `.test.mjs` -- the verify at the API (block +44 7700 900291-900297).
- [x] client_core: models, repository read, providers, rota event line and picker, mobile duty event, staff Events count, fakes, tests.
- [x] Runbooks: 4.11 guide corrected and point 10 added (`contracts-and-owner-seams.md`), `content.md` story 6.12 with owner manual check, `production-promotion-content.md` row and step 11, `duties.md` line.

**Acceptance Criteria:**
- Given a fresh local reset, when the full pgTAP suite runs, then it passes, and the E2E proves the matrix through the Data API.
- Given `flutter test`, when run, then the rota picker sends `event_ref` as a reference, a refusal shows its message, the duty detail shows and opens the event (or says it is gone), and the Events editor shows the count before a change.

## Implementation Notes

- Migration built as `20261027184500`, applied to staging verbatim, hosted as `20261027192013` (after entry 10's `20261027191003`) and renamed locally.
- Existing tests scoped (no behaviour changed): `command_foundation_test.sql` (authenticated ledger + the count read), `content_events_test.sql` (privilege list excludes `%duty_links%`), `duties_tracer_test.sql` and `duties_revisions_test.sql` (My duties key lists exclude `event_ref`), `duties_rota_test.sql` (links a registered SYNTHETIC fixture event instead of a random uuid), `duties_owner_operations_scale_test.sql` (registers the fixture event source before its direct inserts).
- pgTAP: full suite on a fresh reset 68 files, 5571 tests, pass (before the story-branch merge). E2E 10/10 (`evidence-6.12/local-e2e.jsonl`).
- Flutter: client_core 1085, mobile 92, staff 61, design_system 19, all pass; analyze clean (before the story-branch merge). New `test/duties/duties_event_links_test.dart` (11).
- After merging `story/5.8-meetings-held` (d92ed1e, entry 10): fresh reset, full pgTAP 69 files, 5653 tests, pass; E2E 10/10; Flutter client_core 1097, mobile 95, staff 61, design_system 19, analyze clean.
- Staging: 12 of 12 function hashes match; boundary/unowned 0; signed-out reads checked (`evidence-6.12/staging-verify.md`). No duty linked, no notification sent.

## Plan Change Log

## Review Triage Log

- Review deferred to the epic PR review (owner process change 2026-10-27: no reviews per entry).

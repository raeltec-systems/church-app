---
title: "Send a preaching duty's topic and scripture to Media as a sermon draft"
type: 'feature'
ticket: 18
created: '2026-10-28'
status: built
baseline_revision: 'cd4d893'
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
  - '{project-root}/.agents/skills/design-taste-frontend/references/app-screens.md'
deferred:
  - 'Special assignments (owner kind special) can be sent by their assignee: duties_owner_topic answers them and Content refuses only cell parts. The staff special-assignment screens have no Send to Media button (the Pastor is not a manager in duties_owner_topic).'
  - 'A draft is never refreshed from the duty: a later topic change on the duty does not reach Media (a second send answers the existing draft). Media edits the draft itself.'
---

<intent-contract>

## Intent

**Problem:** K11: a preaching duty's topic and scripture live in Duties, and Media retypes them to prepare a sermon page. The 4.11 contract already offers the sermon-draft read `duties_owner_topic` (assignee or managers only), but nothing used it.

**Approach:** A Content member command `content.draft_sermon_from_duty {occurrence_id}` calls `duties_owner_topic` inside its own transaction (the Duties read is the authority) and creates one private 6.9 sermon draft per occurrence: title from the topic, scripture, church date; no speaker or private field. A status read tells the sender whether it was sent. Media sees the draft in the entry 9 editor marked "From a duty" and completes, reviews and publishes it with the existing commands; publishing still needs a speaker, so nothing goes public automatically.

**Decisions:**
- Decision (agent): one draft per occurrence through a link table `app.content_sermon_duty_drafts` (occurrence id primary key, sermon id unique) and a transaction advisory lock per occurrence, so two concurrent sends make one draft. A second send by anyone allowed answers the same draft with `created: false` and changes nothing, whatever Media did to it since.
- Decision (agent): title = topic, else the scripture (a duty with scripture only still makes a usable draft); a duty with neither is refused `no_topic`. sermon_date is the duty's start date in church time (Africa/Lusaka). No speaker (Media decides who is named publicly), notes, series or video.
- Decision (agent): cell programme parts are refused (`cell_part`): a cell meeting's topic is not a church sermon. Department duties and special assignments are accepted, as `duties_owner_topic` answers them.
- Decision (agent): a member command (6.11/6.8 registry), not an editor command: the sender is not a Content editor. The replay recheck (`content_sermon_duty_draft` aggregate, keyed by the occurrence) asks `duties_owner_topic` again, so a replay needs the sender still to be the assignee or a manager.
- Decision (agent): the audit capacity vocabulary (`app.content_state_ok`, replaced as its comment provides) gains `duty_assignee` and `duty_manager`; the draft's `created_by` is the sender, as for any item. The editors' `from_duty` mark names the duty and when it was sent, never who sent it.
- Decision (agent): the status read `api.content_duty_sermon_draft` answers only whether it can be and was sent (`sent_at`, `published`), so the assignee can see the result without reading Content's draft. A refused read hides the section in the clients; a failed read says so.
- Decision (brief): no notification is sent for a draft; no staging duty is published by the build (publishing a duty notifies its member).

## Boundaries & Constraints

**Always:** Content reads Duties only through `app.duties_owner_topic` inside its own command, read or replay check; Duties is unchanged; replaced bodies copied from their latest versions (staging hashes checked first); ASCII migration without backslashes; SYNTHETIC data; boundary/unowned 0.

**Never:** a Duties table read by Content; a draft public without Media publishing it; a speaker, sender or private field on the draft or in public reads; a notification on staging; production.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Send | assignee, duty with topic | one private draft; `created: true` | |
| Again | same or another allowed sender | same `sermon_id`, `created: false` | |
| Manager | department leader, deputy or Admin | same rules, capacity `duty_manager` | |
| Others | member without the duty, another department's leader, Media, a declined assignee | `not_found`; status read 403 `not_granted` | anon refused |
| No topic | neither topic nor scripture | `validation_failed {"occurrence_id": "no_topic"}` | |
| Cell part | `cell_id` set | `validation_failed {"occurrence_id": "cell_part"}` | |
| Public | anon, members | draft invisible in public reads and the staff list | |
| Publish | Media without a speaker | `validation_failed {"speaker": "required"}`; public only after save and publish | |

</intent-contract>

## Code Map

- `supabase/migrations/20261015035112_duties_owner_operations.sql` (`duties_owner_topic`), `20261027182223_content_hymn_lists.sql` (member commands, replay scopes, `content_member_actor`), `20261027083618_content_sermons.sql` and `20261027191003_content_sermon_facebook_video.sql` (sermon revisions, staff JSON), `20261021233523_content_events_tracer.sql` (`content_state_ok`, `content_item_open`).
- Dart: `domain/content_sermons.dart` (`SermonFromDuty`, `DutySermonDraft`, `SermonCommands.draftFromDuty`, repository read), `adapters/supabase_sermons_repository.dart`, `application/sermon_controllers.dart` (`DutySermonDraftController`), `presentation/duties_sermon_draft_widgets.dart` (new part of `duties_screens.dart`), `duties_screens.dart` (mobile detail), `duties_rota_screens.dart` (rota panel), `sermon_staff_screens.dart` (from-duty line), `testing.dart` (`FakeSermons.dutyDrafts`).

## Tasks & Acceptance

**Execution:**
- [x] `supabase/migrations/*_content_sermon_drafts_from_duties.sql` -- link table, command and member-command registration, replay scope, status read, staff JSON `from_duty`, erase part, capacity vocabulary, privileges.
- [x] `supabase/tests/content_sermon_duty_drafts_test.sql` (48) + the authenticated ledger in `command_foundation_test.sql`.
- [x] `tools/identity-e2e/content-sermon-duty-drafts.mjs` + `.test.mjs` -- the verify at the API (block +44 7700 900116-900121).
- [x] client_core: models, repository read, controller, mobile duty section, rota section, staff from-duty line, fakes, `test/content/sermon_duty_drafts_test.dart` (12).
- [x] Runbooks: `content.md` story 6.18 with owner manual check, `production-promotion-content.md` row and step, `contracts-and-owner-seams.md` point 12.

**Acceptance Criteria:**
- Given a fresh local reset, when the full pgTAP suite runs, then it passes, and the E2E proves the verify through the Data API.
- Given `flutter test`, when run, then the duty detail and rota send once, show sent / already sent / refused / unconfirmed / failed honestly, and the staff list and editor mark the draft as from a duty.

## Implementation Notes

- Migration built as `20261028070000`, applied to staging verbatim, hosted as `20261028071717` (after entry 19's `20261028064546`, which touches none of the replaced functions) and renamed locally.
- Existing test scoped (no behaviour changed): `command_foundation_test.sql` (authenticated ledger gains `api/app.content_duty_sermon_draft`).
- pgTAP: full suite on a fresh reset 70 files, 5701 tests, pass. E2E 9/9 (`evidence-6.18/local-e2e.jsonl`); its offline tests 4/4. Migration checker: 93 ordered, unique, non-destructive.
- Flutter: client_core 1109, mobile 95, staff 61, design_system 19, all pass; analyze clean. New `test/content/sermon_duty_drafts_test.dart` (12). No existing key or test changed.
- Staging: 8 of 8 function hashes match; boundary/unowned 0; signed-out reads refused or empty (`evidence-6.18/staging-verify.md`). No duty published, no draft made, no notification sent.
- Design: the Sermon section uses the detail's CardLabel and muted lines, one outlined action, honest sent / refused / unconfirmed / failed states and no state shown when the read is refused (app-screens rules); the staff list keeps one status mark per row and adds the origin as a muted line.

## Plan Change Log

## Review Triage Log

- Review deferred to the epic PR review (owner process change 2026-10-27: no reviews per entry).

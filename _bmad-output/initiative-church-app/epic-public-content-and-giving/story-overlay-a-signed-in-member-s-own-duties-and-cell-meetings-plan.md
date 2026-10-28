---
title: 'Overlay a signed-in member''s own duties and cell meetings on the Calendar'
type: 'feature'
ticket: '19'
created: '2026-10-27'
status: built
baseline_revision: 'd92ed1e1b5b531340edc4044552e2ac8bc478962'
route: 'full'
route_source: 'auto'
review: 'deferred'
review_source: 'owner process change 2026-10-27: review is deferred to the epic PR review'
lenses_ran: []
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/docs/runbooks/cells-meetings.md'
  - '{project-root}/docs/runbooks/content.md'
  - '{project-root}/.agents/skills/design-taste-frontend/references/app-screens.md'
  - '{project-root}/docs/design-handoff/README.md'
warnings: []
deferred: []
---

<intent-contract>

## Intent

**Problem:** The Calendar shows only public church events. A member must open My duties and My cell separately to see where they are expected, although the design (screen 8) and K12 put both on the Calendar as overlays marked as theirs.

**Approach:** Two member-only switches on the mobile Calendar. My duties reuses the 4.5 My duties read unchanged; My cell uses a new bounded Cells read `api.cells_my_meetings()` (a Cells contract change; `api.cells_my_cell()` unchanged). The phone composes both with the public events; no Content function reads Cells or Duties.

**Decisions:**
- Decision (agent): the visible period is the next **31 days** from now (the Cells read's fixed window; the duties overlay applies the same window client-side). A parameterless read keeps it bounded and simple; the Calendar list itself still shows all upcoming public events.
- Decision (agent): "current duties" = waiting for an answer or accepted, not ended (end, else start, after now), starting within the window. Declined and past duties are left out.
- Decision (agent): the Cells read returns only the caller's own **confirmed** cell (a current membership with private access), not cells they lead or assist; meetings not ended and starting within 31 days, states scheduled/moved/cancelled (withdrawn left out), at most 62 rows; ids, date, state and times only, no venue.
- Decision (agent): both switches start **off** and last for the app session (dropped on an account change), so the Calendar opens as everyone's calendar and nothing member-specific is read until asked. Nothing is cached offline.
- Decision (agent): switches show only when the member-access read answered with live access; guests, Pending applicants and a failed access read see none.
- Decision (agent): a cancelled meeting stays listed as "Cell meeting cancelled", "Cancelled · was <time>", with the My cell mark (one status mark per row).

## Boundaries & Constraints

**Always:** Cells owns the new read (prefix `cells_`), `security definer`, `search_path = ''`, Identity's live-access check and the Cells read gate; boundary and unowned counts 0; edits to the shared Calendar list are additive; ASCII migration without backslashes; SYNTHETIC data; church time in the UI.

**Never:** changes to `api.cells_my_cell()` or any Duties read; Content reading Cells or Duties tables; venue, programme or names on the overlay read; overlays for guests or Pending; offline caching of overlays; staging notifications; production.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Member, both on | confirmed in a scheduled cell, one duty this month | own meetings (31 days) and own duty marked My cell / My duty among events | |
| Cancelled meeting | leader cancels one | listed, marked cancelled | |
| Other member's items | another member's duty and cell | never in the answer or on screen | |
| No cell / no schedule | member | `cell_id` null, no meetings, no failure shown | |
| Leader not member | leader of a cell | no meetings (own confirmed cell only) | |
| Transfer | member moves cell | only the new cell's meetings | |
| Guest | no session | no switches | read refused (401) |
| Pending | no member access | no switches | read refused (403) |
| Read fails | offline / server | that overlay says so; events stay | |
| Tap | duty / meeting | duty detail / My cell | |

</intent-contract>

## Code Map

- `supabase/migrations/20261021073514_cells_meetings.sql` -- meetings model, `cells_member_meetings` and `cells_my_cell` (unchanged), generation.
- `packages/client_core/lib/src/domain/duties.dart` -- `MyDuties` (4.5 read) reused.
- `packages/client_core/lib/src/presentation/calendar_screens.dart` -- the Calendar list (shared with entries 1, 4, 11, 12).

## Tasks & Acceptance

**Execution:**
- [x] `supabase/migrations/20261028064546_cells_my_meetings.sql` -- `app.cells_my_meetings()` and `api.cells_my_meetings()`, privileges.
- [x] `supabase/tests/cells_my_meetings_test.sql` (21) and the authenticated ledger in `command_foundation_test.sql`.
- [x] `tools/identity-e2e/calendar-overlays.mjs` + `.test.mjs` (+44 7700 900941-900945).
- [x] client_core: `domain/calendar_overlays.dart`, `adapters/supabase_cell_calendar_repository.dart`, `application/calendar_overlay_controllers.dart`, `presentation/calendar_overlay_widgets.dart`, additive edits to `calendar_screens.dart`, barrels, `composition.dart`, `testing.dart` (`FakeCellCalendar`, `cellMyMeetingsWire`), `test/content/calendar_overlays_test.dart` (15).
- [x] Runbooks: `cells-meetings.md` (contract change), `content.md` (6.19 and owner check), `production-promotion-content.md`.

**Acceptance Criteria:**
- Given the local stack, when the E2E runs, then each member's new read lists only their own cell's meetings for 31 days with the cancelled one marked and no venue, My duties lists only their own duty, Pending and guest are refused and My cell is unchanged.
- Given `flutter test`, when run, then guests and Pending see no switches, a member switches both on and sees My duty / My cell rows in time order with a cancelled meeting marked, failures are said plainly, and taps open duty detail or My cell.

## Implementation Notes

- Built in this session (no subagents, owner process change). The Calendar edit is additive: the month grouping now holds `(time, row)` pairs so the member's rows are inserted among the events; events keep their keys and order.
- The overlay repository provider lives in `calendar_overlay_controllers.dart` (not `providers.dart`) and `CellsRepository` is untouched, to avoid conflicts with entry 12 and epic 7.
- pgTAP first tried to end a membership by a direct update; the table's checks require a transfer, so the test transfers the member instead.
- Verification: fresh reset, full pgTAP 69 files / 5,627 tests (the known board-timing check `duties_owner_decisions_test` 32 failed under full-suite load and passed alone); E2E 10/10; Flutter analyze clean and tests pass: design_system 19, client_core 1,101, mobile 95, staff 61.
- Staging: applied verbatim as `20261028064546` (local file renamed); 4 hashes match; boundary/unowned 0; anon refused. Evidence `evidence-6.19/`.

## Plan Change Log

## Review Triage Log

- Review deferred to the epic PR review (owner process change 2026-10-27: no reviews per entry).

## Verification

**Commands:**
- `npx supabase db reset --local && npx supabase test db` (under the shared lock) -- expected: all files pass
- `select count(*) from app.contract_boundary_violations()` / `app.contract_unowned_objects()` -- expected: 0
- `node --test tools/identity-e2e/calendar-overlays.test.mjs` and `node tools/identity-e2e/calendar-overlays.mjs --evidence <file>` (phone switch on) -- expected: all checks pass
- `flutter analyze && flutter test` in the four Flutter packages -- expected: clean, pass
- `node tools/ci/check-migrations.mjs --base origin/main`, `npm run -s ci:secrets` -- expected: pass

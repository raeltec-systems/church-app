---
title: 'Generate a cell''s weekly meetings and show the next one on My cell'
type: 'feature'
ticket: '1'
created: '2026-10-21'
status: 'done'
baseline_revision: '179d805'
route: 'full'
route_source: 'auto'
review: ''
review_source: ''
lenses_ran: []
review_loop_iteration: 0
context:
  - '{project-root}/docs/runbooks/identity-access.md'
  - '{project-root}/docs/runbooks/contracts-and-owner-seams.md'
  - '{project-root}/docs/runbooks/command-foundation.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** A cell has members, a leader and an assistant (2.6) but no meetings, so nothing can be planned, reminded, published or recorded against a meeting, and a member cannot see when and where their cell meets.

**Approach:** Add the Cells meeting kernel (tracer for epic 5): an Admin-set weekly schedule per cell (day, start and end time, private venue with an optional map pin, the church zone and policy version from the Q2 policy), stable meeting ids generated from the schedule and a nominal occurrence key (the church-local date) through the 3.3 calculation (`app.notifications_occurrences`), explicit one-occurrence exceptions (move, cancel, reinstate) by the cell's leader or an Admin through the 1.4 envelope, a staff web **Cell meetings** screen, and the next meeting with its venue on mobile **My cell** for confirmed members only (`app.cells_member_has_private_access`).

**Decisions:**
- Decision (agent, under owner pre-approval): the schedule is one weekly rule per cell (`weekday` 1-7, ISO Monday first, `start_time`, `end_time`, `from_date`), matching functional-requirements.md Setup ("meeting day/time") and the owner's weekly cells; other cadences wait for an owner request.
- Decision (agent, under owner pre-approval): `cells.set_schedule` is Admin only (epic Notes) and uses the **cell revision** as `expected_revision` (aggregate `cells_cell`), so a schedule change and a cell edit cannot overwrite each other.
- Decision (agent, under owner pre-approval): the venue and map pin are cell-private. An Admin **writes** them (Setup) but an Admin without a leader/assistant scope for the cell **reads only that one is set** (`venue_set`, `pin_set`); leaders and assistants of the cell read them on staff web; confirmed members read them on My cell. This keeps "Admin-only access sees no venue" (ticket verify) and the epic's "Admin alone gets metadata only".
- Decision (agent, under owner pre-approval): moves, cancellations and reinstatements are the cell **leader's** or an Admin's (epic Notes); an assistant reads meetings but cannot change them (`forbidden`). A reinstated meeting returns to its nominal time and the regular venue.
- Decision (agent, under owner pre-approval): meetings are generated for a rolling window of today plus 84 days (12 weeks) in church time, when the schedule is set and on every meetings read (idempotent upsert by `(cell_id, occurrence_date)`), so ids never change on regeneration. A schedule change re-times future **scheduled** meetings in place (same id), withdraws future scheduled meetings whose date the new rule no longer produces (`withdrawn`, hidden, revived with the same id if the rule produces the date again) and never touches moved or cancelled exceptions or anything that has started.
- Decision (agent, under owner pre-approval): generation reads only the schedule's stored zone, so reads keep working if the Q2 policy value later fails validation; `set_schedule` needs the effective Q2 policy (`app.notifications_policy()`, fails closed `unavailable {"policy": "gate_closed"}`) and records its zone and version (AD-9).
- Decision (agent, under owner pre-approval): the next meeting is added to `api.cells_my_cell` only (never to the member command outcome, which an Admin acting for a member also receives), as `meetings: {next, cancelled}` or `null` when the member's cell has no schedule.
- Decision (agent, under owner pre-approval): the map pin is shown on mobile as copyable coordinates; opening a maps app needs a new launcher seam and is left to a later entry.
- Decision (agent, under owner pre-approval): the 5.1 rows hold no member personal data except actor attribution; the Cells deletion hook (`app.cells_erase_member`) replaces the deleted member's and account's ids with the nil UUID in the new tables and counts them in `remaining`. No `_rows` file is needed.

## Boundaries & Constraints

**Always:** every state change through `api.cells_command` (1.4 envelope, registered `cells` authorizer, handler/in-scope functions, revision checks, idempotent replay); the replay recheck for `cells_meeting` is real (a current leader of the meeting's cell, or an Admin); every read through an `api` wrapper over a definer `app` function behind `app.identity_require_access()` and the Q4 personal-data gate; venue text starts `SYNTHETIC ` while Q4 is unapproved; times travel as UTC instants and are entered and shown in church time (Africa/Lusaka); new client-executable functions are added to the privilege ledger; ASCII migration, search_path pinned, no anon grants, no DROP/TRUNCATE/`delete from` in the main file.

**Never:** meeting reminders or change notices (5.2), programmes (5.3+), held state or actual leaders (5.8), transfer/deletion effects on meetings beyond actor anonymisation (5.9), a second calendar in Duties, venue or pin in any Admin-only read, a venue in any notification, offline storage of the venue.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Set schedule | Admin, cell revision, weekday/start/end/venue (+pin) | schedule stored with zone + policy version; cell revision + 1; 12 weeks of meetings generated in church time | none |
| Set schedule refused | non-Admin; bad weekday/time/venue; end before start; > 6 h; first set without venue; stale revision; retired cell | `forbidden`; `validation_failed` with field codes; `conflict` + current revision; `not_found` | nothing written |
| Regenerate | schedule unchanged, read again | same meeting ids, no revision change | none |
| Change schedule | new start time; new weekday | future scheduled meetings re-timed in place (same ids); dates no longer produced withdrawn; exceptions untouched | none |
| Move | leader of the cell or Admin, meeting revision, future start/end, optional venue | state `moved`, same id, revision + 1, audit row | stale: `conflict`; started: `validation_failed {"meeting_id":"started"}`; past/too long/out of range: field codes; cancelled: `conflict {"meeting_id":"cancelled"}` |
| Cancel / reinstate | leader or Admin | `cancelled` / back to nominal `scheduled`, same id | assistant, member, other cell's leader: `forbidden` |
| My cell | confirmed member of the cell | `meetings.next` with time, venue, pin, moved flag; cancelled dates before it | no schedule: `meetings: null` |
| My cell, other people | member of another cell; account without member access (pending applicant); Admin-only | no venue for this cell (own cell only / `403`) | read denied or other cell |
| Staff read | leader/assistant: their cells with venue; Admin: all cells, `venue: null`, `venue_set` | | no scope and not Admin: `403 not_granted` |
| Direct table query | any client role on `app.cells_meeting*` | no privilege | permission denied |
| Replay | same request id and body | stored result; revoked leader's replay refused | `forbidden` |
| Deletion | actor erased | actor member/account ids replaced by the nil UUID; check answers 0 | none |

</frozen-after-approval>

## Code Map

- `supabase/migrations/20261007075946_cell_membership.sql` -- Cells template: actor helper, gate checks, text validation, authorizer, in-scope, entry/api wrappers, reads, privilege block.
- `supabase/migrations/20261008102121_notifications_scheduling.sql` -- `app.notifications_policy()`, `app.notifications_occurrences(policy, rule, from, until)` (the 3.3 calculation).
- `supabase/migrations/20261007174952_member_deletion.sql` -- `app.cells_erase_member` (replaced here).
- `supabase/tests/command_foundation_test.sql` -- authenticated EXECUTE ledger to extend.
- `packages/client_core/lib/src/{domain/cell_membership.dart, application/cell_controllers.dart, presentation/cell_screens.dart, adapters/supabase_cells_repository.dart}` -- Cells client.
- `packages/client_core/lib/src/domain/church_time.dart` -- church-time entry and display.
- `packages/client_core/lib/src/presentation/shell_routing.dart`, `apps/staff/lib/app.dart`, `apps/mobile/lib/app.dart`, `packages/client_core/lib/testing.dart` -- routes, destinations, fakes.
- `tools/identity-e2e/duties-rota.mjs`, `harness.mjs`, `duties-shared.mjs` -- E2E pattern (seeded links, fictional numbers, cleanup).

## Tasks & Acceptance

**Execution:**
- [x] `supabase/migrations/20261021073514_cells_meetings.sql` -- schedule, meeting and audit tables; generation; `cells.set_schedule`, `cells.move_meeting`, `cells.cancel_meeting`, `cells.reinstate_meeting`; authorizer, dispatch and in-scope replaced; `api.cells_meetings`; `api.cells_my_cell` with `meetings`; deletion hook replaced; privileges.
- [x] `supabase/tests/cells_meetings_test.sql` -- pgTAP for the matrix; extend `command_foundation_test.sql`.
- [x] Client: `domain/cell_meetings.dart`, controller, staff **Cell meetings** screen (`/cells/meetings`), My cell next-meeting card, adapter, fakes, exports, routes; staff destination for Admin and cell leaders/assistants.
- [x] Tests: `packages/client_core/test/identity/cell_meetings_test.dart`, app tests.
- [x] `tools/identity-e2e/cells-meetings.mjs` + `cells-meetings.test.mjs` -- local E2E of the verify.
- [x] `docs/runbooks/cells-meetings.md` (+ link in `identity-access.md` and `contracts-and-owner-seams.md`).

**Acceptance Criteria:**
- Given the local stack, when the E2E runs, then an Admin sets a weekly schedule on `SYNTHETIC Shikoswe Cell`, the leader moves one meeting and cancels another, regeneration keeps every id, the moved and cancelled meetings keep their ids, a confirmed member reads the next meeting with its venue, and a member of `SYNTHETIC Estates C5/C7 Cell`, an account without member access and Admin-only access read no venue for Shikoswe.
- Given the full local verification, when run, then db:test, db:smoke, the new and existing Cells E2Es, contracts, offline tool tests, flutter analyze/test, secrets, migrations and function-imports checks pass.

## Implementation Notes

- Implemented directly in this session (no implementation subagent).
- Server: `supabase/migrations/20261021073514_cells_meetings.sql`. Generation uses
  `app.notifications_occurrences` with `{zone}` from the stored schedule, so reads do not depend on
  the Q2 gate; only `set_schedule` calls `app.notifications_policy()`. Ids are kept by an upsert on
  `(cell_id, occurrence_date)` that touches a row only when it is in the future and its nominal
  times changed or it was withdrawn (no revision churn on reads).
- Replaced from earlier stories (`create or replace`, privileges preserved): `app.cells_authorize_command`,
  `app.cells_in_scope` (now plpgsql with a real `cells_meeting` recheck), `app.cells_command`,
  `app.cells_my_cell`, `app.cells_erase_member`. Not touched: the hand-pasted `_rows` purge.
- The set_schedule upsert proposes a complete row (venue and pin coalesced from the current
  schedule) because NOT NULL is checked before ON CONFLICT resolves.
- Ledger: `command_foundation_test.sql` (authenticated EXECUTE: `api/app.cells_meetings`). New
  `supabase/tests/cells_meetings_test.sql` (53 checks).
- Clients: `domain/cell_meetings.dart` (strict parsing; instants must end in `Z`),
  `CellMeetingsController` and notices in `application/cell_controllers.dart`, `CellMeetingsScreen`
  and the My cell next-meeting card in `presentation/cell_screens.dart`, route `/cells/meetings`,
  staff destination **Cell meetings** for Admins and cell leaders/assistants, `FakeCells.meetings`.
  Tests: `test/identity/cell_meetings_test.dart` (13).
- Screens follow the design-taste-frontend app-screen rules (owner request, 2026-10-21): each screen
  answers its one question first (My cell: the next meeting leads, its time the largest text; Cell
  meetings: "Next: …" and the moved/cancelled count per cell), the most frequent job (move or
  cancel one meeting) on the row, the rare schedule change behind a button. The skill's inspector
  measures HTML only, so it could not run on the Flutter screens; the rules were applied by hand.
- E2E: `tools/identity-e2e/cells-meetings.mjs` (10 checks, M01-M50) with offline
  `cells-meetings.test.mjs`; fictional numbers `+44 7700 900200-900206`; pgTAP numbers
  `+1 202 555 0141-0148`.
- Portability fixes found running the suites on Windows: `harness.mjs` starts `npx` through a shell
  on Windows; `supabase/tests/lib/local_stack.sh` falls back to Node for `uuid()` without
  `/proc`. No change on Linux.
- Runbook: `docs/runbooks/cells-meetings.md` (links from `identity-access.md` and
  `contracts-and-owner-seams.md`).

## Plan Change Log

## Review Triage Log

## Design Notes

- Nominal occurrence key = the church-local date the rule produces (`occurrence_date`); the stable id is the row id of `(cell_id, occurrence_date)`. Later owners (programmes, attendance, recaps, offerings) reference `meeting_id`.
- Effective time and venue: `starts_at`/`ends_at` on the row (nominal unless moved); venue = the moved venue or the schedule's venue; the pin applies only when the venue is the schedule's.
- States: `scheduled`, `moved`, `cancelled`, `withdrawn` through `app.cells_meeting_state_ok` in a CHECK, so 5.8 can add `held` with `create or replace`.

## Verification

**Commands:**
- `npx supabase db reset && npm run -s db:test && npm run -s db:smoke` -- expected: all pass
- `node tools/identity-e2e/cells-meetings.mjs --evidence <file>.jsonl` and `cells.mjs` -- expected: exit 0
- `npm run -s contracts:test && node --test tools/identity-e2e/*.test.mjs` -- expected: pass
- `flutter analyze && flutter test` in `packages/client_core`, `apps/mobile`, `apps/staff` -- expected: pass
- `npm run -s ci:secrets && npm run -s ci:migrations -- --base origin/ccr-93e730dd-89lbvg && npm run -s ci:function-imports` -- expected: pass

**Local results (2026-10-21, Windows dev box):** db:test PASS (all files); db:smoke PASS (139 API
checks, 260 fixture cases, 15-case matrix); `cells-meetings.mjs` 10/10 and `cells.mjs` 13/13
(`evidence-5.1/`); contracts 265 pass; tool tests 262 pass, 4 fail and ci:policy-test 54 pass, 2
fail, the same failures as the baseline `179d805` on this machine (CRLF checkout and Windows file
modes); flutter analyze clean in client_core, staff and mobile; client_core 666+13 tests pass
except `boundaries_test.dart` and the apps' "only the composition root" tests, which fail on
Windows paths at baseline too; ci:secrets, ci:migrations (base origin/ccr-93e730dd-89lbvg) and
ci:function-imports pass.

**Manual checks (if no CLI):**
- Parent session: apply `20261021073514_cells_meetings.sql` to staging after `20261015190139`, run `tools/ci/verify-hosted.sql` (`expected_env=staging`). No Edge Function change.
- Owner staging walkthrough (`docs/runbooks/cells-meetings.md`, "Owner manual checks").

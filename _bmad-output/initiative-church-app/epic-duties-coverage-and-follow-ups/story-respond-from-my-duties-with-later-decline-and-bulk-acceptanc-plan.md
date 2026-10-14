---
title: 'Respond from My duties with later decline and bulk acceptance'
type: 'feature'
ticket: '5'
created: '2026-10-14'
status: 'in-progress'
baseline_revision: '6927ff83c1287a3371ee44f3f0a994f91488bee1'
route: 'full'
route_source: 'auto'
review: ''
review_source: ''
lenses_ran: []
review_loop_iteration: 0
context:
  - '{project-root}/docs/runbooks/duties.md'
  - '{project-root}/docs/runbooks/command-foundation.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** A member can only Accept or decline a pending duty one at a time from a plain list. They cannot say "Can't make it anymore" after accepting, cannot accept several listed dates together, and have no detail screen with a response footer, calendar export or Home card.

**Approach:**
- **Server.** A forward migration adds two commands through `api.duties_command`:
  - `duties.withdraw_acceptance` ("Can't make it anymore"): accepted to declined, with an optional note. The earlier acceptance time is kept, and the assignment's pending jobs are cancelled.
  - `duties.accept_many`: all-or-nothing acceptance of 1..50 listed pending assignments, each at the revision the member saw.

  It also adds the earlier acceptance and the department's leaders to My duties, and the later decline to the leader board and rota.
- **Mobile.**
  - My duties gets segments, a detail screen with a sticky footer, a decline sheet, selection with a confirmation step, Sending and Not sent per duty, Add to calendar, and a Home My duties card.

**Decisions:**
- Decision (agent, under owner pre-approval): **later decline**.
  - It uses a separate command, so `duties.respond` keeps refusing a second answer (`responded`). Its expected revision is the assignment's revision, and only an accepted (member) answer can be withdrawn before reporting or start time.
  - The row becomes `declined` with `prior_accepted_at`. Its response actor and time are the withdrawal's. The audit records `acceptance_withdrawn`.
  - Pending jobs are cancelled (`responded`). The leader sees "Can't make it anymore" at once on the board and rota, and `confirmed` drops.
  - No leader push is sent. The leader decline alert belongs to the coverage queue (entry 9), which owns leader mobile screens. Until then the board is the signal.
- Decision (agent, under owner pre-approval): **bulk acceptance**.
  - `duties.accept_many {assignments: [{assignment_id, revision}]}` takes an expected revision of null, so each item carries its own revision.
  - It is atomic: if any item is superseded, cancelled, answered, stale or started, nothing is recorded. The command fails with `conflict` and per-item codes `{"assignment:<id>": code, "assignments": "changed"}`.
  - An item the member does not own, an unknown item or a cell-owned item fails the whole command with `not_found`, which discloses nothing.
  - Only acceptance is offered in bulk, with no note. The receipt's aggregate is the first assignment, so a replay is rechecked against the assignee.
- Decision (agent, under owner pre-approval): **overlaps (4.4)**.
  - Accepting creates no commitment, because pending already counts, so neither command runs the override gate or takes member advisory locks.
  - A decline only removes a commitment. A gate racing with it can at worst ask for a reason that is no longer needed, which fails closed.
  - After a later decline no override is carried on a material change (4.4 B2), so the leader is gated again.
  - Members see no overlap warning. The leader's recorded override already covered it, and the member chooses.
- Decision (agent, under owner pre-approval): **lock order**. `accept_many` takes the occurrences FOR SHARE in (start, id) order and then the assignments FOR UPDATE in the same order, and runs Notifications last. This matches the documented order: occurrences, then assignments, then Notifications. The withdrawal locks only its assignment, like `duties.respond`.
- Decision (agent, under owner pre-approval): **cell-owned fails closed**. Every member response path refuses a cell-owned assignment as `not_found`, now including `duties.respond`, until entry 11. My duties stays department-owned.
- Decision (agent, under owner pre-approval): **detail and leader contact**.
  - The detail screen shows the department's current leader and deputy names.
  - No phone or Call action is shown: contact display waits on the Q4 gate and the 2.5 routes, and entry 9 builds the contact routes.
  - Declined future duties stay in Upcoming, labelled "Can't make it".
- Decision (agent, under owner pre-approval): **calendar**.
  - Add to calendar builds an iCalendar (.ics) event and hands it to the phone's share sheet through `share_plus`, the platform handoff. The event has a stable UID, reporting or start time to end time (start + 2 h when there is no end), duty, position, department and place. Instructions and notes are left out.
  - Wording is honest: the app says it handed a calendar file to the phone, never that it was added. The caveat says the copy does not update after a change and points to My duties in the app.
  - The app link scheme is not widened: the deep link back is the in-app route `/duties/assignments/{id}`.
- Decision (agent, under owner pre-approval): **Home**. A minimal member Home route (`/home`, a mobile tab once access is granted) holds the My duties card. Later epics add their own cards to it.

## Boundaries & Constraints

**Always:**
- A forward migration later than `20261014052239`, using `create or replace` and the same signatures.
- ASCII only, `search_path = ''`, new functions revoked, no anon grants, no DROP, TRUNCATE or `delete from`.
- Revision checks and scope-rechecked replay on every command.
- AD-2 order with Notifications last.
- Receipts and audit hold ids, states and counts only.
- Synthetic data only: pgTAP numbers `+44 7700 900550-900559`, E2E numbers `+44 7700 900560-900569`.

**Never:**
- Partial bulk success.
- Showing Accepted before the server confirms it.
- Leader confirmation, coverage queue or contact routes (entry 9).
- Deadline defaults or reminders (entry 8).
- Cell-part member responses (entry 11).
- Editing merged migrations.
- SMS.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected | Error |
|---|---|---|---|
| Later decline | accepted, not started | declined, `prior_accepted_at` kept, jobs cancelled, board shows it | none |
| Withdraw invalid | pending / declined / started / superseded / cancelled / other's / cell-owned | refused, nothing written | `conflict not_accepted` / `responded` / `validation_failed started` / `superseded`+changes / `cancelled` / `not_found` ×2 |
| Bulk accept | 3 of 4 pending selected | 3 accepted, 4th pending; one receipt | none |
| Bulk with a changed date | one item superseded or stale | nothing accepted | `conflict {"assignment:<id>": ...}` |
| Bulk foreign or cell item | one not the member's | nothing accepted | `not_found` |
| Replay | same request id | same envelope, no second audit | none |
| Race | bulk accept vs leader material edit of one date | either all accepted then re-asked, or none accepted | none |
| Offline / timeout | network fails | duty shows Not sent; Check again resends the same id | none |
| Empty / error | no duties / network error | per-segment empty copy / "No connection" banner | none |

</frozen-after-approval>

## Code Map

- `supabase/migrations/20261014001142_duties_revisions.sql` -- `duties_respond` (4.2 body; replaced to refuse cell-owned).
- `supabase/migrations/20261014023442_duties_rota_series.sql` -- `duties_my_assignment_json`, `duties_authorize_command`, `duties_command`, `duties_in_scope` (unchanged), `duties_notify`.
- `supabase/migrations/20261014052239_duties_overlaps.sql` -- lock order header, `duties_assignment_history_guard`, 3-arg `duties_occurrence_json`, 2-arg `duties_rota_occurrence_json`, `duties_my_duties` (department-owned), `duties_state_ok`.
- `supabase/tests/duties_overlaps_test.sql` -- pgTAP helper pattern. No new client grant, so the ledgers are unchanged.
- `packages/client_core/lib/src/{domain/duties.dart, application/duties_controllers.dart, presentation/duties_screens.dart, presentation/shell_routing.dart}`, `lib/testing.dart` fakes.
- `apps/mobile/lib/app.dart`, `apps/mobile/test/mobile_app_test.dart` -- tabs.
- `tools/identity-e2e/duties-overlaps.mjs` -- E2E template.

## Tasks & Acceptance

**Execution:**
- [ ] `supabase/migrations/20261014093012_duties_member_responses.sql` -- column, guard, commands, dispatch, projections, privileges.
- [ ] `supabase/tests/duties_responses_test.sql` -- the matrix (single session).
- [ ] client_core:
  - domain: commands, `priorAcceptedAt`, leaders, segments, `.ics` builder, `DutyCalendarExport` port;
  - controller: `withdraw` and `acceptMany`, with per-duty Sending and Not sent;
  - screens: segments, detail footer, decline sheet, selection and confirmation, calendar, Home card and route, leader "Can't make it anymore";
  - fakes.
- [ ] `packages/client_core/test/duties/duties_responses_test.dart`.
- [ ] `apps/mobile` -- Home tab, `share_plus` calendar adapter, tests.
- [ ] `tools/identity-e2e/duties-responses.mjs` and `.test.mjs`.
- [ ] `docs/runbooks/duties.md`, story 4.5 section with owner manual checks; `evidence-4.5/`.

**Acceptance Criteria:**
- Given the local stack, when `duties-responses.mjs` runs, then:
  - accept, decline and later decline change the leader board at once;
  - bulk acceptance of 3 of 4 dates records exactly three;
  - a stale bulk is refused whole;
  - a replay returns the same result;
  - the race between bulk acceptance and a leader edit never leaves a partial acceptance.
- Given the full local verification, when it runs, then every gate in Verification passes.

## Implementation Notes

## Plan Change Log

## Review Triage Log

## Verification

**Commands:**
- `npx supabase db reset && npm run -s db:test && npm run -s db:smoke` -- expected: all pass.
- `bash <scratchpad>/e2e-4-5.sh` (every E2E, including `duties-responses`) -- expected: each `exit=0`.
- `npm run -s contracts:test && node --test tools/**/*.test.mjs && npm run -s ci:policy-test` -- expected: pass.
- `flutter analyze && flutter test` in `packages/client_core`, `apps/mobile` and `apps/staff`; the duties tests again under `TZ=America/New_York` -- expected: pass.
- `npm run -s ci:secrets && npm run -s ci:migrations -- --base origin/main && npm run -s ci:function-imports` -- expected: pass.

**Manual checks (if no CLI):**
- Parent session: apply the migration to staging and compare per-function md5.
- Owner: run `docs/runbooks/duties.md`, story 4.5, "Owner manual checks".

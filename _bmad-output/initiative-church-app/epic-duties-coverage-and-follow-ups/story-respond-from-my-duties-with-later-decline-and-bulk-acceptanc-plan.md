---
title: 'Respond from My duties with later decline and bulk acceptance'
type: 'feature'
ticket: '5'
created: '2026-10-14'
status: 'built'
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
- [x] `supabase/migrations/20261014093012_duties_member_responses.sql` -- column, guard, commands, dispatch, projections, privileges.
- [x] `supabase/tests/duties_responses_test.sql` -- the matrix (single session).
- [x] client_core:
  - domain: commands, `priorAcceptedAt`, leaders, segments, `.ics` builder, `DutyCalendarExport` port;
  - controller: `withdraw` and `acceptMany`, with per-duty Sending and Not sent;
  - screens: segments, detail footer, decline sheet, selection and confirmation, calendar, Home card and route, leader "Can't make it anymore";
  - fakes.
- [x] `packages/client_core/test/duties/duties_responses_test.dart`.
- [x] `apps/mobile` -- Home tab, `share_plus` calendar adapter, tests.
- [x] `tools/identity-e2e/duties-responses.mjs` and `.test.mjs`.
- [x] `docs/runbooks/duties.md`, story 4.5 section with owner manual checks; `evidence-4.5/`.

**Acceptance Criteria:**
- Given the local stack, when `duties-responses.mjs` runs, then:
  - accept, decline and later decline change the leader board at once;
  - bulk acceptance of 3 of 4 dates records exactly three;
  - a stale bulk is refused whole;
  - a replay returns the same result;
  - the race between bulk acceptance and a leader edit never leaves a partial acceptance.
- Given the full local verification, when it runs, then every gate in Verification passes.

## Implementation Notes

- Implemented directly: no implementation subagent is available inside this builder run. The worktree merged `ccr-93e730dd-89lbvg` first (4.4 is on staging as `20261014052239`). The new version, `20261014093012`, sorts after it.

### Server

`supabase/migrations/20261014093012_duties_member_responses.sql`.

New:
- `app.duties_assignments.prior_accepted_at` and its check `duties_assignments_prior_accepted`;
- the helpers `app.duties_refuse_ended` (the 4.2 stale-response refusal, shared) and `app.duties_assignment_occurrence`;
- the commands `app.duties_withdraw_acceptance` and `app.duties_accept_many`.

Replaced with `create or replace`, same signatures:
- `duties_state_ok` (audit `acceptance_withdrawn`);
- the history guard (`prior_accepted_at` immutable on ended rows);
- `duties_respond` (cell-owned answers `not_found`);
- `duties_authorize_command` and `duties_command` (the two commands; `accept_many` takes a null expected revision);
- `duties_my_assignment_json` (`owner_kind`, `prior_accepted_at`, `leaders`);
- the 3-argument `duties_occurrence_json` and the 2-argument `duties_rota_occurrence_json` (`prior_accepted_at`).

Unchanged: `duties_in_scope`, `duties_my_duties`, the client grants, deletion. ASCII only, with no backslashes, no DROP, TRUNCATE or `delete from`, and `search_path = ''` everywhere. New functions are revoked from every client role.

### Decisions

- Decision (agent, under owner pre-approval): a **declined future duty stays in Upcoming**, labelled "Can't make it" (or "Can't make it anymore"), so the member sees what they told their leader. With nothing waiting for an answer, My duties opens on Upcoming.
- Decision (agent, under owner pre-approval): **Accept carries no note** in the new screens. The optional practical note belongs to the Can't make it sheet, following the design contract. The server still accepts a note with `duties.respond`.
- Decision (agent, under owner pre-approval): **bulk selection** is offered only when two or more dates wait. The client caps it at 50, the server's limit. A failed bulk acceptance keeps the still-pending dates selected; changed dates drop out because they have new ids after the reload.
- Decision (agent, under owner pre-approval): the calendar handoff is `share_plus` 13.3.0 in `apps/mobile` only.
  - It is a new native plugin. The adapter sits behind the client_core port `DutyCalendarExport`, and staff web and tests get "not available".
  - `share_plus` writes the `.ics` to the app's temporary directory for the handoff.

### Tests

- pgTAP: `supabase/tests/duties_responses_test.sql`, 67 checks. The ledgers `duties_tracer_test.sql` and `duties_revisions_test.sql` now subtract the three new My duties keys and the history key, which are checked in the new suite. No client grant changed, so `command_foundation_test.sql` is untouched.
- Client: `packages/client_core/test/duties/duties_responses_test.dart`, 16 tests. Three 4.1/4.2 widget tests were updated for the new flow: Can't make it now opens a sheet, Accept from the list sends no note, and an answered duty moves to Upcoming.
- Mobile: `apps/mobile/test/share_calendar_export_test.dart` (mocked platform channels), a Home tab test, and the 4.1 mobile test (taps Upcoming).
- E2E: `tools/identity-e2e/duties-responses.mjs`, 12 checks, V00-V99, with the offline `duties-responses.test.mjs`.
  - Race V30 ran three rounds and recorded both orders: bulk first (all three accepted, the moved date pending again) and edit first (bulk refused whole, none accepted).
  - Fictional numbers: pgTAP `+44 7700 900550-900559`, E2E `900560-900569`. No earlier suite uses these blocks (grepped).

### Matrix audit

| Row | Covered by |
|---|---|
| Later decline | pgTAP, E2E V12 |
| Withdraw invalid (pending, declined, started, superseded, cancelled, someone else's, cell-owned) | pgTAP, all seven; E2E V12/V13 |
| Bulk 3 of 4 | pgTAP, E2E V20 |
| Bulk with a changed date (responded, stale, superseded, cancelled, started) | pgTAP, E2E V22 |
| Bulk with a foreign, unknown or cell item | pgTAP, E2E V40 |
| Replay | pgTAP, E2E V21 |
| Race | E2E V30 (pgTAP is one session) |
| Offline / timeout | client tests (Not sent, Check again with the same request id; also on Home) |
| Empty / error | client tests (segments, Home) |

## Plan Change Log

## Review Triage Log

## Verification

**Commands:**
- `npx supabase db reset && npm run -s db:test && npm run -s db:smoke` -- expected: all pass.
- `bash <scratchpad>/verify-4-5.sh` (db reset, db:test, db:smoke, then every E2E with a reset before each, including `duties-responses`) -- expected: each `exit=0`.
- `npm run -s contracts:test && node --test tools/**/*.test.mjs && npm run -s ci:policy-test` -- expected: pass.
- `flutter analyze && flutter test` in `packages/client_core`, `apps/mobile` and `apps/staff`; the duties tests again under `TZ=America/New_York` -- expected: pass.
- `npm run -s ci:secrets && npm run -s ci:migrations -- --base origin/main && npm run -s ci:function-imports` -- expected: pass.

**Manual checks (if no CLI):**
- Parent session: apply the migration to staging and compare per-function md5.
- Owner: run `docs/runbooks/duties.md`, story 4.5, "Owner manual checks".

**Results (2026-10-14, after the container restart; resumed builder):**
- db reset 0; db:test PASS (31 files, 2633 tests, including `duties_responses_test.sql` 67); db:smoke pass, no SMS provider.
- Every E2E `exit=0` (23 scripts), `duties-responses` 12/12. Race V30: bulk first twice (3 accepted, moved date pending again), edit first once (bulk refused whole, 0 accepted).
- contracts:test 242/0; node tool tests (CI set) 183/0; ci:policy-test 56/0.
- flutter analyze clean in all three; flutter test client_core 512, apps/staff 35, apps/mobile 49; under `TZ=America/New_York` client_core `test/duties` 84 and apps/mobile 49.
- ci:secrets clean; ci:migrations (`--base origin/main`) ordered, unique, non-destructive; ci:function-imports ok; evidence scan clean.
- Evidence: `evidence-4.5/duties-responses-e2e.jsonl`, `evidence-4.5/e2e-suite-summary.txt`.
- Remaining (not builder steps): staging apply and md5 parity (parent session), staging APK rebuild for `share_plus`, owner manual checks in `docs/runbooks/duties.md` story 4.5.

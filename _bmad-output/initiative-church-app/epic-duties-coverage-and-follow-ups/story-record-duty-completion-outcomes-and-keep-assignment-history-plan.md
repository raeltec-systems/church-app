---
title: 'Record duty completion outcomes and keep assignment history'
type: 'feature'
ticket: '10'
created: '2026-10-14'
status: 'done'
baseline_revision: '3f8e1bfb6a611535e9c3ac940dc1a6f1de50807f'
route: 'full'
route_source: 'auto'
review: ''
review_source: ''
lenses_ran: []
review_loop_iteration: 0
context:
  - '{project-root}/docs/runbooks/duties.md'
  - '{project-root}/docs/runbooks/identity-access.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** After a duty nothing records whether the member served. The leader cannot record Completed, Excused or No-show, cannot correct a mistake with attribution, and neither the member nor their leaders can see the member's assignment history for a fair workload discussion. The prototype maps past duties to Completed automatically; production must keep Unrecorded.

**Approach:** An append-only outcome log per assignment (`app.duties_outcomes`), written by two Duties commands through `api.duties_command` (`duties.record_outcome`, `duties.correct_outcome`) and separate from the response and from coverage (the assignment row and its revision are untouched). Two reads: `api.duties_outcomes` (the department's started duties with their outcomes, for its leaders and deputies) and `api.duties_member_history` (one member's assignments, outcomes and a per-member summary, for the member and their department's leaders and deputies). My duties shows the member's own outcome. Staff web and mobile get an Outcomes screen and a history screen.

**Decisions:**
- Decision (agent, under owner pre-approval): **who.** Outcomes are recorded and corrected only by a current leader or deputy of the duty's department (scope held; an Admin who also holds the scope may act through the scope). The Admin role alone answers `forbidden`; Pastor, another department's leader and members `not_found` (no disclosure). A leader cannot record or correct an outcome on their own assignment (`validation_failed {"assignment_id": "own"}`).
- Decision (agent, under owner pre-approval): **when and on what.** Only on the current assignment of a published duty whose reporting (or start) time has passed (`{"assignment_id": "not_started"}` before). A superseded assignment (`conflict superseded`), a cancelled position, assignment or duty (`conflict cancelled`) has no outcome. No-show only for an accepted assignment (member or Confirmed by leader); a declined or never-answered assignment may be Completed or Excused, never No-show (`{"outcome": "not_accepted"}`). An erased assignee is refused (`{"member_id": "erased"}`). Nothing is ever recorded by time passing: no job, no default; reads show `unrecorded`.
- Decision (agent, under owner pre-approval): **commands.** `duties.record_outcome {assignment_id, outcome, note?}` (expected = the assignment revision; refused `conflict {"assignment_id": "recorded"}` once one exists). `duties.correct_outcome {assignment_id, outcome, note?, reason}` (expected = the current outcome revision; reason 1-200 required; `{"assignment_id": "unrecorded"}` when none; `{"outcome": "unchanged"}` when outcome and note are the same). Outcomes `completed|excused|no_show`; note optional, 1-200 single-line characters. A correction adds a new revision that names the one it replaces; earlier revisions, their actor, time and note are kept. No time limit (ticket unknown); no clearing back to Unrecorded. Answers carry ids, codes and revisions only.
- Decision (agent, under owner pre-approval): **privacy.** Outcome values, notes, correction reasons and history are visible only to the member themselves and to the current leaders and deputies of the duty's department. The Admin role alone, Pastor, other departments' leaders and other members get nothing (reads answer 403 `not_granted`). The board, rota, coverage queue and Admin overview are unchanged (no outcome there). Audit rows carry codes only; no notification is sent; receipts hold no text. No ranking: no read returns per-member figures for more than one member.
- Decision (agent, under owner pre-approval): **reads.** `api.duties_outcomes(from_date?, to_date?, department_id?, duty?)`: church dates (Africa/Lusaka), default today-13 .. today, at most 31 days, never after today; started published duties' positions with a current assignment, their response and provenance, the outcome (or `unrecorded`) with its trail (newest first, at most 20), what may be recorded, per-department counts (positions, unrecorded, completed, excused, no-show, unfilled); at most 1,000 positions (`truncated`). `api.duties_member_history(member_id?, before_at?, before_id?)`: the caller's own (all departments) or, for a leader or deputy, a member of a department they lead (only that department's assignments); 100 per page, newest first, one row per position held (a same-person material revision is not counted twice); a 12-month summary of past duties (held, accepted, declined, unanswered, completed, excused, no-show, unrecorded) plus upcoming and ended (reassigned or cancelled) counts.
- Decision (agent, under owner pre-approval): **erasure.** The Duties deletion hook clears outcome notes and correction reasons about the erased assignee and anonymises `recorded_by_*`; `_remaining` counts them.
- Decision (agent, under owner pre-approval): **gates and locks.** Q4 gate only (no scheduling, so Q2 is not needed). Lock order: grants -> receipt -> department FOR SHARE -> series FOR SHARE -> occurrence FOR SHARE -> assignment FOR UPDATE -> outcome log. No Follow-ups, no Notifications.

## Boundaries & Constraints

**Always:** forward-only migration after 20261014212507; replaced bodies copied from their latest version with every earlier review fix; ASCII, `search_path = ''`, no backslashes, no DROP/TRUNCATE/`delete from`; no anon grant; client grants only the two new reads and their `app` bodies; set-based reads with a timing test under `statement_timeout = '8s'` (a member with many years of duties; a large department's month); fixed church-time dates in tests; SYNTHETIC data, pgTAP +44 7700 900130-900139, E2E 900140-900149.

**Never:** editing merged migrations or frozen blocks; automatic outcomes; public rankings or league tables; outcome text to Admin role alone, Pastor or another department; lifecycle hooks (entry 12), cell-owned duties (11); Edge Function changes; SMS.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Record | leader, accepted past duty, Completed + note | outcome revision 1, attributed; member and leaders see it | not started / superseded / cancelled refused |
| Unrecorded | past duty, nobody records | stays `unrecorded` in every read | none |
| Declined | declined past assignment, No-show | refused `not_accepted` | Excused allowed |
| Cancelled accepted | accepted, duty cancelled | no outcome, not listed | record refused `cancelled` |
| Correct | Completed -> No-show with reason | revision 2; revision 1 value, note, actor, time kept | stale revision `conflict`; no reason refused |
| Own / others | leader on own; other leader, Admin, Pastor, member | `own`; `not_found` / `forbidden`; reads 403 | nothing private disclosed |
| History | member; their leader; other leader | own all departments; leader's department only; 403 | Admin, Pastor 403 |

</frozen-after-approval>

## Code Map

- `supabase/migrations/20261014212507_duties_coverage.sql` -- latest `duties_state_ok`, `duties_authorize_command`, `duties_command`, `duties_my_assignment_json`, `duties_erase_member`, `duties_deletion_remaining` (copy, keep B1/S1-S3/N1-N9 fixes); pattern of `duties_lock_for_leader` (own refusal, AD-2 order) and `duties_coverage` (window, Lusaka zone, 1,000 cap).
- `supabase/migrations/20261013220239_duties_department_tracer.sql` -- `duties_manage_capacity`, `duties_require_open(_read)`, `duties_text`, `duties_uuid`, `duties_audit_event`, `duties_occurrence_start`, `duties_display_name`; index `duties_assignments_member`.
- `supabase/migrations/20261014052239_duties_overlaps.sql` -- `duties_my_duties` (not replaced; calls `duties_my_assignment_json`).
- `supabase/tests/duties_coverage_test.sql` -- fixture helpers to copy; `command_foundation_test.sql` privilege ledger; `duties_tracer_test.sql`, `duties_revisions_test.sql` key-subset checks of My duties.
- `packages/client_core/lib/src/domain/duty_coverage.dart` (part of `duties.dart`), `application/duties_controllers.dart` (`DutiesController.send`, `_success`, `_refusal`), `adapters/supabase_duties_repository.dart`, `presentation/duties_coverage_screens.dart`, `shell_routing.dart` (routes under `/duties`), `testing.dart` fakes; `apps/staff/lib/app.dart` nav.
- `tools/identity-e2e/duties-coverage.mjs` + `.test.mjs` -- E2E pattern (harness, psql clean-up, redacted evidence).

## Tasks & Acceptance

**Execution:**
- [x] `supabase/migrations/20261015002121_duties_outcomes.sql` -- outcome log, vocabularies, commands, reads, replaced bodies, privileges.
- [x] `supabase/tests/duties_outcomes_test.sql`, `duties_outcomes_scale_test.sql`; earlier tests' ledgers and key subsets.
- [x] `packages/client_core` outcomes domain, port, adapter, controllers, screens (Outcomes, history), routes, fakes, tests; staff and mobile nav.
- [x] `tools/identity-e2e/duties-outcomes.mjs` + `.test.mjs`.
- [x] `docs/runbooks/duties.md` story 4.10 section with owner manual checks; `evidence-4.10/`; CI evidence step.

**Acceptance Criteria:**
- Given the local stack, when `duties-outcomes.mjs` runs, then the verify line passes over HTTP (record, correct with prior value and actor kept, unrecorded stays unrecorded, declined cannot be No-show, cancelled accepted duty has no outcome, another member and other readers see no history).
- Given the full local verification, when run, then every listed check passes.

## Implementation Notes

- Implemented directly (no implementation subagent inside this builder run), as 4.1-4.9. CHECKPOINT 1 pre-approved by the owner (owner-decisions-milestone-1.md, -2.md); the frozen block's decisions are the agent's under that pre-approval.
- Server: `supabase/migrations/20261015002121_duties_outcomes.sql` (ASCII, no backslashes, no DROP/TRUNCATE/`delete from`, `search_path = ''` everywhere; new functions revoked from public, anon, authenticated and service_role; client grants only `api.duties_outcomes`/`app.duties_outcomes` and `api.duties_member_history`/`app.duties_member_history` to authenticated).
  - New: table `app.duties_outcomes` (append-only log: `revision` per assignment, `supersedes_outcome_id`, `correction_reason`, `recorded_by_member/account`, `recorded_at` = `clock_timestamp()`; unique (assignment, revision); FK to the assignment `on delete cascade` so earlier E2E clean-ups keep working; RLS on, no client privilege; trigger `duties_outcomes_append_only` refuses every update except erasure clearing text and anonymising the recorder).
  - New functions: `duties_outcome_guard`, `duties_outcomes_allowed`, `duties_outcome_trail`, `duties_outcome_json`, `duties_lock_for_outcome`, `duties_record_outcome`, `duties_correct_outcome`, `duties_church_zone`, the reads `duties_outcomes` and `duties_member_history` (app and api).
  - Replaced bodies (copied from `20261014212507`, 4.9, the latest version of each; every earlier review fix kept; changes marked "Story 4.10"): `duties_state_ok` (vocabulary `completion_outcome`; audit actions `outcome_recorded`, `outcome_corrected`), `duties_authorize_command` and `duties_command` (the two commands), `duties_my_assignment_json` (the member's own `outcome`), `duties_deletion_remaining` and `duties_erase_member` (outcome text and recorders). Not replaced: the board, rota, coverage, Admin overview, `duties_my_duties`, any Follow-ups or Notifications function, the 4.5 `accept_many` (its lock order untouched), the 4.8 reminder plan.
- Decision (agent, under owner pre-approval): an outcome may be recorded once the duty's reporting (or start) time has passed (a No-show is known then); no upper time limit for records or corrections (the ticket's unknown).
- Decision (agent, under owner pre-approval): the commands are keyed to the occurrence aggregate like 4.9 (replay rechecks "still manages the department"); the record's expected revision is the assignment (answer) revision, the correction's the current outcome revision (the kernel refuses an expected revision of 0, so a correction without an outcome is only reachable with a non-zero revision and then answers `unrecorded`).
- Decision (agent, under owner pre-approval): scope is checked through the Identity grant itself (`identity_member_has_scope`), not `duties_manage_capacity`, so an Admin who also leads the department acts as its leader, and the Admin role alone is `forbidden`.
- Decision (agent, under owner pre-approval): the outcomes read lists started positions with a current assignment and also unfilled started positions (assignment null, counted `unfilled`), so a leader sees the whole duty; cancelled positions and cancelled duties are left out.
- Decision (agent, under owner pre-approval): a member's history for a leader requires the member to have (had) a membership row in a department the leader leads or deputises now; Admin role alone and Pastor are refused (`403 not_granted`) like every other non-member reader; an unknown member answers the same.
- Decision (agent, under owner pre-approval): no notification is sent for an outcome (privacy; the member sees it in My duties and the history).
- Clients: `duty_outcomes.dart` (part of `duties.dart`): `DutyOutcomeCommands`, `DutyOutcome`, `OutcomeState`, `OutcomeRevision`, `DutyOutcomeRecord`, `OutcomeAssignment`, `OutcomePosition`, `OutcomeCounts`, `OutcomeDepartment`, `DutyOutcomes`, `OutcomesQuery`, `OutcomeDraft`, `HistoryEntry`, `HistorySummary`, `MemberHistory`, `HistoryCursor`, `HistoryQuery`, the `DutyOutcomesRepository` port; `MyDuty.outcome`. Adapter `SupabaseDutyOutcomesRepository`; provider `dutyOutcomesRepositoryProvider` (wired in `composition.dart`); controllers `DutyOutcomesController` (`record`, `correct`), `MemberHistoryController` (`open`, `older`, `newer`) with their query providers; six notices. Screens (`duties_outcome_screens.dart`, part of `duties_screens.dart`): `DutyOutcomesScreen` (`/duties/outcomes`), `DutyHistoryScreen` (`/duties/history`, `?member=<uuid>`); My duties shows the outcome and a **My duty history** link; the leader Home card links **Record outcomes of past duties** (mobile). Staff sidebar **Outcomes** (leaders and deputies) and **My duty history** (every member). `testing.dart`: `FakeDutyOutcomes`.
- Earlier tests changed for the new behaviour (no merged migration edited): `command_foundation_test.sql` (privilege ledger), `duties_tracer_test.sql` and `duties_revisions_test.sql` (client-executable list; My duties key subsets drop `outcome`), `duties_coverage_test.dart` (the Home card's outcomes link), `staff_app_test.dart` (destinations).
- Matrix audit: Record (pgTAP recording block; E2E O20; widget "record an outcome"), Unrecorded (pgTAP "passing time" block with the worker run; E2E O10; widget "Not recorded"), Declined (pgTAP; E2E O21; widget "no No-show chip"), Cancelled accepted (pgTAP; E2E O22), Correct (pgTAP corrections block incl. stale, reason, unchanged, append-only trigger; E2E O30; widget correction), Own / others (pgTAP who-may-record and privacy sweep over every Duties read; E2E O31, O40; widget own duty), History (pgTAP history block; E2E O40; widget history). All ran and passed (see Verification).
- Fictional numbers: pgTAP +44 7700 900130-900139, E2E 900140-900149 (grepped: no earlier suite uses them). Tests use fixed church-time clock times on whole days (coordinator's note on 3f8e1bf).
- Open owner questions: none new. Q4 (production personal data) stays the fail-closed default: every outcome read and command is behind the Q4 gate.
- Review amendments (independent review, 2026-10-14; the migration was unmerged and unapplied, so `20261015002121_duties_outcomes.sql` was amended in place; the frozen block is unchanged):
  - Decision S1 (erasure race): `duties_erase_member` first locks, in the commands' AD-2 order, the departments and series the member created, then the occurrences they created or hold a position in, then their assignments, all `FOR UPDATE`. It then clears outcome notes, correction reasons and 4.9 contact-attempt notes by the captured assignment ids. `duties_lock_for_outcome` refuses an assignee who is no longer active or is under deletion with `validation_failed {"member_id": "inactive"}`, as `confirm_by_leader` does. Tests: pgTAP refusal for record and correct; two-session probe `evidence-4.10/erase-race-probe.txt` (the erase waited about 2.1 s, then cleared the note; remaining 0). `_remaining` is unchanged: once erase holds the locks no outcome text can be committed after the clear, so counting by member id stays correct within the erase transaction.
  - Decision S2 (window): the client always sends both dates. Without From, the window ends at church today and reaches back `days - 1`; with From, it ends `days - 1` later or at today, whichever is sooner. A From after today is refused in the form ("Must not be after today"). Tests: `OutcomesQuery.toParams(now:)` cases, plus widget tests for the shown From with 31 days and for From cleared.
  - Decision N1: the history summary reads "N past duties assigned".
  - Decision N2: an erased assignee (nil id) gets no record, correct or history action, and shows "This member's record was removed". The refusals `member_id: erased | inactive` map to the notice `outcomeMemberGone` ("No longer a member").
  - Decision N3: the guard trigger now also runs before insert and delete. An insert must name the same assignment's previous revision, and a direct DELETE is refused; only the cascade from the assignment (`pg_trigger_depth() > 1`) may remove a row. The E2E clean-up no longer deletes outcomes directly. This exception is documented in the runbook.
  - Decision N4 (tests added):
    - pgTAP: a revoked deputy (`not_found`); a deputy on hold (`forbidden`); exact codes for Pastor, member and another member (`not_found`, from the kernel's no-disclosure rule); an Admin who also holds the deputy scope (recorded, audited as `department_deputy`); a replay (same receipt, no second row); an unfilled started position (`unfilled` 1, listed without an assignment); the guard's insert and delete refusals.
    - Scale: a consecutive walk of M's 8 history pages with the cursor each page hands out (784 rows, no repeats, every page under 0.1 s).
    - Flutter: Not sent and Check again for an outcome command (same request id and body).
  - Decision N5: both new reads check the Q4 gate before the caller's grants (4.9's reads are unchanged). The erase hook's `comment on function` is replaced so it names stories 4.1-4.10; the 4.9 comment had not been carried over. The function name `app.duties_outcomes` still equals the table name; it is kept, because a rename touches the API name.
  - Decision N6: the history paging buttons are wrapped in `FocusRing`.
  - Fictional numbers: pgTAP also uses +44 7700 900151-900153 for the three added users (900130-900139 were all in use; grepped free).
- Remaining (not builder steps): staging apply of `20261015002121_duties_outcomes.sql` and per-function md5 parity (parent; no owner SQL paste; no Edge Function redeploy); rebuild the staging staff web and APK; owner manual checks in `docs/runbooks/duties.md`, story 4.10 (record in `evidence-4.10/owner-check.md`).

## Plan Change Log

- 2026-10-14: independent review amendments S1, S2, N1-N6 applied to the unmerged migration, clients, tests, E2E clean-up and runbook. They are recorded under Implementation Notes, "Review amendments". The frozen block is unchanged.

## Review Triage Log

- S1 (should, erasure race leaves outcome text): fixed (locks in AD-2 order, then clear by the captured ids; `inactive` refusal; pgTAP and a two-session probe).
- S2 (should, the 31-day window reached past today): fixed (the window is bounded by church today; both dates are sent; client tests).
- N1 (summary copy): fixed.
- N2 (erased assignee actions): fixed (actions hidden; notice).
- N3 (guard gaps): fixed (insert-chain check; direct delete refused, cascade allowed).
- N4 (test gaps): added (revoked, held, exact codes, Admin with scope, replay, page walk, unfilled count, Not sent / Check again).
- N5 (gate order, comment, name clash): gate first in the new reads; erase hook comment fixed; name clash kept and noted.
- N6 (FocusRing on paging): fixed.

## Verification

**Commands:**
- `npx supabase db reset && npm run -s db:test && npm run -s db:smoke` -- expected: pass.
- e2e-main.sh (worktree copy) with `duties-outcomes` appended -- expected: each `exit=0`.
- `npm run -s contracts:test && node --test <CI set> && npm run -s ci:policy-test` -- expected: pass.
- `flutter analyze && flutter test` in `packages/client_core`, `apps/staff`, `apps/mobile`; `TZ=America/New_York` for `test/duties` and mobile -- expected: pass.
- `npm run -s ci:secrets && npm run -s ci:migrations -- --base origin/main && npm run -s ci:function-imports`; evidence scan -- expected: clean.

**Results after the review fixes (2026-10-15):**
- db reset 0; db:test PASS (39 files, 3374 tests; `duties_outcomes_test.sql` 138, `duties_outcomes_scale_test.sql` 16: member history 36-52 ms, a walk of all 8 pages at most 56 ms a page, leader's fortnight 427 ms, 31 days 375 ms); db:smoke pass.
- Every E2E `exit=0` (27 scripts, reset before each, one at a time; `duties-outcomes` 11/11).
- contracts:test 242/0; node tool tests (CI set) 211/0; ci:policy-test 56/0.
- flutter analyze clean in client_core, apps/staff, apps/mobile; flutter test client_core 611 (`duties_outcomes_test.dart` 19), apps/staff 40, apps/mobile 55; under `TZ=America/New_York` client_core `test/duties` + `test/followups` 183 and apps/mobile 55.
- ci:secrets clean; ci:migrations (`--base origin/main`) ordered, unique, non-destructive; ci:function-imports ok; evidence scan clean.
- S1 probe: `evidence-4.10/erase-race-probe.txt`.

**Results of the first build (2026-10-14):**
- db reset 0; db:test PASS (39 files, 3358 tests; `duties_outcomes_test.sql` 126, `duties_outcomes_scale_test.sql` 12: member history 33-44 ms, leader's fortnight 336 ms, 31 days 267 ms under `statement_timeout = '8s'`); passed after a reset three times; db:smoke pass.
- Every E2E `exit=0` (27 scripts, reset before each, one at a time; `duties-outcomes` 11/11) (`evidence-4.10/e2e-suite-summary.txt`).
- contracts:test 242/0; node tool tests (CI set) 211/0; ci:policy-test 56/0.
- flutter analyze clean in client_core, apps/staff, apps/mobile; flutter test client_core 606 (`duties_outcomes_test.dart` 14), apps/staff 40, apps/mobile 55; under `TZ=America/New_York` client_core `test/duties` + `test/followups` 178 and apps/mobile 55.
- ci:secrets clean; ci:migrations (`--base origin/main`) ordered, unique, non-destructive; ci:function-imports ok; evidence scan clean.

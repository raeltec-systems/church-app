---
title: 'Give special assignments as the Pastor and count them in My duty history'
type: 'feature'
ticket: '17'
created: '2026-10-21'
status: 'built'
baseline_revision: '9f02f0badc970a64f0f1f27fceaf838e04585a62'
route: 'full'
route_source: 'owner'
review: ''
review_source: ''
lenses_ran: []
review_loop_iteration: 0
context:
  - '{project-root}/docs/runbooks/duties.md'
  - '{project-root}/docs/runbooks/contracts-and-owner-seams.md'
  - '{project-root}/docs/runbooks/production-promotion-cells.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** Every duty belongs to exactly one department or one cell (`duties_occurrences_one_owner`). The church also gives duties that belong to neither: a one-off church project, leading a service, a task from church leadership. Today they cannot be given, answered, followed up or counted, so a member's duty history is not the whole picture. Owner decision 2026-10-21: only the **Pastor** role gives them; each has **either** a fixed date and time **or** a due date ("done by", no start time); build it as its own story.

**Approach:** A third owner kind on `app.duties_occurrences`: a **special assignment** is held by the Duties module itself for the whole church (`special = true`, no department, no cell) and managed by the current Pastors. It reuses the one-position engine end to end (slot, assignment, revisions, answers, reminders, outcomes, lifecycle, erasure), so My duties, overlaps, reminders and history read it without a second code path. A due date is stored as one instant, the **due moment** (the due date at 18:00 church time), so every time rule (answer-by, Short notice, reminders, "started", outcomes) applies to it unchanged, and it carries no busy time (it never overlaps). Three Duties commands (`duties.give_special`, `duties.revise_special`, `duties.cancel_special`), the 4.10 outcome commands and the 4.9 Confirmed-by-leader command extended to the Pastor, a Pastor read (`api.duties_special_assignments`) and the candidates read extended to a church-wide roster. Staff web gets a Pastor screen **Special assignments**; mobile My duties lists them in the current design; My duty history counts them under their own kind.

**Decisions:**
- Decision (agent, under the owner's 2026-10-21 decision): **owner model.** New column `special boolean not null default false`; the two-owner check is replaced (one statement) by `duties_occurrences_one_owner_kind`: exactly one of `department_id`, `cell_id`, `special`. A special occurrence is always published (never a draft), never in a series. No new table and no new module: Duties owns it, the Pastor role is read from Identity (`duties -> identity` is already a registered dependency), so `app.contract_boundary_violations()` stays 0 and Duties never reads Cells tables. Reads rooted in departments (board, rota, coverage, outcomes, Admin overview, leader history) leave special assignments out by construction.
- Decision (agent): **due-date shape.** `due_on date` (null for a fixed time); for a due date `starts_at` holds the due moment `due_on 18:00` church time (`app.duties_due_moment`), `ends_at` and `reporting_at` are null (checked). 18:00 is chosen so reminders and default answer-by times land in the evening, never at midnight (there are no quiet hours). Derived rules for a due date: answer-by = the Pastor's, or the shared 3.3 lead-time default computed against the due moment (Short notice when it has passed); reminders = the defaults (24 hours before and at the answer-by time, and "Duty coming up" 24 hours before the due moment); **no busy time** (never an overlap, never an override reason); "started" = the due moment has passed (My duties moves it to Past, answers and "Can't make it anymore" close, an outcome may be recorded). A fixed-time special assignment has a start and an optional end (no reporting time) and takes part in overlaps like any duty.
- Decision (agent): **who gives, changes, cancels.** Any current Pastor (role `pastor`; `lead_pastor` alone does not count). `give_special` without the role answers `forbidden`; `revise_special`, `cancel_special`, outcomes and confirmation on a special assignment answer `not_found` to anyone else, Admin included (no disclosure). A Pastor cannot give one to themselves (`validation_failed {"member_id": "own"}`): their own outcome would need another Pastor. The assignee must be an active member (`{"member_id": "unknown"}`); any church member may be given one (no roster).
- Decision (agent): **who sees it.** The member (My duties, My duty history) and every current Pastor (the Pastor read). Department and cell leaders see only a busy time labelled "Special assignment" in an overlap warning; the Admin role, other members and a department leader reading the member's history see nothing of it. The Pastor sees the member's answer note and the overlap reason.
- Decision (agent): **outcomes.** Recorded and corrected by any current Pastor other than the assignee through `duties.record_outcome` / `duties.correct_outcome` with every 4.10 rule (after the start or due moment; No-show only after an acceptance; correction with a reason; no time limit; nothing by time passing). Capacity `pastor` in the audit.
- Decision (agent): **Confirmed by the Pastor.** `duties.confirm_by_leader` accepts a special assignment from a current Pastor (an accountless member, or one reached by phone): the same attributed confirmation as 4.9 (channel and short reason), shown to the member as "Confirmed by the Pastor".
- Decision (agent): **notices.** The member gets the same notices and reminders as any duty (new, changed, details updated, released, cancelled, answer due, coming up); a held or accountless member's notices route to direct contact (shown on the Pastor read as Needs contact). No Pastor alert (overdue, decline, vacancy) is sent: leader alerts stay department-only, as for cell parts (fail closed; open question).
- Decision (agent): **history.** Kind `special` joins `api.duties_member_history` (`kind` filter value and `kinds.special`); its outcome is tracked, so the summary's outcome figures count department duties and special assignments (cell parts stay `not_tracked`); entries carry `due_on`. A department leader reading a member's history still sees only their departments.
- Decision (agent): **lifecycle.** Church deactivation and deletion end future special assignments through the existing owner-agnostic hook (vacated; the Pastor sees Needs a new person and may give it to someone else); a login hold routes contact; department removal does not touch them; erasure is unchanged (no new personal column).
- Decision (agent): **compatibility.** Clients from 4.11 on leave out a My duties row they cannot read ("Update the app to see them"); older history clients label a special row "Department"; an older staff web shows "Could not check their other duties" when a candidate overlaps a special assignment (the server still checks). Production clients are built from `main` at promotion.

## Boundaries & Constraints

**Always:** forward-only migration after `20261021195642`; replaced bodies copied from their latest version with every earlier review fix, changes marked "Special assignments"; ASCII, `search_path = ''`, no backslashes; the one DROP (the two-owner check, replaced in the same statement) carries an `owner-approved-cleanup` marker citing the owner decision; no anon grant; client grants only the new Pastor read (api and app); set-based reads with a timing test under `statement_timeout = '8s'`; fixed church-time dates in tests; SYNTHETIC data, pgTAP phones +1 202 555 0111-0119.

**Never:** editing merged migrations; Duties reading Cells tables; a special assignment in a department or cell read; Pastor alerts; recurring special assignments; drafts; edits to `account_screen.dart`, `inbox_screen.dart`, `apps/mobile/lib/app.dart` or `packages/design_system/lib/src/components.dart` (another agent); production.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Give at a time | Pastor, member, Sun 10:00-12:00 | published special, pending, notice, reminders | non-Pastor `forbidden`; self `own`; past `past` |
| Give by a date | Pastor, due 30 Nov | starts_at = 30 Nov 18:00 Lusaka, no busy time | both or neither timing `validation_failed` |
| Answer | member accepts / can't make it in My duties | recorded; Pastor read shows it | after the due moment `started` |
| Overlap | fixed special over a department duty | override reason required; leader sees "Special assignment" busy time | due date never overlaps |
| Change | Pastor moves the due date / gives it to another | new pending revision, old answer kept, member asked again | stale `conflict`; started `started` |
| Cancel | Pastor cancels | cancelled, member notified, listed nowhere | non-Pastor `not_found` |
| Outcome | Pastor records after the due moment, corrects with reason | recorded, attributed; history counts it | before `not_started`; own `own`; No-show unanswered `not_accepted` |
| History | member filters Special | entries of kind special, `kinds.special` | `kind` unknown `validation_failed` |
| Privacy | Admin, leader, other member | no Pastor read (403), not_found on commands, history without it | nothing disclosed |

</frozen-after-approval>

## Code Map

- `supabase/migrations/20261014052239_duties_overlaps.sql` -- the one-owner check's origin; `duties_busy_range`, `duties_overlap_counts`, `duties_conflicts_json` (latest), `duties_candidates`.
- `supabase/migrations/20261015035112_duties_owner_operations.sql` -- latest `duties_apply_change`, `duties_assignment_reminder_check`, `duties_update_reminder_check`, `duties_my_assignment_json` (cell-owner precedent).
- `supabase/migrations/20261021101314_duties_cell_confirmation.sql` -- latest `duties_lock_for_confirm`, `duties_in_scope`, `duties_authorize_command`.
- `supabase/migrations/20261015190139_duties_owner_decisions.sql`, `20261015110202_duties_lifecycle.sql` -- latest `duties_state_ok`, `duties_command`.
- `supabase/migrations/20261015002121_duties_outcomes.sql` -- `duties_lock_for_outcome`, `duties_church_zone`.
- `supabase/migrations/20261021195642_duties_history_all_kinds.sql` -- `duties_member_history`.
- `supabase/tests/duties_history_kinds_test.sql`, `command_foundation_test.sql` (privilege ledger).
- `packages/client_core/lib/src/domain/duties.dart` (`DutyOwnerKind`, `MyDuty`, `DutyConflict`, `DutyCandidates`, `CandidateQuery`), `duty_outcomes.dart` (history), `duty_calendar.dart`; `application/duties_controllers.dart`; `adapters/supabase_duties_repository.dart`; `presentation/duties_screens.dart`, `duties_outcome_screens.dart`, `shell_routing.dart`; `testing.dart` fakes; `apps/staff/lib/app.dart` nav.

## Tasks & Acceptance

**Execution:**
- [x] `supabase/migrations/20261021211830_duties_special_assignments.sql` -- owner kind, due date, vocabulary, the three commands, extended locks, reads, replaced bodies, privileges.
- [x] `supabase/tests/duties_special_assignments_test.sql`, `duties_special_assignments_scale_test.sql`; earlier tests' ledgers and key subsets.
- [x] `packages/client_core`: special owner kind and due date in the domain, the Pastor read and commands (port, adapter, controller, fakes), the Special assignments screen and route, My duties and history in the current design, tests; staff nav.
- [x] `docs/runbooks/duties.md` section, `docs/runbooks/production-promotion-cells.md` row, `docs/runbooks/contracts-and-owner-seams.md` item 9; staging apply and parity.

**Acceptance Criteria:**
- Given a fresh local reset, when `npx supabase test db` runs, then every file passes and `app.contract_boundary_violations()` is 0.
- Given `flutter analyze` and `flutter test` in `packages/client_core`, `apps/staff` and `apps/mobile`, then all pass.
- Given staging, when the migration is applied verbatim, then each changed function's md5 matches the local reset and the boundary check is 0.

## Implementation Notes

- Implemented directly in one builder run (owner decision 2026-10-21; the owner could not be asked during the run, so every choice below is the agent's safe default and the true owner decisions are listed under Open owner questions).
- Server: `20261021211830_duties_special_assignments.sql` (ASCII, no backslashes, `search_path = ''`; the one DROP, the two-owner check, is replaced in the same `alter table` by the three-owner check and carries an `owner-approved-cleanup` marker citing the owner decision; no row is deleted).
  - New: columns `special`, `due_on`; checks `duties_occurrences_one_owner_kind`, `_special_shape` (never a draft, never in a series), `_due_on` (special only, no end, no reporting time); index `duties_occurrences_special`; functions `duties_due_moment`, `duties_special_timing`, `duties_lock_special`, `duties_give_special`, `duties_revise_special`, `duties_cancel_special`, `duties_special_json`, `duties_special_assignments` (app and api; the only new client grant).
  - Replaced (latest version copied, earlier review fixes kept, changes marked "Special assignments"): `duties_state_ok` (capacity `pastor`), `duties_busy_range` (null for a due date), `duties_overlap_counts` (due dates out), `duties_conflicts_json` (kind `special`; full to a Pastor, a busy time to others), `duties_in_scope` (replay: a Pastor), `duties_authorize_command` (the three commands; the Pastor grant share-locked), `duties_command` (routing; `give_special` takes no expected revision), `duties_my_assignment_json` (owner kind, `due_on`, the Pastors as contacts, the giver first), `duties_assignment_reminder_check` and `duties_update_reminder_check` (an active member, as a cell part), `duties_apply_change` (no roster for a special assignment; `due_on` written with the other fields), `duties_lock_for_outcome` and `duties_lock_for_confirm` (a Pastor, capacity `pastor`), `duties_candidates` (a Pastor's church-wide check), `duties_member_history` (kind `special`). Comments of `api.duties_command` (names every routed command) and the history and candidates reads updated.
  - Not replaced: department and cell reads, leader alerts (`duties_plan_reminders`, `duties_after_answer`), lifecycle (`duties_vacate_member` is owner-agnostic), erasure (no new personal column), `duties_cancel_one`, the answer commands.
- Decision (agent): the give, change and cancel commands audit as `duty_published` (code `special`), `duty_revised` and `occurrence_cancelled` with capacity `pastor`; no new audit action was needed.
- Decision (agent): a special assignment has no reporting time and no creator reminders (the defaults apply); its answer-by may be set by the Pastor.
- Decision (agent): the Pastors' read lists published special assignments from 90 days ago on (500 at most) and the active members (1000 at most, the reader left out). The candidates read for a special assignment lists the same members with their load and overlaps (a due date: `400 window`, the client does not ask).
- Earlier tests changed for the new behaviour (no merged migration edited): `command_foundation_test.sql`, `duties_tracer_test.sql`, `duties_revisions_test.sql` (client-executable ledgers; My duties key subsets drop `due_on`), `duties_history_kinds_test.sql` (`kinds.special`), Flutter `duties_responses_test.dart` (`pastor` is now a known leader role).
- Clients: `duty_special.dart` (part of `duties.dart`): `DutySpecial`, `SpecialTiming`, `SpecialHolder`, `SpecialVacancy`, `SpecialAssignment`, `SpecialAssignments`, `SpecialDraft`, `SpecialEdit`, `DutySpecialRepository`, `givesSpecialAssignments`; `DutyOwnerKind.special`, `DutyTimes.dueOn`, `MyDuty.isSpecial`/`answersTo`, `DutyLeaderName.isPastor`, `DutyConflict.isSpecial`, `CandidateQuery.special`, `MemberHistory.specialCount`; `DutyCalendar` writes an all-day entry for a due date. Adapter `SupabaseDutySpecialRepository`; provider `dutySpecialRepositoryProvider`; controller `DutySpecialController` (`give`, `revise`, `cancel`, `confirm`, `record`, `correct`); notices `specialGiven`, `specialCancelled`, `specialOwn`; screen `DutySpecialScreen` (`duties_special_screens.dart`, `/duties/special`); staff sidebar **Special assignments** for the Pastor role; `testing.dart`: `FakeDutySpecial`, `specialAssignmentData`, `specialHolderData`.
- Design (app-screens rules): the Pastors' screen answers "which special assignments need me?" first (a finding line under the title, then **Needs you**: outcomes to record and ones that need someone new), its main job is one click away (**Give a special assignment**), one status mark per row, the one action a row that needs doing carries is visible on the row, details and every other action on the opened row. My duties keeps the grouped rows with one status mark; a due date reads "Due 30 Nov" on the row, the Home card, the bulk dialog and the history, and **Due** on the duty. No new design-system component; nothing in the files the other agent owns.
- Matrix audit: Give at a time / by a date, Answer, Overlap, Change, Cancel, Outcome, History, Privacy: each in `duties_special_assignments_test.sql` (and the client side in `duties_special_test.dart`). No E2E script was written (see Remaining).

## Open owner questions

1. **Pastor alerts.** Should a Pastor be alerted when a special assignment's answer is overdue, when the member declines, or when it is left without anyone (member left the church)? Default: no alert (as for cell parts); the Pastors read it on their screen.
2. **Early completion.** May a Pastor record Completed before a due date (the work handed in early)? Default: only after the due moment (18:00 church time on the due date), as for every duty.
3. **The due moment.** A due date ends at 18:00 church time (reminders and default answer-by times then land in the evening, never at midnight). Is 18:00 right, or should it be the end of the day?
4. **Answer-by for a due date.** The default answer-by is the church's lead-time default counted back from the due moment (two weeks before for a task a month or more away). Should "done by" tasks default to a shorter answer window from the day they are given?
5. **Who sees them.** Only the member and the Pastors. Should the Admin role, or the department leaders, see a member's special assignments (for example in the member's history)?
6. **Giving one to yourself.** A Pastor cannot give themselves one (another Pastor would record its outcome). Keep?
7. **No Pastor left.** If the Pastor role is removed from the last Pastor, nobody can change, cancel or record existing special assignments. Should that removal ask for a handover first, as for a department's last leader?
8. **Migration marker.** The migration's `owner-approved-cleanup` line cites the 2026-10-21 decision for replacing the two-owner check (no data removed). Please confirm.

## Plan Change Log

- 2026-10-21: built; the frozen block is unchanged.

## Review Triage Log

- No independent review in this run.

## Verification

**Commands:**
- `npx supabase db reset --local && npx supabase test db` -- expected: pass.
- `node tools/ci/check-migrations.mjs --base origin/main` -- expected: this migration allowed by its marker.
- `flutter analyze && flutter test` in `packages/client_core`, `apps/staff`, `apps/mobile` -- expected: pass.
- Staging: apply verbatim, rename to the hosted version, compare md5 of every `app`/`api` `duties*` function with a fresh local reset, boundary check 0.

**Results (2026-10-21):**
- db reset 0; `npx supabase test db` PASS (57 files, 4,370 tests; `duties_special_assignments_test.sql` 102, `duties_special_assignments_scale_test.sql` 10: the Pastors' read 0.6 s, candidates of 1,000 members 2.4 s). One earlier full run failed only `duties_owner_operations_scale_test.sql` 10 (a 2 s board timing under suite load; 1.1 s alone, unchanged by this story); the next full run passed.
- `app.contract_boundary_violations()` 0 locally and on staging.
- `check-migrations --base origin/main`: this migration allowed by its marker; it also reports the pre-existing `drop function` lines of `20261021195642_duties_history_all_kinds.sql`, which has no marker (not changed here).
- flutter analyze clean in `packages/client_core`, `apps/staff`, `apps/mobile`; flutter test: client_core 752 (`duties_special_test.dart` 18), apps/staff 41, apps/mobile 56.
- Staging (`tmurpotfluignacfueki`): applied as `20261021211830`; all 193 `app`/`api` `duties*` functions identical to a fresh local reset (aggregate md5 `aee5e8f613e2aa39fc17407219bd35f8`); boundary check 0; the new checks present and the two-owner check gone; the Pastors' read executable by authenticated only.

**Remaining (not builder steps):**
- An HTTP E2E script (`tools/identity-e2e/duties-special.mjs`) was not written.
- Rebuild the staging staff web and APK from this branch; owner manual checks in `docs/runbooks/duties.md`, Special assignments (record in `evidence-4.17/owner-check.md`).
- Independent review before merge; the open owner questions above.

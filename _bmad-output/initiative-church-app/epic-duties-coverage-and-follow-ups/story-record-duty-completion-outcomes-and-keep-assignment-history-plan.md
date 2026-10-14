---
title: 'Record duty completion outcomes and keep assignment history'
type: 'feature'
ticket: '10'
created: '2026-10-14'
status: 'in-progress'
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
- [ ] `supabase/migrations/<after 20261014212507>_duties_outcomes.sql` -- outcome log, vocabularies, commands, reads, replaced bodies, privileges.
- [ ] `supabase/tests/duties_outcomes_test.sql`, `duties_outcomes_scale_test.sql`; earlier tests' ledgers and key subsets.
- [ ] `packages/client_core` outcomes domain, port, adapter, controllers, screens (Outcomes, history), routes, fakes, tests; staff and mobile nav.
- [ ] `tools/identity-e2e/duties-outcomes.mjs` + `.test.mjs`.
- [ ] `docs/runbooks/duties.md` story 4.10 section with owner manual checks; `evidence-4.10/`; CI evidence step.

**Acceptance Criteria:**
- Given the local stack, when `duties-outcomes.mjs` runs, then the verify line passes over HTTP (record, correct with prior value and actor kept, unrecorded stays unrecorded, declined cannot be No-show, cancelled accepted duty has no outcome, another member and other readers see no history).
- Given the full local verification, when run, then every listed check passes.

## Implementation Notes

## Plan Change Log

## Review Triage Log

## Verification

**Commands:**
- `npx supabase db reset && npm run -s db:test && npm run -s db:smoke` -- expected: pass.
- e2e-main.sh (worktree copy) with `duties-outcomes` appended -- expected: each `exit=0`.
- `npm run -s contracts:test && node --test <CI set> && npm run -s ci:policy-test` -- expected: pass.
- `flutter analyze && flutter test` in `packages/client_core`, `apps/staff`, `apps/mobile`; `TZ=America/New_York` for `test/duties` and mobile -- expected: pass.
- `npm run -s ci:secrets && npm run -s ci:migrations -- --base origin/main && npm run -s ci:function-imports`; evidence scan -- expected: clean.

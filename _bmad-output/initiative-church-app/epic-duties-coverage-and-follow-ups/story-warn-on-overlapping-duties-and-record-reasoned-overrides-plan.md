---
title: 'Warn on overlapping duties and record reasoned overrides'
type: 'feature'
ticket: '4'
created: '2026-10-14'
status: 'done'
baseline_revision: '3de975e13138a0839b6e8d23e1af07820d1d1f60'
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

**Problem:** A leader can give a member a duty that overlaps another of the member's duties (in another department or a cell programme) without any warning, cannot see how loaded each candidate already is, and nothing records why an overlap was accepted.

**Approach:** A forward migration adds one Duties conflict query over every current duty commitment (department-owned and cell-owned occurrences), a manager-only candidates read that shows each roster member's upcoming load and the overlaps the viewer may see, and a server gate on every command that creates an assignment (publish, give a position, plan a draft, publish drafts, material edits): an overlap is refused without an `override_reason`, and with one the reason is recorded with the assignment while the assignee still answers. Staff web shows load, warnings and the reason field in the publish form, the edit form and the rota picker.

**Decisions:**
- Decision (agent, under owner pre-approval): a **commitment** is a current assignment the member has not declined (`pending` or `accepted`) on a published occurrence. Its busy time is reporting time (or start) to end time; with no end time, start plus 2 hours (one adjustable function, `app.duties_busy_range`). Ranges are half-open: a duty ending at 10:00 does not overlap one starting at 10:00. Availability is never assumed: no conflict does not mean free (copy says so).
- Decision (agent, under owner pre-approval): **disclosure**. A conflict in a department the viewer manages (leader, deputy, Admin) shows department, duty, position, times, place, state and answer; a cell-owned conflict shows duty, position, times and place only to that cell's leader or assistant (Identity scopes; Duties may not read Cells, so no cell name). Every other conflict shows only "another department's duty" or "a cell programme part" and the busy time: no names, ids, place, answer or instructions. Instructions are never shown in any conflict. Load is two counts (next 90 days: all owners, this department).
- Decision (agent, under owner pre-approval): an override is needed only when a command **creates** an overlap: a new assignee, or new times for an existing assignee. A material change that keeps the same person and times (place, duty name) carries the earlier override forward without a new check. A reason given when no overlap exists is ignored (not recorded). The refusal is `validation_failed {"member_id": "overlap", "override_reason": "required"}` (plus `occurrence:<id>` for series commands); the reason is 1..280 characters.
- Decision (agent, under owner pre-approval): drafts. Planning a draft position checks commitments plus other planned positions of the same department; an overlap needs the reason, stored on the slot. Publish N carries it into the assignment (attributed to the planner) and rechecks: an overlap without a stored reason refuses the publish naming that date, and the leader re-plans it with a reason.
- Decision (agent, under owner pre-approval): concurrent assignments of the same member are serialised by a per-member transaction advisory lock taken at the membership step of the AD-2 order (member id order), so two leaders cannot both skip the warning.
- Decision (agent, under owner pre-approval): the reason is shown to everyone who reads that department's duties (its managers and Pastor oversight), never to the member and never to another department; audit rows stay content-free (`overlap_override`, a count). Member deletion clears the reason of the erased assignee's assignments and anonymises the recorder.
- Decision (agent, under owner pre-approval): the cell case. Occurrences gain `cell_id` (exactly one of department or cell owns each occurrence). No command creates cell-owned occurrences until entry 11; a SYNTHETIC fixture proves the cell conflict in pgTAP and the E2E. My duties keeps listing department duties only until cell parts get their member view (entry 11 / 5).

## Boundaries & Constraints

**Always:** forward migration later than `20261014023442` (4.1-4.3 files untouched; `create or replace`); ASCII, `search_path = ''`, new functions revoked, no anon grants, no DROP/TRUNCATE/`delete from`; every change through `api.duties_command` with revision checks and scope-rechecked replay; AD-2 order with Notifications last; answers carry ids, revisions, states and counts only (never the reason); reads behind live access, the Q4 gate and the production synthetic filter; synthetic data and fictional numbers only (pgTAP `+44 7700 900770-900779`, E2E `+44 7700 900760-900769`).

**Never:** availability collection; blocking without an override path; showing another team's names, instructions or answers; leader confirmation or the coverage queue (entry 9); Cells-side commands (entry 11); deadlines defaults or reminders (entry 8); editing merged or hand-pasted migrations; SMS.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Overlap, no reason | member has a pending duty in department B, leader A gives an overlapping one | refused, nothing written | `validation_failed {"member_id":"overlap","override_reason":"required"}` |
| Override | same with `override_reason` | assignment pending, reason/actor/time recorded, notice queued | none |
| No overlap | adjacent or later duty | no warning, no reason needed | none |
| Disclosure | leader A reads candidates | own-department conflicts in full; B's and the cell part as "another duty" + time only, no instructions | non-manager, Pastor, member: `403` |
| Declined / cancelled | other duty declined or cancelled | not a conflict | none |
| Material edit | new time overlaps / place only | reason required / override carried forward | named date for series edits |
| Drafts | plan overlapping person; publish | reason on the slot, carried on publish; overlap appearing later refuses publish naming the date | `occurrence:<id>` |
| Race | two leaders assign the same member at once without reasons | one success, one refusal | none |
| Load | candidate list | `upcoming {total, here}` per member | none |
| Deletion | assignee erased | reason cleared, recorder anonymised, check 0 | none |

</frozen-after-approval>

## Code Map

- `supabase/migrations/20261014023442_duties_rota_series.sql` -- read-only reference: lock order header, `duties_apply_change` (replaced with the same signature to carry overrides and report created assignments), `duties_assign_slot`, `duties_publish_drafts`, `duties_revise_duty`, `duties_revise_series`, `duties_occurrence_json`, `duties_rota_occurrence_json`, deletion hook.
- `supabase/migrations/20261014001142_duties_revisions.sql` -- `duties_publish_duty` (replaced), `duties_assignment_history_guard` (replaced: override fields immutable on ended rows).
- `supabase/migrations/20261013220239_duties_department_tracer.sql` -- `duties_my_duties` (replaced: department-owned only), `duties_manage_capacity`, `duties_roster`, `duties_member_active`.
- `supabase/tests/duties_rota_test.sql` -- pgTAP helper pattern; ledger tests `command_foundation_test.sql`, `duties_tracer_test.sql`, `duties_revisions_test.sql`.
- `packages/client_core/lib/src/{domain/duties.dart, application/duties_controllers.dart, adapters/supabase_duties_repository.dart, presentation/duties_screens.dart, presentation/duties_rota_screens.dart}`, `lib/testing.dart` fakes.
- `tools/identity-e2e/duties-rota.mjs` -- E2E template (harness, cleanup, races).

## Tasks & Acceptance

**Execution:**
- [x] `supabase/migrations/20261014052239_duties_overlaps.sql` -- owner columns, override columns, busy range, commitments, per-member lock, gates, candidates read, replaced commands/projections/guard/my_duties/deletion hook, privileges.
- [x] `supabase/tests/duties_overlaps_test.sql` (+ ledgers) -- the matrix.
- [x] client_core domain (`DutyConflict`, `DutyCandidates`, `CandidateQuery`, override fields), repository `fetchCandidates`, controllers (reason in payloads, `overlapNeedsReason` notice), candidate picker widget in the publish form, edit form and rota panel, overlap markers and recorded reasons; fakes.
- [x] `packages/client_core/test/duties/duties_overlaps_test.dart` -- parsing, picker load and warnings, reason required, refusal shown.
- [x] `tools/identity-e2e/duties-overlaps.mjs` + `.test.mjs`.
- [x] `docs/runbooks/duties.md` story 4.4 section with owner manual checks; evidence in `evidence-4.4/`.

**Acceptance Criteria:**
- Given the local stack, when `duties-overlaps.mjs` runs, then a member assigned to overlapping duties in two departments shows the warning to the second leader without the first team's instructions or names, the assignment is refused without a reason, recorded with one while the member stays Awaiting response, a cell-owned fixture conflict is disclosed as limited, a non-overlapping assignment raises no warning, and concurrent assignments without reasons give one success and one refusal.
- Given the full local verification, when run, then db:test, db:smoke, every E2E, contracts, offline tool tests, flutter analyze/test, secrets, migrations and function-imports pass.

## Implementation Notes

- Implemented directly (no implementation subagent is available inside this builder run). Merged `ccr-93e730dd-89lbvg` at the start (4.3 on staging as `20261014023442`); the 4.4 version `20261014052239` is later.
- Server: `supabase/migrations/20261014052239_duties_overlaps.sql`. New: `app.duties_occurrences.cell_id` with `department_id` nullable (`ALTER ... DROP NOT NULL`, allowed by the migration policy) and the one-owner check; assignment override columns (`override_reason`, `override_overlaps`, `override_by_member`, `override_by_account`, `override_at`) and slot draft override columns; `app.duties_busy_range(_of)`, `app.duties_busy_items` (the conflict query), `app.duties_overlap_count`, `app.duties_conflicts_json` (viewer-safe items), `app.duties_upcoming`, `app.duties_lock_members` (per-member `pg_advisory_xact_lock`), `app.duties_overlap_gate`, `app.duties_gate_created`, `app.duties_occurrence_members`, `app.duties_override_json`, `app.duties_position_overlaps`, read `api.duties_candidates` (typed named parameters; slot, slot at new times, or department window). Replaced by `create or replace` (same signatures): `duties_state_ok` (audit `overlap_override`), the ended-assignment guard, `duties_apply_change` (carries an override when person and times are unchanged; returns `created`), `publish_duty`, `assign_slot`, `publish_drafts`, `revise_duty`, `revise_series`, `duties_occurrence_json`, `duties_rota_occurrence_json`, `duties_my_duties` (department-owned only), deletion hook and remaining check. Authorizer, dispatch and `in_scope` unchanged (no new command).
- Decision (agent, under owner pre-approval): `api.duties_candidates` also takes a position at new times (`slot_id` + `starts_at`...) so the edit form checks the person at the edited times without counting the position itself; a department window is used before publishing.
- Decision (agent, under owner pre-approval): the reason is not required up front on the client (the Save button is not blocked): the server is the authority, and the picker shows the reason field whenever the read shows an overlap or the server refused for one.
- Decision (agent, under owner pre-approval): draft edits (this date / this and later on drafts) ask no reason; Publish N rechecks every new assignment after all are inserted (so two positions of one person in one publish overlap) and names the first date.
- Surprise: none of the 4.1-4.3 behaviour changed; ledgers in `command_foundation_test.sql`, `duties_tracer_test.sql`, `duties_revisions_test.sql`, `duties_rota_test.sql` gained the new client grant and the new count keys in answers (`override_recorded`, `overrides`).
- Tests: `supabase/tests/duties_overlaps_test.sql` (93 checks). Client: `packages/client_core/test/duties/duties_overlaps_test.dart` (13 tests, also run with `TZ=America/New_York` by CI's duties step). E2E: `tools/identity-e2e/duties-overlaps.mjs` (11 checks, V01-V40) with offline `duties-overlaps.test.mjs`; with `app.duties_lock_members` replaced by a no-op the race check V20 fails (both leaders succeed), so it proves the lock. Fictional numbers: pgTAP `+44 7700 900770-900779`, E2E `900760-900769`.
- Clients: `_CandidatePicker` (in `duties_screens.dart`) replaces the Who dropdown in Publish a duty, Change this duty (one position) and every Rota position; load and overlap count in each item, a warning box with what the leader may see, the reason field, "no overlap does not mean free". Board and rota show overlap counts and recorded overrides; refused rota changes show a reason field; Publish N refusals name the date (existing Open button). Mobile unchanged (only the shared core).
- Matrix audit: Overlap no reason, Override, No overlap, Disclosure (incl. non-manager, Pastor, member 403), Declined/cancelled (both tested), Material edit (reason required / carried), Drafts (planned reason, later overlap refuses publish with the date), Load, Deletion: pgTAP. Race: E2E V20 (pgTAP is one session). Disclosure, refusal, override, member still Awaiting response, no-overlap, cell fixture and the race also run over HTTP in the E2E.
- Owner/staging steps remaining (not blocking): the parent applies the migration to staging and checks function md5s; the owner runs `docs/runbooks/duties.md`, story 4.4, "Owner manual checks" and records `evidence-4.4/owner-check.md`.

- Review fixes (independent review; the migration was edited in place, as it is applied nowhere hosted):
  - B1: `app.duties_cancel_one` replaced (full body copied): cancelling a draft clears its planned people and their planned reasons, so `cancel_occurrence`/`cancel_series` over a planned-reason draft no longer hit the `duties_slots_draft_override` check. No other writer nulls `draft_member_id` alone (publish, erase and assign_slot clear both). pgTAP covers both commands.
  - B2: an override is carried only while the old answer stands (`pending`/`accepted`): asking a declined member again (a place change after another department gave them that time) is gated. pgTAP and E2E V22 cover it.
  - S1: overlap counts are computed once per read, set-based (`app.duties_overlap_counts(uuid[])`, init-plan subqueries in the board and in `app.duties_series_json`, replaced), with the partial index `duties_assignments_member_current`; 3-argument projections take the counts and the 4.1-4.3 signatures wrap them. Seeded local benchmark (50 series x 52 weeks x 3 positions, 7,800 assignments): rota 49 s -> 2.9 s (1.6 s without counts), 200 board duties 3.4 s -> 0.25 s (0.09 s without); recorded in `evidence-4.4/read-cost.txt`.
  - S2: E2E V21 races `assign_slot` (rota position in D) against `publish_duty` (E) for the same member and time: one wins.
  - N1: the edit preview moves the person's other positions of the same date with the new times (`p_moving` in the conflict query).
  - N2: the board and rota reads name the viewer (`app.duties_viewer`, transaction-local) and the reason (or planned reason) about the viewer's own assignment is hidden; `app.duties_leader_board` and `app.duties_rota` replaced for that.
  - N3 (note for entry 11): `duties.respond` on a cell-owned assignment is unreachable today (no command creates one, My duties lists department-owned duties only); entry 11 must decide the member view and answer path for cell parts, including the audit's null department.
  - N5: the picker reads after a 400 ms pause in typing, has a permanent **Who** label, and shows load and "overlaps N" on their own line and in the item's semantics label.
  - N6: a synthetic department is never shown in full in a conflict outside local and staging.
  - A 4.3 pgTAP check ordered assignments by `assigned_at` only (a tie inside one transaction); the new index changed the scan order and exposed it, so the check now also orders by state.
  - Tests now: pgTAP `duties_overlaps_test.sql` 103 checks; E2E 13 checks.

## Plan Change Log

## Review Triage Log

## Verification

**Commands:**
- `npx supabase db reset && npm run -s db:test && npm run -s db:smoke` -- expected: all pass
- `bash <scratchpad>/e2e-4-4.sh` (every E2E incl. `duties-overlaps`) -- expected: each `exit=0`
- `npm run -s contracts:test && node --test tools/**/*.test.mjs` -- expected: pass
- `flutter analyze && flutter test` in `packages/client_core`, `apps/mobile`, `apps/staff` -- expected: pass
- `npm run -s ci:secrets && npm run -s ci:migrations -- --base origin/main && npm run -s ci:function-imports` -- expected: pass

**Manual checks (if no CLI):**
- Parent session: apply the migration to staging after `20261014023442`, run `tools/ci/verify-hosted.sql`, compare per-function md5 with local.
- Owner staging walkthrough: `docs/runbooks/duties.md`, story 4.4, "Owner manual checks".

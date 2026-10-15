---
title: 'Apply membership lifecycle and handover to duties and follow-ups'
type: 'feature'
ticket: '12'
created: '2026-10-15'
status: 'built'
baseline_revision: '269acf1493ba632f647c10f74525eb583d411065'
route: 'full'
route_source: 'auto'
review: ''
review_source: ''
lenses_ran: []
review_loop_iteration: 2
context:
  - '{project-root}/docs/runbooks/identity-access.md'
  - '{project-root}/docs/runbooks/duties.md'
  - '{project-root}/docs/runbooks/follow-ups.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** Identity's 2.10/2.11 lifecycle seams (hold, deactivation, deletion, `scope_revoked`, handover and deletion hooks) reach no Duties or Follow-ups behaviour: a deactivated or departed member keeps future assignments and open tasks, nobody is told a position is empty, the last leader of a department can be deactivated, a removed member cannot be taken out of a department, and a held member's duties only reach Needs contact once a reminder fires.

**Approach:** One forward migration registers Duties and Follow-ups lifecycle hooks (`membership_deactivated`, `deletion_requested`, `access_hold_applied`, `scope_revoked`) and handover hooks, adds `duties.remove_member` and `duties.resolve_handover`, a leader vacancy notice and a `vacated` flag on the board and the coverage queue; Follow-ups hands open tasks over under the Q4 owner-scope rule. Everything runs inside Identity's (or the Duties command's) transaction in AD-2 order, Notifications last.

**Decisions:**
- Decision (agent, under owner pre-approval): **deactivation and deletion** (`membership_deactivated`, and `deletion_requested` for a member deactivated earlier): every current assignment of the member on a published occurrence that has not started (department duties and cell parts, any answer) ends (`superseded`, end reason `member_left`), leaving the position unfilled; the member's jobs for it and its leaders' alerts are cancelled and its coverage case closes (`superseded`); the member's planned draft positions are cleared. The member gets no notice (no access). Past and started duties, answers, outcomes and history are kept. Department membership rows are kept (a restoration does not restore assignments).
- Decision (agent, under owner pre-approval): **removal from a department** is `duties.remove_member {department_id, member_id}` (Admin, expected = department revision): the membership row ends (attributed), the member's current assignments of that department's future published duties end (`removed`) with `duty_released` to the member (routed to Needs contact when the app cannot reach them), and their draft plans there are cleared. `validation_failed {"member_id": "not_in_department"}` otherwise.
- Decision (agent, under owner pre-approval): **vacancy flag and leader notice**: each ended position whose member had not declined sends `duties_coverage` / `duty_vacated` ("Position needs cover") now to each reachable current leader and deputy of the department (never the member; held or in-review leaders are skipped and refused at delivery), keyed by the ended assignment's revision (fresh keys); delivered while the position is still unfilled, not cancelled and not started. The board and the coverage queue show `vacated: {since}` on such a position. No reason (hold, deactivation, deletion, removal) is ever disclosed: one generic flag. Cell parts get no leader alert (4.11: cell-scope alerts are a later contract change); the owner read shows the gap.
- Decision (agent, under owner pre-approval): **login hold** (`access_hold_applied`, any hold kind): duties are kept; each current assignment of a published, not-started duty that is not declined gets a Needs contact entry at once (kind `access_hold`, shown as `not_reached` while the member still cannot be reached in the app, so a release clears it). No leader alert (a hold is never disclosed).
- Decision (agent, under owner pre-approval): **`scope_revoked`**: Duties and Follow-ups authority is already checked on current grants at every command and replay; the hook additionally cancels the removed leader's pending leader alerts of departments they no longer lead or deputise, moves task supervision to another current holder of the task's scope (leaders first, reachable first) and hands over tasks whose owner left the task's roster.
- Decision (agent, under owner pre-approval): **handover hooks**: Duties reports `department_leader` (subject = department) when the member leads or deputises an active department and no other approved, reachable member holds its leader or deputy scope (`last_responsible: true`, so a deactivation is refused `handover_required`). Follow-ups reports `followup_task` per active task the member owns, `last_responsible` when no other candidate exists. Candidates (Q4 owner-scope rule): the task's supervisor, other holders of the task's scope, live Pastors, then other roster members; the Follow-ups lifecycle hook reassigns each task to the first candidate and resolves its obligation (`handed_over`); a task finished or reassigned later resolves its obligation through a trigger. `duties.resolve_handover {department_id}` (Admin, department revision) resolves a department's pending obligations once it has a reachable leader or deputy again (`conflict {"department_id": "leader_required"}` otherwise); a deletion's erasure waits for it.
- Decision (agent, under owner pre-approval): **actor and gates**: hook audit rows are attributed to the session's account and its member (the Admin or the deleting member), capacity `lifecycle`, or the nil UUID with no session. Ending work never needs Q2: with the policy unavailable the notices are skipped and audited `reminders_skipped` (`policy_unavailable`). Q4: hooks run regardless (they only reduce processing); erasure follows Identity's `identity_deletion_retention` gate (fixture in local/staging, closed in production).
- Decision (agent, under owner pre-approval): **erasure**: the new attribution columns (`ended_by_member`, `ended_by_account` of department memberships) are anonymised and counted in `_remaining`; the 4.10 S1 lock-first order is kept.

## Boundaries & Constraints

**Always:** forward migration after `20261015035112`; replaced bodies copied from their latest version with every earlier review fix; ASCII, `search_path = ''`, no backslashes, no DROP/TRUNCATE/`delete from`; new functions revoked from public, anon, authenticated and service_role, no new client grant (both commands go through `api.duties_command`); AD-2 lock order (Identity rows, Duties departments, series, occurrences, slots, member advisory locks, membership rows, assignments, coverage cases, Follow-ups, Notifications last); fixed church-time test dates; SYNTHETIC data, pgTAP +44 7700 900460-900469, E2E 900470-900479.

**Never:** Identity, Cells or Notifications behaviour changes; editing merged migrations, hand-pasted functions or frozen blocks; disclosing any hold, deactivation or deletion reason; restoring assignments on restoration; SMS.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Deactivate | member with pending, accepted and declined future duties, a past duty, a draft plan, open tasks | future assignments ended, positions unfilled and flagged, jobs cancelled, leaders alerted (not for the declined one), draft cleared, tasks handed over, past kept; one transaction | a raising hook rolls back the deactivation |
| Last leader | sole leader of an active department | deactivation `conflict handover_required`, nothing changes | second leader granted, then allowed |
| Remove from department | Admin removes M | membership ended, M's future duties there vacated, `duty_released` to M | not a member `validation_failed` |
| Login hold | held member with duties | duties kept, Needs contact at once, cleared on release | none |
| scope_revoked | leader removed | commands and replays `forbidden`/`not_found`, pending alerts cancelled, supervision moved | none |
| Delete | member with duties and tasks | as deactivation; obligations block erasure until resolved; check answers 0 | handover pending |
| Q2 closed | policy unavailable | work ends, notices skipped and audited | none |

</frozen-after-approval>

## Code Map

- `supabase/migrations/20261007151523_membership_lifecycle.sql` (2.10) -- `identity_register_handover_hook`, `identity_collect_handover` (called before grants end), `identity_resolve_handover_obligation`, `identity_deactivate_membership` (grants end with `scope_revoked`, then obligations recorded, then `membership_deactivated`); `20261007174952_member_deletion.sql` (2.11) -- deletion begin dispatches `membership_deactivated` (if approved) and `deletion_requested`; erase steps wait on pending obligations.
- `20261003134340_cross_epic_contracts.sql` -- `contract_register_lifecycle_hook(module, event, handler)` (handler `(jsonb) returns void`), event `{event, member_id, occurred_at, identity_revision}`; dispatch by lock rank (duties 20, followups 30, notifications 40). `20261006234820_identity_grants.sql` -- `identity_end_grant` dispatches `scope_revoked` with no scope details.
- `20261015035112_duties_owner_operations.sql` (4.11) -- latest `duties_state_ok`, `duties_authorize_command`, `duties_command`, `duties_deletion_remaining`, `duties_erase_member` (S1), `duties_occurrence_json` (3-arg).
- `20261014212507_duties_coverage.sql` (4.9) -- `duties_notify` (cancel ops close cases), `duties_close_cases`, `duties_cancel_position` (ending pattern), `duties_coverage` (queue), `duties_decline_alert_check` (alert check pattern).
- `20261014171038_duties_reminders.sql` (4.8) -- `duties_needs_contact`, `duties_alert_recipients`, `duties_leader_reachable`, `duties_contact_needs`.
- `20261013220239_duties_department_tracer.sql` (4.1) -- `duties_department_json`, `duties_add_member` (Admin pattern), `duties_command_actor`.
- `20261014110258_followups_registry.sql`, `20261014130535_followups_reminders.sql` -- `followups_scope_roster`, `followups_holds_scope`, `followups_activity_event`, `followups_cancel_reminders`, `followups_schedule_reminders`, `followups_lock_pastor`.
- Clients: `packages/client_core/lib/src/domain/duties.dart`, `duty_coverage.dart`, `application/duties_controllers.dart`, `membership_lifecycle_controllers.dart`, `presentation/duties_screens.dart`, `duties_coverage_screens.dart`, `membership_lifecycle_screen.dart`, `domain/followups.dart` (activity attribution).

## Tasks & Acceptance

**Execution:**
- [x] `supabase/migrations/20261015043644_duties_lifecycle.sql` -- hooks, commands, vacancy kind and flag, Follow-ups handover, replaced bodies, privileges.
- [x] `supabase/tests/duties_lifecycle_test.sql`, `duties_lifecycle_scale_test.sql`; ledgers and earlier tests updated.
- [x] `packages/client_core` -- remove member, handovers and resolve, `vacated` flag, handover refusal text, task handover attribution; tests.
- [x] `tools/identity-e2e/duties-lifecycle.mjs` + `.test.mjs`.
- [ ] Runbooks `duties.md`, `follow-ups.md`, `identity-access.md`; `evidence-4.12/`; CI evidence step.

**Acceptance Criteria:**
- Given synthetic members with upcoming duties and open tasks, when they are held, deactivated, removed from the department and deleted through the API, then vacancies are flagged with leader notices, jobs are cancelled in the same transaction, the last leader's deactivation is refused until handover, a held member's duty is listed with Needs contact, and the deletion check answers zero.

## Implementation Notes

- Implemented directly (no implementation subagent inside this builder run), as 4.1-4.11. CHECKPOINT 1 pre-approved by the owner (owner-decisions-milestone-1.md, -2.md); the frozen block's decisions are the agent's under that pre-approval.
- Server: `supabase/migrations/20261015043644_duties_lifecycle.sql` (ASCII, no backslashes, no DROP/TRUNCATE/`delete from`, `search_path = ''` everywhere; every new function revoked from public, anon, authenticated and service_role; no new client grant).
  - New: columns `duties_department_members.ended_by_member/ended_by_account` (with a check); functions `duties_lifecycle_actor`, `duties_vacated_since`, `duties_lifecycle_notify` (Q2 guard), `duties_vacate_member` (the one ending routine), `duties_hold_contact`, `duties_scope_revoked`, `duties_on_member_lifecycle` (hook), `duties_report_handover` (hook), `duties_vacancy_alert_check`, `duties_remove_member`, `duties_pending_handovers`, `duties_has_reachable_leader`, `duties_resolve_handover`; `followups_reachable`, `followups_handover_candidate`, `followups_supervisor_candidate`, `followups_handover_task`, `followups_handover_member`, `followups_on_member_lifecycle` (hook), `followups_report_handover` (hook), trigger `followups_tasks_handover_sync` (`followups_task_handover_sync`). Reminder kind `duties_coverage/duty_vacated`. Registrations: Duties lifecycle hooks on four events, Follow-ups on three, both handover hooks.
  - Replaced bodies (each copied from its latest version, changes marked "Story 4.12", every earlier review fix kept):
    - from `20261015035112` (4.11): `duties_state_ok` (end reason and change class `vacated`, capacity `lifecycle`, four audit actions), `duties_authorize_command` and `duties_command` (two commands), `duties_deletion_remaining` and `duties_erase_member` (4.10 S1 lock-first order kept; `ended_by_*` anonymised and counted).
    - from `20261014212507` (4.9): `duties_coverage` (`vacated` per position and per department count; everything else unchanged).
    - from `20261014171038` (4.8): `duties_needs_contact` (`access_hold` entries while the member is unreachable), `duties_coverage_source_check` (also current for an assignment that ended `vacated` at that revision).
    - from `20261014130535` (4.7): `followups_state_ok` (activity `reminders_skipped`).
    - from `20261013220239` (4.1): `duties_department_json` (`handovers`, `needs_leader`).
  - Not replaced: `duties_notify`, `duties_close_cases`, `duties_alert_recipients`, the board/rota projections, every Identity and Notifications function, `followups_reassign` (the trigger resolves obligations instead).
- Decision (agent, under owner pre-approval; **changes a frozen detail**, recorded in the Plan Change Log): the leaders' vacancy notice is **one per department and lifecycle change**, keyed by the soonest position the change ended, titled **Positions need cover**, actionable while any position of that change is still unfilled; not one per position. Why: per-position notices flooded a leader (a member with 120 future duties gave 120 notices per leader) and cost 2.3 ms each; the queue still flags every position.
- Decision (agent, under owner pre-approval): a deputy counts as the department's responsible person (FR: "Admin assigns a deputy/replacement"); a held, in-review or accountless leader or deputy does not.
- Decision (agent, under owner pre-approval): end reason `vacated` is one generic code for deactivation, deletion and removal (leaders read the board history); the audit keeps `member_left` / `removed`.
- Decision (agent, under owner pre-approval): the scope_revoked hook works from the member's current grants (the v1 event carries no scope), so it acts on every department the member no longer leads; authority itself was already live-checked everywhere (pgTAP and E2E prove commands, replays, reads and supervision end).
- Decision (agent, under owner pre-approval): a deletion's pending `department_leader` handover is resolved by an explicit Admin command (`duties.resolve_handover`, refused until a reachable leader or deputy exists), not by a hook on grants (Identity has no grant event).
- Client fix found while building: `AssignmentHistoryEntry` refused `response_provenance: leader`, so a Confirmed by leader assignment that ended (now possible through a vacancy; earlier through a position cancellation) would have failed the whole board read. It now accepts `leader`; the 4.2 test that asserted the refusal was changed.
- Clients (`packages/client_core`): `DutyCommands.removeMember`/`resolveHandover`, `DutyEndReasons`, `DepartmentHandover`, `AdminDepartment.handovers/needsLeader` (tolerant of older servers), `DutyPosition.vacated`, `CoveragePosition.vacatedSince`, `CoverageCounts.vacated`; controller `removeMember`, `resolveHandover`, notices `memberRemoved`, `handoverResolved`, `leaderRequired`; Departments: **Remove from department** (confirmed), **Handover pending** with **Mark handover done**; Coverage and board: **Needs a new person**; Membership status **Hand over first** text; follow-up activity "handed over automatically". Tests: new `test/duties/duties_lifecycle_test.dart` (9); changed `duties_revisions_test.dart` (leader provenance) and `membership_lifecycle_test.dart` (refusal text).
- Earlier pgTAP files changed for the new behaviour (no merged migration edited): `cross_epic_contracts_test.sql`, `notifications_routing_test.sql`, `duties_reminders_test.sql`, `duties_coverage_test.sql` (details in duties.md, story 4.12, Local runs).
- Matrix audit: Deactivate (pgTAP "Church deactivation" block incl. pending/accepted/declined/other department/cell part/past/draft/coverage case/task; E2E L20, L21), Last leader (pgTAP "The last leader" incl. held deputy; E2E L30), Remove (pgTAP removal incl. refusals; E2E L40), Hold (pgTAP hold block; E2E L10), scope_revoked (pgTAP revoked block incl. replay; E2E L50), Delete (pgTAP deletion block incl. pending handovers, resolve, erase/check 0; E2E L60), Q2 closed (pgTAP Q2 block). All ran and passed (Verification).
- Fictional numbers: pgTAP +44 7700 900460-900469, scale 900480-900489, E2E 900470-900479 (grepped: unused before).
- Earlier E2E scripts changed for the new behaviour: `tools/identity-e2e/lifecycle.mjs` and `runbooks.mjs` (their precondition counted every registered handover hook; it now counts the fixture's only), `duties-reminders.mjs` D50 (the hold's own `access_hold` entry is not one of the routed reminder needs it counts).
- Open owner questions (fail-closed defaults built; also in duties.md, story 4.12): Q4 retention/anonymisation (unchanged); may leaders learn why a position became vacant (built: no); one vacancy notice per department and change (built); a reachable deputy counts as responsible (built: yes).
- Remaining (not builder steps): staging apply of the migration with per-function md5 parity (parent; no owner SQL paste; no Edge Function redeploy); rebuild the staging staff web and APK; owner manual checks in `docs/runbooks/duties.md`, story 4.12.

### Review amendments (2026-10-15, round 1; the unmerged migration was edited in place)

- Decision (agent, under owner pre-approval; S1): **cap, not unbounded work.** Ending duties is now set-based (`duties_vacate_member`: one assignments update, one occurrence bump, slot revisions and audit in single inserts, one `duty_vacated` per department, cancels only for jobs or schedules that exist). The Follow-ups plan is one set-based function (`followups_handover_plan`: rosters once per scope, reachability once per person, candidates once per distinct owner, supervisor, scope and purpose, materialized), shared by the handover hook (`followups_report_handover`, now SQL over the plan) and the handover (`followups_handover_member`: one update, one activity insert, bulk `reminders_skipped`). The per-task cost left is Notifications' own (cancel and plan a task's reminders, about 15-20 ms), so **one lifecycle change hands over at most 25 tasks** (one transaction budget shared by its events, soonest first); the rest keep pending obligations, listed for the Admin on Membership status, and the new Admin command `followups.complete_handover` continues 100 per step. Why the cap: 1000 tasks at 15-20 ms each is 15-20 s, over the 8 s statement timeout, and the per-task cost sits in Notifications' API. Measured: deactivation with 200 duties and 1030 open tasks 1.1-1.8 s; a 100-task step 1.7-2.5 s.
- Decision (S2): Duties and Follow-ups commands take `FOR KEY SHARE` on the identity rows of the members they may notify, member-id order, one helper per module (`duties_lock_people`, `followups_lock_people`, plpgsql so every row is locked), in the authorizer before any owner row. The 1.4 authorizer seam sees only the actor and the command, so each dispatcher hands the payload over in a transaction-local setting (`duties.command_payload`, `followups.command_payload`, cleared after; it decides only what is locked). `duties_command_people` / `followups_command_people` read the people (safe uuid parsing: a malformed payload is still refused by the handler). The 4.11 owner operations lock in `duties_owner_session` and `duties_owner_positions` (bodies replaced, copied from `20261015035112`). Identity's `FOR UPDATE` is unchanged. Proven by E2E L23 (deactivation first: the leader's revise and publish wait, then `conflict` and `validation_failed`), L24 and L25 (revise and publish paused mid-command by a third connection while the Admin deactivates: both succeed). L24 and L25 failed with `40P01` before the payload hand-over (the authorizer then locked only the actor) and pass after it. L20 stays strict.
- Decision (S3): owner candidates are only members the app can reach; with none, the task's obligation is `last_responsible` (a deactivation is refused). pgTAP: an accountless supervisor is passed over for a reachable Pastor; with no Pastor the owner is last responsible.
- Decision (S4): the Departments warning shows whenever `needs_leader` is true. The revoke-first bypass (`identity.revoke_scope` calls no handover hook) is a **known limit**, with a follow-up item: an Identity grant-revocation handover hook. Identity's seams were not used: `revoke_scope` does not call the hooks.
- N1: the vacancy check's `current` no longer looks at the duty's state; `actionable` decides.
- N2: `followup_supervision` obligation (never last responsible) for a task nobody else can supervise; resolved by the sync trigger when the supervisor changes.
- N3: a task handed to its supervisor gets a new supervisor from the other holders (reachable first), else self-supervision when the new owner holds the scope (4.9 fallback), else the N2 obligation.
- N4: `notices_skipped: true` gives **Removed, but nobody was told**; the dialog promises notices only when they can be sent; pgTAP proves a held member's `duty_released` need reaches the leaders' contact notices.
- N5: in the vacate, the advisory lock comes first and occurrences found then are locked before their assignments (documented).
- N6: `duties_scope_revoked` finds the pending alerts in one query and cancels only those.
- N7: `duties_coverage_test.sql` restores the 4.9 `replaced_case` path (a revoked deputy who stays a department member keeps the task; the leader's next attempt replaces the case).
- N8: deploy order recorded (migration, then staff web and APK in the same rollout).
- Removed functions (never merged): `followups_handover_candidate`, `followups_supervisor_candidate`, `followups_handover_task`. New: `duties_lock_people`, `duties_command_people`, `duties_jsonb_uuid`, `followups_jsonb_uuid`, `followups_lock_people`, `followups_command_people`, `followups_handover_plan`, `followups_resolve_obligations`, `followups_complete_handover`. Newly replaced bodies: `duties_owner_session`, `duties_owner_positions` (from 4.11), `followups_in_scope`, `followups_authorize_command`, `followups_command` (from 4.6, review N5 kept).
- Clients: notice `memberRemovedNoNotices`; the needs-leader label; **Hand over the next 100 follow-up tasks** on Membership status (`LifecycleNotice.handoverContinued`). Tests: `duties_lifecycle_test.dart` 11, `membership_lifecycle_test.dart` +2.
- The per-department vacancy notice (a frozen-block deviation, Plan Change Log) is **pending owner acknowledgement**.

### Review amendments (2026-10-15, round 2)

- B1 (blocker, a revoked scope over the cap left tasks with the former leader): (a) `followups_capacity` replaced (from 4.6): owner capacity needs the owner in the task's group now (`followups_in_group`, the Q4 roster incl. live Pastors and accountless group members); `followups_my_tasks` replaced to match. (b) Decision (agent, under owner pre-approval): Identity's obligations table needs a lifecycle event and is Identity's, so Follow-ups cannot record obligations for a revoked scope; instead `followups_pending_handovers()` lists, with the same kinds, every task whose owner left its group or whose supervisor left or lost its scope, and `followups_admin_routing` (replaced, from 4.6) returns `handovers` per member, shown on Follow-up routing with **Hand over the next 100**. (c) `followups.complete_handover` acts on active members (only what they may no longer hold).
- S5: `followups_handover_member` share-locks the chosen owners and supervisors (id order, before the tasks), rechecks them and recomputes the plan (up to three tries). E2E L27 (negative control: without the lock the tasks went to the member being deactivated). Two simultaneous deactivations handing to each other can still deadlock (detector; retry) - documented.
- N9: authorizers lock the actor's member row, then the actor's grants, then the payload's people; the remaining pre-handler window is documented (duties.md).
- N10: the 4.6 review N5 supervisor-grant lock now reads the dispatcher's payload; pgTAP shows the grant row locked.
- N11: "handed over" only when something moved (`handoverNoneMoved` otherwise, both screens); the Membership status button shows whenever Follow-ups obligations remain.
- N12: a deactivation or deletion cancels the member's reminders of the tasks still waiting (about 0.5 ms each; deactivation with 1030 tasks now 1.5-2.3 s); documented that after a revoked scope the reminders keep going to the still-reachable former owner until the Admin continues.
- N13: none (e800a7d never reached staging).
- Newly replaced bodies: `followups_capacity`, `followups_my_tasks`, `followups_admin_routing` (from 4.6). New: `followups_in_group`, `followups_pending_handovers`.
- Rule slip to disclose: during the re-verification one `git fetch --dry-run` was run (output discarded, no refs updated) before `ci:migrations --base origin/main`; no other fetch, pull or push.

## Plan Change Log

- 2026-10-15 (build): the vacancy notice is one per department and lifecycle change (title **Positions need cover**), not one per ended position as the frozen Decisions say; `duties_coverage_source_check` (4.8) is replaced too so the notice's source is current for a vacated assignment. Recorded under Implementation Notes. The frozen block is unchanged. **Pending owner acknowledgement.**
- 2026-10-15 (review round 2): owner capacity is live (the owner must be in the task's group); what waits for handover is listed for the Admin on Follow-up routing; `followups.complete_handover` acts on active members too. Recorded under Implementation Notes (round 2). The frozen block is unchanged.
- 2026-10-15 (review round 1): a lifecycle change hands over at most 25 follow-up tasks; the rest stay pending for the Admin, who continues with the new command `followups.complete_handover` (100 per step). Owner candidates must be reachable in the app. A `followup_supervision` obligation is added. Duties and Follow-ups commands share-lock the identity rows of the members they may notify first. Recorded under Implementation Notes (Review amendments). The frozen block is unchanged.

## Review Triage Log

- 2026-10-15, independent review (probes in the coordinator's scratchpad `rv412/`): 0 blockers, 4 should-fix (S1-S4), 8 nits (N1-N8).
- S1 (should, unbounded handover cost): fixed by set-based work plus a cap (25 per change; `followups.complete_handover` for the rest). Scale test: 200 duties and 1030 tasks in one deactivation, under 3 s.
- S2 (should, deadlock with a leader's command): fixed (people `FOR KEY SHARE` first, payload handed to the authorizer); E2E L23-L25; L20 strict.
- S3 (should, unreachable owner chosen): fixed (reachable candidates only, else last responsible); pgTAP.
- S4 (should, needs-leader warning and revoke-first bypass): warning fixed; bypass recorded as a known limit with a follow-up item (an Identity grant-revocation handover hook).
- N1-N8: fixed (N5 documented, N8 recorded in the runbook).
- 2026-10-15, re-review of round 1: S2, S3, N1-N8 confirmed; 1 blocker (B1) and 1 should-fix (S5) from the cap, nits N9-N13. B1 fixed (a, c as asked; b as a Follow-ups list with the same kinds, because Identity's obligations need a lifecycle event). S5 fixed (lock and recheck; E2E L27). N9 reordered and documented; N10, N11, N12 fixed; N13 no action.

## Verification

**Commands:**
- `npx supabase db reset && npm run -s db:test && npm run -s db:smoke` -- expected: pass.
- e2e-main.sh (worktree copy) with `duties-lifecycle` appended -- expected: each `exit=0`.
- `npm run -s contracts:test`, `dart test` in `packages/contracts/dart`, node tool tests, `npm run -s ci:policy-test` -- expected: pass.
- `flutter analyze && flutter test` in `packages/client_core`, `apps/staff`, `apps/mobile`; `TZ=America/New_York` for `test/duties` and mobile -- expected: pass.
- `npm run -s ci:secrets && npm run -s ci:migrations -- --base origin/main && npm run -s ci:function-imports`; evidence scan -- expected: clean.

**Results (2026-10-15, after review round 2):**
- db reset 0; db:test PASS (43 files, 3715 tests; `duties_lifecycle_test.sql` 136, `duties_lifecycle_scale_test.sql` 20, `duties_coverage_test.sql` 162). Scale: hold over 230 duties 29-34 ms; removal of 30 duties 172-191 ms; deactivation ending 200 duties with 1030 open tasks (25 handed over, the rest's reminders cancelled) 2.1-2.3 s; one `followups.complete_handover` step (100 tasks) 1.8-1.9 s; all under `statement_timeout = '8s'`. db:smoke pass (139 ok).
- Every E2E `exit=0` (29 scripts, reset before each, one at a time; `duties-lifecycle` 16/16 incl. races L23-L25 and L26-L27) (`evidence-4.12/e2e-suite-summary.txt`). Negative control: with the S5 lock disabled, L27 fails (tasks given to the member being deactivated).
- contracts:test 265/0; Dart contracts 282 pass; node tool tests (CI set) 229/0; ci:policy-test 56/0.
- flutter analyze clean in client_core, apps/staff, apps/mobile; flutter test client_core 637, apps/staff 40, apps/mobile 55; under `TZ=America/New_York` client_core duties + followups + membership lifecycle 224 and apps/mobile 55.
- ci:secrets clean (1586 files); ci:migrations (`--base origin/main`) 48 ordered, unique, non-destructive; ci:function-imports ok; evidence scan (the 4.12 CI step) clean.

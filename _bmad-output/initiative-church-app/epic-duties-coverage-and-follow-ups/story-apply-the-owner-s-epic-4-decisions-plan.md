---
title: 'Apply the owner''s epic 4 decisions'
type: 'feature'
ticket: '16'
created: '2026-10-15'
status: 'built'
baseline_revision: '4352fbb2258201cad9cd280768d3c628c1062c36'
route: 'full'
route_source: 'auto'
review: ''
review_source: ''
lenses_ran: []
review_loop_iteration: 1
context:
  - '{project-root}/docs/runbooks/identity-access.md'
  - '{project-root}/docs/runbooks/duties.md'
  - '{project-root}/docs/runbooks/production-promotion-identity.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** The owner's 2026-10-15 decisions (owner-decisions-milestone-2.md, items 7, 8 and 10, and the Q1 production settings) differ from what 4.11 and 4.12 built: a linked meeting or event change only flags department duties (nobody is told), leaders never learn why a position became vacant, revoking the last reachable leader's scope bypasses the handover rule, and `dormancy_days` has no operator path, so G3 cannot be approved at promotion.

**Approach:** One forward migration: a `duty_review_flagged` leaders' notice from `duties_owner_flag_review`; a vacancy reason code on vacated assignments, shown to the department's leaders and deputies only; a minimal Identity change so `identity.revoke_scope` collects the handover hooks after the grant ends (refused `handover_required` and rolled back when a hook reports a last responsible person; other obligations recorded); `app.identity_approve_setting`. Clients show the reason, open the review deep link and explain the refusal; the promotion runbook gets G3, G4 and G11.

**Decisions:**
- Decision (agent, under owner pre-approval; owner item 7): the notice is `duties_review` / `duty_review_flagged` ("Duty needs review", generic body, link `/duties/leader?needs=review`). One per department per flag operation, keyed by the soonest occurrence flagged in that department at its flag's revision (fresh key per change, as the 4.12 `duty_vacated`); recipients `duties_alert_recipients` (reachable, active leaders and deputies; held leaders excluded, 4.8); actionable while any flag of that source in that department is open on a published duty that has not started; recipient eligible while they lead or deputise it and are reachable. Q2 closed: the flags are recorded, the notice is skipped and audited `reminders_skipped` (`policy_unavailable`). Cell parts are never flagged (unchanged).
- Decision (agent, under owner pre-approval; owner item 8, **supersedes the 4.12 "no reason" decision because the owner decided so**): `duties_assignments.vacancy_reason` in (`removed_from_department`, `member_inactive`, `member_deleted`), set only with end reason `vacated`: removal -> removed; deactivation -> inactive; deactivation dispatched by a deletion (a deletion row exists) and `deletion_requested` -> deleted. No free text, no hold category (holds never vacate). Shown as `vacancy_reason` in the board's history entry and the coverage queue's `vacated` object only when the viewer leads or deputises that department; null for the Admin role alone, Pastor, other leaders and members. Existing vacated rows have no code (shown without a reason). Erasure keeps the code (a category, not personal data). A later deletion does not rewrite an earlier inactive code.
- Decision (agent, under owner pre-approval; owner item 10, **cross-epic Identity change**): `identity_end_grant` is split into `identity_end_grant_record` (update, revision, audit; returns the revision) plus the unchanged dispatch; `identity_revoke_scope` records the end, then (with the revoked grant in the transaction-local `identity.revoked_grant`, read through `app.identity_revoked_scope()`) calls `identity_collect_handover` with a `scope_revoked` event, refuses `conflict {"member_id": "handover_required"}` when any obligation is last responsible (the command's savepoint rolls the end back), records the other obligations against the grant, then dispatches `scope_revoked`. `identity_handover_obligations.lifecycle_event_id` becomes nullable (precedent: 20261014052239 `drop not null`, allowed by ci:migrations) with a new `revoked_grant_id` and a check that exactly one is set. Duties reports the revoked department when no current, active, reachable leader or deputy remains (the member's own remaining grant counts). Follow-ups reports, for `scope_revoked`, what the member may no longer hold, never last responsible (a revocation narrows access; tasks nobody can take stay listed, as 4.12). The fixture hook answers nothing for `scope_revoked`. Deactivation, deletion, unlink and role revocation are unchanged.
- Decision (agent, under owner pre-approval; G3): `app.identity_approve_setting(setting, value, approver, note)`: restricted operator (`ops_require_operator`), no client grant, owner note required (not TEST FIXTURE), plain object; inserts the next version `source = 'approved'`; audited `church_setting_approved` with the setting name (both action lists already allow it). No migration approves a value; 180 days is applied by the operator at promotion.

## Boundaries & Constraints

**Always:** migration after `20261015143102`; replaced bodies copied from their latest version with every review fix; ASCII, `search_path = ''`, no backslashes, no TRUNCATE/`delete from`/object drops; new functions revoked from public, anon, authenticated and service_role; ledgers updated; AD-2 lock order, Notifications last; SYNTHETIC data, pgTAP +44 7700 900850-900859, E2E 900720-900729.

**Never:** editing merged migrations, hand-pasted functions or frozen blocks; free-text reasons; approving `dormancy_days` in a migration; SMS; hosted or production changes.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Event change | linked event flags duties in D (2) and E (1) | one notice per leader/deputy of D and of E; held leader skipped | Q2 closed: flags kept, notice skipped and audited |
| Vacancy reason | M removed / deactivated / deleted | leader or deputy of D sees the category | Admin alone, Pastor, other leader, member: null |
| Revoke last leader | sole reachable leader's scope revoked | `conflict handover_required`, grant kept | second reachable leader granted, then allowed |
| Revoke with tasks | leader with owned tasks of D, another holder exists | allowed; tasks handed over (cap 25), the rest recorded as obligations | listed on Follow-up routing as before |
| Dormancy approval | non-operator / operator 180 | refused 42501 / version 2 approved, effective | fixture row unchanged |

</frozen-after-approval>

## Code Map

- `supabase/migrations/20261006234820_identity_grants.sql` -- `identity_end_grant` (L1042), `identity_revoke_scope` (L1160), `identity_approve_church_setting` (L248, pattern for G3). Not replaced since.
- `supabase/migrations/20261007151523_membership_lifecycle.sql` -- `identity_handover_obligations` (FK `lifecycle_event_id`), `identity_collect_handover`, `fixture_report_handover`, deactivation's collect-before pattern.
- `supabase/migrations/20261015110202_duties_lifecycle.sql` (4.12) -- latest `duties_state_ok`, `duties_vacate_member`, `duties_on_member_lifecycle`, `duties_report_handover`, `duties_coverage`, `duties_lifecycle_notify` (Q2 guard), `duties_vacancy_alert_check` (pattern), `followups_report_handover`.
- `supabase/migrations/20261015035112_duties_owner_operations.sql` (4.11) -- `duties_owner_flag_review`, `duties_occurrence_json` (3-arg, viewer `app.duties_viewer`), `fixture_event_changed`.
- `supabase/migrations/20261014171038_duties_reminders.sql` -- `duties_alert_recipients`, `duties_leader_reachable`.
- `supabase/migrations/20261006215842_identity_live_access.sql` -- `identity_settings`, `identity_setting` (approved first, fixture only local/staging).
- Clients: `packages/client_core/lib/src/domain/duties.dart` (`AssignmentHistoryEntry`, `DutyPosition.vacated`), `duty_coverage.dart` (`CoveragePosition`), `presentation/duties_screens.dart` (board, `DutyLeaderScreen`), `duties_coverage_screens.dart`, `shell_routing.dart` (deep links), `application/access_controllers.dart` + `access_screens.dart` (revoke scope), `application/duties_controllers.dart` (`_refusal`, `removeStaff`).
- E2E: `tools/identity-e2e/duties-lifecycle.mjs`, `duties-owner-ops.mjs`, `duties-shared.mjs`.

## Tasks & Acceptance

**Execution:**
- [x] `supabase/migrations/20261015180000_duties_owner_decisions.sql` -- everything above, replaced bodies listed in its header.
- [x] `supabase/tests/duties_owner_decisions_test.sql` (+ timing check) and the earlier pgTAP files whose assertions change (4.12 "no reason", ledgers).
- [x] `packages/client_core` -- reason line (board, coverage), deep link and reviews-only view, revoke refusal text; tests.
- [x] `tools/identity-e2e/duties-decisions.mjs` + `.test.mjs`.
- [x] Runbooks `duties.md`, `identity-access.md`, `production-promotion-identity.md`; `evidence-4.16/`; CI evidence step.

**Acceptance Criteria:**
- Given a department with leaders, a held deputy and duties linked to a SYNTHETIC event, when the event changes, then each reachable leader and deputy gets one notice per department and the held deputy none.
- Given the matrix above, when each scenario runs through the API, then the outcomes hold and every earlier test still passes.

## Implementation Notes

- Implemented directly (no implementation subagent inside this builder run), as 4.1-4.14. CHECKPOINT 1 pre-approved by the owner (owner-decisions-milestone-1.md, -2.md); the frozen block's decisions are the agent's under that pre-approval. The owner's choices themselves are in owner-decisions-milestone-2.md (2026-10-15).
- **This story supersedes the 4.12 decision "no reason is ever disclosed" because the owner decided so** (decision 8, against both recommendations). The 4.12 plan's frozen block is unchanged; the 4.12 runbook text, its pgTAP header and the client test wording now say "superseded by 4.16". The 4.12 review S4 follow-up item (an Identity grant-revocation handover hook) is built here.
- **Cross-epic Identity change (recorded for the Identity owner):** `identity_revoke_scope` (2.3) now records the grant end through the new `identity_end_grant_record` (the unchanged 2.3 update, revision and audit), calls `identity_collect_handover` with a `scope_revoked` event while the transaction-local `identity.revoked_grant` names the grant (read only through `app.identity_revoked_scope()`, cleared after the call), refuses `conflict {"member_id": "handover_required"}` (current grant revision) when an obligation is last responsible (the 1.4 command's savepoint rolls the grant end back: no audit row, no revision), records the other obligations against the grant, then dispatches `scope_revoked` as `identity_end_grant` does. `identity_end_grant` keeps its exact behaviour (record + dispatch); deactivation, deletion, unlink and role revocation are unchanged. `identity_handover_obligations.lifecycle_event_id` is nullable with the new `revoked_grant_id` (FK to `identity_grants`; grants are never deleted, the deletion rows file does not touch them) and a check that exactly one is set; every reader keys on member, owner, kind and subject, so `identity_admin_membership_lifecycle`, `identity_lifecycle_member_json` and the deletion blocker are unchanged and now also see revocation obligations. `fixture_report_handover` (2.10, SYNTHETIC) answers nothing for `scope_revoked`.
- Decision (agent, under owner pre-approval): `drop not null` on `lifecycle_event_id` is a constraint relaxation, not a destructive statement: ci:migrations allows it and 20261014052239 (on staging) did the same. The alternatives (a second obligations table, or fake lifecycle rows) would duplicate Identity's readers or falsify its audit.
- Decision (agent, under owner pre-approval): the review notice is a new source type `duties_review` (source = the review flag) rather than `duties_coverage` (whose source is an assignment). Currency is "the flag at that revision" (the 3.2 contract requires `revision` to equal the key's when current): a later change sends a fresh notice and supersedes a still-queued older one; the department's review of the keyed duty ends it (a review bumps the flag). `duties_lifecycle_notify` (4.12) is reused for the Q2 guard (one `reminders_skipped` audit per department).
- Decision (agent, under owner pre-approval): the vacancy reason is derived inside `duties_vacate_member` without a signature change: `removed` -> `removed_from_department`; otherwise `member_deleted` when an `identity_deletions` row exists for the member (a deletion inserts it before dispatching `membership_deactivated`), else `member_inactive`. A later deletion does not rewrite an earlier `member_inactive` (no history rewrite; neither leaks anything). Erasure keeps the code.
- Decision (agent, under owner pre-approval): the reason is gated like the 4.11 review B1 confirmation reason (`duties_manage_capacity(app.duties_viewer, department)` in leader/deputy) on the board, and on `cd.scope_kind` (the `full` view) in the coverage queue. Only vacated history entries carry the `vacancy_reason` key (other entries are byte-identical to 4.15's expectations); an unknown code reads as no reason on the clients.
- Decision (agent, under owner pre-approval): for a revoked scope Follow-ups never reports last responsible (a revocation narrows access; a task nobody can take stays listed for the Admin, as 4.12). Duties reports the revoked department when no current, active, reachable leader or deputy remains (the member's own remaining grant counts, so revoking one of two scopes of the same person is allowed). A revoked leader's pending review notice is refused at delivery (recipient check), not cancelled at once (`duties_scope_revoked` is not replaced).
- Decision (agent, under owner pre-approval; G3): `app.identity_approve_setting` requires an active restricted operator (`ops_require_operator`, as `identity_approve_church_setting`), has no client grant (as `policy_approve`), validates `dormancy_days` (1-3650), serialises versions per setting with a transaction advisory lock, and audits with the existing `church_setting_approved` action (both action lists already allow it; widening them would need another retire-and-recreate). Production: version 2 (the labelled fixture row v1 exists everywhere and is never honoured there).
- G4: the agent proposed modest limits (sign-ins and sign-ups 20 per 5 min per IP, token refresh 120 per 5 min, verification 20 per 5 min; OTP, SMS and anonymous unchanged) with the shared-mobile-address reasoning in `production-promotion-identity.md`; password minimum 8, no character rules. G11: open after G5 and G8.
- Server: `supabase/migrations/20261015180000_duties_owner_decisions.sql` (ASCII, no backslashes, no TRUNCATE or `delete from`, `search_path = ''` on all 15 functions, every new function revoked from public, anon, authenticated and service_role). Replaced bodies, each copied from its latest version with every earlier review fix, changes marked "Story 4.16":
  - from `20261015110202` (4.12): `duties_vacate_member` (reason code; S1 set-based work and N5 lock order kept), `duties_coverage` (`vacated.reason`; everything else unchanged), `duties_report_handover` (revoked-scope branch; the lifecycle query unchanged, restructured into a union), `followups_report_handover` (active plan and never last responsible for `scope_revoked`).
  - from `20261015035112` (4.11): `duties_occurrence_json` (3-argument; B1 gating kept), `duties_owner_flag_review` (the notice after the flags; S1, N5 kept).
  - from `20261006234820` (2.3): `identity_end_grant`, `identity_revoke_scope`.
  - from `20261007151523` (2.10): `fixture_report_handover`.
  - New: `duties_vacancy_reason`, `duties_review_source_check`, `duties_review_alert_check`, `identity_revoked_scope`, `identity_end_grant_record`, `identity_approve_setting`; column `duties_assignments.vacancy_reason` (check); column `identity_handover_obligations.revoked_grant_id` (+ index, origin check); source type `duties_review`, kind `duty_review_flagged` and its contract.
- Tests: new `supabase/tests/duties_owner_decisions_test.sql` (88; timing: one change over 63 linked duties with its notices 115-131 ms, asserted < 3 s); changed `duties_tracer_test.sql` (+1: the last reachable deputy's revoke refused, then a leader regranted), `duties_owner_operations_test.sql` (a flag adds only the review notice), `membership_lifecycle_test.sql` (obligation columns), `duties_lifecycle_test.sql` (+1: the leader reads the category, the Admin not; wording). Fictional numbers: pgTAP +44 7700 900850-900859, E2E 900720-900729 (grepped: unused before).
- Clients (`packages/client_core`): `DutyVacancyReasons`, `AssignmentHistoryEntry.vacancyReason`, `DutyPosition.vacancyReason`, `CoveragePosition.vacancyReason`; **Reason: ...** lines on the board and in Coverage (both apps share the screens); `DutyPaths.leaderReviews` (`/duties/leader/reviews`, a known deep link) opening `DutyLeaderScreen(reviewsOnly: true)` (**Duties to review**, **Show all duties**); `GrantNotice.handoverRequired` and `DutyNotice.staffHandoverRequired` (**Hand over first**). Test: `test/duties/duties_owner_decisions_test.dart` (10); `duties_lifecycle_test.dart` wording.
- E2E: `tools/identity-e2e/duties-decisions.mjs` (11 checks) + `.test.mjs` (8); CI evidence step for `evidence-4.16`.
- Runbooks: `duties.md` (story 4.16 section; 4.12 "never a reason", known limit S4 and owner question marked superseded or fixed), `identity-access.md` (revocation handover, obligation origin, `identity_approve_setting`), `follow-ups.md` (revocation obligations), `production-promotion-identity.md` (G3 exact call, "no operator function" note removed; G4 values; G11).
- Earlier E2Es changed for the new behaviour: `duties-owner-ops.mjs` X30 (a flag adds only the leaders' review notice: its job count excludes `duty_review_flagged`), `duties-pilot.mjs` P98 (the API cleanup's revocation of the department's only reachable leader is now refused `handover_required`; it is recorded `kept_last_leader`, and the cleanup SQL removes a department the pilot created). The pilot runs against staging too: its cleanup now leaves the leader persona's scope when the persona is the department's last reachable leader.
- Matrix audit: Event change (pgTAP item 7 block: recipients, held deputy, Admin, Pastor, other leader, dedup, second change, Q2 closed; E2E D10-D13), Vacancy reason (pgTAP item 8 block: three codes, board and coverage per reader, erasure; E2E D20), Revoke last leader (pgTAP item 10 block: refused with nothing changed, allowed after a reachable leader, held deputy not counted, own remaining grant counts; E2E D30-D32), Revoke with tasks (pgTAP: obligation recorded against the grant with budget 0, listed by `followups_pending_handovers`, shown on Membership status, completed by `followups.complete_handover`), Dormancy approval (pgTAP G3 block: client roles, non-operator 42501, validation, approved version honoured by the live-access predicate, fixture kept). All ran and passed.
- Rule note: one E2E batch was started while the full suite was still running on the shared stack; those results were discarded and the scripts rerun alone (evidence-4.16/e2e-suite-summary.txt).
- Remaining (not builder steps): staging apply with per-function md5 parity (parent session; no owner SQL paste, no Edge Function); staging staff web and APK rebuild; owner manual checks (duties.md, story 4.16); at production promotion the operator applies G3, G4 and G11 as documented.

### Review amendments (2026-10-15, round 1; the unmerged migration was edited in place)

- Decision (agent, under owner pre-approval; S1): **`identity.unlink_account` names item 10 explicitly.** Unlinking is a security action and is never refused. `identity_unlink_account` (replaced, copied from `20261007063340`, 2.5) ends each scope grant through `identity_end_grant_record`, collects the handover hooks for it (`identity_collect_revocation_handover`), records every reported obligation pending against that grant (`identity_record_revocation_obligations`, a Duties `department_leader` one included) and dispatches `scope_revoked`; roles end through `identity_end_grant` as before; validation, the last-Admin rule, link end, audit and `account_deactivated` are unchanged. The Admin sees the handover on **Membership status** and **Handover pending** on **Departments**, and resolves it with `duties.resolve_handover` once the department has a reachable leader. A later `deactivate_membership` of that member follows the 4.12 rules unchanged (they hold no scope any more). `identity_revoke_scope` uses the same two helpers plus `identity_scope_revoked_event`.
- Decision (S2): **a review notice stays while its change is open.** `duties_review_key_open(flag, revision)`: the key's flag is at that revision (and open), or another open flag of the same source in the same department remains on a published duty that has not started. `duties_review_alert_check` and `duties_review_source_check` use it for `current`; `actionable` additionally needs any open flag on a published duty that has not started. Because the 3.2 contract requires a current answer to carry the key's revision, `revision` is the key's while current and the flag's own otherwise. Consequence: an older change's notice still waiting stays current while the department has open flags of that source (one notice per change). The migration header now says this.
- Decision (S3): the G4 section was rewritten from Supabase's docs (checked 2026-10-15): password sign-in (`/token?grant_type=password`) shares the token bucket (`rate_limit_token_refresh`) with refreshes, so that is the limit tightened (150 -> 120 per 5 minutes, per IP); the "sign-ups and sign-ins" bucket covers `/signup`, `/recover`, `/resend`, `/magiclink`, `/otp`, `/user` (30 -> 20 per 5 min). Its Management API key is not stated in the current docs (it may be `rate_limit_otp`), so the steps read the keys and units from `GET .../config/auth` first. The clients call `/user` only for `updateUser` (password or recovery email change), never `getUser` polling; refreshes are about hourly per open session plus one retry on a rejected token.
- N1: **Hand over first** now says "This department has no other leader or deputy who can use the app" (also true for a held sole leader), on Roles & access and Departments.
- N2: the pilot header and duties.md (story 4.13) say that a reused staging department's leader persona keeps the leader scope after P98, and how an Admin removes it (give another reachable member the role first, then remove the persona's).
- N3: timing assertion unchanged (99-131 ms against a 3 s bound).
- Found while re-verifying N5: without a fence the planner pulled the board's per-department lateral up and computed the overlap counts once per listed duty (a 270-duty board read ran for minutes). The lateral now ends in `offset 0`, so the counts are computed once per department; pgTAP asserts the 206-duty board read under 3 s (471 ms).
- N4: the person making the change is excluded from the review notice (`duties_alert_recipients(department, actor)`).
- N5: `duties_leader_board` (replaced, copied from `20261014171038`, 4.8) lists its first 200 duties plus every duty with an open review that has not started; overlap counts are computed once over the listed duties; `duties_truncated` is unchanged. The reviews view hides the 200 note; the full board's note says "and every duty that needs review".
- Tests: `duties_owner_decisions_test.sql` 106 (+18: board timing; S2 stays current while EV2 is open and ends once both are reviewed, source check; N4; N5 with 144 more duties pushing linked ones past 200; S1 unlink of a member who was the last leader of two departments, both handovers recorded against the grants, shown on Departments and Membership status, deactivation allowed afterwards, resolve; G3 now uses the Pastor for the dormancy check). Dart: the new copy asserted.

## Plan Change Log

- 2026-10-15 (review round 1): S1 unlink records (never refuses) the handovers its ended scopes leave; S2 a review notice stays current while any flag of its source in the department is open; S3 G4 rewritten (the token bucket throttles password sign-in); N1, N2, N4, N5 as above. `duties_leader_board` and `identity_unlink_account` are newly replaced bodies. Recorded under Review amendments. The frozen block is unchanged.

- 2026-10-15 (build): the review notice's link is `/duties/leader/reviews`, not `/duties/leader?needs=review` as the frozen Decisions say: the 3.2 reminder contract only accepts path segments (no query string). The client gained the `leader/reviews` route. The frozen block is unchanged.
- 2026-10-15 (build): the review notice is current while the keyed flag is at its revision (as the frozen text says), so a review of the keyed duty ends it even if another duty of the same change is still open (the 3.2 contract requires `revision` to equal the key's when current). Recorded under Implementation Notes. The frozen block is unchanged.

## Review Triage Log

- 2026-10-15, independent review: 0 blockers, 3 should-fix (S1-S3), 5 nits (N1-N5). S1, S2, S3 fixed; N1, N2, N4, N5 fixed; N3 no change (as asked).

## Verification

**Commands:**
- `npx supabase db reset && npm run -s db:test && npm run -s db:smoke` -- expected: pass.
- e2e-main.sh (worktree copy) with `duties-decisions` appended -- expected: each `exit=0`.
- `npm run -s contracts:test`, Dart contracts, node tool tests, `npm run -s ci:policy-test` -- expected: pass.
- `flutter analyze && flutter test` in `packages/client_core`, `apps/staff`, `apps/mobile`; TZ=America/New_York runs -- expected: pass.
- `npm run -s ci:secrets && npm run -s ci:migrations -- --base origin/main && npm run -s ci:function-imports`; evidence scan -- expected: clean.

**Results after review round 1 (2026-10-15):**
- db reset 0; db:test PASS (45 files, 3845 tests; `duties_owner_decisions_test.sql` 106); db:smoke pass (139 ok).
- Every E2E `exit=0` in one run (31 scripts, reset before each, one at a time, nothing else on the stack; `duties-decisions` 11/11).
- contracts:test 265/0; Dart contracts 282; node tool tests 252/0; ci:policy-test 56/0.
- flutter analyze clean in client_core, apps/staff, apps/mobile; tests 655, 40, 55; `TZ=America/New_York` client_core 241, apps/mobile 55.
- ci:secrets clean; ci:migrations (`--base origin/main`) 50 ordered, unique, non-destructive; ci:function-imports ok; evidence scan clean.

**Results (2026-10-15, build):**
- db reset 0; db:test PASS (45 files, 3827 tests; `duties_owner_decisions_test.sql` 88, timing 115-131 ms); db:smoke pass (139 ok).
- Every E2E `exit=0` on its final run (31 scripts, reset before each, one at a time; `duties-decisions` 11/11) (`evidence-4.16/e2e-suite-summary.txt`).
- contracts:test 265/0; Dart contracts 282; node tool tests (CI set) 252/0; ci:policy-test 56/0.
- flutter analyze clean in client_core, apps/staff, apps/mobile; flutter test client_core 655, apps/staff 40, apps/mobile 55; `TZ=America/New_York` client_core duties + followups + membership lifecycle 241, apps/mobile 55.
- ci:secrets clean; ci:migrations (`--base origin/main`) 50 ordered, unique, non-destructive; ci:function-imports ok; evidence scan (the 4.16 CI step) clean.

---
title: 'Apply the owner''s epic 4 decisions'
type: 'feature'
ticket: '16'
created: '2026-10-15'
status: 'in-progress'
baseline_revision: '4352fbb2258201cad9cd280768d3c628c1062c36'
route: 'full'
route_source: 'auto'
review: ''
review_source: ''
lenses_ran: []
review_loop_iteration: 0
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
- [ ] `supabase/migrations/20261015180000_duties_owner_decisions.sql` -- everything above, replaced bodies listed in its header.
- [ ] `supabase/tests/duties_owner_decisions_test.sql` (+ timing check) and the earlier pgTAP files whose assertions change (4.12 "no reason", ledgers).
- [ ] `packages/client_core` -- reason line (board, coverage), deep link and reviews-only view, revoke refusal text; tests.
- [ ] `tools/identity-e2e/duties-decisions.mjs` + `.test.mjs`.
- [ ] Runbooks `duties.md`, `identity-access.md`, `production-promotion-identity.md`; `evidence-4.16/`; CI evidence step.

**Acceptance Criteria:**
- Given a department with leaders, a held deputy and duties linked to a SYNTHETIC event, when the event changes, then each reachable leader and deputy gets one notice per department and the held deputy none.
- Given the matrix above, when each scenario runs through the API, then the outcomes hold and every earlier test still passes.

## Implementation Notes

## Plan Change Log

## Review Triage Log

## Verification

**Commands:**
- `npx supabase db reset && npm run -s db:test && npm run -s db:smoke` -- expected: pass.
- e2e-main.sh (worktree copy) with `duties-decisions` appended -- expected: each `exit=0`.
- `npm run -s contracts:test`, Dart contracts, node tool tests, `npm run -s ci:policy-test` -- expected: pass.
- `flutter analyze && flutter test` in `packages/client_core`, `apps/staff`, `apps/mobile`; TZ=America/New_York runs -- expected: pass.
- `npm run -s ci:secrets && npm run -s ci:migrations -- --base origin/main && npm run -s ci:function-imports`; evidence scan -- expected: clean.

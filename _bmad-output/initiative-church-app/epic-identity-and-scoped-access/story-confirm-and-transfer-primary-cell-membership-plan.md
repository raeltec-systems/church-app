---
title: 'Confirm and transfer primary cell membership'
type: 'feature'
ticket: '6'
created: '2026-10-07'
status: 'done'
baseline_revision: 'a16094ac8b8e18b67f979f55cb950b077d42b5c2'
route: 'full'
route_source: 'auto'
review: ''
review_source: ''
lenses_ran: []
review_loop_iteration: 0
context:
  - '{project-root}/_bmad-output/initiative-church-app/owner-decisions-milestone-1.md'
  - '{project-root}/docs/runbooks/identity-access.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** A cell answer from the application (2.4) is only "requested": nobody can set up cells or their leaders, confirm a member into a cell, follow up "not sure / not in a cell yet", or move a member to another cell, and no surface depends on confirmed cell membership.

**Approach:** Cells owns Admin cell setup, revisioned per-member primary membership with requests (from approved applications, the member or Admin), leader/Admin confirmation separate from church approval, an Admin follow-up queue, and an atomic confirmed transfer that ends the old membership (and its cell-private access) and dispatches the registered `cell_transferred` owner hooks in the same transaction. Leader and assistant are Identity scope grants (`cell_leader`, `cell_assistant`) given through the 2.3 `identity.grant_scope` command. Staff web gets Admin "Cells" and leader "My cell group" screens; mobile gets "My cell" with a change request.

## Boundaries & Constraints

**Always:**
- Every read/command passes `app.identity_access_evaluate()` (via `identity_evaluate_grant`/`identity_require_access`); untrusted sessions get `unauthenticated`. Cells commands use the 1.4 envelope through a `cells` authorizer registered in the 2.3 authorizer registry (the registry requires namespace = module, so Identity's authorizer cannot own `cells.*`).
- Confirm: the leader (active `cell_leader` scope) of the requested cell, or a live Admin. Assistants get cell-private access but cannot confirm. Nobody confirms, declines or requests a change for their own member record except the member's own change request/cancel.
- Zero or one current primary membership per member (partial unique index). A request grants nothing. Old-cell access ends in the confirming transaction; church membership, links and grants are untouched.
- Audit rows hold ids, codes and revisions only.
- Personal-data gate `identity_applications_open()`; while Q4 is unapproved, cell names/labels start `SYNTHETIC `.

**Decisions:**
- Decision (agent, under owner pre-approval): application-origin requests are created by Cells from approved applications (Cells may read Identity; Identity may not call Cells), idempotently, when a Cells read or command runs; one per application.
- Decision (agent, under owner pre-approval): a leader's decline refers the request to the Admin follow-up queue (`referred`); an Admin decline is final. Follow-up = open requests with no cell (`not_sure`, `not_in_cell`) or `referred`; Admin resolves by confirming into a chosen cell or declining.
- Decision (agent, under owner pre-approval): `cell_transferred` keeps the contract v1 payload (`identity_revision` = the member's Cells revision after the move); its emitter becomes `cells`. Owners needing old/new cell ids need a contract version change (not fabricated here).
- Decision (agent, under owner pre-approval): the fixture hook (`app.fixture_record_lifecycle`) is defined but registered only by tests/E2E, so no synthetic hook runs on hosted projects.

**Never:** destructive SQL or the text `delete from` in the main migration; hosted apply; SMS; real names/numbers; meetings, attendance, reports, chat, duties or follow-up workflows; Admin access to cell-private content by role alone.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected | Error |
|---|---|---|---|
| Setup | Admin `cells.create_cell` | cell + signup option, audited | non-Admin `forbidden`; non-SYNTHETIC name `validation_failed` |
| Confirm join | leader of requested cell | one primary; private surface opens | other leader / own record `forbidden`; stale `conflict` |
| Transfer | change request, new leader confirms | old ended, new active, hook ran in tx, church state unchanged | failing hook rolls everything back |
| Follow-up | not_sure / referred | Admin confirms with `cell_id` or declines | leader cannot see/confirm it |
| Change request | member, open request exists / same cell | `conflict` / `validation_failed` | — |

</frozen-after-approval>

## Code Map

- `supabase/migrations/20261003134340_cross_epic_contracts.sql` -- module registry (cells → identity, platform allowed), `contract_dispatch_lifecycle`, `cell_transferred` event, `contract_register_lifecycle_hook`.
- `supabase/migrations/20261006234820_identity_grants.sql` -- `cmd_register_authorizer`, `identity_register_scope_kind`, `identity_evaluate_grant`, `identity_member_has_scope/role`, `identity_require_access`, `cmd_current_request_id`, `identity_grant_command` (leader assignment reuses it).
- `supabase/migrations/20261007050512_membership_applications.sql` -- `cells_cells`, `cells_signup_options`, `cells_option_revision`, application table (`cell_choice`, `cell_id`), `identity_applications_open`.
- `supabase/migrations/20261007063340_membership_review.sql` -- application `member_id` on approval; command handler/outcome patterns.
- Tests: `membership_review_test.sql` helpers; `command_foundation_test.sql` allowlist; `identity_api_smoke.sh`.
- `tools/identity-e2e/review.mjs` -- E2E template (psql, signup, cleanup).
- client_core: `review_controllers.dart`, `membership_review_screen.dart`, `supabase_api_reader.dart`, `providers.dart`, `testing.dart`, `shell_routing.dart`, `composition.dart`; `apps/staff/lib/app.dart`, `apps/mobile/lib/app.dart`.

## Tasks & Acceptance

**Execution:**
- [x] `supabase/migrations/20261007075946_cell_membership.sql` -- tables (member states, requests, memberships, audit, fixture lifecycle calls), scope kinds, authorizer, commands, reads, private fixture read, privileges.
- [x] `supabase/tests/cell_membership_test.sql`, allowlist, smoke checks.
- [x] `tools/identity-e2e/cells.mjs` (+ test) -- proves the verify bullet.
- [x] client_core domain/adapter/controllers/screens/routes/fakes + tests; staff and mobile destinations + tests.
- [x] runbook section, `evidence-2.6/README.md`, CI evidence scan.

**Acceptance Criteria:**
- Given synthetic cells and leaders, when a leader confirms a member and a second leader confirms that member's change request, then the API shows one primary cell, the old private surface denies at once, the new one opens, the fixture hook ran in the same transaction and church membership is unchanged.
- Given CI, when db:test, db:smoke, analyze and tests run, then all pass.

## Implementation Notes

- Built directly (no subagent tool in this session). Checkpoint 1 pre-approved by the owner decisions; the plan is above the 1600-token guide because one Cells owner change spans DB, two clients and evidence (kept whole, as the epic's lane decision does).
- Files:
  - Migration `supabase/migrations/20261007075946_cell_membership.sql` (single file, no `delete from`, non-destructive: new tables, one `update` of the `cell_transferred` emitter, scope-kind and authorizer registrations).
  - pgTAP `supabase/tests/cell_membership_test.sql` (88); allowlist in `command_foundation_test.sql` (+10); `identity_grants_test.sql` authorizer/scope-kind assertions narrowed to their own module (Cells now registers its own); `identity_api_smoke.sh` (+10 checks).
  - E2E `tools/identity-e2e/cells.mjs` (+ `cells.test.mjs`).
  - client_core: `domain/cell_membership.dart`, `adapters/supabase_cells_repository.dart`, `application/cell_controllers.dart` (generic `CellsController<T>` + Admin/leader/my-cell controllers), `presentation/cell_screens.dart` (`CellAdminScreen`, `CellLeaderScreen`, `MyCellScreen`), routes `/admin/cells`, `/cells/leader`, `/my-cell`, `cellsRepositoryProvider`, composition, fakes (`FakeCells`, `adminCellData`, `adminCellRequestData`, `cellMemberRowData`, `myCellData`), tests `test/identity/cell_membership_test.dart` (15).
  - Apps: staff sidebar `staffCellsDestination` (Admin) and `staffCellLeaderDestination` (cell scope); mobile `mobileCellDestination` (member access); tests.
  - Docs: runbook section, `evidence-2.6/README.md`, CI evidence scan step.
- Decision (agent, under owner pre-approval): leader assignment reuses `identity.grant_scope` from the client (Admin screen sends it to `identity_grant_command`) rather than a Cells command, so the 2.3 audit, separation of duty and immediate effect apply unchanged.
- Decision (agent, under owner pre-approval): the Admin overview returns approved members (at most 500) with grant and Cells revisions so the Admin can pick leaders and request a cell for an accountless member without another read.
- Decision (agent, under owner pre-approval): cells reads are behind the same personal-data gate as the commands (`403 unavailable` when closed); a hold does not block a confirmation (holds deny access, not membership facts).
- Surprise: the command kernel runs handlers inside a subtransaction, so a hook's `pg_current_xact_id()` differs from the rows' `xmin`. The E2E proves "same transaction" by equal `xmin` of the hook row and both membership rows plus equal transaction start time; pgTAP proves atomicity with a failing hook.
- Environment: the local stack was reset three times; the phone switch was on only for the E2E and the regressions (`run`, `apply`, `review`, `grants`), then off as found. Every synthetic user and record created was removed.
- Owner/parent steps: apply the migration to staging after `20261007131600` and repeat the E2E-equivalent demo on staging (staff web + Android). No owner-only setting blocks the build.
- Review fixes (coordinator review, 2026-10-07; `20261007075946` edited in place, on no hosted project):
  - Admin cancellation recorded as `cancelled_by_admin` (request and audit; reason CHECK widened in the same file); member cancellation stays `member_withdrew`; pgTAP +2; Dart `CellDeclineReason.cancelledByAdmin`.
  - Mobile My cell keeps the chooser read (`MyCellView.options` is an `AccessRead`); a failure shows the read-problem banner with **Try again**, never "No other cells are listed"; widget test.
  - `cell_transferred`: migration updates the event description; fixture case name (and regenerated `fixtures.g.dart`) and runbook say `identity_revision` carries the member's Cells revision and that a v2 payload with `from_cell_id`/`to_cell_id` is needed before any real owner hooks it.
  - Evidence README: the staff-web UI path is covered by widget tests plus the API E2E and is driven for real in the owner's consolidated staging test.
  - Re-run: `db:test` 921/921 (cells 90); `db:smoke` ok; `cells.mjs` 13/13; client_core 216, staff 18, mobile 20, analyze clean; contracts dart 243 and ts 226 pass.

## Plan Change Log

## Review Triage Log

## Verification

**Commands:**
- `npx supabase db reset && npm run db:test && npm run db:smoke` -- pass
- `node tools/auth-harness/local-phone-auth.mjs on && node tools/identity-e2e/cells.mjs --evidence …; node tools/auth-harness/local-phone-auth.mjs off` -- all pass
- `flutter analyze && flutter test` in `packages/client_core`, `apps/staff`, `apps/mobile` -- pass
- Results (2026-10-07, local, after a reset): `db:test` 919/919 (cells 88); `db:smoke` all ok (105); `cells.mjs` 13/13; regressions `run.mjs` 30/30, `apply.mjs` 27/27, `review.mjs` 18/18, `grants.mjs` 18/18; client_core 215, staff 18, mobile 20 tests, analyze and format clean; staff `flutter build web` ok; `ci:migrations --base ccr-93e730dd-89lbvg` 16 ordered, non-destructive; `ci:secrets`, `scan-evidence`, node tool tests (44), `ci:policy-test`, `contracts:test` clean. Evidence: `evidence-2.6/README.md`.
- Matrix audit: every I/O row has a passing pgTAP assertion; Setup, Confirm join, Transfer and Follow-up also have E2E steps (C10–C40).

## Hosted verification

Staging apply, parity check and API checks: `evidence-2.6/staging-verify.md`. Owner device and staff-web check: consolidated test at the end of the epic.

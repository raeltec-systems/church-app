# Evidence: story 2.6 — confirm and transfer primary cell membership

**Run:** 2026-10-07, on the LOCAL stack only (Supabase CLI 2.119.0), after `npx supabase db reset` with every migration up to `20261007140000_cell_membership.sql`. Phone sign-up used the local-only phone switch (`tools/auth-harness/local-phone-auth.mjs on`/`off`): no SMS provider, hook, test OTP or SMS MFA; the E2E confirms `sms_provider` is empty. The switch was turned off afterwards.

**Data:** every record is SYNTHETIC.
- Phone numbers: `+1 202 555 0120–0139` (pgTAP), `+44 7700 900260–900264` (E2E).
- Names, cell names, labels and areas start with `SYNTHETIC `; no email was collected.
- The E2E removed every user, application, member, link, grant, cell, request, membership, audit row, receipt and its hook registration (`users_left: 0`, `hooks_left: 0`; the cells tables were empty afterwards). The Admin bootstrap leaves an append-only operator-journal row, as 2.3's and 2.5's E2E do.
- No hosted project was changed.

**Review fixes (2026-10-07):** an Admin cancellation is recorded as `cancelled_by_admin` (pgTAP); the mobile My cell screen shows the cell-list read failure with a retry instead of "no cells listed" (widget test); the `cell_transferred` contract description, fixture name and runbook say that `identity_revision` carries the member's Cells revision and that a v2 payload with `from_cell_id`/`to_cell_id` is needed before any real owner hooks it. All files here were re-run after the fixes.

## Results

| File | What it shows | Result |
|---|---|---|
| `local-pgtap.txt` | `npm run db:test`: the whole suite, including the new `cell_membership_test.sql` (90), the updated `command_foundation_test.sql` allowlist and two `identity_grants_test.sql` assertions narrowed to their own module | 921/921 pass |
| `local-api-smoke.txt` | `npm run db:smoke` with the CLI's default config (phone off), including the new cells checks (signed-out 401, applicant 403 `not_linked`, applicant cannot create a cell) | all ok (105) |
| `cells-e2e.jsonl` | `node tools/identity-e2e/cells.mjs`: real GoTrue phone sign-in and the real Data API | 13/13 pass |

Regressions on the same stack: `run.mjs` 30/30, `apply.mjs` 27/27, `review.mjs` 18/18, `grants.mjs` 18/18. Flutter: client_core 216 tests, staff 18, mobile 20, `flutter analyze` and `dart format` clean, staff `flutter build web` ok. `ci:migrations --base ccr-93e730dd-89lbvg` ordered and non-destructive; `ci:secrets`, `scan-evidence` and the node tool tests (44) clean.

### The ticket's `verify`, step by step

| Verify clause | Evidence |
|---|---|
| On **staff web**, confirm a synthetic member's cell **as its leader** | E2E C10–C11: an Admin creates two cells (a non-Admin is refused) and gives each a leader through `identity.grant_scope` with the Cells-registered `cell_leader` kind. C20: church approval of an application asking for X confirms no cell (primary `null`, request `pending`). C21–C22: the leader of X sees the request, the leader of Y does not and cannot confirm it; the leader of X confirms: X's private surface opens, Y's stays `403`. Staff web screens: `CellLeaderScreen` and `CellAdminScreen`, widget-tested in `packages/client_core/test/identity/cell_membership_test.dart` (exact envelopes, own record disabled, unknown outcome resent under the same request id) and `apps/staff/test/staff_app_test.dart` "story 2.6" (navigation follows the cell scope and the Admin role). |
| **Transfer** them to another cell | C30: the member asks to move to Y (a request grants nothing: Y is still `403`). C31: the leader of X cannot confirm the move into Y (`forbidden`); the leader of Y confirms it. |
| Through the API, **only one primary cell** exists | C32: `cells_my_cell` names Y only; one current membership row; the X membership ended as `transferred` (history kept). pgTAP: the partial unique index, "exactly one current primary membership". |
| The old cell's private fixture surface is **denied at once** | C32: the same session gets `403 not_granted` from X's surface right after the confirmation. pgTAP also shows an assistant losing access on the next call after the scope is revoked. |
| The **new one opens** | C32: Y's surface answers `200`. |
| A fixture **transfer hook ran in the same transaction** | C33: the SYNTHETIC `app.fixture_record_lifecycle` hook, registered for `cell_transferred` for this run only, ran once, with the member's new Cells revision; its own row's `xmin` equals the `xmin` of both the new and the ended membership rows, and its time equals the membership's start (same transaction). pgTAP: a failing hook makes the confirmation `unavailable` and rolls everything back (still in X, request still pending); a replay runs no hook again. |
| **Church membership is unchanged** | C34: the member summary keeps the member id and `approved`; the Identity member revision and the grant-set revision are unchanged across the transfer. pgTAP: member row, grants revision and account link identical before and after. |

**Staff-web UI path:** covered by the widget tests (`cell_membership_test.dart`, `staff_app_test.dart`) plus the API E2E above. It is driven for real in the owner's consolidated staging test at the end of the epic.

### Also covered

- **Admin follow-up queue** (C40; pgTAP): a "not sure" applicant's request is flagged `follow_up`, no leader sees it, a leader cannot read the Admin overview, and the Admin confirms it into the cell they checked (a cell is required). A leader's decline refers a request to the queue; an Admin's decline is final.
- **Separation of duty** (pgTAP): nobody confirms their own cell membership; a member cannot request for someone else; the Admin role alone gives no cell-private access.
- **Content-free audit** (C50; pgTAP): no audit row contains a phone, name or label of the run; actor capacity and command request id are recorded.

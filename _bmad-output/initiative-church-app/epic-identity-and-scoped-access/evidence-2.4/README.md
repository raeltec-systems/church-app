# Evidence: story 2.4 — register and apply for membership with a safe cell choice

**Run:** 2026-10-07, on the LOCAL stack only (Supabase CLI 2.119.0), after `npx supabase db reset` with every migration up to `20261007042111_membership_applications.sql`. Phone sign-up used the local-only phone switch (`tools/auth-harness/local-phone-auth.mjs on`/`off`): no SMS provider, hook, test OTP or SMS MFA, and the E2E confirms `sms_provider` is empty.

**Data:** every record is SYNTHETIC.
- Phone numbers come only from `+1 202 555 0141–0149` (pgTAP), `+1 202 555 0181–0183` and `+44 7700 900181` (E2E and adapters). pgTAP also uses `+999…`, an unassigned ITU code, only to prove the fictional-range fence.
- No email was collected for any applicant.
- The cells are the three SYNTHETIC seed cells.
- Each run deleted every user, application, event, receipt and seeded cell it created.
- No hosted project was changed.

## Results

| File | What it shows | Result |
|---|---|---|
| `local-pgtap.txt` | After the review fixes, a targeted run of `membership_applications_test.sql` (97 assertions) and `command_foundation_test.sql` (the EXECUTE allowlist). Before the fixes, the full `npm run db:test` passed 699/699; the coordinator re-runs the full suite. | 167/167 pass |
| `local-api-smoke.txt` | `npm run db:smoke`, including the new Data API checks | all ok |
| `local-apply-e2e.jsonl` | `node tools/identity-e2e/apply.mjs`: real GoTrue phone sign-up and the real Data API | 27/27 pass |
| `local-client-adapter-check.txt` | `tools/identity-e2e/live-application-check.sh`: the real Dart adapters | L1–L8 pass |

The smoke checks: signed-out callers get 401 on the three new functions. An unlinked phone account reads its own empty request and the safe chooser, applies, and still gets `403 not_linked` on its access read.

The real Dart adapters are `SupabaseAccountAuthGateway`, `SupabaseMembershipRepository`, `SupabaseCommandGateway`, `SupabaseMemberAccessRepository` and `SupabaseGrantsRepository`.

### The ticket's `verify`, step by step

| Verify clause | Evidence |
|---|---|
| Register a new synthetic applicant with **each cell choice** and **no email** | E2E A10–A14 (three phone sign-ups, `has_email: false`; choices `cell`, `not_sure`, `not_in_cell`); A44 (no applicant email in Auth); adapter L1, L4. Mobile flow: `apps/mobile/test/mobile_app_test.dart` "story 2.4" and `packages/client_core/test/identity/membership_application_test.dart` (one test per choice). |
| **Correct** the request | E2E A20 (revision 2), A21 (stale revision gets `conflict` + `current_revision`), A22 (a replay returns the stored result; a reused request id with a changed body gets `conflict`), A23 (membership and cell status fields are refused as `unknown_field`); adapter L5–L6; widget tests "correct the request" and "changed elsewhere". |
| A **duplicate username** is rejected **without overwrite** | E2E A30: sign-up with the same phone gets `422 user_already_exists`; the duplicate's password does not sign in (400); the original password signs in to the same account id; one Auth user for the number; the request is unchanged at revision 2. Adapter L8: `usernameUnavailable`. |
| The cell projection exposes **only names and broad areas** | E2E A11 (keys exactly `broad_area, cell_id, label, revision`); A01 (401 without a session). pgTAP: the projection table has only label, area and listing columns; applicants and members get the same safe list; access review and OTP sessions are refused; SYNTHETIC options are never listed in an unmarked (production) database. |
| The pending account cannot read **any member, cell or private surface** | E2E A40: member summary, own access, Admin roster and fixture scoped surface all return `403 not_linked`. A41: the app/api tables, including `cells_cells`, are not reachable (406/404). A42: each applicant sees only their own request. A43: no member, link or grant was created. pgTAP covers the same and adds direct-select refusal (42501) and a refused grant command. |

## Client checks

- **Flutter** (`flutter analyze` and `flutter test`):
  - `packages/client_core`: 180 tests, analyze clean.
  - `apps/mobile`: 18 tests (new "story 2.4" shell test), analyze clean.
  - `apps/staff`: 16 tests, analyze clean.
  - Staff web build and bundle secret scan: clean.
- **Repository checks:**
  - `ci:migrations --base ccr-93e730dd-89lbvg`: 13 migrations, ordered and non-destructive.
  - `ci:secrets` and `ci:policy-test` (49) are clean.
  - Node tool tests: 39.
  - `scan-evidence` is clean for this folder and `tools/identity-e2e`.
- **Regressions:** with the phone switch on, `tools/identity-e2e/run.mjs` (2.1/2.2) passed 30/30 and `tools/identity-e2e/grants.mjs` (2.3, through the replaced dispatching authorizer) passed 18/18.

## Not done here (owner or parent)

- **Staging apply** of `20261007042111_membership_applications.sql` to `bic-kafue-platform-test`, then `select app.cells_seed_synthetic_cells('<operator>')` on staging. Hosted apply was out of scope for this build.
- **The owner's device demonstration** on Android: Create account, then Join the church with each choice, then Correct.
- **Owner gates, all left fail-closed:**
  - the church's real cell list and sign-up labels (entry 6 Admin cell setup; production lists no cells until then);
  - the approved privacy-notice text and `q4_personal_data`; production refuses applications as `unavailable` until the owner approves.

## Review fixes (2026-10-07)

After the coordinator's review, the migration was edited in place; it is on no hosted project. pgTAP covers each fix:

- **Name normalisation.**
  - Every Unicode whitespace run collapses to one space and a regex trim removes the ends, so tab, newline, NBSP and ideographic-space edges no longer reach the table CHECK as `unavailable`.
  - Unicode control (Cc) and format (Cf) characters are refused as `validation_failed` on `full_name`. That includes U+202E and zero-width characters.
  - While Q4 is unapproved, the name must start with `SYNTHETIC `.
- **Who is an applicant.** Only an account with no live link, and no open hold on any member it was ever linked to. Accounts linked to a pending, rejected or deactivated member, and an ended link with a held member, get `forbidden` with reason `not_applicant` on the command, the chooser and my-application.
- **Chooser behind the personal-data gate.** A production database with Q4 closed lists nothing, even a non-synthetic cell. With Q4 approved, only the non-synthetic option is listed.
- **Held restore fenced in every environment.** A production held restore stays closed even with Q4 approved.
- **Correction cap.** 10 corrections per application per rolling 24 hours (`app.identity_application_correction_limit()`); the 11th gets `rate_limited`.
- **Nested field errors use dotted paths:** `cell_choice.choice`, `cell_choice.cell_id`, `cell_choice.cell_revision`, and each unknown nested key on itself as `cell_choice.<key>`.
- **Explicit privacy acceptance (client).**
  - A new request needs the "I have read the privacy notice" checkbox, which is unchecked by default.
  - When the app has no bundled text for the server's notice version, sending is disabled and the screen sends the applicant to the church office.
  - Two new widget tests cover this; `membership_application_test.dart` has 21 tests, and the mobile "story 2.4" test passes.
- **Re-runs after the fixes:** `local-apply-e2e.jsonl` 27/27, the adapter check L1–L8, and the identity smoke all pass.
- **Deferred, not built:** sign-up rate limits are Supabase Auth's own settings (owner/Q1 configuration); re-applying after a rejection belongs to entry 5.

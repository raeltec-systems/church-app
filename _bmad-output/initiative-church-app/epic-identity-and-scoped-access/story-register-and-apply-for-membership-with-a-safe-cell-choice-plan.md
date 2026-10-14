---
title: 'Register and apply for membership with a safe cell choice'
type: 'feature'
ticket: '4'
created: '2026-10-07'
status: 'done'
baseline_revision: '9775471ca2a73d6a032af78008695d3cbc0a5db9'
route: 'full'
route_source: 'auto'
review: 'quick'
review_source: 'pinned'
lenses_ran: []
review_loop_iteration: 0
context:
  - '{project-root}/_bmad-output/initiative-church-app/owner-decisions-milestone-1.md'
  - '{project-root}/docs/runbooks/identity-access.md'
  - '{project-root}/docs/runbooks/contracts-and-owner-seams.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** A new phone/password account has nowhere to go: there is no membership application, no cell chooser and no applicant status, so nothing records who is asking to join or which cell they named, and an applicant has no safe way to read their own request.

**Approach:** Identity gains a correctable membership application (name, privacy-notice version, cell choice) changed only through 1.4 commands and read only by its own applicant. The Cells owner gets its first records: synthetic-seeded cells and a separately persisted safe sign-up projection (name and broad area only), registered with the 1.5 source-type seam so Identity validates a chosen cell without depending on Cells. Mobile goes from Create account to the application and then to a status view with separate church and cell chips.

## Boundaries & Constraints

**Always:**
- An applicant is a trusted password session whose predicate outcome is `not_linked` (`app.identity_access_evaluate()`, not copied). Applying never creates a member, link, grant, scope or cell membership, so an unapproved applicant still gets `not_linked` everywhere.
- The applicant may set only name, cell choice and the notice version, never membership or cell status. Corrections need `expected_revision`, and the receipts make replays safe.
- The cell projection returns only `cell_id`, label, broad area and revision. Never leaders, members, addresses, phones, chat or reports.
- Every phone and name is synthetic: `+1 202 555 0100–0199`, `+44 7700 900000–900999`. Email stays optional and unused. No SMS.

**Decisions:**
- Decision (agent, under owner pre-approval): commands `identity.submit_application` (create, `expected_revision` null) and `identity.correct_application` go through `api.identity_application_command`. The 2.3 `identity` authorizer is replaced in a new migration so that it dispatches: application commands require `not_linked`, and grant commands keep their body unchanged.
- Decision (agent, under owner pre-approval): Identity checks a chosen cell through `app.contract_check_source` against the `cells_signup_option` source type that Cells registers. This keeps Identity independent of Cells, as AD-1 and the 1.5 guards require. A stale or unlisted option returns `validation_failed {"cell_id": "invalid"}`.
- Decision (agent, under owner pre-approval): the application stores the choice (`cell`, `not_sure` or `not_in_cell`). Cells confirmation requests, the Admin follow-up queue and the leader confirmation belong to entry 6, and review belongs to entry 5. Applying does not create them. The state CHECKs already list every later state, because widening a CHECK would need a destructive statement.
- Decision (agent, under owner pre-approval): cell records come only from the restricted operator function `app.cells_seed_synthetic_cells`. It refuses unless the database is marked local or staging. Synthetic options are never listed in an unmarked or production database. The real cell list is an owner gate (entry 6/14).
- Decision (agent, under owner pre-approval): applications hold personal data, so they need `q4_personal_data` approved, or a local/staging database that is not a held restore, in which case the applicant phone must be in a fictional range. Otherwise the result is `unavailable {"policy":"gate_closed"}`. The privacy notice is a labelled DRAFT (version `draft-2026-10-07`) until Q4 approves the text.
- Decision (agent, under owner pre-approval): one open application (submitted or needs_details) per account. Correcting a needs_details request returns it to submitted. The audit events hold ids, revisions and changed field names only.
- Decision (agent, under owner pre-approval): Create account opens the application on mobile. Staff web keeps its sign-in and the shared route, but has no application entry point.

**Never:** destructive SQL; hosted apply; Admin review, linking or the duplicate queue (5); cell setup, confirmation or follow-up queue (6); recovery-email entry (7); youth fields (Q4); applicant-visible data about other people.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Submit each choice | new phone account, choice cell / not_sure / not_in_cell | revision 1, state submitted; status shows Awaiting church approval + cell chip | — |
| Correct | own application, current revision | revision+1, events row | stale → `conflict` + current_revision |
| Replay | same request_id, same/changed body | stored result / `conflict` | — |
| Forbidden fields | payload with membership/cell status | `validation_failed` unknown_field | — |
| Second open application | already submitted | `conflict` | — |
| Unlisted or stale cell | retired id / old revision | `validation_failed {"cell_id":"invalid"}` | reload options |
| Duplicate username | sign-up with an existing phone | Auth 422; same user id, old password works, application unchanged | generic message |
| Pending reads | applicant token | own application only; member summary, access, roster, fixture scope, tables denied | — |
| Member / held / untrusted | granted, review_required, otp session | command `forbidden` / `forbidden` / `unauthenticated` | — |
| Production unmarked | q4 closed | `unavailable` gate_closed; options empty | — |

</frozen-after-approval>

## Code Map

- `supabase/migrations/20261006234820_identity_grants.sql` -- `identity_authorize_command` (replace body, keep grant branch verbatim), `identity_access_evaluate`, the `identity_lock_grant_set` pattern, `cmd_current_request_id`.
- `supabase/migrations/20261003134340_cross_epic_contracts.sql` -- `cmd_execute`, `contract_register_source_type`, `contract_check_source`, `contract_uuid_error`, `contract_revision_error`, `policy_is_open`, `platform_current_environment`. The prefixes `cells_` and `identity_` are already registered, and cells→identity is allowed.
- `supabase/tests/command_foundation_test.sql` -- the exact allowlist of what `authenticated` may execute (add new pairs); `identity_grants_test.sql` fixture helpers (`pg_temp.session`, claims).
- `supabase/tests/identity_api_smoke.sh`, `tools/identity-e2e/run.mjs` (helpers `assertLocalOrigin`, `redact`), `tools/auth-harness/local-phone-auth.mjs` (phone on/off).
- `packages/client_core`: `supabase_grants_repository.dart` `_read` (extract shared reader), `account_controllers.dart` generation pattern, `fixture_command_screen.dart`/`access_controllers.dart` command handling, `sign_in_screen.dart`, `account_screen.dart`, `shell_routing.dart`, `testing.dart` harness, `composition.dart`; `apps/mobile/lib/app.dart`.

## Tasks & Acceptance

**Execution:**
- [x] `supabase/migrations/20261007050512_membership_applications.sql` -- Cells tables, projection, seed, check hook, registration and `api.cells_signup_options`; Identity applications, events, the authorizer dispatch, the two commands, `api.identity_application_command` and `api.identity_my_application`; grants.
- [x] `supabase/tests/membership_applications_test.sql` -- pgTAP for the matrix, privileges, gates and guards; update the allowlist in `command_foundation_test.sql`.
- [x] `supabase/tests/identity_api_smoke.sh` -- anon is denied the new functions.
- [x] `tools/identity-e2e/apply.mjs` (+ test) -- real phone sign-up for each choice, correction, duplicate username, projection keys, pending denials, cleanup, redacted JSONL.
- [x] `packages/client_core` -- application domain, adapter, controller, application/status screen, post-sign-up route, account-screen link, fakes, tests.
- [x] `apps/mobile` -- route wiring and an app test; `apps/staff` unchanged except for tests if needed.
- [x] `docs/runbooks/identity-access.md`, `evidence-2.4/README.md`, CI evidence scan.

**Acceptance Criteria:**
- Given three new synthetic phone accounts without email, when each applies with a different choice and one corrects it, then each status shows church approval and cell status separately and every non-own surface is denied.
- Given CI, when db:test, db:smoke, flutter analyze and flutter test run, then all pass.

## Implementation Notes

- Built directly, because this session has no subagent tool. Files:
  - Migration: `20261007050512_membership_applications.sql`.
  - Database tests: pgTAP `membership_applications_test.sql` (72); allowlist in `command_foundation_test.sql` (+6 client-executable functions); `identity_api_smoke.sh` (+7 checks, and its cleanup now removes applications, events and receipts).
  - E2E tools: `tools/identity-e2e/apply.mjs` (+ `apply.test.mjs`), `live-application-check.sh` and `packages/client_core/tool/live_application_check.dart`.
  - client_core:
    - `domain/membership_application.dart`;
    - `adapters/supabase_api_reader.dart`: the shared read helper, extracted from the 2.3 grants repository, which now uses it;
    - `adapters/supabase_membership_repository.dart`;
    - `application/application_controllers.dart`;
    - `presentation/membership_application_screen.dart`;
    - the `/membership` route, the `membershipRequests` router flag, the post-sign-up destination, the account-screen link, fakes (`FakeMembership`, `applicationData`) and `test/identity/membership_application_test.dart` (18).
  - Mobile: `membershipRequests: true` and a "story 2.4" shell test.
  - Docs: the runbook section, `evidence-2.4/README.md` and the CI evidence scan step.
- Cross-lane edits (necessary):
  - `app.identity_authorize_command` (2.3) is replaced with `create or replace` in the new migration. It dispatches application commands to `app.identity_authorize_application_command`; the grant branch is the 2.3 body verbatim. Regressions: `identity_grants_test.sql` 113/113 and `grants.mjs` 18/18.
  - The `command_foundation_test.sql` allowlist.
- Decision (agent, under owner pre-approval): `app.cells_option_revision` is the single listing rule, shared by the chooser read and the check hook. An option is listed only when its cell is active, it is marked listed, and it is not SYNTHETIC unless the database is marked local or staging.
- Decision (agent, under owner pre-approval): the cell check hook reports `current` only when the chosen revision is still the option's revision. Relabelling an option therefore makes a client reload before it submits, so the applicant never confirms a label they did not see.
- Decision (agent, under owner pre-approval): while `q4_personal_data` is unapproved, the applicant's phone must be in a fictional range. This keeps staging synthetic, as the owner decision of 2026-10-06 requires. pgTAP proves the fence with `+999…`, an unassigned ITU code, so no real-format number is used.
- Decision (agent, under owner pre-approval): a correction that changes nothing returns the current request without a new revision or event.
- Decision (agent, under owner pre-approval): the recovery-email offer after sign-up is a note only ("email is optional; staff help in person without it"). The same-account email-addition flow is entry 7, and no email field is collected here.
- Surprise: after `tools/identity-e2e/grants.mjs` (2.3) runs, `identity_grants_test.sql` fails 2 assertions. The E2E leaves append-only operator-journal rows, so the 2.3 pgTAP counts are not re-entrant. A `supabase db reset` restores them. This is pre-existing and was not changed here.
- Environment: the local stack was reset twice (`npx supabase db reset`); the 2.3 migration had been applied locally under its earlier version. The local phone switch was turned on for the phone E2E and the adapter check, then off. Every synthetic user, application, event, receipt and seeded cell created here was removed.
- Owner gates (fail-closed, nothing to do for this build):
  - the church's real cell list and sign-up labels (entry 6 Admin setup, then entry 14 production);
  - the approved privacy-notice text and the `q4_personal_data` gate (production refuses applications until then).

  For the parent and owner: the staging apply, `select app.cells_seed_synthetic_cells('<operator>')` on staging, and the Android device demonstration.

- Review fixes (coordinator review, 2026-10-07; migration edited in place because it is on no hosted project):
  - **Name normalisation.** Collapse all Unicode whitespace, then a regex trim. Unicode Cc and Cf characters, including U+202E, are refused as `validation_failed full_name`. While Q4 is unapproved, the name must start with `SYNTHETIC `.
  - **Applicant authorizer.** New `app.identity_applicant_outcome()`: an account with no live link and no open hold on any linked member. Linked-to-pending/rejected/deactivated and held accounts get `forbidden not_applicant` on the command, the chooser and my-application.
  - **Chooser.** Returns nothing unless `app.identity_applications_open()`.
  - **Held restore.** `app.identity_applications_open()` now refuses a held restore in every environment.
  - **Correction cap.** `APPLICATION_CORRECTION_LIMIT` = 10 per application per rolling 24 hours gives `rate_limited`.
  - **Dotted paths.** `cell_choice.*` field errors, each unknown nested key on itself. The contract runbook's only nested rule is "every unknown key is reported on itself", so the dotted path extends it to keys inside a payload object.
  - **Client.** An explicit privacy-notice checkbox, unchecked by default, is required to send a new request; the controller refuses without it too. With no bundled text for the server's version, sending is disabled and the church-office message is shown. The controller and screen read the dotted keys.
  - **Tests.** pgTAP 72 → 97; widget tests +2; the E2E and adapter check were re-run.
- Deferred (not built, by direction):
  - sign-up rate limits are Supabase Auth's settings (Q1 owner configuration);
  - re-applying after a rejection belongs to entry 5.

## Verification

**Commands:**
- `npx supabase db reset && npm run db:test && npm run db:smoke` -- expected: pass
- `node tools/auth-harness/local-phone-auth.mjs on && node tools/identity-e2e/apply.mjs --evidence … ; node tools/auth-harness/local-phone-auth.mjs off` -- expected: all pass
- `flutter analyze && flutter test` in `packages/client_core`, `apps/mobile`, `apps/staff` -- expected: pass
- Results (2026-10-07, local):
  - `db:test` 699/699 (applications 72); `db:smoke` all ok.
  - `apply.mjs` 27/27; live adapter check L1–L8 pass.
  - Regressions with the phone switch on: `run.mjs` 30/30, `grants.mjs` 18/18.
  - Flutter tests: client_core 180, mobile 18, staff 16; analyze clean, format clean; staff web build and bundle scan clean.
  - `ci:migrations --base ccr-93e730dd-89lbvg`: ordered and non-destructive. `ci:secrets`, `ci:policy-test`, `env:check`, the node tool tests (39) and `scan-evidence` are clean.
  - Evidence: `evidence-2.4/README.md`.

## Review Triage Log

| Finding | Verdict | Route | Evidence |
|---|---|---|---|
| whitespace edges reach the table CHECK as `unavailable`; format characters (U+202E) accepted | medium | patch | identity_application_name used btrim and `\s` |
| accounts linked to a pending/rejected/deactivated member, or held, could apply | high | patch | the authorizer accepted any `not_linked` outcome |
| chooser not behind the personal-data gate | medium | patch | cells_signup_options ignored identity_applications_open |
| held restore fenced only in local/staging | medium | patch | identity_applications_open |
| privacy notice accepted implicitly | medium | patch | client send() had no explicit acceptance |
| corrections unlimited | low | patch | no cap |
| nested field errors not path-qualified | low | patch | cell_choice errors used bare keys |
| local/staging fence checked the phone only | low | patch | name not required to be SYNTHETIC |

## Hosted verification

Staging apply, parity check and the owner's Android demonstration: `evidence-2.4/staging-verify.md`.

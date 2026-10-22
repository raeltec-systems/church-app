---
title: 'Publish verified giving methods and show How to give to guests'
type: 'feature'
ticket: '3'
created: '2026-10-21'
status: built
baseline_revision: 'd2ed1540051bda211b0eab50f53acb6e0aca8f1f'
route: 'full'
route_source: 'auto'
review: 'quick'
review_source: 'pinned'
lenses_ran: ['quick']
review_loop_iteration: 0
followup_review_recommended: true
context:
  - '{project-root}/docs/runbooks/content.md'
  - '{project-root}/docs/runbooks/client-shells.md'
  - '{project-root}/.agents/skills/design-taste-frontend/references/app-screens.md'
  - '{project-root}/_bmad-output/initiative-church-app/epic-public-content-and-giving/story-publish-an-event-on-staff-web-and-read-it-as-a-guest-on-the-plan.md'
warnings: ['oversized', 'multiple-goals']
deferred:
  - summary: >-
      One person can hold two Admin identities and verify their own destination, because Identity
      lets one Admin approve a member and grant Admin alone.
    evidence: |-
      External check finding 2. A Content-side "granted by the saver" rule would block the normal
      case where the first Admin grants the second. Recorded as a residual risk in content.md and
      an owner question (a two-person rule for granting Admin, a minimum time as Admin before
      verifying, or showing "Admin since, granted by" in the Verify dialog).
    location: >-
      supabase/migrations/20261022011438_content_giving_methods.sql (app.content_giving_verify);
      Identity grants (20261006234820_identity_grants.sql)
    severity: medium
  - summary: >-
      A database-owner role could rewrite an unverified revision's savers list in one UPDATE and
      verify in a second one.
    evidence: |-
      External check second pass, informational: the trigger enforces saver-list integrity on
      published and verified rows and on the verifying UPDATE itself, not on unverified rows.
      Reachable only by roles that can also disable triggers; no client role holds any privilege.
    location: >-
      supabase/migrations/20261022011438_content_giving_methods.sql (app.content_giving_revision_guard)
    severity: low
  - summary: >-
      The Admins' read names only the last saver while every saver is blocked from verifying, so
      nobody sees that a third Admin or a discard is needed.
    evidence: |-
      External check second pass, cosmetic. Adding every saver's name to the staff read is a wire
      change for the client parser; the staff screen's footer already says a draft both Admins
      saved needs a third Admin or Discard changes.
    location: >-
      app.content_giving_revision_json; packages/client_core/lib/src/presentation/giving_staff_screens.dart
    severity: low
---

<intent-contract>

## Intent

**Problem:** The Give tab does not exist, and nothing lets the church publish where and how to give. A wrong or maliciously changed destination can redirect money, so one Admin must never be able to put a destination in front of members alone (owner decision 2026-10-21).

**Approach:** Add the Content kind `giving_method` (Admin only) on entry 1's lifecycle through its registries: type-specific destination fields (mobile money, bank, other), numbered steps, optional starting USSD code, purpose, currency, contact, sort order; a per-revision church verification recorded by a different Admin from the one who last saved it, required before any publication; a `q3_giving` gate; public reads; a staff web **Giving** screen; and the mobile **Give** tab (How to give, method list, method detail with copyable values, steps, beneficiary check, last verified date, contact, sample banner off production).

**Decisions:**
- Decision (owner, 2026-10-21): a destination added or changed by one Admin is verified by a different Admin before members see it; until then it stays a draft.
- Decision (agent, under owner pre-approval): verification is per revision, stricter than K16's "after any destination change": name, steps, USSD code, beneficiary and contact can each redirect a gift, so every saved revision needs its own verification (verifier, tested-on date, how tested). Any save clears it. The verifier must not be the Admin who last saved the revision. Every save carries the whole method (absolute state), so the last saver vouches for all of it and the verifier is a second person: no Admin publishes alone, and two Admins never deadlock. The rule holds in the database too: a published revision must be verified (check), and a verification recorded by the revision's last saver is refused (trigger).
- Decision (agent, under owner pre-approval): order is outside revisions: `content.move_giving_method` applies at once (no verification; order redirects nothing) and is audited. Hide is the lifecycle's withdraw (republish shows the live revision again). The method type is fixed at creation.
- Decision (agent, under owner pre-approval): nothing shared is replaced: kind, commands and erase part are registry rows; the giving-only audit actions (`verified`, `reordered`) go to a Content-owned `app.content_giving_audit`, because widening `app.content_state_ok` would replace a shared function.
- Decision (agent, under owner pre-approval): `q3_giving` is closed in production until Israel approves it (`unavailable {policy: gate_closed}` on publish); its local/staging fixture is `sample_only`, so a method published there must be named `SAMPLE ...`. The public read's `sample` flag is true off production; the app shows the amber sample banner from it.
- Decision (agent, under owner pre-approval): each method carries its church contact (verified with the rest). A mobile money method requires a beneficiary and one identifier (merchant ID, till number or phone number). The dialler button, logos, offline cache and the unsafe flag are entry 5 (and 4); this entry shows the USSD code as a copyable value.

## Boundaries & Constraints

**Always:** every write through `api.content_command` (registered commands, kind editor roles = `admin` only, entry 1 authorizer and replay recheck unchanged); handlers `set search_path = ''`; outcomes carry ids, states and revisions only; public projection is the live revision's giver-facing fields plus the verified-on date, never verifier, test notes, editor identity or drafts; staff read Admin only; ASCII migration, no backslashes, no destructive statements, no row deletion; privilege ledgers and the fixture-gate list updated; church dates in Africa/Lusaka.

**Never:** amount, payer, sender, donor, proof, receipt, gift or transaction fields in any table, payload, read or screen; payment processing, success state or "record my gift"; a dialler handoff, logo, offline cache or unsafe flag (entries 4, 5); edits to entry 1's shared functions (`app.content_state_ok`, lifecycle helpers, authorizer, dispatch, deletion handler) or to the staff screens another agent is redesigning (Coverage, Outcomes, Special assignments, Cell meetings, Plan meeting, My cell group, member panel).

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Create | Admin A, valid fields of a type | draft revision 1, unverified, last position; public unchanged | none |
| Refused actor | Media, Pastor, plain member, Pending; anon | every giving command `forbidden`; anon 401 | nothing written |
| Bad payload | amount / payer / unknown key; bad type field; > 12 steps; bad USSD, currency, SWIFT | `validation_failed` with `unknown_field` / field codes | nothing written |
| Verify own save | A verifies the revision A last saved | `validation_failed {method_id: saved_by_you}` | trigger refuses a direct write too |
| Verify | B, tested_on within 90 days, not future, how tested | revision verified (who, when, tested_on, how) | future/older: `tested_on: out_of_range`; no draft: `nothing_to_verify`; again: `already_verified` |
| Publish | verified draft | live; public read shows it with verified-on date | unverified: `method_id: not_verified`; nothing: `nothing_to_publish` |
| Change destination | A saves new account number on a live method | new draft, unverified; old revision stays public | publish: `not_verified` until B verifies |
| Gate | production, q3 unapproved | publish `unavailable {policy: gate_closed}`; drafts and verify allowed | fixture: name without `SAMPLE ` prefix: `name: sample_only` |
| Hide / archive | published / any | hidden leaves public reads, republishable; archived refuses all later commands | `not_published`, `archived` |
| Reorder | move to position p | public order follows at once; audited | `position: out_of_range`; stale: `conflict` |
| Public reads | anon, Pending, member | `{sample, methods}` in order; detail by id; null for draft-only, hidden, archived, unknown | no verifier, test note, editor or draft |
| Staff read | Admin | all methods, live and draft revisions, verification, `saved_by_you` | Media, Pastor, member 403 `not_granted`; anon refused |
| Tables | any client role | no privilege on any `app.content_giving*` table | permission denied |
| Deletion | Admin erased | saved/verified/published attribution and giving audit actors become nil UUID; staff read `Former member`; check 0 | |

</intent-contract>

## Code Map

- `supabase/migrations/20261021233523_content_events_tracer.sql` -- template and the registries to call: `app.content_kinds`, `app.content_register_command`, `app.content_register_erase_part`, lifecycle helpers (`content_command_actor`, `content_item_open/lock/draft_no/saved/publish/withdraw/archive/outcome`), `content_free_text`, `content_editor_name`, `content_editor_capacity`; event commands, public and staff reads, erase part, privilege block. Do not edit it.
- `supabase/migrations/20261003134340_cross_epic_contracts.sql` -- `app.policy_gates` row shape (`fixture_value` with `fixture_label`), `app.policy_effective` (closed: `unavailable {policy: gate_closed}`), `app.contract_unknown_keys`, `app.contract_uuid_error`, `app.cmd_utc`.
- `supabase/tests/content_events_test.sql` -- pgTAP pattern (users, sessions, `cmd` helpers); `supabase/tests/command_foundation_test.sql` -- anon and authenticated EXECUTE ledgers; `supabase/tests/cross_epic_contracts_test.sql:320` -- the fixture-gate list.
- `tools/identity-e2e/content-events.mjs`, `content-events.test.mjs`, `harness.mjs` -- E2E pattern.
- Client (entry 1's pattern for every layer): `packages/client_core/lib/src/domain/content_events.dart` (strict parsers, `editsContent`), `adapters/supabase_content_repository.dart` (public reads via `SupabaseApiReader.read(public: true)`), `application/content_controllers.dart` (public controller keeps the last good answer; staff controller), `presentation/calendar_screens.dart` (public list/detail), `presentation/content_screens.dart` (staff Events with `ChurchPageScaffold`), `presentation/shell_routing.dart` (`ClientPaths`, `memberHome` routes), `application/providers.dart`, `composition.dart`, `testing.dart` (fakes), `church_client_core.dart` (exports), `test/content/content_events_test.dart`.
- `packages/design_system/lib/src/` -- `ChurchCard`, `SectionHeader`, `CardLabel`, `DetailTable`, `MenuRow`, `StatusLabel`, `RequestStateBanner`, `ChurchDialog`, `ChurchPageScaffold`, `StaffPageHeader`, `FocusRing`, `announce`; tokens `ChurchColors` (amber/warning tone for the sample banner).
- `apps/mobile/lib/app.dart` -- `mobileDestinations` (insert Give between Home and Calendar: entries 6 and 9 add Bible & Hymns and Sermons in their places), `_showsTopBar` (the Give root shows it). `apps/staff/lib/app.dart` -- `staffNavGroupsFor` Content group (add Giving, Admin only).

## Tasks & Acceptance

**Execution:**
- [x] `supabase/migrations/20261022011438_content_giving_methods.sql` (local `20261021235500` until applied) -- kind, `app.content_giving_methods` (type, sort order), `app.content_giving_revisions` (+ guard trigger, verification columns and checks), `app.content_giving_audit`, field validation, seven commands, gate, public and staff reads, erase part, privileges -- the server half of the wire contract.
- [x] `supabase/tests/content_giving_test.sql` (+ ledger updates in `command_foundation_test.sql`, fixture list in `cross_epic_contracts_test.sql`) -- every matrix row, the trigger and check, the gate in a simulated production, column-name scan for payer fields.
- [x] `tools/identity-e2e/content-giving.mjs` + `.test.mjs` -- the verify at the API (+44 7700 900510-900518).
- [x] client_core: `domain/content_giving.dart`, repository methods, `application/giving_controllers.dart`, `presentation/give_screens.dart` (mobile), `presentation/giving_staff_screens.dart` (staff), routes `ClientPaths.give` (`/give`), `giveMethod(id)` (`/give/methods/:methodId`), `contentGiving` (`/content/giving`), providers, fakes, exports; tests `test/content/content_giving_test.dart`.
- [x] `apps/mobile/lib/app.dart` (Give tab), `apps/staff/lib/app.dart` (Giving, Admin only); their tests.
- [x] `docs/runbooks/content.md` (Story 6.3 section), `production-promotion-content.md` (migration, `q3_giving` approval step), `contracts-and-owner-seams.md` (registry rows).

**Acceptance Criteria:**
- Given the local stack, when the E2E runs, then Admin A drafts SAMPLE mobile-money and bank methods, A's own verification is refused, Admin B verifies, A publishes and reorders them, anon reads every value in order, a changed account number is refused publication until B verifies it again while anon still reads the old number, Media, Pastor and a plain member are refused every giving command, an amount or payer key is rejected, and anon sees no draft, verifier or test note.
- Given `flutter test`, when run, then a signed-out phone has the tabs Home, Give, Calendar, opens How to give, a method's detail copies each value to the clipboard and shows steps, the beneficiary check, the verified date, the contact and the sample banner when `sample` is true; staff web shows Giving only to Admin, where an Admin cannot verify their own save and sees why.

## Implementation Notes

- Split of the work (as in entry 1): the server tasks (migration, pgTAP and ledgers, E2E) and the
  runbooks are done in the main session; the implementation agent does the client tasks
  (client_core, mobile, staff and their tests) from the wire contract in Design Notes, against
  fakes. The implementation agent does not commit and does not touch `supabase/`, `tools/` or
  `docs/`; the main session reviews and commits.
- Windows workspace rules for the client work: `dart format` only the files you changed (never a
  whole package: in `packages/client_core` it rewrites unrelated files); run `flutter analyze` and
  `flutter test` in `packages/design_system`, `packages/client_core`, `apps/mobile` and
  `apps/staff`. Shared files (`shell_routing.dart`, `church_client_core.dart`, `providers.dart`,
  `testing.dart`, `apps/mobile/lib/app.dart`, `apps/staff/lib/app.dart`) get small additive edits
  only: other agents edit them in parallel (entries 2 and 13).
- Screens follow `docs/design-handoff/README.md` member screen 7 (Give) and the screenshots
  `docs/design-handoff/screenshots/app-12-give.png` and `app-13-give-instructions.png`, plus
  `app-screens.md`. Mobile Give, list: title "How to give", the explainer ("Choose a method and
  follow the steps. You give through your provider; the app doesn't process or record gifts."),
  one row per method (name; purpose and currency joined by " · "), and below it the contact when
  every listed method shares one. Detail (pushed, back title "How to give"): name, purpose ·
  currency, the amber sample banner when `sample` ("Sample details for testing. The church must
  supply and verify its own."), a card of copyable rows (label, value, a Copy button per value
  that puts exactly the value on the clipboard and announces "<label> copied"), the starting
  code row for mobile money ("Starting code", copyable; no dialler button in this entry), the
  numbered Steps, the note, a "Before you confirm" card (mobile money and bank: check that your
  provider shows <beneficiary> before you confirm, and stop and contact the church if it does
  not; other: give only through the church's own channels), then "Details checked by the church
  on <d MMM yyyy>" and "Questions? <contact>". Honest states: loading, failed with Try again,
  empty ("The church hasn't published any giving methods yet."), a method that is gone ("This
  giving method is no longer listed."), a failed refresh keeps the last good answer with a
  notice. No amount, success state or "record my gift" anywhere.
- Staff Giving (`/content/giving`, Content group, Admin only, `ChurchPageScaffold` header with
  New method and Reload): methods in order with their state label, Move up and Move down buttons
  (accessible names), and per method Edit, Verify, Publish, Hide, Archive as its state allows.
  The editor form shows only the method type's fields (type chosen once on New method: Mobile
  money, Bank, Other), steps as an ordered list (add, remove, reorder) and keeps input on a
  failed save. Verify is a dialog (Tested on date, How it was tested) and is disabled with the
  reason "You saved these details, so a different Admin must verify them." when the draft's
  `saved_by_you` is true. Every refusal code in Design Notes has a plain message. Show who
  saved, verified and published each revision and when (church time).
- Server built in the main session, clients by the implementation agent (as planned). Plan to code:
  as designed, plus the review changes below (strict savers rule, no-op refusal, changed-field
  audit, `content.discard_giving_draft`, `tested_on: before_saved`). Nothing shared was replaced:
  the kind, eight commands and the erase part are registry rows; the giving-only audit actions are
  in Content's own `app.content_giving_audit`.
- Migration `supabase/migrations/20261022011438_content_giving_methods.sql` (staging's version; the
  local file was `20261021235500` until applied). pgTAP `supabase/tests/content_giving_test.sql`
  (171, including the gate in a simulated production with `private_access` approved inside a
  rolled-back block). Ledgers: `command_foundation_test.sql` (anon and authenticated EXECUTE),
  `cross_epic_contracts_test.sql` (fixture gates: + `q3_giving`), `content_events_test.sql` (its
  registry and privilege assertions now scoped to events, so each kind pins its own; one added
  line per list).
- E2E `tools/identity-e2e/content-giving.mjs` (12/12, `evidence-6.3/content-giving-e2e.jsonl`) and
  `content-giving.test.mjs` (7), block +44 7700 900510-900516 of the assigned 900510-900518.
- Clients: `domain/content_giving.dart`, `adapters/supabase_giving_repository.dart` (its own
  `GivingRepository`, provider and composition override), `application/giving_controllers.dart`,
  `presentation/give_screens.dart` (mobile `/give`, `/give/methods/:methodId`),
  `presentation/giving_staff_screens.dart` (`/content/giving`); mobile tabs Home, Give, Calendar;
  staff **Giving** in the Content group for Admins. Shared-file edits are additive.
- Staging: applied verbatim through the connector as `20261022011438`; the 37 giving function
  hashes, the giving tables' constraint and column hashes match the fresh local reset; guards 0
  (`evidence-6.3/staging-verify.md`).
- Owner question (new): Identity lets one Admin approve a member and grant Admin alone, so one
  person could hold two Admin identities and verify their own destination. A two-person rule for
  granting Admin (an Identity change), a minimum time as Admin before verifying, or showing "Admin
  since, granted by" in the Verify dialog would close it.

## Plan Change Log

### 2026-10-22 — External check, first pass (finding 1, high)
- Trigger: the agent decision in the intent ("the verifier must not be the Admin who last saved the
  revision ... two Admins never deadlock") let the Admin who changed a destination verify it after
  any other Admin saved the draft, even with no change. That contradicts the owner decision the
  intent quotes first ("verified by a different Admin"), which prevails; the intent-contract text
  is left as written and superseded by this entry.
- Amended (outside the intent-contract): the verifier must not be any Admin, member or account, who
  saved the revision (`saved_by_members`, `saved_by_accounts`, also in the trigger); a save that
  changes nothing is refused (`method_id: unchanged`); each save audits its changed field names;
  `content.discard_giving_draft` (a method with a live revision) lets two Admins who both saved a
  draft start afresh, a never-published draft is archived; `tested_on` is not before the day the
  draft was last saved (`tested_on: before_saved`, finding 3).
- KEEP: per-revision verification, the check that nothing published is unverified, the published
  revision's immutability, order outside revisions, the q3 gate and its SAMPLE fixture.

## Review Triage Log

### 2026-10-22 — Review pass (independent reviewer: the entry's external check, which also covered the quick lens's acceptance criteria, rules and bugs)
- verdicts: 7 findings — high 1, medium 2, low 4, false 0, maybe-false 0
- findings:
  - `[high]` `[patch]` The Admin who changed a destination could verify it after another Admin's save (even a no-op) — every saver of a revision is now barred from verifying (command and trigger), no-op saves are refused, changed fields audited, discard added; pgTAP and E2E G13 cover the exact scenario.
  - `[medium]` `[defer]` One person can hold two Admin identities (Identity lets one Admin grant Admin) — an Identity rule; a Content check on "granted by" would block the normal first-grants-second case; residual risk in content.md and an owner question.
  - `[medium]` `[patch]` The tested date could predate the save it vouches for — `tested_on: before_saved`; pgTAP and E2E G11.
  - `[low]` `[patch]` One direct UPDATE could add a verification together with a content or saver change — the trigger refuses it; two pgTAP cases.
  - `[low]` `[patch]` Mobile "Copied" could outlive the copied value — keyed by value and publication revision; widget test.
  - `[low]` `[patch]` The test note invited transaction data — helper text "Don't include phone numbers, amounts or transaction IDs"; examples changed.
  - `[low]` `[patch]` Promotion runbook, doc wording (hidden method with a draft) and staging evidence missing — written.
- External check verdict: FAIL on the first pass; PASS on the second (`evidence-6.3/external-check.md`), with two informational notes deferred (owner-role two-statement write; the Admins' read names only the last saver).

## Design Notes

Wire contract (SQL, Dart and the E2E share it):
- Commands, expected = the method's `revision` (create: null). `content.create_giving_method {method_type, ...F}`; `content.save_giving_method {method_id, ...F}`; `content.verify_giving_method {method_id, tested_on, test_method}`; `content.publish_giving_method`, `content.hide_giving_method`, `content.archive_giving_method {method_id}`; `content.move_giving_method {method_id, position}` (1-based among non-archived). Success `data` = `{method_id, revision, state, live_revision_no, draft_revision_no}`.
- F (every save carries all of its type's keys; absent optional = null): all types `name` (req, 60), `purpose` (60), `currency` (`^[A-Z]{3}$`), `steps` (req, 1-12 single-line items of 200), `note` (200), `contact` (req, 160). `mobile_money` adds `beneficiary` (req, 120), `identifier_kind` (req `merchant|till|phone`), `identifier` (req, 1-40 of letters, digits, spaces, hyphens, optional leading +), `ussd_code` (`^[*][0-9*]{1,20}#$`). `bank` adds `bank_name` (req, 80), `beneficiary` (req, 120), `account_number` (req, 4-34 of letters, digits, spaces, hyphens), `branch` (80), `branch_code` (20), `swift_code` (`^[A-Z]{6}[A-Z0-9]{2}([A-Z0-9]{3})?$`), `reference` (120). `other` adds nothing. Another type's key is `unknown_field`.
- Field codes: `required|invalid|too_long|unknown_field`; `steps: too_many`; `tested_on: required|invalid|out_of_range` (`YYYY-MM-DD`, church today back 90 days); `test_method` (req, 500, multiline); `position: required|invalid|out_of_range`; `method_id: nothing_to_verify|already_verified|saved_by_you|not_verified|nothing_to_publish|not_published|archived`; `name: sample_only`; closed gate `unavailable {policy: gate_closed}`.
- `api.content_public_giving_methods()` -> `{sample, methods: [P], truncated}` (at most 50, order); `api.content_public_giving_method(method_id)` -> `{sample, method: P|null}`. P = `{method_id, method_type, name, purpose, currency, details: [{key, value}], ussd_code, steps, note, contact, verified_on, publication_revision, published_at}`; `details` in order: mobile money `beneficiary`, then `merchant_id|till_number|phone_number`; bank `bank_name, beneficiary, account_number, branch, branch_code, swift_code, reference` (present ones); other `[]`.
- `api.content_staff_giving_methods()` -> `{capacity, methods: [S], truncated}`; S = `{method_id, method_type, position, revision, state, created_at, created_by, updated_at, published_at, published_by, withdrawn_at, archived_at, live: R|null, draft: R|null}` (non-archived by position, then archived; `position` null when archived); R = every F key of the type plus `{revision_no, saved_at, saved_by, saved_by_you, published_at, published_by, verification: {verified_at, verified_by, verified_by_you, tested_on, test_method}|null}`.
- Staff states shown: Draft, needs verifying / Verified, ready to publish / Live / Live, changes need verifying / Live, changes ready to publish / Hidden / Archived.

## Auto Run Result

- **Summary:** Admin-only, instruction-only giving methods (mobile money, bank, other) on the 6.1
  publication lifecycle through its registries; per-revision church verification by an Admin who
  saved none of the revision (owner decision 2026-10-21), held in the commands, a check and a
  trigger; discard draft; the `q3_giving` gate (closed in production, SAMPLE-only fixture); order
  outside revisions; anonymous reads of the live giver-facing fields and the verified date only;
  the Admins' read; the giving erase part. No amount, payer or transaction field anywhere. Mobile
  Give tab (How to give, copyable values, steps, beneficiary check, verified date, contact, sample
  banner); staff web Giving for Admins.
- **Files:** migration `20261022011438_content_giving_methods.sql`; pgTAP `content_giving_test.sql`
  and three ledger updates; E2E `content-giving.mjs` + `.test.mjs`; client_core domain, adapter,
  controllers, `give_screens.dart`, `giving_staff_screens.dart`, routes, providers, composition,
  fakes, exports, tests; `apps/mobile/lib/app.dart` (Give tab), `apps/staff/lib/app.dart`
  (Giving); runbooks `content.md`, `production-promotion-content.md`,
  `contracts-and-owner-seams.md`; evidence `evidence-6.3/`.
- **Review:** 7 findings: 6 patched (1 high, 1 medium, 4 low), 1 deferred (medium, Identity-level,
  owner question), none rejected; 2 informational notes deferred from the second pass.
- **Follow-up review recommended:** true — a high was patched on the first pass (the second pass
  of the same reviewer closed it).
- **Verification:** full pgTAP PASS (59 files, 4661) on a fresh reset; E2E 12/12; Flutter
  design_system 14, client_core 807, mobile 63, staff 51, analyze clean; check-migrations and
  scan-secrets pass; staging `20261022011438` with function, constraint and column hashes identical
  to the local reset and guards 0.
- **Residual risks:** the owner's two-Admin walkthrough on staging with a signed-out phone is not
  done (`content.md`, Story 6.3, "Owner manual check"); real methods and the `q3_giving` approval
  are Q3; the two-Admin-identities risk above.

## Verification

**Commands:**
- `npx supabase db reset --local && npx supabase test db` (under the shared DB lock) -- expected: all files pass
- `select count(*) from app.contract_boundary_violations()` and `app.contract_unowned_objects()` -- expected: 0
- `node tools/identity-e2e/content-giving.mjs --evidence <file>` and `node --test tools/identity-e2e/content-giving.test.mjs` -- expected: all checks pass
- `flutter analyze && flutter test` in `packages/design_system`, `packages/client_core`, `apps/mobile`, `apps/staff` -- expected: clean, pass
- `node tools/ci/check-migrations.mjs --base origin/main` and `npm run -s ci:secrets` -- expected: pass

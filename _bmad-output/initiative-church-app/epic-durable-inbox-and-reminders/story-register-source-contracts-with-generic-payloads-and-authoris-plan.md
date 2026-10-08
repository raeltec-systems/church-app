---
title: 'Register source contracts with generic payloads and authorised deep links'
type: 'feature'
ticket: '2'
created: '2026-10-08'
status: 'built'
baseline_revision: '18f0ea955e406e89e72e30b89ce882ee32e2ef19'
route: 'full'
route_source: 'auto'
review: ''
review_source: ''
lenses_ran: []
review_loop_iteration: 0
context:
  - '{project-root}/docs/runbooks/contracts-and-owner-seams.md'
  - '{project-root}/docs/runbooks/notifications.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** After 3.1 a source owner registers only a source type, a `(source_ref) -> {current, revision}` hook and bare reminder kinds. Nothing says what an item may show, where it leads, or whether the recipient may still act on it, so an opened item cannot explain a superseded, cancelled or revoked source (N2, AD-5, AD-8).

**Approach:** Add a platform **reminder contract** per (source_type, reminder_kind), registered in the owner's migration with `app.contract_register_reminder_contract(module, source_type, kind, check regprocedure, text jsonb)`: a recipient-aware check hook `(notification_key) -> {current, revision, actionable, recipient_eligible}` (strict result), fixed generic `title`/`body` and a deep-link `link` template. Enqueue refuses a source type or kind without a contract; the worker rechecks through it; `api.notifications_open_item(item_id)` re-reads it and answers either `current` with the authorised target or the generic `superseded` state. SYNTHETIC adapters on `fixture_reminder` cover current, stale revision, cancelled, revoked scope and expired; both clients open items at `/inbox/:itemId`; a consumer guide documents it.

## Boundaries & Constraints

**Always:** text is fixed (no placeholders), length-bounded, and refused when it carries `{`, `}`, `@`, `http` or a run of 7+ digits; `link` is a relative path of lower-case segments with at most one whole `{source_id}` segment, no scheme, host or query; unknown keys in the text object or in a hook result are refused (PCTR1), so an owner cannot pass private fields through; the open answer carries no source id, revision or source content unless `current`, and then only the resolved target; the caller sees only their own items (another member's or unknown id answers `{"state": "not_found"}`); new `app` objects carry `contract_`/`notifications_`/`fixture_` prefixes, pin `search_path = ''`, revoke PUBLIC/anon/service_role; migration ASCII, non-destructive, no row deletions, version after `20261008073631`.

**Never:** leases, attempts, retries, expiry policy or Cron (entry 4); scheduling or snooze (entry 3); routing of held/accountless recipients, tokens, push (entries 5-6); a new wire contract kind or version; applying to staging.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Register | valid contract in owner migration | row stored; re-registration by the owner replaces it | other module / unknown kind / bad hook / private-looking text / unknown key / bad link: PCTR1 |
| Enqueue unregistered | unknown source_type, or kind with no contract | nothing written | `validation_failed {"source_type"|"reminder_kind": "unregistered"}` |
| Enqueue with private field | key carrying `body`/`phone` | nothing written | `validation_failed {"<key>": "unknown_field"}` |
| Open current | own item, source current, actionable, eligible | `state: current`, generic title/body, `target` | — |
| Open stale / cancelled / revoked / expired | source revised, cancelled, scope revoked, or past expiry | `state: superseded`, title/body only, `target: null` | — |
| Open foreign / unknown | B opens A's item | `{"state": "not_found"}` | signed out: no EXECUTE |
| Hook misbehaves | result with extra key or wrong types | nothing returned | raised PCTR1 (500, content-free) |
| Worker | due job, contract says not actionable / not eligible | `obsolete` / `ineligible`, no item | — |

Decision (agent, under owner pre-approval): the template and target fit contract v1. Registration is server-side SQL, the hook input is the v1 `notification_key`, and the open answer is a Notifications read projection, not a shared wire kind, so no version change (contracts-and-owner-seams.md rules). New `notification_key`/`source_ref` fixture cases with private fields (`unknown_field`) prove the refusal in SQL, Dart and TypeScript.
Decision (agent, under owner pre-approval): every negative outcome is one generic `superseded` state with no reason, so revocation or cancellation discloses nothing; the client offers the target only for routes it knows, otherwise "opens in a later version".
Decision (agent, under owner pre-approval): SYNTHETIC adapters are a `fixture.reminder_change {source_id, change: revise|revoke|expire}` command plus the existing cancel; `revise` bumps the revision, cancels old pending jobs and enqueues at the new revision; `revoke`/`expire` keep the revision and cancel pending jobs. `fixture.reminder_create` accepts an optional `reminder_kind` so the API can show an unregistered kind refused.

</frozen-after-approval>

## Code Map

- `supabase/migrations/20261003134340_cross_epic_contracts.sql` -- `contract_validate_handler` (reuse for hook checks, returns jsonb), `contract_require_source_owner`, `contract_check_source` (dynamic-execute pattern to mirror), `contract_reminder_key`, `contract_token_error`, `contract_registration_fail`. Do not edit.
- `supabase/migrations/20261008073631_notifications_inbox.sql` -- `notifications_enqueue`, `notifications_sys_deliver_due`, `notifications_my_inbox`, fixture source/commands/authorizer/dispatch: replace with `create or replace` in the new migration.
- `supabase/tests/notifications_inbox_test.sql` -- helpers (`pg_temp.cmd`, `sys`, sessions); pins that may need updating.
- `packages/contracts/fixtures/v1/{notification_key,source_ref}.json`, `packages/contracts/dart/tool/embed_fixtures.dart`, `packages/contracts/ts` -- fixture parity.
- `packages/client_core/lib/src/{domain/inbox.dart,adapters/supabase_inbox_repository.dart,application/inbox_controllers.dart,presentation/inbox_screen.dart,presentation/shell_routing.dart}`, `lib/testing.dart` (`FakeInbox`, `inboxItemData`), `test/notifications/inbox_test.dart`.
- `tools/identity-e2e/inbox.mjs` -- E2E pattern (local credential minting, cleanup).

## Tasks & Acceptance

**Execution:**
- [x] `supabase/migrations/<ts>_notifications_source_contracts.sql` -- registry table + register function + `contract_check_reminder`; enqueue/worker/inbox-read updates; `notifications_open_item` + api wrapper; fixture columns, open check, `reminder_change`, contract registration; grants.
- [x] `supabase/tests/notifications_source_contracts_test.sql` -- matrix, registration refusals, privileges, guards.
- [x] `packages/contracts/fixtures/v1/*.json` + Dart embed regen -- private-field cases.
- [x] `tools/identity-e2e/source-contracts.mjs` + `.test.mjs` -- HTTP E2E over the five adapters.
- [x] `packages/client_core` -- `InboxItem` title/body from server, `InboxOpened` + `openItem`, controller, `InboxItemScreen`, route `/inbox/:itemId`, tile tap, fakes + tests.
- [x] `docs/runbooks/contracts-and-owner-seams.md`, `notifications.md` -- consumer guide and staging steps; `.github/workflows/ci.yml` if new tests need wiring.

**Acceptance Criteria:**
- Given a reset local stack, when db:test, db:smoke, every identity E2E, the new E2E, contracts tests, tool tests and flutter analyze/test run, then all pass.
- Given the guards, when pgTAP runs, then no unowned, unpinned or boundary-violating objects exist.

## Implementation Notes

- Implemented directly (no subagent tool in this run). Files: migration `supabase/migrations/20261008074412_notifications_source_contracts.sql`; pgTAP `supabase/tests/notifications_source_contracts_test.sql` (60); pins updated in `command_foundation_test.sql` (new authenticated function) and `notifications_inbox_test.sql` (inbox item keys now include title/body; the flaky source registers a reminder contract); fixtures `notification_key.json` (+2), `source_ref.json` (+1) and regenerated `packages/contracts/dart/test/fixtures.g.dart`; E2E `tools/identity-e2e/source-contracts.mjs` (+ test); live adapter check extended (L9/L10); client_core `domain/inbox.dart` (`OpenedInboxItem`, `InboxItemState`, `isInAppPath`, registered title/body), adapter `openItem`, `InboxItemController` (autoDispose family), `InboxItemScreen`, route `/inbox/:itemId`, `ClientPaths.inboxItem`/`deepLinkTargets`, tappable tiles, `FakeInbox.opened`, `openedItemData`, `test/notifications/inbox_item_test.dart`; runbooks `contracts-and-owner-seams.md` (consumer guide) and `notifications.md` (3.2 section, staging steps); evidence `evidence-3.2/`; CI evidence scan step.
- Surprise: plpgsql reads an `IF` condition up to the first `THEN`, so a `CASE ... THEN` inside it broke the migration; the length bound moved to a variable.
- The worker now rechecks through the reminder contract (small `create or replace`); entry 4 still owns leases, attempts and retry policy.
- Apps were not changed: the item screen comes from the shared router. On `/inbox/<id>` no navigation destination is highlighted (apps compare `location == path`); entry 7 can refine that with the inbox screens.
- `ClientPaths.deepLinkTargets` is empty, so a current fixture item shows "Still current" with no Open button; the Open path is proven with an injected matcher in the widget test.
- Matrix audit: register/refusals, enqueue unregistered/private field, open current/stale/cancelled/revoked/expired, foreign/unknown/signed out, malformed hook answers, worker obsolete/ineligible are in pgTAP; unregistered kind, private field, the five adapters, generic superseded and foreign/signed-out open in `source-contracts.mjs`; real adapters open current/not_found in the live check; client mapping and states in `inbox_item_test.dart`.
- Owner/staging steps remaining (not blocking `built`): parent applies the migration to staging and runs `verify-hosted.sql`; owner runs the demonstration in `notifications.md` (Story 3.2, Hosted staging step 2).

- Review fixes (coordinator, independent review of 3.2): `notifications_open_item` runs the owner check in a subtransaction and answers a fixed `PT503 source_check_failed` (SQLSTATE-only log), and the PCTR1 messages name no hook; the generic-text check requires printable ASCII, treats any short non-alphanumeric run as a digit separator and refuses domain shapes; the worker ends a job whose kind has no reminder contract `obsolete` at once; `fixture.reminder_change` has production and non-SYNTHETIC refusal tests; the item screen has its own failure title. pgTAP now 80 assertions.

## Plan Change Log

## Review Triage Log

## Verification

**Commands:**
- `npx supabase db reset && npm run -s db:test && npm run -s db:smoke` -- expected: pass
- `node tools/identity-e2e/source-contracts.mjs --evidence <file>` and every other identity E2E -- expected: pass
- `npm run -s contracts:test`; `dart test` in `packages/contracts/dart` -- expected: pass
- `flutter analyze && flutter test` in `packages/client_core`, `apps/mobile`, `apps/staff` -- expected: clean
- `npm run -s ci:secrets && npm run -s ci:migrations` -- expected: pass

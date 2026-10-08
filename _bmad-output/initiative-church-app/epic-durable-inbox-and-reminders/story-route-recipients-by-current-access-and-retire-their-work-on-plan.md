---
title: 'Route recipients by current access and retire their work on lifecycle events'
type: 'feature'
ticket: '5'
created: '2026-10-08'
status: 'built'
baseline_revision: 'e1369683da6bdecb16b6f38d6325594e60e98aef'
route: 'full'
route_source: 'auto'
review: ''
review_source: ''
lenses_ran: []
review_loop_iteration: 0
context:
  - '{project-root}/docs/runbooks/notifications.md'
  - '{project-root}/docs/runbooks/contracts-and-owner-seams.md'
  - '{project-root}/docs/runbooks/identity-access.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** The worker delivers an inbox item to any approved member and ends every other recipient `ineligible`, so a held, deactivated or accountless member's reminder need is silently lost; there are no device tokens, push settings or member-push work, and Identity's lifecycle events and deletion workflow do not touch Notifications' personal data (N5, AD-3, AD-8, AD-14).

**Approach:** Route each due job at the attempt through current Identity state: an active linked account (approved member, live link whose account standing is `ok`) gets the inbox item and, when push is allowed for that account and category and it has a live token, one pending member-push job; an approved member who is held, in review or accountless, or a deactivated member, gets no item and no push job, and a direct-contact need is recorded and handed to the route the source owner registers with its reminder contract. Add per-account device tokens and push settings by category (1.4 commands plus a read), lifecycle hooks that retire tokens and cancel member-push jobs, and a deletion hook (row deletions in a separate `_rows` migration).

## Boundaries & Constraints

**Always:** routing reads Identity without locks (AD-2 order); a relative's or household contact route is never a destination: needs carry only the notification key and a need id; job states keep their 3.1 CHECK (routed jobs end `ineligible`, finish reason `direct_contact` or `no_direct_contact_route`); every need is recorded in Notifications even without a registered route; tokens are never returned by any read or answer; lifecycle hooks never raise on missing rows and run in Identity's transaction; the deletion hook covers jobs, attempts, inbox items, schedules, needs, push jobs, tokens and settings, and the fixture hook covers `fixture_reminder_sources` and the fixture needs; main migration has no `delete from` (fail-closed stubs answering `unavailable`), deletions live only in a small `_rows` file; new objects prefixed, `search_path = ''`, no anon grants, ASCII, versions after `20261008121248`; no edit of hand-pasted functions.

**Never:** FCM sending, client token registration or push-tap handling (entry 6); settings, inbox or snooze screens (entry 7); health view (entry 8); group mutes; quiet hours; widening `job_state`; applying to staging or deploying functions.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Active linked | due job, standing ok, token, push on | one item, one pending push job | push off or no token: item only |
| Held / review | open hold or link in review | no item, no push job; need `routed`, owner hook called | hook raises: transient `failed`, retried |
| Deactivated | membership deactivated | as held | — |
| Accountless | approved, no live link | as held | no route registered: need `unrouted`, `no_direct_contact_route` |
| Relative's contact | accountless member with a relative's route; relative is an active member | nothing for the relative | — |
| Deleted / pending / rejected | tombstone or never approved | `ineligible` (`member_deleted` / `membership_inactive`), no need | enqueue for a tombstone refused |
| Lifecycle | `sessions_revoked`, `access_hold_applied`, `membership_deactivated`, `account_deactivated`, `deletion_requested` | member's tokens retired, pending push jobs cancelled (reason = event); deletion also cancels pending jobs and ends schedules | — |
| Deletion hook | erase then check | `remaining` 0 | `_rows` missing: `unavailable` |
| Device / settings | register, retire, set category | own rows only, revisioned | foreign id `not_found`; unknown category `unregistered`; not granted `forbidden` |

Decision (agent, under owner pre-approval): routed jobs keep job state `ineligible` with a new finish reason, so the Edge worker's outcome list, `deliver_due`'s five counts and the 3.1 CHECK stay unchanged (no redeploy needed).
Decision (agent, under owner pre-approval): the direct-contact route is registered per reminder contract with `app.contract_register_direct_contact_route(module, source_type, kind, handler)`; the handler is `(jsonb) returns void`, gets `{need_id}` plus the notification key and nothing else (no reason, so a hold is not disclosed), must be idempotent on `need_id` and must not lock the source aggregate.
Decision (agent, under owner pre-approval): push settings are per account and category (source type + reminder kind with a registered contract), default on; `notifications.set_push_category` creates with expected revision null and updates with the setting's revision. Tokens belong to one account (re-registering a token on another account retires the old row), at most 10 live per account.
Decision (agent, under owner pre-approval): the SYNTHETIC fixture gains an Admin-only `fixture.reminder_create_for {member_id, due_at}` (local/staging, SYNTHETIC members) so the API can enqueue for held, deactivated and accountless members, a direct-contact route recording into `fixture_reminder_contact_needs`, and its deletion hook becomes permanently registered (tests that registered it now tolerate that).

</frozen-after-approval>

## Code Map

- `supabase/migrations/20261008121248_notifications_worker.sql` -- `app.notifications_attempt` (replace in place: routing after the contract and schedule rechecks), `notifications_finish_job`, `notifications_job_expiry`.
- `supabase/migrations/20261008102121_notifications_scheduling.sql` -- `notifications_enqueue_job` (replace: refuse a deletion tombstone), schedules FKs (`jobs.schedule_id`, `jobs.snoozed_from_item_id`).
- `supabase/migrations/20261008090057_notifications_source_contracts.sql` -- `contract_reminder_contracts`, `contract_check_reminder` dynamic-call pattern, fixture authorizer/command (replace).
- `supabase/migrations/20261006234820_identity_grants.sql` -- `identity_account_standing(auth_user_id)` (ok / review_required / not_linked), `identity_evaluate_grant`.
- `supabase/migrations/20261007174952_member_deletion.sql` + `_rows` -- deletion hook contract, `cells_erase_member` + stub pattern, `fixture_erase_member` (replace), `identity_deletions`.
- `supabase/migrations/20261003134340_cross_epic_contracts.sql` -- `contract_register_lifecycle_hook`, `contract_validate_handler`, `contract_require_source_owner`; one hook per (event, module).
- Tests that register the same slots: `cross_epic_contracts_test.sql` (notifications/access_hold_applied), `member_deletion_test.sql` and `tools/identity-e2e/deletion.mjs` (fixture deletion hook); worker test expects `membership_inactive` for a deactivated member (now `direct_contact`).

## Tasks & Acceptance

**Execution:**
- [x] `supabase/migrations/<ts>_notifications_routing.sql` -- route registry + register fn; needs, tokens, settings, push jobs; routing fn; attempt and enqueue replacement; lifecycle + deletion hooks and stubs; device/settings commands, authorizer, read; fixture route, `reminder_create_for`, erase extension, registrations; privileges.
- [x] `supabase/migrations/<ts+>_notifications_routing_rows.sql` -- the purge bodies only.
- [x] `supabase/tests/notifications_routing_test.sql` + pin updates in existing tests -- the matrix, privileges, guards.
- [x] `tools/identity-e2e/routing.mjs` + `.test.mjs`, `deletion.mjs` adjustment, e2e list -- API E2E of the verify line.
- [x] `docs/runbooks/notifications.md`, `contracts-and-owner-seams.md`, `identity-access.md` (hook list) -- routing, consumer guide, owner `_rows` step.

**Acceptance Criteria:**
- Given a reset local stack, when db:test, db:smoke, every E2E, contracts and tool tests, scan-secrets and check-migrations run, then all pass.
- Given a member deletion run through Identity's hooks, when the `check` phase runs, then Notifications and the fixture answer `remaining: 0`.

## Implementation Notes

- Implemented directly (no subagent tool in this run). Files: migrations `supabase/migrations/20261008143000_notifications_routing.sql` (no `delete from`; stubs `app.notifications_deletion_purge_rows(uuid, uuid)` and `app.fixture_deletion_purge_rows(uuid)` answer `unavailable`) and `supabase/migrations/20261008143100_notifications_routing_rows.sql` (the two bodies only); pgTAP `supabase/tests/notifications_routing_test.sql` (105); E2E `tools/identity-e2e/routing.mjs` (+ test, 18 checks); runbooks `notifications.md` (Story 3.5 section, earlier limits updated), `contracts-and-owner-seams.md` (direct-contact route guide, deletion hooks), `identity-access.md` (hook lists); CI evidence scan step; evidence `evidence-3.5/`.
- Pins updated in existing tests: `command_foundation_test.sql` (authenticated may execute `api/app.notifications_command` and `notifications_my_push_settings`), `notifications_scheduling_test.sql` (member 1 gets an account so the snooze case still has an item; client-executable allowlist), `notifications_worker_test.sql` (a deactivated recipient now ends `direct_contact`, not `membership_inactive`), `cross_epic_contracts_test.sql` (removes Notifications' real hooks inside the test before registering its synthetic ones), `member_deletion_test.sql` and `tools/identity-e2e/deletion.mjs` (the fixture deletion hook is registered by migration and stays registered).
- Routing uses `app.identity_account_standing(auth_user_id)` (the predicate's account half): `ok` = member route; anything else with a live link = direct contact. Dormancy is not part of routing (documented).
- Postgres regex repetition bounds stop at 255, so the token shape is a character class plus a length check (found by the first pgTAP run).
- Deletion: `deletion_requested` also cancels the member's pending jobs and ends schedules, and enqueue refuses a tombstone, so a completed deletion cannot be refilled; the hook's `erase` nulls snooze links (an update) before the purge.
- Matrix audit (all ran and passed): active linked with token and push on/off and without token, held (real hold command), link in review, deactivated (real command), accountless, relative's contact (relative is an active member with a device), no route (`unrouted`), raising route (transient, retried), deleted (`member_deleted`), never approved (`membership_inactive`), the five lifecycle events (hold and deactivation and lost-device hold through real commands, others dispatched), deletion hook erase/check incl. cells and fixture, stub `unavailable`, device and settings commands incl. foreign `not_found`, unregistered category, held `forbidden`, stale revisions: `notifications_routing_test.sql`; the API path of the verify line (enqueue for four recipients, routing, relative, hold, lost-device sessions revoked, own deletion request, deletion check zero): `routing.mjs`.
- Owner/staging steps remaining (not blocking `built`): parent applies `20261008143000` and runs `verify-hosted.sql`; owner pastes `20261008143100_notifications_routing_rows.sql` in the staging SQL editor (until then staging deletions wait at `erase_owners`); owner demonstration (runbook `notifications.md`, Story 3.5, Hosted staging). No Edge Function redeploy needed.

## Plan Change Log

- 2026-10-08, independent review of 3.5 (coordinator; three mediums, three lows), patched in place in the unapplied migrations `20261008143000` / `20261008143100`:
  1. (medium) Lock order: `notifications_attempt` and `notifications_device_register` take `FOR KEY SHARE` on the member row before any Notifications lock; the `deletion_requested` hook cancels pending jobs `for update skip locked` (a skipped job is routed `member_deleted` by the attempt and erased by the deletion hook). Not testable in single-session pgTAP; documented in the runbook.
  2. (medium) Decision (agent, under owner pre-approval; supersedes the frozen "enqueue for a tombstone refused"): enqueue for a member with a deletion request is skipped, not raised: `{job_id: null, job_state: null, created: false, refused: "member_deleted"}`, nothing written, so one deleted member never rolls back a multi-recipient source command. Guide, runbook, pgTAP and E2E R51 updated.
  3. (medium) `app.notifications_set_schedule` replaced in place (same signature and privileges): a member with a deletion request is skipped (`schedule_id: null, refused: "member_deleted"`); no schedule written or reactivated, even for a plan with no entries (pgTAP probe).
  4. (low) The fail-closed pgTAP case saves `pg_get_functiondef` of the installed purge, asserts it is the rows file's body, stubs it and restores it verbatim with `execute`.
  5. (low) `notifications.register_device` (null expected revision, may refresh an existing row) is a documented exception in `command-foundation.md`.
  6. (low) `scan-evidence.sh` now has FCM token (`...:APA91...`) and synthetic `fcm-` device-token patterns.
  pgTAP 100 -> 105.

## Review Triage Log

## Verification

**Commands:**
- `npx supabase db reset && npm run -s db:test && npm run -s db:smoke` -- expected: pass
- E2E loop (scratchpad `e2e-main.sh` with this worktree, plus `routing`) -- expected: every suite passes
- `npm run -s contracts:test && node --test tools/**/*.test.mjs supabase/functions/*/logic.test.mjs && npm run -s ci:secrets && npm run -s ci:migrations` -- expected: pass

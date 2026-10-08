---
title: 'Route recipients by current access and retire their work on lifecycle events'
type: 'feature'
ticket: '5'
created: '2026-10-08'
status: 'in-progress'
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
- [ ] `supabase/migrations/<ts>_notifications_routing.sql` -- route registry + register fn; needs, tokens, settings, push jobs; routing fn; attempt and enqueue replacement; lifecycle + deletion hooks and stubs; device/settings commands, authorizer, read; fixture route, `reminder_create_for`, erase extension, registrations; privileges.
- [ ] `supabase/migrations/<ts+>_notifications_routing_rows.sql` -- the purge bodies only.
- [ ] `supabase/tests/notifications_routing_test.sql` + pin updates in existing tests -- the matrix, privileges, guards.
- [ ] `tools/identity-e2e/routing.mjs` + `.test.mjs`, `deletion.mjs` adjustment, e2e list -- API E2E of the verify line.
- [ ] `docs/runbooks/notifications.md`, `contracts-and-owner-seams.md`, `identity-access.md` (hook list) -- routing, consumer guide, owner `_rows` step.

**Acceptance Criteria:**
- Given a reset local stack, when db:test, db:smoke, every E2E, contracts and tool tests, scan-secrets and check-migrations run, then all pass.
- Given a member deletion run through Identity's hooks, when the `check` phase runs, then Notifications and the fixture answer `remaining: 0`.

## Implementation Notes

## Plan Change Log

## Review Triage Log

## Verification

**Commands:**
- `npx supabase db reset && npm run -s db:test && npm run -s db:smoke` -- expected: pass
- E2E loop (scratchpad `e2e-main.sh` with this worktree, plus `routing`) -- expected: every suite passes
- `npm run -s contracts:test && node --test tools/**/*.test.mjs supabase/functions/*/logic.test.mjs && npm run -s ci:secrets && npm run -s ci:migrations` -- expected: pass

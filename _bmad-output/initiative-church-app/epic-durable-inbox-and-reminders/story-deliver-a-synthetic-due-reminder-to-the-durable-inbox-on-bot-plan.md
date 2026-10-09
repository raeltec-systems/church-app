---
title: 'Deliver a synthetic due reminder to the durable inbox on both clients'
type: 'feature'
ticket: '1'
created: '2026-10-08'
status: 'done'
baseline_revision: '04c8501d037ddcc56c965023589eb8889e46c7d8'
route: 'full'
route_source: 'auto'
review: ''
review_source: ''
lenses_ran: []
review_loop_iteration: 0
context:
  - '{project-root}/docs/runbooks/contracts-and-owner-seams.md'
  - '{project-root}/docs/runbooks/system-access-and-operations.md'
  - '{project-root}/docs/runbooks/command-foundation.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** No module owns reminder work yet: `app.contract_reminder_key` only validates a logical key, nothing persists a job or an inbox item, and neither client can show outstanding reminders. Every later reminder (duties, follow-ups, cells) needs this durable path first (AD-8, N1/N4/N6 tracer).

**Approach:** Add the Notifications owner tables (`notifications_jobs` with the AD-8 logical key, source revision and applied Q2 policy; `notifications_inbox_items`, one per job) and owner operations `app.notifications_enqueue` / `app.notifications_cancel` that run inside the caller's transaction; a SYNTHETIC `fixture_reminder` source whose 1.4-envelope commands enqueue and cancel; a worker step `notifications.deliver_due` on the bounded system route (new purpose `notifications_worker`) that turns due pending jobs into exactly one inbox item each; and `api.notifications_my_inbox()` behind the live-access predicate, shown as an **Inbox** destination on mobile and staff web.

## Boundaries & Constraints

**Always:** one job per logical key (`source_type, source_id, source_revision, recipient_member_id, reminder_kind, scheduled_at`) and one inbox item per job, enforced by unique indexes; enqueue validates through `app.contract_reminder_key` (registered kind, current source revision via the owner hook, Q2 gate open: fixture in local/staging, closed in production); jobs record `policy_source` and `policy_digest` (sha256 of the effective `q2_church_time` value); the worker rechecks the source through `app.contract_check_source` and the recipient's approved membership before writing an item; a cancelled, obsolete or future job never becomes an item; all `app` objects carry the `notifications_`/`fixture_` prefix, pin `search_path = ''`, revoke PUBLIC/anon/service_role; only `authenticated` executes the read and the fixture command; inbox read exposes no source id, revision or private text; protected client state stays in memory per account generation; migration is ASCII, non-destructive, no row deletions, version `20261008073631`.

**Never:** leases, fencing, attempts, retries, expiry, Cron or an Edge worker (entry 4); scheduling calculation (entry 3); source-contract text/deep links (entry 2); recipient routing for held/accountless members, device tokens, push, lifecycle or deletion hooks (entries 5-6); applying anything to staging or deploying functions; minting a non-local credential.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Create due reminder | granted SYNTHETIC member, `fixture.reminder_create {due_at: now}` | source rev 1 + one pending job in the same transaction | — |
| Replay create | same request_id and body | stored envelope, still one job | changed body: `conflict` |
| Worker run | due pending job | one inbox item, job `delivered`; second run delivers 0 | per-job error leaves job pending, counted `failed` |
| Concurrent/duplicate | two runs, or job re-enqueued | still one item (unique job_id; `skip locked`) | — |
| Cancel | `fixture.reminder_cancel` at current revision | source cancelled, pending jobs `cancelled`; worker writes nothing | stale revision: `conflict` |
| Stale source | pending job whose source revision moved | worker marks `obsolete`, no item | — |
| Future job | due_at later than now | stays pending | — |
| Another member / signed out | B reads inbox; anon calls read | B: empty list; anon: no EXECUTE (401/404) | — |
| Production marker | enqueue with Q2 unapproved | `unavailable {"policy":"gate_closed"}`, nothing written | — |
| Wrong principal | probe/identity credential calls `notifications.deliver_due` | `forbidden` | audited |

Decision (agent, under owner pre-approval): the synthetic source lives in the `fixture` module with a new allowed edge `fixture -> notifications` (precedent: 2.3 added `fixture -> identity`); its commands are self-only (recipient = caller's member), local/staging and SYNTHETIC members only, authorised by a registered `fixture` authorizer.
Decision (agent, under owner pre-approval): "policy version" is recorded as source + digest of the effective `q2_church_time` value until entry 3 introduces numbered policy versions.
Decision (agent, under owner pre-approval): until entry 5, the worker delivers only to an `approved` member; any other recipient state ends the job `ineligible` with no item (fail closed). No deletion hook yet: entry 5 registers it; recorded as a known gap in the runbook.
Decision (agent, under owner pre-approval): inbox items carry no text; clients show a generic label per reminder kind (entry 2 adds registered generic text and deep links).
Decision (agent, under owner pre-approval): the tracer worker is an operator-run Node script over the system route; entry 4 replaces it with the Cron-triggered Edge worker.

</frozen-after-approval>

## Code Map

- `supabase/migrations/20261003134340_cross_epic_contracts.sql` -- `contract_reminder_key` (reuse for validation), `contract_check_source`, `policy_effective`, registries `contract_register_source_type/_reminder_kind`, module edges. Do not edit.
- `supabase/migrations/20261007140729_assisted_recovery.sql` -- `app.sys_execute` registry: `sys_command_kinds(command, purpose, description, payload_check, handler)`; handler `(uuid principal, uuid request_id, jsonb)` -> `{data, revision?}`; payload check `(jsonb)` -> field errors.
- `supabase/migrations/20261006234820_identity_grants.sql` -- `cmd_register_authorizer`, fixture->identity edge precedent.
- `supabase/migrations/20261007075946_cell_membership.sql` -- command entry/api wrapper/authorizer/scope pattern; `identity_require_access`, `identity_evaluate_grant`, `identity_record_activity`.
- `supabase/tests/system_access_test.sql` -- pins the allowlist (must add the new command).
- `supabase/tests/member_deletion_test.sql` -- pgTAP helpers for sessions and `pg_temp.sys`.
- `tools/identity-e2e/harness.mjs`, `cells.mjs`, `deletion.mjs` -- local E2E pattern, local credential minting.
- `tools/identity-deletion/worker.mjs` -- `systemClient` pattern for the worker.
- `packages/client_core/lib/src/{domain,adapters,application,presentation}` -- `AccessRead`, `SupabaseApiReader`, generation-scoped controller (`MyMembershipStatusController`), `ClientPaths`, `buildClientRouter`; `testing.dart` fakes/harness; `composition.dart`.
- `apps/mobile/lib/app.dart`, `apps/staff/lib/app.dart` -- destinations shown when grants != null.

## Tasks & Acceptance

**Execution:**
- [x] `supabase/migrations/20261008073631_notifications_inbox.sql` -- tables, enqueue/cancel, worker handler + payload check + command kind, read, fixture source/commands/authorizer, registrations, grants.
- [x] `supabase/tests/notifications_inbox_test.sql` -- pgTAP for the whole matrix, privileges, guards; `supabase/tests/system_access_test.sql` -- allowlist row.
- [x] `tools/notifications/worker.mjs` + `worker.test.mjs` -- `run-once [--limit n]` over the system route, credential from env/file, content-free output.
- [x] `tools/identity-e2e/inbox.mjs` + `inbox.test.mjs` -- local HTTP E2E through real GoTrue, PostgREST and the worker script; full cleanup.
- [x] `packages/client_core` -- `domain/inbox.dart`, `adapters/supabase_inbox_repository.dart`, `application/inbox_controllers.dart`, `presentation/inbox_screen.dart`, route `/inbox`, provider, composition, fake + tests.
- [x] `apps/mobile/lib/app.dart`, `apps/staff/lib/app.dart` + tests -- Inbox destination when member access is granted.
- [x] `.github/workflows/ci.yml` -- worker tests and evidence scan.
- [x] `docs/runbooks/notifications.md` (new), `contracts-and-owner-seams.md`, `system-access-and-operations.md` -- owner API, worker credential and staging steps.

**Acceptance Criteria:**
- Given the local stack after `db reset`, when `db:test`, `db:smoke`, every identity E2E, `inbox.mjs`, contracts and tool tests, flutter analyze/test run, then all pass.
- Given a production-marked database, when a fixture reminder is created, then nothing is written and the answer is `forbidden` (no member access is served there yet); a direct `app.notifications_enqueue` there answers `unavailable {"policy":"gate_closed"}`.
- Given the boundary guards, when pgTAP runs, then no unowned objects, unpinned functions or boundary violations exist.

## Implementation Notes

- Implemented directly (no subagent tool in this run). Files: migration `supabase/migrations/20261008073631_notifications_inbox.sql`; pgTAP `supabase/tests/notifications_inbox_test.sql` (52); allowlist/privilege pins updated in `system_access_test.sql` and `command_foundation_test.sql`; worker `tools/notifications/worker.mjs` (+ test); E2E `tools/identity-e2e/inbox.mjs` (+ test); live adapter check `tools/identity-e2e/live-inbox-check.sh` + `packages/client_core/tool/live_inbox_check.dart`; client_core `domain/inbox.dart`, `adapters/supabase_inbox_repository.dart`, `application/inbox_controllers.dart`, `presentation/inbox_screen.dart`, route `/inbox`, provider, composition, `FakeInbox`; Inbox destination in both apps; CI node tests + evidence scan; runbooks `notifications.md` (new), `contracts-and-owner-seams.md`, `system-access-and-operations.md`.
- Surprise: registering the `fixture` command authorizer took over the whole `fixture.*` namespace, which the 1.4 kernel test uses (`fixture.broken` with per-actor fixture grants). The authorizer now keeps the 1.4 per-actor `fixture_command_grants` check for every other `fixture.*` command, so prior behaviour is unchanged.
- A non-SYNTHETIC member never reaches the fixture handler's SYNTHETIC check off production: the live-access predicate already refuses non-synthetic members while `private_access` is closed, so the command answers `forbidden` (pinned in pgTAP); the handler check stays as defence in depth.
- Worker reads the recipient's membership without a lock (AD-2 orders Identity before Notifications and the step already holds the job row); the source check hook does not lock the source either, so a cancellation committing after the recheck can still leave a delivered item (the AD-8 accepted race; entry 2 re-reads on open).
- Matrix audit: create/replay/conflict, worker once/twice, per-job failure, duplicate item and re-enqueue, cancel/stale cancel/foreign cancel, stale source, ineligible recipient, future job, other member/signed out, production gate and wrong principal are covered by pgTAP; create, replay, worker, racing workers, cancel, future, other member/unlinked/signed out by `inbox.mjs`; both clients' reads by `live-inbox-check.sh` and the Flutter tests.
- Review fixes (coordinator, independent review of 3.1): failing jobs now record `failed_attempts`/`last_failed_at`, log a content-free SQLSTATE and back off min(2^(n-1), 60) minutes, ordered by failures, so a poison job cannot starve later jobs (pgTAP proves a later job is delivered with limit 1); pgTAP covers the fixture command in production (`forbidden`, nothing written) and the handler's own SYNTHETIC check (private_access opened inside the test transaction); the inbox read has a keyset cursor (`next`, pages of 50) with **Show older reminders** on both clients; the runbook names every table that keeps member ids until the entry 5 deletion hook.
- Owner/staging steps remaining (not blocking `built`): apply the migration to staging and run `verify-hosted.sql` (parent session); the owner mints and registers the staging `notifications_worker` credential (runbook `notifications.md`, Hosted staging step 2) and runs the staging demonstration (step 3) on mobile and staff web.

## Plan Change Log

## Review Triage Log

## Verification

**Commands:**
- `npx supabase db reset && npm run -s db:test && npm run -s db:smoke` -- expected: all pass
- `node tools/identity-e2e/inbox.mjs --evidence <file>` -- expected: all checks pass, cleanup leaves nothing
- `node --test tools/notifications/*.test.mjs tools/identity-e2e/*.test.mjs` -- expected: pass
- `flutter analyze && flutter test` in `packages/client_core`, `apps/mobile`, `apps/staff` -- expected: clean
- `npm run -s ci:secrets && npm run -s ci:migrations && npm run -s contracts:test` -- expected: pass

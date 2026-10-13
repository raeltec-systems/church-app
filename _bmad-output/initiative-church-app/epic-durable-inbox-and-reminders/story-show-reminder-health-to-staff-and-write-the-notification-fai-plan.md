---
title: 'Show reminder health to staff and write the notification-failure runbook'
type: 'feature'
ticket: '8'
created: '2026-10-13'
status: 'built'
baseline_revision: 'b6e4d7328bb89859e7cfbe562c061e7885d2d1a1'
route: 'full'
route_source: 'auto'
review: 'quick'
review_source: 'pinned'
lenses_ran: [quick]
review_loop_iteration: 0
context:
  - '{project-root}/docs/runbooks/notifications.md'
  - '{project-root}/docs/runbooks/system-access-and-operations.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** Staff cannot see whether reminders are healthy or follow a consistent recovery procedure when notifications fail.

**Approach:** Add a content-free reminder health read and staff web view for Admin and the restricted operator: scheduler success, job age/delays, failed leases/attempts, retired tokens, and direct-contact backlog. Document notification recovery, including pausing and resuming through `outbound_sending`.

**Decision (user, 2026-10-13):** Add a nullable Auth-account mapping for restricted operators. Only the health read honors it; operator procedures remain client-inaccessible. The owner provisions the mapping per environment; no account is inferred or seeded.

## Boundaries & Constraints

**Always:** Return counts and timestamps only; never expose content, recipient details, tokens, or source payloads. Authorize a live Admin grant or specifically mapped operator server-side. Keep alerts disabled and use synthetic data for demonstrations.

**Never:** Send alerts, open gates, enable production scheduling/push, grant client access to existing operator functions, or edit hosted databases during local implementation.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Authorized read | Admin or mapped operator | Content-free scheduler, job, attempt, token, and direct-contact aggregates | Stale/unavailable shown without private fields |
| Unauthorized read | Other signed-in user | No health data | Server returns forbidden; hidden navigation is insufficient |
| Sending paused | `outbound_sending` closed | New push work stops; inbox reminders remain | Explain already accepted pushes cannot be recalled |

</frozen-after-approval>

## Code Map

- `supabase/migrations/20261008121248_notifications_worker.sql`, `20261008155801_notifications_push.sql` -- scheduler/attempt state and operator-only `app.notifications_scheduler_status()`; reuse its aggregates, but do not grant it to clients.
- `supabase/migrations/20261008135811_notifications_routing.sql` -- direct-contact needs; expose backlog counts only.
- `supabase/migrations/20261006234820_identity_grants.sql` -- live Admin check via `app.identity_require_grant('admin', null, null)`.
- `packages/client_core/lib/src/{domain,application,adapters,presentation}`; `apps/staff/lib/app.dart`, `packages/client_core/lib/src/presentation/shell_routing.dart` -- shared client layers and staff routes. Navigation filtering is not authorization.
- `supabase/tests/notifications_worker_test.sql`, `supabase/tests/notifications_push_test.sql`, `apps/staff/test/staff_app_test.dart` -- health, permissions, and staff navigation test patterns.
- `docs/runbooks/notifications.md`, `docs/runbooks/system-access-and-operations.md` -- worker operation and owner-only gate procedures.

## Tasks & Acceptance

**Execution:**
- [x] `supabase/migrations/20261013000000_notifications_health.sql` -- add nullable operator/Auth mapping and a redacted health read for live Admins or mapped operators; add delayed-job, failed-lease, and direct-contact aggregates. Extend push claim/prepare to enforce `outbound_sending` before leasing work or returning tokens. Keep operator functions private.
- [x] `supabase/tests/notifications_health_test.sql`, `supabase/tests/notifications_worker_test.sql`, `supabase/tests/notifications_push_test.sql` -- cover aggregates, synthetic failure states, redaction, Admin/mapped-operator access, other-user refusal, procedure isolation, and gate-closed push behavior.
- [x] `packages/client_core/lib/src/domain/notification_health.dart`, `application/notification_health_controllers.dart`, `adapters/supabase_notification_health_repository.dart`, `presentation/notification_health_screen.dart` -- implement typed read and loading, empty, stale, and error states.
- [x] `packages/client_core/lib/src/presentation/shell_routing.dart`, `apps/staff/lib/app.dart`, `apps/staff/test/staff_app_test.dart` -- add Admin/operator destination and cover navigation/refusal.
- [x] `docs/runbooks/notifications.md` -- document health interpretation, synthetic failure demonstration, and owner-only pause/resume through `outbound_sending`; do not change gate state during implementation.

**Acceptance Criteria:**
- Given synthetic delayed/failed jobs, retired tokens, and direct-contact needs on staging, when Admin or mapped operator opens the view, then counts/times match and no private data appears.
- Given another signed-in user calls the read directly, when authorization runs, then the server refuses without returning health data.
- Given an operator account is mapped, when it reads health, then only this projection is available; operator procedures remain inaccessible.
- Given `outbound_sending` is closed, when push is claimed/prepared, then no new push target is returned and inbox reminders remain; eligible unexpired work resumes after owner reapproval.

## Implementation Notes

Stories 3.5 and 2.3 are done; 3.7 is built. No local prerequisite blocks implementation. Q12 alert thresholds/destination do not block a state-only view. Staging demonstration still needs 3.7’s migration and 3.4 worker setup; the owner must map their account in that environment.

## Plan Change Log

## Review Triage Log

- `low` / `patch` — The migration added `last_success_at` without copying the pre-existing successful tick, so the new health projection could report no successful handoff until the next successful scheduler tick; baseline `notifications_scheduler_note` records `last_tick_at` and `last_tick_outcome = 'sent'` together, which supplies the prior handoff timestamp.

## Design Notes

`notifications_scheduler_status()` is operator-only; never expose it by changing grants. Add a separate read that checks a live Admin grant or mapped operator account. Push claim/prepare currently check `push_enabled`, not `outbound_sending`; enforce the gate in both paths while preserving in-app reminders. The owner sets the account mapping per environment.

## Verification

**Verification completed:**
- `flutter test` in `packages/client_core` (427 tests) and `apps/staff` (31 tests) passed.
- `npm run -s ci:migrations` passed (34 ordered, unique and non-destructive migrations).
- Scoped `pg_prove` for `notifications_health_test.sql`, `notifications_push_test.sql`, and `notifications_worker_test.sql` passed (224 tests); the scheduler-success backfill SQL was also checked in a rolled-back transaction.
- `git diff --check` passed.

**Database environment limitation:** The standard `npx supabase db reset && npm run -s db:test` path could not complete because the local Supabase containers could not reach Postgres through Docker's `db` alias. The same three pgTAP files passed through a host-gateway connection. No hosted database was changed.

**Manual checks:** The staging demonstration remains for the owner: map the operator, set synthetic delayed/failure states, and confirm both roles, redaction, refusal, and gate pause/resume procedure.

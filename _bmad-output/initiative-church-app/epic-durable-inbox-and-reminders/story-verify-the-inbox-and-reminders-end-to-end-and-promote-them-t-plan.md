---
title: 'Verify the inbox and reminders end to end and promote them to production'
type: 'feature'
ticket: '10'
created: '2026-10-13'
status: 'built'
baseline_revision: '1c6d1afa7bed90c638759e918db52b2b925aa5cf'
route: 'full'
route_source: 'auto'
review: 'quick'
review_source: 'pinned'
lenses_ran: [quick]
review_loop_iteration: 0
context:
  - '{project-root}/docs/runbooks/notifications.md'
  - '{project-root}/docs/runbooks/environments-and-promotion.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** Stories 3.1–3.8 have separate notification implementations and checks, but there is no closing, repeatable release path proving mobile, staff web, worker, routing, push, inbox and health together or ensuring production receives its Edge Functions safely.

**Approach:** Complete a documented, evidence-producing staging acceptance sequence using synthetic members and the existing scenario suites, then make the protected promotion workflow deploy the pinned Edge Functions and verify that unapproved production scheduler, push, outbound-send and alerting controls stay disabled. Production promotion and owner decisions remain gated; missing owner prerequisites leave Story 3.10 open.

## Boundaries & Constraints

**Always:** Keep production deployments on `main`, behind environment reviewers and target-project guards. Use synthetic staging data only; do not persist credentials, tokens, message content or member identifiers in evidence. Deploy Edge Functions after migrations and before clients. Keep all activation controls fail-closed until owners approve them.

**Never:** Create or change hosted projects, configure Firebase/APNs or worker secrets, schedule production work, enable push/sending/alerts, approve policy gates, or claim staging/production evidence that has not been witnessed.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Promotion target | Protected staging or production environment and guarded project ref | Migrations, deployed functions, verification, then immutable client artifact in order | Missing credentials, target mismatch or failed gate assertion stops promotion |
| Production activation | Any scheduling, push, outbound sending or alert destination approval missing | Corresponding activation remains disabled and visible in release evidence | Hosted verification fails if a required disabled baseline is open |
| Synthetic reminder lifecycle | Short notice, recurrence edit, cancellation, stale revision, revoked scope, duplicate worker, app closed or push denied | Existing suites and both clients show correct inbox, retry, retirement and health outcomes without cross-member access | Failures are recorded as redacted evidence; no real recipient is used |

</frozen-after-approval>

## Code Map

- `tools/identity-e2e/{inbox,source-contracts,worker,routing,push,inbox-screens}.mjs` -- existing local real-stack scenario suites and evidence output; reuse them rather than duplicate their API setup.
- `supabase/functions/{identity-assisted-recovery,identity-deletion,notifications-worker}/` and `supabase/config.toml` -- three repository Edge Functions; all are configured for explicit `--no-verify-jwt` deployment.
- `.github/workflows/promote.yml` -- guarded migration and client promotion; insert function deployment between database verification and client build, using the already-guarded target ref and pinned Supabase CLI.
- `tools/ci/verify-hosted.sql`, `tools/ci/hosted-sql.mjs`, `tools/ci/ci-tools.test.mjs` -- post-promotion assertions and offline test patterns; assert the production notification activation baseline without rejecting approved staging operation.
- `docs/runbooks/notifications.md`, `docs/runbooks/environments-and-promotion.md` -- existing owner setup and per-story staging instructions; add a closing choreography, evidence requirements and owner-held production gate list.
- `_bmad-output/initiative-church-app/epic-durable-inbox-and-reminders/evidence-3.{1..7}/` -- prior artifacts; `evidence-3.7/owner-device-check.md` is absent and there is no `evidence-3.8/` yet.

## Tasks & Acceptance

**Execution:**
- [ ] `.github/workflows/promote.yml`, `tools/ci/ci-tools.test.mjs` -- deploy all three functions with `--no-verify-jwt` to the guarded target after database verification and before client builds; test names, flags, target use and workflow ordering offline.
- [ ] `tools/ci/verify-hosted.sql`, `tools/ci/hosted-sql.mjs`, `tools/ci/ci-tools.test.mjs` -- assert on production that the scheduler is inactive, push is disabled, outbound sending stays closed and alerting is disabled; test generated SQL and preserve staging behavior.
- [ ] `docs/runbooks/environments-and-promotion.md` -- document function deployment, required secrets, fail-closed conditions and updated promotion order.
- [ ] `docs/runbooks/notifications.md`, `_bmad-output/initiative-church-app/epic-durable-inbox-and-reminders/evidence-3.10/README.md`, `_bmad-output/initiative-church-app/epic-durable-inbox-and-reminders/evidence-3.10/owner-review.md` -- give the owner a repeatable synthetic staging sequence spanning the existing E2Es, clean builds on mobile and staff, health states, independent reruns and redacted witness record; explicitly mark unavailable owner evidence and production gates pending.
- [ ] `.github/workflows/ci.yml` -- scan new Story 3.10 evidence for credentials and sensitive values.

**Acceptance Criteria:**
- Given the protected promotion workflow targets staging or production, when it applies migrations, then it deploys each configured Edge Function to that same guarded project before building clients and rejects deployment errors.
- Given a production baseline with unapproved notification controls, when hosted verification runs, then scheduler, push, outbound sending and alerting remain disabled; a staging scheduler configured for synthetic acceptance is not rejected by the production-only assertion.
- Given the staging owner follows the closing runbook with synthetic members, when all scenarios and independent reruns complete, then both client builds and recorded expected outcomes cover scheduling, lifecycle, worker retries, push, inbox/snooze and health without exposing secrets or personal data.
- Given production project, policy, Firebase/APNs, worker credential, Q12 tolerance, or witness evidence is still missing, when this story is reviewed, then the missing gate is listed and production is not represented as promoted or complete.

## Implementation Notes


## Plan Change Log


## Review Triage Log


## Design Notes

Promotion remains one ordered release: migrations establish server contracts, hosted assertions confirm the target baseline, functions become available, and clients are built last. Story 3.10 provides repeatable evidence and deployment mechanics; it does not authorize opening production gates or substitute for owner-held credentials and witness evidence.

## Verification

**Commands:**
- `npm run ci:policy-test` -- expected: offline workflow and hosted-SQL assertions pass.
- `npm run env:check && npm run ci:migrations` -- expected: environment and migration policies pass.
- `npm run ci:secrets` -- expected: no credentials in tracked files.
- `node --test tools/identity-e2e/*.test.mjs supabase/functions/*/*.test.mjs` -- expected: scenario helper and function tests pass.
- Flutter analysis, tests and clean web builds for `apps/mobile` and `apps/staff` -- expected: both clients build with staging defines.

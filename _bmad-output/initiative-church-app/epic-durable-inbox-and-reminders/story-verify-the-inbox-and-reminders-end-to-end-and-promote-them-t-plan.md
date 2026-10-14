---
title: 'Verify the inbox and reminders end to end and promote them to production'
type: 'feature'
ticket: '10'
created: '2026-10-13'
status: 'in-review'
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

- Added the guarded Edge Function deployment step and production-only notification activation assertions; offline tests cover workflow order, function names/flags and SQL branch scope.
- `npm run ci:policy-test` passed (51); `npm run env:check`, `npm run ci:migrations -- --base origin/main` (34 migrations), and `npm run ci:secrets` passed.
- Notification helper/function tests passed (107). Flutter 3.47.6 Core analysis and tests passed (427); mobile analysis/tests passed (44); staff analysis/tests passed (31). A clean staff web release build passed.
- Mobile APK build is still unverified because Android SDK is absent; mobile is not configured as a web target. Full local Supabase reset/E2E is unavailable: `supabase start` fails in the Realtime migration with a Postgres connection-pool timeout, leaving GoTrue schema incomplete. No staging or production tests were run.
- Matrix coverage is present in offline release-policy tests and shared-client tests. Live integrated staging evidence and independent witness remain owner steps; implementation does not mark those as complete.

## Plan Change Log


## Review Triage Log

- **medium — patch:** `.github/workflows/ci.yml` ran the credential scanner without checking personal identifiers, so a UUID, phone number, email address, or labeled witness name could enter Story 3.10 release evidence despite the runbook ban. Reproduced with a temporary UUID in `owner-review.md`; the scan passed. The opt-in personal-data patterns now run only on Story 3.10 evidence, with focused reject/clean tests.

## Design Notes

Promotion remains one ordered release: migrations establish server contracts, hosted assertions confirm the target baseline, functions become available, and clients are built last. Story 3.10 provides repeatable evidence and deployment mechanics; it does not authorize opening production gates or substitute for owner-held credentials and witness evidence.

## Verification

**Commands and results:**
- `npm run ci:policy-test` -- passed, 51 tests including production-only verification and function deployment order.
- `npm run env:check` -- passed.
- `npm run ci:migrations -- --base origin/main` -- passed, 34 migrations checked.
- `npm run ci:secrets` -- passed, 1,437 tracked files scanned.
- `node --test tools/auth-harness/scan-evidence.test.mjs` and `bash tools/auth-harness/scan-evidence.sh --personal-data _bmad-output/initiative-church-app/epic-durable-inbox-and-reminders/evidence-3.10` -- passed; personal-data fixtures are rejected and release evidence is clean.
- `node --test tools/identity-e2e/*.test.mjs supabase/functions/*/*.test.mjs` -- passed, 107 helper and function tests.
- `/tmp/flutter/bin/flutter analyze --fatal-infos && /tmp/flutter/bin/flutter test` in `packages/client_core` -- passed, 427 tests.
- Flutter analyze/test in `apps/mobile` -- passed, 44 tests; `flutter build apk --debug` could not run because Android SDK is not installed.
- Flutter analyze/test in `apps/staff` -- passed, 31 tests; clean `flutter build web --release --no-web-resources-cdn` passed.
- `npx supabase db reset` and local full-stack E2E -- blocked by Realtime migration connection-pool timeout during Supabase startup. Staging and production owner checks remain unwitnessed.

## Review fixes (2026-10-13)

Source: `review-3.8-3.10.md` findings 3, 4, 11, 13 and 15.

- `tools/ci/verify-hosted.sql`: staging accepts `outbound_sending` open (owner decision); in
  production each activation assertion applies only while its gate is unapproved: scheduler job
  unless `ops_system_access`, `q2_church_time` and `q12_operations` are approved; `outbound_sending`
  open unless its approval value names production; `push_enabled` unless that approval exists.
  `ci-tools.test.mjs` asserts the structure; five rolled-back local runs confirmed pass/fail cases.
- `tools/identity-e2e/push.mjs` opens the gate for its run and restores the exact row in cleanup.
- `scan-evidence.sh`: flags in any position, unknown flags / missing paths / bare `--personal-data`
  exit 2, spaced international numbers and unlabeled names flagged; tests added.
- Runbooks: `notifications.md` Story 3.10 production gate, `environments-and-promotion.md` and
  `production-promotion-identity.md` describe the conditional assertions.
- The 3.8 fixes ship as the repair migration `20261013194009_notifications_health_repair.sql`;
  `check-migrations` passes with `--base ccr-93e730dd-89lbvg` and `--base origin/main`.

**Status `in-review`: pending owner/staging items (finding 15).** Every execution item of this
story's staging acceptance remains unwitnessed:
1. The 3.8 staging items (apply, gate decision, redeploy both functions, mapping) first.
2. Staging owner acceptance steps 1-8 in `notifications.md` Story 3.10 (clean client builds, account split, lifecycle cases on both clients, 3.7 checks twice, closed-app scheduler delivery with failure/recovery and stale check, real-device push where available, cleanup, independent witness), recorded redacted in `evidence-3.10/owner-review.md`.
3. Android APK build on a machine with the Android SDK.
4. Production prerequisites (project/ref, protected environment, Q2, `ops_system_access`, Q12 and lateness tolerance, Firebase/APNs, worker credential and Edge secrets, `outbound_sending` production approval, witness evidence). Production is not promoted.

**Full local verification (after all review fixes):** `npx supabase db reset`; `npm run -s db:test` (26 files, 2144 tests, PASS); `npm run -s db:smoke` (exit 0); `npm run -s contracts:test` (242); `npm run -s ci:policy-test` (56); `node --test tools/auth-harness/*.test.mjs tools/identity-e2e/*.test.mjs supabase/functions/*/*.test.mjs tools/identity-deletion/*.test.mjs tools/notifications/*.test.mjs` (156, includes `_shared`); `ci:secrets`, `ci:migrations -- --base origin/main` (34), `ci:function-imports`, `env:check` and all 23 CI evidence scans clean; Flutter analyze clean and tests pass for `packages/client_core` (428), `apps/staff` (33), `apps/mobile` (45); `verify-hosted.sql` exercised locally in five rolled-back marker/gate cases. E2E, each after a reset:

```
run exit=0 
grants exit=0 
apply exit=0 27/27 checks passed 
review exit=0 18/18 checks passed 
cells exit=0 13/13 checks passed 
recovery exit=0 20/20 checks passed 
credentials exit=0 15/15 checks passed 
assisted exit=0 16/16 checks passed 
lifecycle exit=0 9/9 checks passed 
deletion exit=0 12/12 checks passed 
runbooks exit=0 16/16 checks passed 
inbox exit=0 13/13 checks passed 
source-contracts exit=0 10/10 checks passed 
worker exit=0 17/17 checks passed 
routing exit=0 18/18 checks passed 
push exit=0 12/12 checks passed 
inbox-screens exit=0 12/12 checks passed
```

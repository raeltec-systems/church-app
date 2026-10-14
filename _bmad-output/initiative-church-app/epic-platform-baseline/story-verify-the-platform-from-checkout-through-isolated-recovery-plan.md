---
title: 'Verify the platform from checkout through isolated recovery'
type: 'chore'
ticket: '12'
created: '2026-10-03'
status: 'blocked'
blocked_reason: 'Owner items (all agent-side checks pass, 19 pass / 7 blocked / 0 fail in evidence-1.12/README.md): (1) 1.2 phone-provider decision: Supabase requires an SMS provider to enable phone signup, so external.phone stays false and identity tracer entry 1 (after 1.2) stays blocked; never configure SMS. (2) Approve apply_migration recovery_journal (exact local 20261003161000_recovery_journal.sql) on staging tmurpotfluignacfueki, then rerun list_migrations and verify-hosted.sql expected_env=staging. (3) Native Android run of the APK built from this commit on a real phone (hosted value, airplane-mode error, Try again). (4) Native iOS run (signing/hardware). (5) GitHub staging/production environments, secrets and production project (1.8 owner steps A-C) for a real promote.yml run. (6) Owner review and confirmation of evidence-1.12, plus the outstanding 1.6 browser/screen-reader spot-check.'
baseline_revision: '2b3ad1824ea255bf2b59b196c239de2d25f4fdcf'
route: 'full'
route_source: 'auto'
review: ''
review_source: ''
lenses_ran: []
review_loop_iteration: 0
context: []
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** Stories 1.1–1.11 each recorded their own evidence, but nothing has yet re-run the whole platform from one clean checkout of the integration branch, against isolated staging, with independent security checks and the owner-blocked items made visible in one place.

**Approach:** From a clean checkout, rebuild both clients for staging, run every local suite CI runs plus the recovery rehearsal (including incomplete-journal denial), check hosted staging read-only through the Supabase MCP, and record raw output plus a verdict table (scenario → pass / blocked-on-owner / fail, with evidence path) in `evidence-1.12/`. Fix only genuine defects, with the smallest change.

Decision (agent, under owner pre-approval): native Android and iOS runs are recorded as blocked-on-owner (no KVM/emulator here; iOS needs signing/hardware). No emulator is presented as FCM evidence.
Decision (agent, under owner pre-approval): hosted staging is checked read-only. The pending `20261003161000_recovery_journal` staging apply is recorded as expected drift and blocked-on-owner, not applied.
Decision (agent, under owner pre-approval): the 1.4 command smoke is local-only by design (needs psql and the local secret key); it runs locally and its staging variant is recorded as not supported by the tool. The 1.9 matrix runs against staging only if an already-registered, unexpired staging credential exists; no new credential is minted or registered, and nothing is minted for production.
Decision (agent, under owner pre-approval): the 1.2 phone track is evidenced as blocked by a read-only `GET /auth/v1/settings` on the auth-test project plus the unresolved `q1_auth_recovery` gate; no SMS or provider setting is touched.

## Boundaries & Constraints

**Always:** synthetic data only; publishable key only via `--dart-define` at run time; raw output saved under `evidence-1.12/`; every scenario gets exactly one verdict with an evidence path; plan status `blocked` while any owner item remains.

**Never:** weaken a test, contract or policy to make it pass; apply migrations or change settings on any hosted project; configure SMS, a phone provider or test OTPs; mint or register production credentials; present an emulator as native/FCM evidence; commit secrets, tokens or keys.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Clean client builds | clean checkout, staging defines | APK + web bundle build; bundle scan clean; sealed checksums verify | build/scan failure = fail |
| Staff tracer in Chromium | staging web build served locally | shows hosted `platform_status` value | network failure recorded raw |
| Incomplete journal | absent / gap / tampered / unsealed / early seal | restore held; private_access and outbound_sending closed | any open gate = fail |
| Unapproved production policy | verify-hosted / env:check / promote preflight vs production | refuses activation | acceptance = fail |
| Phone provider unavailable | auth-test `external.phone=false` | identity activation stays closed | recorded blocked-on-owner |
| Anon REST exposure | publishable key, `Accept-Profile: app` / `public` | only `api` reachable | any app/public data = fail |

</frozen-after-approval>

## Code Map

- `package.json` -- every suite script (`db:test`, `db:smoke`, `contracts:test`, `env:check`, `ci:policy-test`, `recovery:rehearse`, `ci:migrations`, `ci:secrets`).
- `.github/workflows/ci.yml` -- authoritative list of CI steps (Flutter analyze/test per package, `dart test -p chrome`, bundle scan).
- `.github/workflows/promote.yml` -- preflight + verify-hosted gates for production.
- `tools/ci/verify-hosted.sql`, `tools/ci/package-web.mjs`, `tools/ci/scan-secrets.mjs`, `tools/ci/check-migration-drift.mjs` -- 1.8 tooling reused as-is.
- `tools/ops/system-credential.mjs` -- 1.9 matrix (`matrix --env staging`).
- `tools/recovery/rehearse.mjs` -- 1.10 rehearsal incl. denial scenarios.
- `tools/auth-harness/` -- `*.test.mjs` and `scan-evidence.sh`.
- `apps/mobile`, `apps/staff`, `packages/{design_system,client_core,contracts/dart}` -- Flutter targets.
- Prior evidence: `evidence-1.1` … `evidence-1.10` (format and earlier staging baselines).

## Tasks & Acceptance

**Execution:**
- [x] `evidence-1.12/local/*` -- run each local suite, save raw output -- regression proof.
- [x] `evidence-1.12/builds/*` -- APK + staff web build for staging, bundle scan, package-web seal/verify, checksums -- immutable artifact proof.
- [x] `evidence-1.12/browser/*` -- Playwright Chromium run of the staging staff build -- tracer proof.
- [x] `evidence-1.12/staging/*` -- MCP marker/gates/migrations/advisors, verify-hosted, REST exposure, 1.9 matrix or its blocked note -- hosted proof.
- [x] `evidence-1.12/gates/*` -- production refusals and phone-provider blocking -- activation-gate proof.
- [x] `evidence-1.12/README.md` -- verdict table and owner actions.
- [x] Any genuine defect (none found) -- smallest fix plus its regression check.

**Acceptance Criteria:**
- Given the integration branch at a clean checkout, when every suite in the matrix runs, then each has a recorded verdict and raw output in `evidence-1.12/`.
- Given any owner-dependent item, when the plan closes, then its status is `blocked` with each owner action named.

## Implementation Notes

- Implemented directly (no coding subagent available in this run). Worktree merged `ccr-93e730dd-89lbvg` at `2b3ad18`; `npm ci` and all Flutter `pub get --enforce-lockfile` ran from scratch; `supabase db reset` applied this checkout's 8 migrations to the local stack.
- Results: 19 pass, 7 blocked-on-owner, 0 fail (`evidence-1.12/README.md`). No genuine defect found; no source, test, contract or policy file changed.
- Hosted staging: read-only MCP only. Marker `staging`; private_access/outbound_sending/q1/q4/q12/ops gates closed; expected drift `20261003161000_recovery_journal` pending, so `verify-hosted.sql` refuses (`rcv_serving_hold() is missing`) - recorded blocked-on-owner, not applied. Hardening migration `20261003131021` is now on staging (the 1.4 plan's blocked_reason is stale).
- 1.9 matrix ran against staging with the existing, unexpired 1.9 staging credential (expires 2026-10-05 15:40 UTC), 14/14; nothing minted into .ops-state or registered. The 1.4 command smoke has no staging mode (needs local secret key + psql) and passed locally.
- Staff web tracer: Playwright 1.56.1 + Chromium 141, the sealed staging build served by route-fulfil (loopback goes through the agent proxy otherwise); hosted value, blocked network error + Try again, recovery.
- Phone provider: read-only `GET /auth/v1/settings` on auth-test and staging (external.phone=false); no setting touched.
- Observation for review (1.8 lane, not changed): `environments.mjs target production <auth-test ref>` is accepted; only refs of configured environments are rejected.

## Plan Change Log

## Review Triage Log

## Verification

**Commands:**
- `npm run db:test && npm run db:smoke && npm run recovery:rehearse` -- expected: exit 0.
- `npm run ci:policy-test && npm run env:check && npm run ci:secrets && npm run ci:migrations -- --base origin/main` -- expected: exit 0.
- `flutter analyze && flutter test` in each Flutter package -- expected: no issues, all pass.

## Review Triage Log

| Finding | Verdict | Route | Evidence |
|---|---|---|---|
| (builder risk) `resolveDeployTarget` accepts the auth-test project ref for production | medium | patch | environments.mjs had no list of harness-only refs; added NON_DEPLOYABLE_REFS + test |
| (builder risk) promote.yml runs verify-hosted only after `db push`, so a mis-set ref is migrated before refusal | medium | patch | added `hosted-sql.mjs precheck` step before link/push; refuses a database marked as another environment; unit test added |
| (builder risk) 1.4 plan `blocked_reason` stale | low | patch | hardening migration 20261003131021 is on staging; status set done |

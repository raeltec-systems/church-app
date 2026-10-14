---
title: 'Sign in with a phone username and reach a live-access-checked read'
type: 'feature'
ticket: '1'
created: '2026-10-06'
status: 'done'
baseline_revision: 'f0a115dc4a51e50cdd7d35f9eb1f7551b7c5a9ab'
route: 'full'
route_source: 'auto'
review: 'quick'
review_source: 'pinned'
lenses_ran: []
review_loop_iteration: 0
context:
  - '{project-root}/_bmad-output/initiative-church-app/owner-decisions-milestone-1.md'
  - '{project-root}/_bmad-output/initiative-church-app/epic-platform-baseline/evidence-1.2/README.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** No Identity owner exists: nothing ties a Supabase Auth account to a church member, and no server predicate decides private access. Phone `/otp` can mint `password`-AMR sessions for any number (F1), so AMR alone must never unlock member data.

**Approach:** Add the Identity owner schema (members, account links with a versioned approved phone/recovery-email binding, holds, versioned settings) and ONE server live-access predicate (password AMR + live `auth.sessions` row + active approved link + current Auth binding + no hold + dormancy evaluated before activity refresh + release gate). Expose one allowlisted `api` read of the caller's own member summary. Both clients get a shared phone/password sign-up and sign-in screen (no SMS) and a "My membership" screen that shows the summary or a generic denial.

## Boundaries & Constraints

**Always:**
- Phone usernames are international (any country code), normalized to `+<digits>` E.164 (8–15 digits); +260 is only the picker default; no operator-prefix rules. Tests use only fictional ranges (`+1 202 555 0100–0199`, `+44 7700 900000–900999`).
- The predicate fails closed: missing/otp/recovery-only AMR, a dead session, no active approved link, a binding mismatch with `auth.users` phone/email, an open hold, dormancy past the effective setting, or an unset setting all deny. Login and token refresh never refresh activity; only a granted read does.
- Private serving needs the `private_access` gate, except a synthetic member in a database marked `local`/`staging` with no recovery hold.
- Identity objects use the `identity_` prefix in non-exposed `app`; clients get only `api` wrappers; no client table privileges. Errors are generic; denial reasons never disclose another person's data.
- Protected client state lives in memory, keyed to the account generation; sign-out clears it.

**Never:** SMS, SMS provider, Send SMS hook, test OTP or SMS MFA; real numbers or member data; grants/roles (2.3), applications/registration fields (2.4), admin linking UI (2.5), recovery email (2.7); service-role keys in clients; destructive SQL; editing other lanes' platform migrations.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Approved member read | password session, live, active link, binding matches | summary {member_id, display_name, membership_state, phone_username, is_synthetic}; activity refreshed | — |
| Unlinked account | password session, no link | denied `not_linked` | generic "no member access yet" |
| Signed out | no JWT | denied (no EXECUTE for anon) | sign-in prompt |
| Untrusted session | amr otp only, or session row deleted | denied `untrusted_session`, no activity write | ask to sign in again |
| Binding drift / hold / dormant | auth phone or email ≠ approved; open hold; last activity older than dormancy | denied `review_required` | generic access-review screen |
| Gate closed | unmarked/production DB, gate unapproved | denied `unavailable` | "not available yet" |
| Direct table query | REST on app tables or api tables | refused (schema not exposed / no privilege) | — |
| Sign-up / sign-in | `+260 97…` picker or `+1 202 555 0101` typed | normalized E.164 sent to Auth; wrong password and unknown phone show the same message | rate limit, unreachable, weak password distinct; existing username generic |

</frozen-after-approval>

## Code Map

- `supabase/migrations/20261003*.sql` -- platform; do not edit. Reuse `app.policy_is_open`, `app.platform_current_environment`, `app.rcv_serving_hold`; owner prefix registry already maps `identity_` -> `identity` (lock_rank 10); identity may depend on platform only.
- `tools/auth-harness/sql/001_trusted_session_probe.sql` -- 1.2 session-half predicate (amr `password` + live `auth.sessions` row with `not_after`); port its logic.
- `supabase/tests/*.sql` (pgTAP), `supabase/tests/*_smoke.sh` -- patterns for DB tests and REST smoke; add new files, register smoke in root `package.json` `db:smoke`.
- `packages/client_core` -- ports in `lib/src/domain`, adapters only in `lib/src/adapters` (guard test), providers in `lib/src/application/providers.dart`, routes in `lib/src/presentation/shell_routing.dart`, fakes in `lib/testing.dart`, composition in `lib/composition.dart` (keep `persistSession:false`).
- `apps/mobile/lib/app.dart`, `apps/staff/lib/app.dart` -- nav destination lists; add the account destination.
- Local GoTrue has phone forced off by CLI 2.119.0 (evidence-1.2/local-cli-phone-gate.txt); staging lacks `20261006215306_recovery_journal (+ 20261006215400_recovery_journal_hold)` (owner gate from 1.10/1.12) and phone provider.

## Tasks & Acceptance

**Execution:**
- [x] `supabase/migrations/20261006215842_identity_live_access.sql` -- identity tables, settings (fixture dormancy 90 days, labelled), predicate, activity refresh, `api.identity_my_member_summary()`, restricted synthetic-link seeding function.
- [x] `supabase/tests/identity_live_access_test.sql` -- pgTAP for every matrix row plus grants.
- [x] `supabase/tests/identity_api_smoke.sh` + `package.json` -- REST: anon denied, app table not reachable.
- [x] `tools/auth-harness/local-phone-auth.mjs` -- local-only: recreate the CLI auth container with phone on, sms autoconfirm on, no provider/hook/test OTP; refuses any non-local target.
- [x] `tools/identity-e2e/` -- dependency-free Node E2E: phone sign-up/sign-in, seed link, read, deny cases, cleanup; redacted evidence.
- [x] `packages/client_core` -- phone normalization + country list, auth and member-access ports, Supabase adapters, controllers, sign-in and membership screens, routes, fakes, tests.
- [x] `apps/{mobile,staff}` -- account destination; app tests.
- [x] `docs/runbooks/identity-access.md` -- predicate, seeding, owner staging steps.
- [x] `evidence-2.1/README.md` -- results and owner steps.

**Acceptance Criteria:**
- Given a seeded synthetic approved member, when they sign in with phone+password on either client, then the membership screen shows their summary from the api read.
- Given the CI checks, when run, then pgTAP, smoke, flutter analyze/test pass and no SMS config exists.

## Implementation Notes

- Decision (agent, under owner pre-approval): in-memory sessions stay (`persistSession:false`); I2's persistence across app restarts needs secure token storage (mobile keystore, web policy), which is deferred (deferred-work.md). This choice is fail-closed: it causes extra sign-ins, never extra access.
- Decision (agent, under owner pre-approval): the 2.1 read is a SECURITY DEFINER app function behind an invoker `api` wrapper (AD-2 "audited scoped read function"), because a granted read must refresh activity in the same transaction.
- Decision (agent, under owner pre-approval): dormancy uses an identity-owned versioned setting; a labelled fixture is honoured only in `local`/`staging`; production stays unset, so it fails closed until entry 14.
- Decision (agent, under owner pre-approval): non-production synthetic members bypass the closed `private_access` gate so staging can demonstrate the tracer while verify-hosted keeps the gate closed.
- Decision (agent, under owner pre-approval): the approved link for the tracer is created by a restricted, operator-only seeding function that refuses production and binds the account's current Auth phone; Admin linking is entry 5.
- Decision (agent, under owner pre-approval): the migration is not applied to staging, because staging still lacks the 1.10 migration and applying 2.1 first would break version order.

- Built directly (no subagent tool in this session). Files: migration `20261006215842_identity_live_access.sql`; pgTAP `identity_live_access_test.sql` (71); smoke `identity_api_smoke.sh` (in `db:smoke`); `tools/auth-harness/local-phone-auth.mjs` (+ tests); `tools/identity-e2e/run.mjs` (+ tests); client_core domain `phone_username`, `account_auth`, `member_access`, adapters `supabase_account_auth_gateway`, `supabase_member_access_repository`, `account_controllers`, screens `sign_in_screen`, `account_screen`, routes `/account`, `/sign-in`, `/create-account`, fakes in `testing.dart`, `tool/live_identity_check.dart`; app nav entries and app tests; CI auth-harness job runs the new node tests and scans `evidence-2.1`; runbook `docs/runbooks/identity-access.md`.
- Cross-lane edit (necessary): `supabase/tests/command_foundation_test.sql` keeps an exact allowlist of functions `authenticated` may execute; it now also lists `api.identity_my_member_summary` and its definer entry point.
- Decision (agent, under owner pre-approval): local phone sign-in uses a documented local-only switch that recreates the CLI auth container with exactly `GOTRUE_EXTERNAL_PHONE_ENABLED=true` and `GOTRUE_SMS_AUTOCONFIRM=true` and refuses any SMS provider/credential/hook/test OTP/phone MFA. It mirrors the hosted Management API body; CI keeps the CLI default and its smoke signs in through the verified-email alias (same predicate).
- Decision (agent, under owner pre-approval): denial reasons go only to the caller about their own account (`not_linked`, `review_required`, `untrusted_session`, `unavailable`); screens show generic copy. HTTP 401 for unauthenticated/untrusted, 403 otherwise.
- Decision (agent, under owner pre-approval): the country picker lists a curated set with trunk prefixes; any other country works by typing `+`/`00`. The only national-form rule is dropping the picked country's trunk prefix once.
- Decision (agent, under owner pre-approval): "Forgot password?" and "Get church help" open a staff-help panel until email recovery (entry 7) exists.
- Surprise: `/otp {phone, create_user}` reproduces F1 locally (unlinked Auth user row, evidence E18); the reclaim path is deferred (deferred-work.md).
- Environment: the docker daemon was not running and the disk was full (unused `postgres:17.6.1.011` image removed); the local stack was recreated (`stop --no-backup` + `start`) after the daemon restarted mid-reset. Local synthetic users created by this story were all deleted.
- Not done (owner-gated): staging apply, staging phone provider, the hosted native + staff-web demonstration. Staff web was not driven in a browser here; the shared screens are widget-tested in both app shells, and the real adapters were exercised live on the VM.

## Verification

**Commands:**
- `npm run db:test && npm run db:smoke` -- expected: pass
- `node tools/auth-harness/local-phone-auth.mjs on && node tools/identity-e2e/run.mjs && node tools/auth-harness/local-phone-auth.mjs off` -- expected: all scenarios as the matrix
- `flutter analyze && flutter test` in `packages/client_core`, `apps/mobile`, `apps/staff` -- expected: pass
- Results (2026-10-06, local): db:test 424/424 (identity 71); db:smoke all ok (identity 13); recovery:rehearse no problems; E2E 15/15; adapter live check PASS x2; client_core 116, mobile 14, staff 14 tests pass; analyze clean; staff web build + bundle scan clean; ci:migrations, ci:secrets, ci:policy-test, env:check, scan-evidence clean. Evidence: `evidence-2.1/README.md`.

## Review Triage Log

| Finding | Verdict | Route | Evidence |
|---|---|---|---|
| real-format Zambian number +260971234567 in tests | medium | patch | identity_live_access_test.sql:90, run.test.mjs:16; owner decision 2026-10-06 forbids |
| 7-digit numbers accepted; plan says 8–15 | low | patch | phone_username.dart:126; migration CHECK {6,14} |
| dial code doubled for national input already carrying it | medium | patch | phone_username.dart:105-115; `260…`→`+260260…` accepted |
| plan/smoke reference missing local-phone-auth.sh | low | patch | only .mjs delivered |
| local-phone-auth `off` leaves SMS autoconfirm on | low | patch | withPhone(env,false) forces AUTOCONFIRM=true |
| no pgTAP for restore-hold half of synthetic bypass | medium | patch | migration 305-308 untested condition |
| runbook 4.8 under-describes /otp side effect (F1) | low | patch | evidence-1.2 H25, evidence-2.1 E18 |
| re-sign-in same account keeps stale denial | low | patch | _onAccount early return + distinct() |

## Hosted verification

Staging server checks and the owner's Android demonstration are recorded in `evidence-2.2/staging-verify.md` (2026-10-06).

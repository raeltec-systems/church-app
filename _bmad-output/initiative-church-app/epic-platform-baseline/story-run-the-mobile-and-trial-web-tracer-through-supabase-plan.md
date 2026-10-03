---
title: 'Run the mobile and trial-web tracer through Supabase'
type: 'feature'
ticket: '1'
created: '2026-10-03'
status: 'built'
baseline_revision: '48fd56ab763442a4d9cadd57b5cbecaf9fceb7b8'
route: 'full'
route_source: 'auto'
review: 'quick'
review_source: 'pinned'
lenses_ran: ['quick']
review_loop_iteration: 0
context:
  - '{project-root}/_bmad-output/initiative-church-app/architecture-church-app/architecture-church-app.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** The repository has no code. Every later story needs a proven path from both Flutter clients, through an explicit Supabase API, to the database.

**Approach:** Scaffold a locked official Flutter mobile app and a disposable Flutter Web trial. Add one Supabase migration that exposes a synthetic platform status only through an allowlisted `api` read. Show the status in both clients with honest loading, retry and failure states, and add a minimum CI smoke check.

## Decisions

- **Backend: both.** Local Supabase (CLI in Docker) for development and CI. The hosted isolated test project `bic-kafue-platform-test` (ref `tmurpotfluignacfueki`, eu-central-1, free plan, Raeltec Systems Limited org) proves the tracer remotely. It was created on the owner's instruction on 2026-10-03, holds synthetic data only, and its region is not a production decision.
- **Native target: both.** A Linux desktop run in this session is the interim native evidence, and an Android APK is built. The owner's run of that APK on an Android phone or emulator against the hosted project closes the human gate.

## Boundaries & Constraints

**Always:**
- Flutter 3.47.6 and Dart 3.13.5, using the official `flutter create`.
- `supabase_flutter` 2.18.0, with lockfiles committed.
- Clients get only the project URL and publishable key, through `--dart-define`.
- Application tables live in the non-exposed `app` schema with RLS enabled. Only `api` is exposed, and it allows SELECT only, granted explicitly.
- The synthetic data is labelled as synthetic.
- A failure must look different from success, and retry re-runs the real request.
- Statuses are shown as text, never colour alone. Tap targets are at least 44 px.

**Never:**
- No client table DML, `auth`/`storage`/`realtime` objects, secrets in clients or the repo, or real member data.
- Nothing that belongs to later entries: the contracts package (1.5), the design system or the selected `apps/staff` shell (1.6/1.7), staging or production environments (1.8), command envelopes (1.4).
- No fake success, timer-driven states, Riverpod or go_router app architecture beyond what the tracer needs.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Load OK | `api.platform_status` holds one row | Loading indicator, then the status text, message and `updated_at` | None |
| Backend changed | Row updated with SQL by a privileged role | Retry or reload in either client shows the new value | None |
| Network down | API unreachable or times out | "Couldn't reach the server" error panel with **Try again**; no stale value shown as current | Retry sends a fresh request |
| No row | View returns zero rows | "No platform status recorded" (empty state, distinct from the error state) | None |
| Write attempt | anon or authenticated INSERT/UPDATE through the API, or direct `app` access | Denied | Permission error |

</frozen-after-approval>

## Code Map

- The repo contains only planning docs, `docs/design-handoff/`, `.agents/skills`, `_bmad/` and the `.claude/skills` symlink. There is no `pubspec`, no `supabase/` folder and no `.github/`.
- `architecture-church-app.md` §Structural Seed sets the layout: `apps/mobile`, `apps/staff` (only after Q10), `packages/`, `supabase/{migrations,functions,tests}`. AD-2 covers the `api`/`app` split and grants. AD-16 says Flutter Web is only a trial.
- `spec-church-app/design-contract.md` §Tokens: bg `#F4F6FA`, ink `#0E1530`, primary `#14246B`, red `#FCE5E2`/`#A3241A`. Use these as local constants only; the design system is entry 1.7.
- Environment facts:
  - Docker runs, once `dockerd` is started.
  - Supabase CLI 2.119.0 works through npx.
  - Flutter 3.47.6 can be downloaded.
  - No KVM, so no Android emulator, and no iOS tooling.
- `_bmad/render/` is untracked generated skill output. Add it to `.gitignore`.

## Tasks & Acceptance

**Execution:**
- [x] `.gitignore` -- ignore `_bmad/render/`, Flutter build outputs and `supabase/.temp` -- keeps the tree clean.
- [x] `package.json` -- pin the `supabase` CLI 2.119.0 as a devDependency, with scripts `db:start`, `db:test` and `db:reset` -- reproducible CLI version.
- [x] `supabase/config.toml` -- create with `supabase init`, then set `[api] schemas = ["api"]` and `extra_search_path = ["api"]` -- only `api` is exposed.
- [x] `supabase/migrations/<ts>_platform_status_tracer.sql` -- create schemas `app` and `api`, plus table `app.platform_status`:
  - columns: id smallint PK, `check (id = 1)`, status text, message text, is_synthetic bool, updated_at timestamptz
  - RLS enabled, with a select-only policy
  - view `api.platform_status` with `security_invoker = true`
  - explicit USAGE and SELECT grants to anon and authenticated
  - no other privileges

  Rationale: AD-2 read path.
- [x] `supabase/seed.sql` -- one synthetic row -- data for the tracer.
- [x] `supabase/tests/platform_status_test.sql` -- pgTAP: anon can read through `api`, anon and authenticated cannot write, and `app` is not reachable through PostgREST -- permission evidence.
- [x] `apps/mobile/` -- `flutter create --org zm.bickafue --platforms android,ios,linux --empty` -- native client. Add:
  - `lib/platform_status/` with a repository interface, a Supabase adapter and a screen with loading, data, empty and error+retry states
  - widget tests using a fake repository
- [x] `trials/staff_web/` -- `flutter create --platforms web --empty` -- disposable trial (`apps/staff` waits for Q10). A minimal copy of the same read and states, plus a widget test. Its README marks it disposable.
- [x] `.github/workflows/ci.yml` -- `db` job (`supabase start`, `db test`) and `flutter` job (pinned 3.47.6: `pub get --enforce-lockfile`, `analyze` and `test` in both apps, `build web` for the trial) -- minimum smoke check.
- [x] Hosted project -- apply the same migration with the Supabase connector, seed the synthetic row, add `api` to the exposed schemas (the connector cannot change API settings, so this is an owner dashboard step if needed), and check the security advisors -- remote proof.
- [x] `docs/runbooks/tracer.md` -- how to start the local stack, run both clients with `--dart-define`, change the status with SQL, and simulate a failure.

**Acceptance Criteria:**
- Given a clean checkout, when CI runs, then the db and flutter jobs pass.
- Given the local stack is running, when the status is updated with SQL, then the mobile native target and the web trial both show the new value after reload.
- Given the API is stopped, when either client loads, then it shows the error panel, and **Try again** recovers once the API is back.

## Design Notes

The table has a single row (`id = 1`). Clients read `api.platform_status` through `supabase.from(...)` with the client schema set to `api`. The tracer uses a plain `FutureBuilder`-style state holder; Riverpod and go_router stay with entry 1.7.

## Verification

**Commands:**
- `npm run db:start && npm run db:test` -- expected: pgTAP passes
- `cd apps/mobile && flutter analyze && flutter test` -- expected: clean
- `cd trials/staff_web && flutter analyze && flutter test && flutter build web` -- expected: clean

**Manual checks (if no CLI):**
- Run the Linux desktop app and the web trial against the hosted project, change the row, then point a client at an unreachable URL. Screenshots go into Implementation Notes.
- Owner: install the APK on an Android device, check that it shows the hosted value, and toggle airplane mode to see the error and **Try again** states.

## Implementation Notes

Implemented 2026-10-03.

**What landed**
- `supabase/migrations/20261003112319_platform_status_tracer.sql`: `app`/`api` schemas, `app.platform_status` (single row, RLS, select-only policy for anon/authenticated), `api.platform_status` (`security_invoker = true`), explicit USAGE + SELECT grants only. Because the view is security_invoker, anon/authenticated also need USAGE on `app` and SELECT on the base table; `app` stays unreachable over HTTP because only `api` is exposed. Also `alter default privileges for role postgres revoke execute on functions from public` (AD-2): per-schema default ACLs cannot remove the global PUBLIC EXECUTE default, so the global form is used. The file is named with the version the hosted project recorded, so local and hosted migration histories match.
- `supabase/config.toml`: `schemas = ["api"]`, `extra_search_path = ["api"]`, `auto_expose_new_tables = false`.
- `supabase/migrations/20261003114608_revoke_public_default_privileges.sql`: removes the postgres-role default privileges that gave anon/authenticated full access to new tables, sequences and functions in `public` (AD-2 no default exposure; service_role and supabase_admin defaults untouched). Applied to hosted under the same version.
- `supabase/tests/platform_status_test.sql` (29 pgTAP assertions, incl. a new public table/function getting no client privileges) plus `supabase/tests/api_smoke.sh` (`npm run db:smoke`): pgTAP cannot see PostgREST's exposed schemas, so the "app not reachable through PostgREST" and HTTP write-denial evidence is an HTTP check against the running stack.
- `apps/mobile` (`zm.bickafue.bic_kafue_mobile`): `lib/platform_status/` = domain model + `PlatformStatusRepository` port, `SupabasePlatformStatusRepository` adapter (reads `api.platform_status` with SDK auto-retry off and a 10 s abort signal on the single request; `ClientException`/abort/timeout → "Couldn't reach the server", PostgREST/payload errors → "The server couldn't provide the platform status"), and a `StatefulWidget` screen with loading/data/empty/error states. Reload/retry always re-requests and clears the old value. `http` 1.6.0 is a direct dependency (already transitive) for the `ClientException` type. Supabase auth is in-memory with deep-link detection off (no sign-in in the tracer). Release manifest gained `INTERNET` (absent from the `--empty` template's main manifest). 14 tests: 6 widget, 6 adapter (MockClient: `Accept-Profile: api`, fresh request per fetch, ClientException and abort-timeout → unreachable, PostgREST error → rejected), 2 model.
- `trials/staff_web` (`staff_web_trial`): copy of the same read/states, 6 widget tests; README marks it disposable pending Q10.
- `.github/workflows/ci.yml`: `db` job (`npm ci`, `supabase start` minus unused services, `db:test`, `db:smoke`); `flutter` job (Flutter 3.47.6 asserted, `pub get --enforce-lockfile`, analyze, test for both apps, `build web` for the trial).
- `docs/runbooks/tracer.md`, root `package.json` (supabase 2.119.0 + `db:start|stop|reset|test|smoke`), `.gitignore`.

**Verification (this session)**
- `npm run db:start && npm run db:test` → 29/29 PASS; `npm run db:smoke` → 6/6 ok (api 200 with `is_synthetic: true`; `app` and `public` 406 PGRST106; anon POST/PATCH/DELETE 401).
- Both Flutter apps: `flutter analyze` clean, `flutter test` green, `flutter build web` ok — re-run from a copy holding only tracked + non-ignored files with `--enforce-lockfile` (clean-checkout proxy). CI itself has not run on GitHub yet.
- Linux desktop (Xvfb) and web trial (headless Chromium) against the local stack: initial value → SQL update → Reload shows new value → Kong stopped → error panel → Kong started → **Try again** recovers. Screenshots: `evidence-1.1/linux-local-*.png`, `evidence-1.1/web-local-*.png`; unreachable URL: `evidence-1.1/linux-unreachable-url.png`.
- Hosted `tmurpotfluignacfueki`: migrations applied via connector (versions 20261003112319, 20261003114608; history matches local), synthetic row seeded, grants confirmed (anon/authenticated SELECT only), security advisors: no lints.
- Hosted, after the owner exposed only `api` (app/public → PGRST106), on both the Linux desktop app (Xvfb) and the web trial (headless Chromium): (1) first load shows the hosted synthetic row; (2) row changed with the connector's `execute_sql` (synthetic 'degraded' message per client) → Reload shows it; (3) network to the host blocked → "Couldn't reach the server"; row changed again to a distinct "recovery check … after Try again" message, block lifted → **Try again** shows that new value, proving a fresh request. Linux blocking: the app ran as a separate `tracer` user with an `iptables -m owner` REJECT rule (removed afterwards); web blocking: Playwright `page.route(... abort('internetdisconnected'))`, then unroute. Chromium needed the agent-proxy CA added to the root NSS store to reach the hosted host. Screenshots: `evidence-1.1/linux-hosted-*.png`, `evidence-1.1/web-hosted-*.png`. The seeded row was restored on hosted afterwards (12:02 UTC).
- Android: `flutter build apk --release` against the hosted project → `app-release.apk` (debug-signed, minSdk 24, targetSdk 36, `INTERNET` present), rebuilt after the adapter retry/abort fix (sha256 `612c9726…`).

**Open / owner actions**
- Hosted Data API now exposes only `api` (owner dashboard change done); hosted path evidenced above.
- **Owner gate still open:** install the APK on an Android phone; check the hosted value and airplane-mode error → **Try again**.
- Hosted HTTP write-denial was not probed from this session (local pgTAP + smoke cover the same migration).
- iOS not built (no tooling); Android emulator unavailable (no KVM).

## Review Triage Log

**Pass 1 (quick lens), 2026-10-03.** Verdicts: high 0 · medium 2 · low 3 · false 1 · maybe-false 1 · rejected (owner gate) 1.

| # | Finding | Verdict | Route | Evidence / action |
|---|---------|---------|-------|-------------------|
| 1 | Network-failure test exits through `TimeoutException`, so the `ClientException` mapping is untested | medium | patch (grouped with #2) | postgrest 2.9.1 `_executeWithRetry` retries GETs with 1, 2 and 4 s back-off, and the test's 2 s timeout fires first. Fix: disable SDK retry, use an abort-signal bound, and add a hang test. |
| 2 | `.timeout()` does not cancel the request; SDK retries pile up behind Try again | medium | patch (same root cause as #1) | `Future.timeout` only stops the UI from waiting, while postgrest keeps retrying in the background (`retry()` and `abortSignal()` exist in 2.9.1). Fix: per-request `retry(enabled: false)` plus `abortSignal`. |
| 3 | AC1: CI unproven; the reduced `-x` stack was never run | false | reject | I re-ran the exact CI `supabase start -x …` command locally, then `db:test` (24/24) and `db:smoke` (6/6). Both pass. GitHub CI runs on the PR push. |
| 4 | Hosted success path, hosted write denial and the web trial against hosted are not evidenced | real, blocked on owner | reject (planned owner gate) | The connector cannot expose `api`. The plan names this as an owner dashboard step, and the APK test as the owner gate. Tracked as open in the summary, not a code defect. |
| 5 | The web "recovered" screenshot is byte-identical to the "after reload" one | maybe-false (low if true) | reject | The same row and the same rendering produce identical pixels, which is plausible. The Linux pair differs. Settling it needs a recapture with a changed value before recovery. A low-value evidence issue. |
| 6 | Runbook step 2: the second `cd` fails when pasted | low | patch | `cd trials/staff_web` runs from inside `apps/mobile`. Direct correction. |
| 7 | Hosted `public` default ACLs give anon/authenticated full table, sequence and function privileges | medium | patch | Confirmed with `pg_default_acl` on `tmurpotfluignacfueki`. AD-2 requires revoking default table exposure. Fix: a new migration revoking the postgres-role defaults in `public`, applied to local and hosted, plus a pgTAP assertion. |
| 8 | Matrix "Write attempt": no `authenticated` DELETE through api and no `anon` INSERT into app assertions | low | patch | pgTAP lacks those two cases. Authenticated HTTP needs an auth session and is left to entry 1.2/1.4. Add the two SQL assertions. |

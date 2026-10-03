---
title: 'Run the mobile and trial-web tracer through Supabase'
type: 'feature'
ticket: '1'
created: '2026-10-03'
status: 'draft'
baseline_revision: ''
route: 'full'
route_source: 'auto'
review: ''
review_source: ''
lenses_ran: []
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
- [ ] `.gitignore` -- ignore `_bmad/render/`, Flutter build outputs and `supabase/.temp` -- keeps the tree clean.
- [ ] `package.json` -- pin the `supabase` CLI 2.119.0 as a devDependency, with scripts `db:start`, `db:test` and `db:reset` -- reproducible CLI version.
- [ ] `supabase/config.toml` -- create with `supabase init`, then set `[api] schemas = ["api"]` and `extra_search_path = ["api"]` -- only `api` is exposed.
- [ ] `supabase/migrations/<ts>_platform_status_tracer.sql` -- create schemas `app` and `api`, plus table `app.platform_status`:
  - columns: id smallint PK, `check (id = 1)`, status text, message text, is_synthetic bool, updated_at timestamptz
  - RLS enabled, with a select-only policy
  - view `api.platform_status` with `security_invoker = true`
  - explicit USAGE and SELECT grants to anon and authenticated
  - no other privileges

  Rationale: AD-2 read path.
- [ ] `supabase/seed.sql` -- one synthetic row -- data for the tracer.
- [ ] `supabase/tests/platform_status_test.sql` -- pgTAP: anon can read through `api`, anon and authenticated cannot write, and `app` is not reachable through PostgREST -- permission evidence.
- [ ] `apps/mobile/` -- `flutter create --org zm.bickafue --platforms android,ios,linux --empty` -- native client. Add:
  - `lib/platform_status/` with a repository interface, a Supabase adapter and a screen with loading, data, empty and error+retry states
  - widget tests using a fake repository
- [ ] `trials/staff_web/` -- `flutter create --platforms web --empty` -- disposable trial (`apps/staff` waits for Q10). A minimal copy of the same read and states, plus a widget test. Its README marks it disposable.
- [ ] `.github/workflows/ci.yml` -- `db` job (`supabase start`, `db test`) and `flutter` job (pinned 3.47.6: `pub get --enforce-lockfile`, `analyze` and `test` in both apps, `build web` for the trial) -- minimum smoke check.
- [ ] Hosted project -- apply the same migration with the Supabase connector, seed the synthetic row, add `api` to the exposed schemas (the connector cannot change API settings, so this is an owner dashboard step if needed), and check the security advisors -- remote proof.
- [ ] `docs/runbooks/tracer.md` -- how to start the local stack, run both clients with `--dart-define`, change the status with SQL, and simulate a failure.

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

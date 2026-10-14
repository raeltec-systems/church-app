# Evidence: story 1.12, platform verification from checkout through isolated recovery

Recorded 2026-10-03, 16:54–17:05 UTC. Everything ran from one clean checkout of the integration branch `ccr-93e730dd-89lbvg` at `2b3ad1824ea255bf2b59b196c239de2d25f4fdcf`, in a fresh worktree with no `node_modules` and no build outputs. All data is synthetic.

What is not in these files:
- **The publishable key.** It went in only through `--dart-define` and environment variables at run time, and build logs show it as `sb_publishable_<redacted>`.
- **Secrets.** No secret key, service-role key, DB password, JWT or system credential appears here. A grep of this folder for the key prefix finds nothing.

Hosted staging means `bic-kafue-platform-test` (`tmurpotfluignacfueki`), reached through the Supabase MCP. Every MCP call was read-only: `list_migrations`, `get_advisors`, and `execute_sql` running only `SELECT` statements or `DO` blocks that can only raise. Nothing was applied, set or registered on any hosted project.

## Verdicts

**Totals:** 19 pass, 7 blocked-on-owner, 0 fail.

| # | Scenario | Verdict | Evidence |
|---|---|---|---|
| 1 | Clean checkout: `npm ci`, then pinned toolchain checks: Flutter 3.47.6, Dart 3.13.5, Supabase CLI 2.119.0 | pass | `local/flutter/toolchain.txt` |
| 2 | Staff web (Flutter Web) release build for staging (`--no-web-resources-cdn`, defines only) | pass | `builds/staff-web-build.txt` |
| 3 | Staff web bundle secret scan, seal (40 files, tree `e48857ef…`), verify for staging, and verify refused for production | pass | `builds/staff-web-bundle-scan.txt`, `builds/staff-web-seal.txt`, `builds/staff-web-verify-staging.txt`, `builds/staff-web-verify-as-production-refused.txt`, `builds/staff-web-staging.{manifest.json,SHA256SUMS}` |
| 4 | The sealed staff web build in headless Chromium 141 against staging. It showed the hosted value (`operational`, synthetic). With network blocked it showed "Couldn't reach the server" and **Try again**. After **Try again** it recovered with the hosted value. | pass | `browser/tracer-log.jsonl`, `browser/1-initial-hosted.png`, `browser/2-network-blocked.png`, `browser/3-recovered.png`, `browser/tracer.mjs` |
| 5 | Android APK release build for staging (debug-signed, as in 1.1; 52.7 MB; sha256 `78b23a04…`). Secret scan of the unzipped APK: clean, 368 files. The publishable key is present only in `libapp.so`. | pass | `builds/mobile-apk-build.txt`, `builds/mobile-apk-checksum.txt`, `builds/mobile-apk-bundle-scan.txt`, `builds/mobile-apk-key-present.txt` |
| 6 | Native Android device run of this APK: hosted value, airplane mode, recovery | **blocked-on-owner** | There is no KVM or emulator here, and no emulator is offered as native or FCM evidence. The owner's earlier phone run of the 1.1 APK is in `../evidence-1.1/android-hosted-*.jpg`. |
| 7 | Native iOS run | **blocked-on-owner** | Needs Apple signing and hardware. |
| 8 | `npm run db:test` after `supabase db reset` from this checkout: 5 files, 357 tests | pass | `local/supabase-db-reset.txt`, `local/npm-db-test.txt` |
| 9 | `npm run db:smoke`. See the breakdown below the table. | pass | `local/npm-db-smoke.txt` |
| 10 | `npm run contracts:test` (226/226) plus the Dart contracts: `dart analyze --fatal-infos`, `dart test` on the VM (243), `dart test -p chrome` (242; one file is `@TestOn('vm')`) | pass | `local/npm-contracts-test.txt`, `local/flutter/contracts-*.txt` |
| 11 | `ci:policy-test` (48/48), `env:check` (3 configs valid), `ci:migrations --base origin/main` (8 ordered, 6 new, none destructive), `ci:secrets` (repo mode, clean) | pass | `local/npm-ci-policy-test.txt`, `local/npm-env-check.txt`, `local/npm-ci-migrations-base-origin-main.txt`, `local/npm-ci-secrets.txt` |
| 12 | `npm run recovery:rehearse`, including the incomplete-journal denial. See the breakdown below the table. | pass | `local/npm-recovery-rehearse.txt`, `local/recovery-scenarios-summary.json` |
| 13 | Auth harness: `node --test` (22/22) and `scan-evidence.sh` (clean over evidence-1.2, evidence-1.3 and the harness) | pass | `local/auth-harness-node-test.txt`, `local/auth-harness-scan-evidence.txt` |
| 14 | `flutter pub get --enforce-lockfile`, `analyze` and `test`. Analyze reported no issues for any package. Test counts: design_system 14, client_core 72, mobile 13, staff 13, trials/staff_web 35. | pass | `local/flutter/summary.txt`, `local/flutter/*-{analyze,test}.txt` |
| 15 | Staging environment marker is `staging`. `private_access`, `outbound_sending`, `q1`, `q4`, `q12` and `ops_*` are all closed, and alerting is disabled. Q2 and Q9 are open only through their labelled non-production fixtures. | pass | `staging/mcp-readonly-checks.json` |
| 16 | Staging migration history vs local. 7 of 8 migrations match. `20261003161000_recovery_journal` is pending, which was the expected drift. | **blocked-on-owner** | `staging/hosted-migrations.json`, `staging/migration-drift.txt` (`pending for staging: 20261003161000_recovery_journal`, exit 1 under `--require-synced`) |
| 17 | `verify-hosted.sql` run against staging | **blocked-on-owner** (it refuses correctly) | `staging/mcp-readonly-checks.json`: the run with staging expected refuses with `app.rcv_serving_hold() is missing (story 1.10 migration not applied)`. This follows from row 16. With production expected, it refuses with `database is marked staging, expected production`. |
| 18 | Staging security advisors | pass | `staging/mcp-readonly-checks.json`. There are 26 INFO `rls_enabled_no_policy` findings, all on `app.*` tables, which are deny-all and unexposed by design. One pre-existing WARN `auth_leaked_password_protection` is recorded and was not changed. |
| 19 | Anon REST exposure on staging (publishable key only) | pass | `staging/anon-rest-exposure.jsonl`. `api.platform_status` returns 200. Every `app` table and RPC returns 406 `PGRST106`, as do `public` and `graphql_public` ("Only the following schemas are exposed: api"). The OpenAPI root returns 401 for a publishable key. |
| 20 | 1.9 system endpoint matrix against staging | pass (14/14) | `staging/system-matrix.jsonl`, `staging/system-matrix-audit.json`. See the notes below the table. |
| 21 | 1.4 command race and idempotency smoke against staging | pass locally; there is no staging mode | `supabase/tests/command_api_smoke.sh` needs psql and the local secret key, so it is local-only by design. It passed in row 9. A staging run would need new secrets, so it was not attempted. |
| 22 | Unapproved production policies block deployment activation. See the breakdown below the table. | pass | `gates/production-activation-refusals.txt`, `gates/local-production-marker-gates.txt`, `gates/local-production-gate-opened-refused.txt`, `builds/staff-web-verify-as-production-refused.txt` |
| 23 | `promote.yml` run on GitHub: preflight, production environment protection, deploy | **blocked-on-owner** | The GitHub `staging` and `production` environments, their secrets and the production project do not exist yet (1.8 plan `blocked_reason`). The preflight's local equivalents pass or refuse as shown in rows 11 and 22. |
| 24 | The failed phone-provider assumption blocks identity activation | **blocked-on-owner** (it blocks correctly) | See the breakdown below the table. |
| 25 | Repo and bundle secret scans rerun after this evidence was written | pass | `local/npm-ci-secrets-final.txt` (repo mode, run after this evidence was committed), `local/bundle-scan-final.txt` (staff web plus unzipped APK, 408 files, clean), `local/auth-harness-scan-evidence-final.txt` |
| 26 | Owner confirmation of the recorded evidence, and the outstanding 1.6 browser spot-check | **blocked-on-owner** | — |

**Row 9, `npm run db:smoke`.** The run covered:
- 56 `ok` checks with 0 `FAIL`;
- the 1.4 command checks: duplicates, changed-payload replay, stale revisions, simultaneous writes, rollback, malformed envelopes, and revocation racing an in-flight command;
- 223 shared fixture cases checked against SQL;
- the 15-case local system-route matrix.

**Row 12, `npm run recovery:rehearse`.** Every restore first landed `restored_held` with both gates closed.
- The `absent`, `gap`, `tampered`, `unsealed` and `early_seal` journals were refused. Each stayed `held` with `private_access` and `outbound_sending` closed, even under a rolled-back owner approval.
- Only `complete` reconciled. Its subject's access was revoked and the restored object removed.
- The summary line reports `problems: []`.

**Row 20, the system endpoint matrix.**
- It used the existing story 1.9 staging credential. That credential was checked by digest before the run: registered, unexpired (expires 2026-10-05 15:40 UTC), unrevoked, and its principal is enabled.
- No credential was minted into `.ops-state` or registered for this run.
- The two wrong-environment cases send in-memory strings that the tool generates and never stores or registers.
- The user-session case was skipped because the 1.9 synthetic user is banned. It is covered locally in row 9.
- 12 content-free audit rows were written (ids 39–50).

**Row 22, production activation refusals.** Each of these refuses:
- `environments.mjs target production` with no ref;
- `target production tmurpotfluignacfueki`, because that ref belongs to another environment;
- `recipients production …`, because sending is disabled;
- `package-web verify --env production` on the staging artifact.

On the local stack under a production marker (rolled back):
- all 9 gates are closed, including Q2 and Q9, whose fixtures do not resolve in production;
- `verify-hosted.sql` passes only while they stay closed;
- once `private_access` is opened, `verify-hosted.sql` refuses with `private_access gate is open in production`.

**Row 24, the phone-provider gate.** Phone sign-in is off on both projects, and every identity path that depends on it is held:
- `gates/auth-test-provider-settings.json` shows `external.phone=false` on the auth-test project.
- `gates/staging-provider-settings.json` shows the same on staging.
- Both were read with read-only `GET /auth/v1/settings` calls.
- The `q1_auth_recovery` gate is unresolved and closed on staging (`staging/mcp-readonly-checks.json`).
- The 1.2 plan is `blocked`.
- Identity tracer entry 1 lists `after = ["1.2", "1.7"]` (`../../epic-identity-and-scoped-access/tickets.toml`), so it cannot start until the 1.2 phone track has been shown to pass.
- No SMS provider, hook, test OTP or phone setting was touched.

## Findings

- **Genuine defects found: none.** No code, test, contract or policy was changed by this story.
- **Observation (not changed; review item).** `node tools/env/environments.mjs target production szfyfezfvxyuvovnnakr` is accepted, exit 0 (`gates/production-activation-refusals.txt`).
  - The guard rejects only refs that belong to a configured environment, and the auth-test project is not one.
  - In `promote.yml`, a wrong production `SUPABASE_PROJECT_REF` would still need the owner to set it on the protected environment and to pass the required-reviewer approval.
  - However, `verify-hosted` runs only *after* `db push`.
  - A cheap hardening would be to add the auth-test ref to a denylist in the environment config. That file belongs to the 1.8 lane, so it is left for review rather than changed here.
- **Note.** The 1.4 plan's `blocked_reason` is stale. Staging now records `20261003131021_command_foundation_hardening`, per `staging/hosted-migrations.json`.

## Owner actions

1. **1.2 phone provider decision.** The dashboard requires an SMS provider before phone signup can be enabled.
   - Decide the phone track.
   - Until then, identity tracer entry 1 stays blocked.
   - Never configure SMS.
2. **Staging apply of `20261003161000_recovery_journal`.**
   - Approve the `apply_migration` named `recovery_journal` on `tmurpotfluignacfueki`, with the exact local file contents. The Supabase connector asks for confirmation because of the in-function auth session delete.
   - Then rerun `list_migrations` and `verify-hosted.sql` with `expected_env=staging`. Both should pass, with no recovery hold.
3. **Native Android run.**
   - Install the APK built from this commit on a real phone. Run `flutter build apk --release` with the two defines, as in `builds/mobile-apk-build.txt`.
   - Confirm the hosted value, then airplane mode ("Couldn't reach the server" with **Try again**), then recovery.
   - FCM is not part of this baseline and no emulator evidence is claimed.
4. **iOS.** Provide Apple signing and a device or Mac when available.
5. **GitHub environments and the production project.** These are 1.8 owner steps A–C in `docs/runbooks/environments-and-promotion.md`.
6. **Review and confirm this evidence**, together with the 1.6 owner spot-check: Firefox, Edge, Safari, Android Chrome and real screen readers.

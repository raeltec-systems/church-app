# Validation ledger — 30 October 2026

## Scope and result

Every safely supported check from `tools/ci/run-local-ci.sh` and `.github/workflows/ci.yml` completed successfully in this workspace. The local database, real HTTP and physical-device checks below remain **unrun here**. This is automated regression/build evidence, not completed Epic 6 owner acceptance or permission to deploy.

The baseline is `c96cd562b2650c37f5d3d879cb12891419700139` (latest main when this task began). Runs record their individual Git HEAD, command, directory, UTC times and actual exit code in the adjacent JSON and raw log. Most Flutter checks used documentation checkpoint `66b1562e13abe939e9d328fa9f59fd35e6c3ea25`. At that checkpoint the tracked `apps`, `packages`, `supabase`, `tools` and root npm manifest/lock objects were identical to baseline; see [source-equivalence.json](source-equivalence.json). Subsequent mobile/staff README corrections are documentation changes. Runtime sources, dependencies and configuration are unchanged by this reconciliation, and this validation agent changed no runtime source or package lock.

Environment: Linux x86_64; Node **22.23.4**; pinned Supabase CLI **2.119.0**; Flutter **3.47.6**, Dart **3.13.5**; Chrome for Testing **151.0.7922.34**. [toolchain.json](toolchain.json) records exact sources, checksums and environment recovery. Dependency resolution used existing lockfiles with `--enforce-lockfile` for Dart/Flutter. `npm ci` completed with exit 0. No dependency upgrade was performed.

## Complete automated results

All results in this table have exit 0 and, where applicable, the final suite/build success marker. Counts are individual tests, not merely test files.

| Check | Result | Record |
| --- | --- | --- |
| Policy tool tests | 56 passed, 0 failed | [policy.json](policy.json) |
| Environment configs | 3 configs valid | [environment.json](environment.json) |
| Migration policy vs `origin/main` | 101 ordered/unique/non-destructive; 0 new | [migrations-retry.json](migrations-retry.json) |
| Tracked-file secret scan | Clean, 2,148 tracked files at that run's HEAD | [secrets-retry.json](secrets-retry.json) |
| Edge Function import boundary | Passed | [imports.json](imports.json) |
| TypeScript contract fixtures | 267 passed, 0 failed | [contracts-retry.json](contracts-retry.json) |
| Harness, identity E2E tool units, Edge Functions and shared modules | 410 passed, 0 failed; offline unit suite | [harness.json](harness.json) |
| Content asset unit subset | 34 passed, 0 failed; included in the 410 above | [content-assets-retry.json](content-assets-retry.json) |
| Existing CI evidence scans | All 35 invocations passed | [evidence-scans.json](evidence-scans.json) |
| Dart contracts, VM | 284 passed, 0 failed | [contracts-vm.json](contracts-vm.json) |
| Dart contracts, Chrome/dart2js | 283 passed, 0 failed | [contracts-chrome.json](contracts-chrome.json) |
| Design system | 20 passed, 0 failed | [design-system-test.json](design-system-test.json) |
| Client core, full suite | 1,169 passed, 0 failed | [client-core-test-retry.json](client-core-test-retry.json) |
| Mobile | 115 passed, 0 failed; identical isolated source copy | [mobile-test.json](mobile-test.json), [mobile-copy.json](mobile-copy.json) |
| Staff | 63 passed, 0 failed | [staff-test.json](staff-test.json) |
| Staff framework trial | 35 passed, 0 failed | [trial-test.json](trial-test.json) |
| Duties with `TZ=America/New_York` on Linux | 224 passed, 0 failed; reruns a core subset | [timezone-duties.json](timezone-duties.json) |
| Follow-ups with `TZ=America/New_York` on Linux | 37 passed, 0 failed; reruns a core subset | [timezone-followups.json](timezone-followups.json) |
| Staff web build without CDN resources | Complete; `Built build/web` | [staff-web-build-retry.json](staff-web-build-retry.json) |
| Staff framework trial web build | Complete; `Built build/web` | [trial-web-build.json](trial-web-build.json) |
| Both generated web bundles, secret scan | Clean, 91 files | [bundle-scan.json](bundle-scan.json) |

Locked pub resolution and analysis completed for all six packages/apps: Dart contracts, design system, client core, mobile, staff and the staff framework trial. Dart used `dart analyze --fatal-infos`; every Flutter target used `flutter analyze`. Every analysis reported no issues. The corresponding `*-pub.json` and `*-analyze.json` records preserve exact commands and logs.

These counts overlap: the content-assets run is part of the harness suite, timezone runs repeat core tests, and VM/Chrome exercise shared contracts on different runtimes. Do not add them into a count of distinct accepted scenarios. The Flutter tests include permissions, stale response ordering, offline reads and failure recovery through adapters; they still do not establish live backend or physical-device acceptance.

Both web builds completed their Wasm dry run and warned that `packages/cupertino_icons/CupertinoIcons` was expected while only `MaterialIcons` was found. No missing icon defect was demonstrated. The app and framework-trial source do not directly reference that family. Dependency update notices report available newer versions; existing pins were preserved.

The generated web artifacts remain local under `apps/staff/build/web` and `trials/staff_web/build/web`. They were scanned, not published or deployed. The old staff `browser_smoke.mjs` targets the superseded signed-out tracer UI and requires a local API; it was not treated as a current Epic 6 acceptance check.

## Checks that remain unrun or skipped

| Check | Why this workspace cannot establish it | Required follow-up |
| --- | --- | --- |
| Fresh local Supabase, full pgTAP, Data API smoke and database/object restore rehearsal | Neither Docker nor Podman nor their standard engine socket is present. No database reset was attempted. | Run the isolated local sequence in [local-validation.md](local-validation.md). |
| G1 real HTTP RSVP contention | Needs full local Auth/PostgREST/Storage/Edge runtime. Offline harness tests are not HTTP concurrency evidence. | Run `content-event-rsvp.mjs`; expect 13/13 including five-client, one-seat races. |
| G2 scheduler/worker/Storage retention | Needs disposable local Supabase with cron and Edge runtime. | Run `content-retention.mjs`; expect 6/6. |
| Actual two-session sermon-from-duty locking | No PostgreSQL runtime; the existing stale-first-read injection is single-session evidence. | Capture separate-session blocking and convergence using the owner walkthrough. |
| Android/iOS dialler/player/calendar handoff, offline relaunch, push and printed-hymn checks | No attached phones, Android SDK/emulator, Xcode or printed source book. | Follow [content-owner-walkthrough.md](../../../../docs/runbooks/content-owner-walkthrough.md), recording OS/app commit and sanitized outcomes. |
| CLI staging migration drift | `npm run ci:drift:staging` exits 0 but explicitly **skips** when `SUPABASE_ACCESS_TOKEN` is absent. | Do not infer parity from this result. See the separately captured staging read-only reconciliation. |

[blocked-checks.json](blocked-checks.json) preserves the blocked commands and reasons. [local-validation.md](local-validation.md) gives the concrete local setup, safe fixture boundaries, harness commands, cleanup and evidence handling. A successful historical hosted main CI run is separately recorded in [hosted-main-ci-summary.json](hosted-main-ci-summary.json); it is not a new local database run or owner acceptance.

## Interrupted attempts and recovery

- Default sandbox subprocess/network/cache restrictions prevented useful migration/secret/CLI checks. Normal execution escalation allowed the authorized read-only checks and dependency downloads. The `*-retry` records are the definitive results. Initial Node contract/content-asset output reported only file-level TAP successes; full assertion-level suites were rerun and recorded.
- Official pinned Flutter archive discovery returned 404, so the exact official Git tag was used. Slow official Dart/web archives were downloaded over the existing TLS/proxy route with complete size/MD5 verification; standard bootstrap/precache then completed. The Chromium CDN returned HTML, so the matching official Google archive was used. No silent version substitution, proxy/TLS change or application-source change was made.
- Initial concurrent core tests/web builds met resource pressure in an 8 GiB container. A kernel OOM kill counter of 1 was observed, but its cause was not independently attributed. The core run stopped progressing without a final success marker. Only validation-owned process trees were stopped. Although Flutter returned exit 0 when interrupted, those records are explicitly **skipped/incomplete** and are not passing evidence.
- The full core suite was rerun successfully with `--concurrency=2`; mobile and timezone suites used the same limit. The incomplete staff build was rerun sequentially and finished. The framework-trial build had already completed and was not repeated. The final successful retry supersedes, but does not erase, each incomplete log.
- Mobile used a source-identical isolated copy so Flutter-generated Linux plugin files could not disturb the shared checkout. The active checkout's generated files were never reset or changed by this validation agent.

## Evidence integrity

The current reconciliation directory is scanned for credential patterns before its raw logs are compressed. The completed result is [new-evidence-scan.json](new-evidence-scan.json). The machine-readable table is [validation-ledger.json](validation-ledger.json).

Every full raw log is retained. Logs larger than 150,000 bytes, or containing original terminal trailing padding that would fail textual git diff checks, use deterministic gzip (no timestamp or original filename in the gzip header); adjacent JSON records point to the compressed file. Original log bytes and assertions are never trimmed or changed. [log-manifest.json](log-manifest.json) records each stored file's bytes/SHA256 and the original raw bytes/SHA256. To read a compressed log, use `gzip -dc <path>.log.gz`; decompression reproduces the complete original bytes. No active log was compressed.

Owner acceptance, migration-history repair, pilot sign-off and deployment remain separate gates. This validation work performs none of them.

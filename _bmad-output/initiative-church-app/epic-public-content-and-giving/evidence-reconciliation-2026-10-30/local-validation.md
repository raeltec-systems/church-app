# Reproduce the remaining local validation

This is a validation procedure for a **disposable local database**, not permission to deploy, change a hosted policy gate, or notify church members. The candidate source SHA and each command's result must accompany returned evidence. Device acceptance and the normal member/leader walkthrough are separate.

## 1. Prepare an isolated checkout and the pinned toolchain

Use Bash on Linux/macOS, WSL, or Git Bash on Windows. Docker Desktop/Engine must be running. Use a separate checkout so the aggregate runner cannot reset another developer's local database or restore their generated Flutter files. No other church-app checkout may use its `supabase_db_church-app` stack while these checks run.

```bash
git clone --single-branch --branch acceptance/epic-6-reconcile-epic-7-plan \
  https://github.com/raeltec-systems/church-app.git church-app-acceptance
cd church-app-acceptance
git fetch origin main:refs/remotes/origin/main
git status --short
git rev-parse HEAD
node --version
flutter --version
docker version
npm ci
npx --no-install supabase --version
```

Expected: a clean checkout, Node **22.x**, Flutter **3.47.6**, Dart **3.13.5**, a reachable Docker engine, and Supabase CLI **2.119.0**. Keep the locked dependencies; do not upgrade them to make a check run. A running Docker client without a reachable engine is insufficient.

The `origin/main` comparison uses the fetched main from this checkout. Before a release, record the selected candidate SHA and freshly inspect main; do not silently validate a different candidate.

## 2. Full CI-equivalent local validation

From the repository root:

```bash
bash tools/ci/run-local-ci.sh /tmp/church-app-ci-results.txt --base origin/main
cat /tmp/church-app-ci-results.txt
```

The script starts and **resets the local database**, runs pgTAP/API smoke/restore checks, Node checks, locked Dart/Flutter setup, analysis and tests, timezone checks, both web builds and the bundle scan. It also restores generated `apps/mobile/linux/flutter` files. It deliberately continues after failures: a final `done` line is not a pass. Read every `PASS`, `FAIL` and `UNRUN`, then inspect its corresponding log in `/tmp/ci-logs/`.

Keep raw start/status logs private: local Supabase tooling can print local keys. Return the result summary and a credential-scanned, redacted copy of relevant failure evidence, not a raw environment or key dump.

On a constrained machine, run the same package commands sequentially and use `flutter test --concurrency=2`. A test pass requires its final **All tests passed!** marker; a web-build pass requires **Built build/web**, as well as exit 0. In this session Flutter handled an interrupted command with exit 0, so the exit code alone was insufficient.

For native non-Lusaka behavior, run the following on **Linux/WSL with the Linux Flutter SDK**, or rely on the corresponding Ubuntu CI job. Setting `TZ` in a Windows shell does not independently establish that Windows Dart changed its native timezone.

```bash
(cd packages/client_core && TZ=America/New_York flutter test test/duties --concurrency=2)
(cd packages/client_core && TZ=America/New_York flutter test test/followups --concurrency=2)
```

## 3. Actual HTTP RSVP race and scheduler/Storage retention

These integrations are separate from the offline `*.test.mjs` tests. Run on the candidate, with Docker running and nobody else using the disposable local stack. The stop/start below ensures the full set of services after the aggregate runner used a reduced stack; it discards only this explicitly disposable local stack. The harness accepts only `http://127.0.0.1:54321`; do not substitute staging or a LAN URL.

```bash
mkdir -p /tmp/church-epic6-evidence
git rev-parse HEAD > /tmp/church-epic6-evidence/head.txt
(
  set -e
  npx supabase stop --no-backup
  npx supabase start
  npx supabase db reset --local
  npx supabase test db
  node --test tools/identity-e2e/content-event-rsvp.test.mjs tools/identity-e2e/content-retention.test.mjs
  node tools/auth-harness/local-phone-auth.mjs on
  trap 'node tools/auth-harness/local-phone-auth.mjs off' EXIT
  node tools/identity-e2e/content-event-rsvp.mjs \
    --evidence /tmp/church-epic6-evidence/content-event-rsvp-e2e.jsonl
  node tools/auth-harness/local-phone-auth.mjs off
  trap - EXIT
  node tools/identity-e2e/content-retention.mjs \
    --evidence /tmp/church-epic6-evidence/content-retention-e2e.jsonl
)
bash tools/auth-harness/scan-evidence.sh /tmp/church-epic6-evidence
```

The scripts obtain local keys internally from `npx supabase status -o env`; no credentials need to be invented or copied into evidence. G1 creates its own fictional identities in the reserved `+44 7700 900584–900598` range. Keep that range free of other simultaneous runs. The phone switch refuses any SMS-provider, OTP or phone-MFA configuration and changes only this project's local Auth container. If interrupted before the trap executes, run `node tools/auth-harness/local-phone-auth.mjs off` before further work.

Expected G1 result at this source version: **13/13**, including `C21-racing-members-get-exactly-one-place`. Five real signed-in HTTP clients compete for one place: exactly one succeeds and four receive Full. After the winner cancels, the remaining members race again with exactly one winner. The run also checks actual poster Storage, organizer access, member lifecycle and cleanup. This does not replace the separate two-device normal-UI race.

Expected G2 result at this source version: **6/6**. The real local scheduler invokes the notification worker and protected Content retention action; old unreferenced ready/pending objects and metadata disappear, recent and referenced objects remain, and missing/wrong triggers claim nothing. Its temporary function environment and locally minted credentials are cleaned up. Its remit is private draft retention; it is not an autonomous public-upload sweep.

Both runners clean their fixtures. They are **not** a persistent set of login accounts for the owner pilot. Use the separate normal-UI walkthrough's account/content setup for that pilot.

## 4. Focused regression evidence

The complete suites in this session included these regressions. If a future candidate changes the relevant code, these commands isolate them:

```bash
node --test supabase/functions/content-assets/*.test.mjs
(cd apps/mobile && flutter test test/offline/public_content_ordering_test.dart test/offline/public_content_cache_adapter_test.dart --concurrency=2)
(cd packages/client_core && flutter test test/content --concurrency=2)
# Requires the disposable local stack above:
npx supabase test db supabase/tests/cells_meeting_reminders_test.sql
```

The real two-session sermon-from-duty lock check remains separate. The current pgTAP injected stale-first-read test is not a two-session contention run. Preserve that distinction in the release matrix; capture the waiting transaction, the committed authority change and the denied post-wait command with no public draft side effect.

## 5. Hosted history and device evidence

`npm run ci:drift:staging` can exit 0 while explicitly **skipping** when no management credential is available. That is not proof of parity. Use the dated read-only staging evidence and the production-promotion runbook to reconcile the history and current function definitions. Do not replay a `_rows` operation solely because an old paragraph called it pending.

Android/iOS dialler return, actual YouTube/Facebook playback, push permission and receipt, offline saved text after relaunch, calendar import into the device's app, and source-book hymn comparisons require the owner walkthrough. Push builds need the Firebase configuration documented in `docs/runbooks/notifications.md`; without it the app deliberately uses the no-push adapter. iOS additionally needs the documented APNs/provisioning capability on the owner's Mac. An inbox item is not evidence that a push arrived.

Return the candidate SHA, tool/device/OS versions, date, scenario identifier, expected/observed outcome and sanitized evidence. Record **failed**, **blocked** or **not run** explicitly; do not turn any of them into a completed acceptance step.

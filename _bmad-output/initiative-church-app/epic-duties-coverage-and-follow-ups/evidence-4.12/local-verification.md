# Story 4.12 local verification (2026-10-15, after review round 1)

Worktree of story 4.12 merged with `ccr-93e730dd-89lbvg` (baseline `269acf1`). Local stack only, SYNTHETIC data, fictional numbers (+44 7700 900460-900469 pgTAP, 900480-900489 scale, 900470-900479 E2E). No hosted project, GitHub or production was touched; no SMS provider is configured. This run was repeated in full after a container restart killed the first re-verification.

| Check | Result |
|---|---|
| `npx supabase db reset` | exit 0 (migration `20261015043644_duties_lifecycle.sql`, amended in place, applied after `20261015035112`) |
| `npm run -s db:test` | PASS: 43 files, 3701 tests. `duties_lifecycle_test.sql` 122, `duties_lifecycle_scale_test.sql` 20, `duties_coverage_test.sql` 162 (review N7 restored) |
| Scale (under `statement_timeout = '8s'`) | 230 future duties, 1030 open tasks. Login hold over 230 duties 29-41 ms; removal ending 30 duties 151-230 ms; **deactivation ending 200 duties with 1030 open tasks (25 handed over, the rest pending) 1,058-1,754 ms** (asserted < 3 s); one `followups.complete_handover` step of 100 tasks 1,639-2,453 ms (asserted < 4 s); eleven steps leave no open task and no pending obligation |
| `npm run -s db:smoke` | pass (139 ok, 0 not ok) |
| `npm run -s contracts:test` (TypeScript) | 265 pass, 0 fail |
| Dart contracts (`packages/contracts/dart`, `dart test`) | 282 pass |
| E2E, every script, reset before each, one at a time | 29 scripts, all `exit=0` (`e2e-suite-summary.txt`); `duties-lifecycle` 14/14 (`duties-lifecycle-e2e.jsonl`) |
| Races (review S2) | L20: a publish raced with a deactivation: `validation_failed`, never `unavailable`. L23: a deactivation held open; the leader's revise and publish waited, then `conflict` and `validation_failed`. L24 and L25: a revise and a publish paused mid-command by a third connection while the Admin deactivated the member: both succeeded and the duty was vacated. Before the payload hand-over to the authorizer, L24 and L25 failed with `40P01` (server log) |
| Node tool tests (CI set) | 229 pass, 0 fail (`duties-lifecycle.test.mjs` 10) |
| `npm run -s ci:policy-test` | 56 pass |
| Flutter `packages/client_core` | analyze clean; 634 tests pass; `TZ=America/New_York` `test/duties` + `test/followups` + `membership_lifecycle_test.dart` 221 pass |
| Flutter `apps/staff` | analyze clean; 40 tests pass |
| Flutter `apps/mobile` | analyze clean; 55 tests pass; 55 under `TZ=America/New_York` |
| `npm run -s ci:secrets` | clean (1586 files) |
| `npm run -s ci:migrations -- --base origin/main` | 48 migrations ordered, unique and non-destructive |
| `npm run -s ci:function-imports` | ok |
| Evidence scan (`tools/auth-harness/scan-evidence.sh`, the 4.12 CI step) | clean |
| Owner registry guards | `contract_unowned_objects`, `contract_unpinned_functions`, `contract_boundary_violations`: 0 rows |
| Migration rules | ASCII only, no backslashes, no DROP, TRUNCATE or `delete from`, `search_path = ''` on every function, every new function revoked from public, anon, authenticated and service_role |

# Story 4.12 local verification (2026-10-15)

Worktree of story 4.12 merged with `ccr-93e730dd-89lbvg` (baseline `269acf1`). Local stack only, SYNTHETIC data, fictional numbers (+44 7700 900460-900469 pgTAP, 900480-900489 scale, 900470-900479 E2E). No hosted project, GitHub or production was touched; no SMS provider is configured.

| Check | Result |
|---|---|
| `npx supabase db reset` | exit 0 (migration `20261015043644_duties_lifecycle.sql` applied after `20261015035112`) |
| `npm run -s db:test` | PASS: 43 files, 3679 tests, 74 s. New: `duties_lifecycle_test.sql` 109, `duties_lifecycle_scale_test.sql` 16. Changed for 4.12: `cross_epic_contracts_test.sql`, `notifications_routing_test.sql`, `duties_reminders_test.sql`, `duties_coverage_test.sql` |
| Scale (under `statement_timeout = '8s'`) | login hold over 150 duties 18-31 ms (< 2 s); removal ending 30 duties 154-249 ms (< 2 s); deactivation ending 120 duties and handing over 130 tasks (100 owned, 30 supervised) 2,345-3,376 ms (< 6 s). Unchanged suites: coverage admin 31 days 566-892 ms; publish 200 slots 4,022-4,344 ms |
| `npm run -s db:smoke` | pass (139 ok, 0 not ok) |
| `npm run -s contracts:test` (TypeScript) | 265 pass, 0 fail |
| Dart contracts (`packages/contracts/dart`, `dart test`) | 282 pass |
| E2E, every script, reset before each, one at a time | 29 scripts; final state all `exit=0` (see `e2e-suite-summary.txt`); `duties-lifecycle` 11/11 (`duties-lifecycle-e2e.jsonl`) |
| Race (E2E L20) | a deactivation and a leader publishing a new duty for the same member at once: the publish was refused (`validation_failed`) and no future assignment of the member was left current |
| Node tool tests (CI set) | 225 pass, 0 fail (`duties-lifecycle.test.mjs` 6) |
| `npm run -s ci:policy-test` | 56 pass |
| Flutter `packages/client_core` | analyze clean; 630 tests pass (`duties_lifecycle_test.dart` 9); `TZ=America/New_York` `test/duties` + `test/followups` 202 pass |
| Flutter `apps/staff` | analyze clean; 40 tests pass |
| Flutter `apps/mobile` | analyze clean; 55 tests pass; 55 under `TZ=America/New_York` |
| `npm run -s ci:secrets` | clean (1583 files) |
| `npm run -s ci:migrations -- --base origin/main` | 48 migrations ordered, unique and non-destructive |
| `npm run -s ci:function-imports` | ok |
| Evidence scan (`tools/auth-harness/scan-evidence.sh`, the 4.12 CI step) | clean |
| Owner registry guards | `contract_unowned_objects`, `contract_unpinned_functions`, `contract_boundary_violations`: 0 rows |

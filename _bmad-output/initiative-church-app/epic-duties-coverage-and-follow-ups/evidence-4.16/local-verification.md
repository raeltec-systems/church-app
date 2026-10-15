# Story 4.16 local verification (2026-10-15, after review round 1)

Worktree of story 4.16 merged with `ccr-93e730dd-89lbvg` (baseline `4352fbb`). Local stack only, SYNTHETIC data, fictional numbers (+44 7700 900850-900859 pgTAP, 900720-900729 E2E). No hosted project, GitHub or production was touched; no SMS provider is configured; nothing was fetched, pulled or pushed.

| Check | Result |
|---|---|
| `npx supabase db reset` | exit 0 (migration `20261015180000_duties_owner_decisions.sql` applied after `20261015143102`) |
| `npm run -s db:test` | PASS: 45 files, 3845 tests. New `duties_owner_decisions_test.sql` 106; changed `duties_tracer_test.sql` 95, `duties_lifecycle_test.sql` 155, `duties_owner_operations_test.sql` 167, `membership_lifecycle_test.sql` 86, `duties_revisions_test.sql` 93 (unchanged count) |
| Timing (under `statement_timeout = '8s'`) | one event change flagging 63 linked duties and queueing their notices: 96-131 ms; the leader board with 206 duties in a department (200 plus the reviewed ones, review N5): 471 ms (both asserted < 3 s) |
| `npm run -s db:smoke` | pass (139 ok, 0 not ok) |
| `npm run -s contracts:test` (TypeScript) | 265 pass, 0 fail |
| Dart contracts (`packages/contracts/dart`) | 282 pass |
| E2E, every script, reset before each, one at a time | 31 scripts, every one `exit=0` in one run (`e2e-suite-summary.txt`; the 4.11 X30 and 4.13 P98 assertions changed for the new behaviour during the build); `duties-decisions` 11/11 (`duties-decisions-e2e.jsonl`) |
| Node tool tests (CI set) | 252 pass, 0 fail (`duties-decisions.test.mjs` 8) |
| `npm run -s ci:policy-test` | 56 pass |
| Flutter `packages/client_core` | analyze clean; 655 tests pass (`duties_owner_decisions_test.dart` 10); `TZ=America/New_York` `test/duties` + `test/followups` + `membership_lifecycle_test.dart` 241 pass |
| Flutter `apps/staff` | analyze clean; 40 tests pass |
| Flutter `apps/mobile` | analyze clean; 55 tests pass; 55 under `TZ=America/New_York` |
| `npm run -s ci:secrets` | clean |
| `npm run -s ci:migrations -- --base origin/main` | 50 migrations ordered, unique and non-destructive |
| `npm run -s ci:function-imports` | ok |
| Evidence scan (the 4.16 CI step) | clean |
| Owner registry guards | `contract_unowned_objects`, `contract_unpinned_functions`, `contract_boundary_violations`: 0 rows |
| Migration rules | ASCII only, no backslashes, no TRUNCATE or `delete from`, no object drop (one `drop not null`, as 20261014052239), `search_path = ''` on all 15 functions, every new function revoked from public, anon, authenticated and service_role |

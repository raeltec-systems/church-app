# Story 4.11 local verification (2026-10-15, rerun after the independent review fixes)

Worktree of story 4.11 merged with `ccr-93e730dd-89lbvg` (including 187f0d1), with the review amendments S1-S4 and N1-N10 (N9 left as is). Local stack only, SYNTHETIC data, fictional numbers (+44 7700 900160-900169 pgTAP, 900240-900249 E2E). No hosted project, GitHub or production was touched; no SMS provider is configured.

| Check | Result |
|---|---|
| `npx supabase db reset` | exit 0 (migration `20261015035112_duties_owner_operations.sql` applied after `20261015002121`) |
| `npm run -s db:test` | PASS: 41 files, 3554 tests, 64 s. New: `duties_owner_operations_test.sql` 167 (review block: S1 cross-cell put and link `not_found`, S4 accept then withdraw a cell part, N1, N2, N3, N5, N7), `duties_owner_operations_scale_test.sql` 13 |
| Scale (under `statement_timeout = '8s'`, each threshold 2,000 ms) | flag 400 duties of one event 470 ms; event links read 10 ms; leader board with 400 open reviews 356 ms; create a 10-position part over 4,000 commitments 488 ms; revise it (all ten re-asked) 534 ms; owner read 11 ms; My duties with 200 cell parts 190 ms. Unchanged 4.8 scale: publish 200 slots 4,094 ms |
| `npm run -s db:smoke` | pass; contract fixtures 260 cases against `app.contract_check`, 25 envelopes, and the 29 `source_ref` cases through the Duties owner operations' reference check (`app.duties_owner_ref_errors`) |
| `npm run -s contracts:test` (TypeScript) | 265 pass, 0 fail |
| Dart contracts (`packages/contracts/dart`, `dart test`, fixtures re-embedded) | 282 pass |
| E2E, every script, reset before each, one at a time | 28 scripts all `exit=0` (see `e2e-suite-summary.txt`); `duties-owner-ops` 13/13 (`duties-owner-ops-e2e.jsonl`) |
| Race (E2E X21) | two transactions link the same part position at once: one `linked`, one `conflict {"position_key": "linked"}`; one link row |
| Node tool tests (CI set) | 219 pass, 0 fail (`duties-owner-ops.test.mjs` 8) |
| `npm run -s ci:policy-test` | 56 pass |
| Flutter `packages/client_core` | analyze clean; 621 tests pass (`duties_owner_ops_test.dart` 10, including S2 tolerant My duties, S3 cell notices, N6 label); `TZ=America/New_York` `test/duties` + `test/followups` 193 pass |
| Flutter `apps/staff` | analyze clean; 40 tests pass |
| Flutter `apps/mobile` | analyze clean; 55 tests pass; 55 under `TZ=America/New_York` |
| `npm run -s ci:secrets` | clean (1575 files) |
| `npm run -s ci:migrations -- --base origin/main` | 47 migrations ordered, unique and non-destructive |
| `npm run -s ci:function-imports` | ok |
| Evidence scan (`tools/auth-harness/scan-evidence.sh`, the 4.11 CI step) | clean |
| Owner registry guards | `contract_unowned_objects`, `contract_unpinned_functions`, `contract_boundary_violations`: 0 rows |

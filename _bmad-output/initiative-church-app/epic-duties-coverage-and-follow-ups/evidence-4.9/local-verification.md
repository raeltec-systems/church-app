# Story 4.9 - local verification (2026-10-14, after the independent review fixes)

Synthetic data only (pgTAP +44 7700 900780-900789, E2E 900790-900799). Local stack only; nothing
applied to staging or production.

| Check | Result |
|---|---|
| `npx supabase db reset` | 0 |
| `npm run -s db:test` | PASS, 37 files, 3220 tests (`duties_coverage_test.sql` 157, `duties_coverage_scale_test.sql` 10) |
| Scale under `statement_timeout = '8s'` | leader week of 250 positions 207 ms; Pastor view of 40 departments 478 ms; Admin 31 days of a real month (4,930 positions) 914 ms (4.8 reminders scale: publish 200 slots 4,689 ms) |
| `npm run -s db:smoke` | pass (no SMS provider) |
| Every E2E (reset before each) | 26 scripts exit 0 (`e2e-suite-summary.txt`); `duties-coverage` 12/12 (`duties-coverage-e2e.jsonl`) |
| `contracts:test` / node tool tests (CI set) / `ci:policy-test` | 242/0, 206/0, 56/0 |
| Flutter | analyze clean in client_core, apps/staff, apps/mobile; tests client_core 592 (`duties_coverage_test.dart` 25), staff 39, mobile 55; `TZ=America/New_York`: client_core `test/duties` + `test/followups` 164, mobile 55 |
| `ci:secrets`, `ci:migrations -- --base origin/main`, `ci:function-imports`, evidence scan | clean |

The first build's run: a container restart interrupted the E2E run after 23 scripts; the last
three were re-run (`duties-reminders` needed its generic-text list to include the new
`duty_declined` alert, then passed 17/17). After the review fixes every script was run again, one
at a time with a reset before each (an accidental overlap of two batches was discarded and re-run
sequentially). `followups_reminders_test.sql` test 8 now reads only its own purpose's schedule
(4.9 registers `coverage_follow_up`, checked in `duties_coverage_test.sql`).
`duties_reminders_scale_test.sql` (4.8) timed out on its publish of 200 slots when the suite ran
straight after a reset: the 4.9 scale test's ANALYZE, inside its rolled-back transaction, leaves
its row counts in pg_class. The 4.8 test now analyzes its own rows before measuring; the suite then
passed after a reset four times out of four.

Owner manual checks: `docs/runbooks/duties.md`, story 4.9 (record them in `owner-check.md` here).

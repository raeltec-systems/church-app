# Story 4.9 - local verification (2026-10-14)

Synthetic data only (pgTAP +44 7700 900780-900789, E2E 900790-900799). Local stack only; nothing
applied to staging or production.

| Check | Result |
|---|---|
| `npx supabase db reset` | 0 |
| `npm run -s db:test` | PASS, 37 files, 3191 tests (`duties_coverage_test.sql` 129, `duties_coverage_scale_test.sql` 9) |
| Scale under `statement_timeout = '8s'` | leader week of 250 positions 178 ms; Pastor view of 40 departments (2,590 positions) 611 ms; Admin 31 days 665 ms |
| `npm run -s db:smoke` | pass (no SMS provider) |
| Every E2E (reset before each) | 26 scripts exit 0 (`e2e-suite-summary.txt`); `duties-coverage` 12/12 (`duties-coverage-e2e.jsonl`) |
| `contracts:test` / node tool tests (CI set) / `ci:policy-test` | 242/0, 206/0, 56/0 |
| Flutter | analyze clean in client_core, apps/staff, apps/mobile; tests client_core 590, staff 39, mobile 55; `TZ=America/New_York`: client_core `test/duties` + `test/followups` 162, mobile 55 |
| `ci:secrets`, `ci:migrations -- --base origin/main`, `ci:function-imports`, evidence scan | clean |

The container restarted during the first E2E run; the first 23 scripts had passed, and the
remaining three were re-run after the restart (`duties-reminders` needed its generic-text list to
include the new `duty_declined` alert, then passed 17/17).

Owner manual checks: `docs/runbooks/duties.md`, story 4.9 (record them in `owner-check.md` here).

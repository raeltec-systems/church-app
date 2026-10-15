# Story 4.10 - local verification (2026-10-15, after the independent review fixes)

Synthetic data only (pgTAP +44 7700 900130-900139 and 900151-900153, E2E 900140-900149). Local stack only; nothing
applied to staging or production.

| Check | Result |
|---|---|
| `npx supabase db reset` | 0 |
| `npm run -s db:test` | PASS, 39 files, 3374 tests (`duties_outcomes_test.sql` 138, `duties_outcomes_scale_test.sql` 16) |
| Scale under `statement_timeout = '8s'` | member with fifteen years of weekly duties: own history 52 ms, by their leader 41 ms, a late page 36 ms, a walk of all 8 pages with the real cursors (784 rows, no repeats) at most 56 ms a page; department of 300 members, 80 positions a day: leader's fortnight (over 1000 positions) 427 ms, 31 days (2,404 positions) 375 ms |
| `npm run -s db:smoke` | pass (no SMS provider) |
| Every E2E (reset before each, one at a time) | 27 scripts exit 0 (`e2e-suite-summary.txt`); `duties-outcomes` 11/11 (`duties-outcomes-e2e.jsonl`) |
| `contracts:test` / node tool tests (CI set) / `ci:policy-test` | 242/0, 211/0, 56/0 |
| Flutter | analyze clean in client_core, apps/staff, apps/mobile; tests client_core 611 (`duties_outcomes_test.dart` 19), staff 40, mobile 55; `TZ=America/New_York`: client_core `test/duties` + `test/followups` 183, mobile 55 |
| `ci:secrets`, `ci:migrations -- --base origin/main`, `ci:function-imports`, evidence scan | clean |

The verify line over HTTP (`duties-outcomes-e2e.jsonl`): O10 an unrecorded past duty stays
unrecorded after the worker ran; O20 record Completed, the member sees it, the response is kept;
O21 a declined assignment cannot become a No-show; O22 a cancelled accepted duty has no outcome;
O30 a correction keeps the prior value, note and actor (stale and second records refused); O31 a
leader cannot grade their own duty; O40 another member, Admin (role alone), Pastor and another
department's leader read no history and no outcome text in any Duties read; O90 codes-only audit,
no receipt text, no notification, the outcome log not reachable over the Data API.

Review S1 erasure race: `erase-race-probe.txt` (two sessions; the erase waited for the in-flight
outcome, then cleared its note).

Owner manual checks: `docs/runbooks/duties.md`, story 4.10 (record them in `owner-check.md` here).

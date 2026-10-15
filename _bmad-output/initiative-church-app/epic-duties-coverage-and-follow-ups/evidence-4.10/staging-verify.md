# Story 4.10 - staging verification (tmurpotfluignacfueki, 2026-10-15)

Synthetic data only. Merged `d81f1f2` after the independent review fixes (S1 erasure race on
outcome text; S2 outcomes window past today; nits N1-N6). PR #6 CI green on `1586909` (after the coverage-test time-of-day fix `ea2e1f2`). Local verification: db:test 39 files / 3374 tests, db:smoke, Flutter client_core 611 / staff 40 / mobile 55, all 27 E2Es exit 0 (`duties-outcomes` 11/11).

| Version | Name | How applied |
|---|---|---|
| 20261015002121 | duties_outcomes | 62 KB, split at a top-level statement boundary into two parts (lines 59-720 by Supabase MCP `execute_sql`, then 721-1151 by `apply_migration` so the version is recorded last); column-0 comment lines were left out. Local file renamed from 20261014231512. |

| Check | Result |
|---|---|
| The 296 `app`/`api` `duties_*`, `notifications_*`, `followups_*` and `identity_scoped*` functions | per-function `md5(pg_get_functiondef)` identical to local: aggregate `9d1ddf5c...`, 296 rows each side |
| Backslashes | none |
| Client grants | `anon` none; `authenticated` gains only `app`/`api.duties_outcomes` and `app`/`api.duties_member_history` |
| After the apply | 0 rows in `app.duties_outcomes` |
| Staging assertions of `tools/ci/verify-hosted.sql` (marker staging, private_access closed, alerting disabled, no recovery hold, Auth schema 20260831180000 with the reset gate trigger) | passed |
| Edge Functions | no change in 4.10 |

No owner SQL paste is needed for 4.10.

Pending:
- Rebuild the staging staff web and mobile APK before the owner's checks (batched at the end of
  the milestone).
- Owner: the story 4.10 manual checks in `docs/runbooks/duties.md`.

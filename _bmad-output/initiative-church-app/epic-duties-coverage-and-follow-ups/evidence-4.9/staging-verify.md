# Story 4.9 - staging verification (tmurpotfluignacfueki, 2026-10-14)

Synthetic data only. Merged `4a5d3e7` after the independent review fixes (B1 Admin saw the
Confirmed-by-leader reason on the board; S1 orphaned Follow-ups tasks with Q2 invalid; S2
self-targeted coverage commands; S3 supervisor = owner; nits N1-N9). PR #6 CI green on `d9c244f`. Local verification on the merged branch: db:test 37 files / 3220 tests, db:smoke, Flutter client_core 592 / staff 39 / mobile 55, all 26 E2Es exit 0 (`duties-coverage` 12/12).

| Version | Name | How applied |
|---|---|---|
| 20261014212507 | duties_coverage | 152 KB, split at top-level statement boundaries into five parts (lines 1-673, 674-1240, 1241-1718, 1719-2251 by Supabase MCP `execute_sql`, then 2252-2819 by `apply_migration` so the version is recorded last); column-0 comment lines were left out. Local file renamed from 20261014201500. |

| Check | Result |
|---|---|
| The 284 `app`/`api` `duties_*`, `notifications_*`, `followups_*` and `identity_scoped*` functions | per-function `md5(pg_get_functiondef)` identical to local: aggregate `8d6ac7d3...`, 284 rows each side |
| Backslashes | none |
| Client grants | `anon` none; `authenticated` gains only `app.duties_coverage` / `api.duties_coverage` (the other Duties and Follow-ups entry points are unchanged); no `identity_scoped*` function is client-executable |
| After the apply | 0 coverage cases |
| Staging assertions of `tools/ci/verify-hosted.sql` (marker staging, private_access closed, alerting disabled, no recovery hold, Auth schema 20260831180000 with the reset gate trigger) | passed |
| Edge Functions | no change in 4.9 |

No owner SQL paste is needed for 4.9.

Pending:
- Rebuild the staging staff web and mobile APK (`url_launcher` and the Android `tel:`/`sms:`
  queries) before the owner's checks, batched at the end of the milestone.
- Owner: the story 4.9 manual checks in `docs/runbooks/duties.md`.
- Owner question Q4: which contact fields a leader may see in production (production shows none
  until `q4_personal_data` is approved).

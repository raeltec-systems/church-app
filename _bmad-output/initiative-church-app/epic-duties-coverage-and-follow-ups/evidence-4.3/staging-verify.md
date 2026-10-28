# Story 4.3 - staging verification (tmurpotfluignacfueki, 2026-10-14)

Synthetic data only. Merged `670539e` after the independent review fixes; full local verification
on the merged branch: db:test 2463, all 20 E2Es including `duties-rota` 17/17, Flutter
client_core 483 / staff 35 / mobile 46. PR #6 CI green on `670539e`.

| Version | Name | How applied |
|---|---|---|
| 20261014023442 | duties_rota_series | Supabase MCP, in four parts because of the file size (127 KB): lines 1-1947 through `execute_sql` (three parts, split only between top-level statements), then lines 1949-2532 through `apply_migration`, which recorded the version. Local file renamed from 20261014093000. |

| Check | Result |
|---|---|
| The 73 `app`/`api` `duties_*` functions (purge stub excluded) | every per-function `md5(pg_get_functiondef)` identical to local |
| `\u` escapes | none in the migration (no backslashes at all) |
| Client grants | `anon`: no duties function; `authenticated`: the 4.1/4.2 entry points plus `app.duties_rota()` / `api.duties_rota()` only |
| `app.duties_series` | RLS on; no client table privilege |
| Reminder contracts | `duty_assigned`, `duty_cancelled`, `duty_changed`, `duty_released`, `duty_updated` |
| `tools/ci/verify-hosted.sql` (expected `staging`) | passed |
| Edge Functions | no change in 4.3 |

No owner SQL paste is needed for 4.3 (no new row deletions).

Pending (owner): the story 4.3 manual checks 1-10 in `docs/runbooks/duties.md`.

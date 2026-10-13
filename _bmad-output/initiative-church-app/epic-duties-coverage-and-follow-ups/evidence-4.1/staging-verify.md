# Story 4.1 - staging verification (tmurpotfluignacfueki, 2026-10-13)

Synthetic data only. Merged `b71fcf5` after the independent review fixes; full local verification
on the merged branch: db:test 2239, all 18 E2Es including `duties` 13/13, Flutter client_core 448 /
staff 34 / mobile 46.

| Version | Name | How applied |
|---|---|---|
| 20261013220239 | duties_department_tracer | Supabase MCP `apply_migration` (local file renamed from 20261013200000) |
| 20261013220300 | duties_department_tracer_rows | **pending: owner paste** (renamed from 20261013200100 so it sorts after the main file) |

| Check | Result |
|---|---|
| The 37 `app`/`api` `duties_*` functions (purge stub excluded) | every per-function `md5(pg_get_functiondef)` identical to local |
| `duties_text` | first applied with its `­`-style regex escapes decoded to literal characters by the MCP transport (semantically the same regex, but not ASCII); re-created through `execute replace(..., chr(92))` so the stored body is byte-identical to local |
| Edge Functions | no change in 4.1 |

Lesson for later stories: the MCP `apply_migration`/`execute_sql` path decodes `\uXXXX` in the
query text. Migrations with `\u` escapes must be re-checked by per-function md5 after applying.

Pending (owner): paste `20261013220300_duties_department_tracer_rows.sql` in the staging SQL editor
(until then a staging member deletion waits at its erase step, erasing nothing); the duties
walkthrough in `docs/runbooks/duties.md`, "Owner manual checks".

# Story 4.14 - staging verification (tmurpotfluignacfueki, 2026-10-15)

Merged `bd04c72` after the independent review (no blockers; Cells `_reload` pending fix C5b,
two runbook notes corrected, word-boundary match in `duties_comments_test.sql`).

| Version | Name | How applied |
|---|---|---|
| 20261015143102 | duties_comment_refresh | Comment-only migration, one Supabase MCP `apply_migration` call. Local file renamed from 20261015130404. |

| Check | Result |
|---|---|
| The 392 `app`/`api` `duties_*`, `notifications_*`, `followups_*`, `identity_scoped*` and `fixture*` functions | aggregate unchanged after the apply: `5fc1c65b...` (no body changed) |
| The four refreshed comments (`api.duties_command`, `app.duties_state_ok`, `api.followups_command`, `app.followups_state_ok`) | identical to local: md5 of the four comments `d0b02b6d...` on both sides; function aggregate `5fc1c65b...` on both sides |
| Grants, rows, Edge Functions | unchanged |

No owner SQL paste. The client fixes (Follow-ups and Cells pending across a reload) ship with the
next staging staff web and APK build.

Local verification on the merged branch: db:test 44 files / 3737 tests, db:smoke, Flutter
client_core 645 / staff 40 / mobile 55, all 30 E2Es exit 0. PR #6 CI green on `6ca0aee`.

# Story 4.14 - staging verification (tmurpotfluignacfueki, 2026-10-15)

Merged `bd04c72` after the independent review (no blockers; Cells `_reload` pending fix C5b,
two runbook notes corrected, word-boundary match in `duties_comments_test.sql`).

| Version | Name | How applied |
|---|---|---|
| 20261015143102 | duties_comment_refresh | Comment-only migration, one Supabase MCP `apply_migration` call. Local file renamed from 20261015130404. |

| Check | Result |
|---|---|
| The 392 `app`/`api` `duties_*`, `notifications_*`, `followups_*`, `identity_scoped*` and `fixture*` functions | aggregate unchanged after the apply: `5fc1c65b...` (no body changed) |
| The four refreshed comments (`api.duties_command`, `app.duties_state_ok`, `api.followups_command`, `app.followups_state_ok`) | staging md5 of the four comments `d0b02b6d...`; comparison with local pending the local verification run |
| Grants, rows, Edge Functions | unchanged |

No owner SQL paste. The client fixes (Follow-ups and Cells pending across a reload) ship with the
next staging staff web and APK build.

# Story 4.6 - staging verification (tmurpotfluignacfueki, 2026-10-14)

Synthetic data only. Merged `63c3f86` after the independent review fixes (no blockers; S1 family
scope, S2 roster-only candidates, S3 manual create for `fixture_` sources only, S4 duplicate
submits, plus nits). Full local verification on the merged branch: db:test 2783, every E2E
including `followups` 15/15, Flutter client_core 536 / staff 36 / mobile 51. PR #6 CI green on
`63c3f86`.

| Version | Name | How applied |
|---|---|---|
| 20261014110258 | followups_registry | 93 KB, split at top-level statement boundaries: lines 49-928 and 937-1518 by Supabase MCP `execute_sql`, then lines 1524-2080 by `apply_migration` so the version is recorded last. Local file renamed from 20261014120000. |

| Check | Result |
|---|---|
| The 55 `app`/`api` `followups_*` functions | per-function `md5(pg_get_functiondef)` identical to local (55 rows each side) |
| `\u` escapes | none |
| Client grants | `anon` none; `authenticated` execute only on `followups_command`, `followups_my_tasks`, `followups_task`, `followups_supervision`, `followups_admin_routing` (app and api) |
| Seed rows | 4 scope families, 1 purpose (the SYNTHETIC `fixture_followup/synthetic_check_in` source) |
| Staging assertions of `tools/ci/verify-hosted.sql` (marker staging, private_access closed, alerting disabled, no recovery hold, Auth schema 20260831180000 with the reset gate trigger) | passed |
| Edge Functions | no change in 4.6 |

No owner SQL paste is needed for 4.6.

Pending:
- Rebuild the staging staff web and mobile APK before the owner's checks (batched at the end of
  the milestone).
- Owner: the story 4.6 manual checks in `docs/runbooks/follow-ups.md`.
- Owner decision Q4 (may a task owner be outside the task's own department or cell?); the build
  keeps owners inside the task's group until answered.

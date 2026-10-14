# Story 4.7 - staging verification (tmurpotfluignacfueki, 2026-10-14)

Synthetic data only. Merged `5fb6d9e` after the independent review fixes (B1 reassign-back
swallowed reminders, S1 already-passed deadline alert, S2 Q4 needs Q2, S3 supervisor `before`
specs refused, S4 tests, nits N1-N7). PR #6 CI green on `5fb6d9e`. Local verification on the
merged branch: db:test 33 files / 2915 tests, db:smoke, Flutter client_core 550 / staff 37 /
mobile 52 (analyze clean), every E2E (see `e2e-suite-summary.txt`).

| Version | Name | How applied |
|---|---|---|
| 20261014130535 | followups_reminders | 65 KB, split at a top-level statement boundary: lines 1-622 by Supabase MCP `execute_sql`, then lines 623-1286 by `apply_migration` so the version is recorded last. Local file renamed from 20261014143021. |

| Check | Result |
|---|---|
| The 64 `app`/`api` `followups_*` functions | staging aggregate `a3b6b06b...` (64 rows); comparison with local pending the local E2E run |
| `\u` escapes / backslashes | none |
| Client grants | unchanged: `anon` none; `authenticated` execute only on `followups_command`, `followups_my_tasks`, `followups_task`, `followups_supervision`, `followups_admin_routing` (app and api) |
| Reminder contracts | 3 `followups_*` reminder contracts; 1 source-specific schedule (SYNTHETIC `fixture_followup/synthetic_report_due`) |
| Staging assertions of `tools/ci/verify-hosted.sql` (marker staging, private_access closed, alerting disabled, no recovery hold, Auth schema 20260831180000 with the reset gate trigger) | passed |
| Edge Functions | no change in 4.7 (the worker is generic) |

No owner SQL paste is needed for 4.7.

Pending:
- Rebuild the staging staff web and mobile APK before the owner's checks (batched at the end of
  the milestone).
- Owner: the story 4.7 manual checks in `docs/runbooks/follow-ups.md`.
- Production gate order: approve `q2_church_time` before or together with `q4_personal_data`
  (Follow-ups answers `unavailable` until both are open).

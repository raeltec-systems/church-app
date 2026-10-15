# Story 4.10 - staging verification (tmurpotfluignacfueki, 2026-10-15)

Synthetic data only. Merged `d81f1f2` after the independent review fixes (S1 erasure race on
outcome text; S2 outcomes window past today; nits N1-N6).

| Version | Name | How applied |
|---|---|---|
| 20261015002121 | duties_outcomes | 62 KB, split at a top-level statement boundary into two parts (lines 59-720 by Supabase MCP `execute_sql`, then 721-1151 by `apply_migration` so the version is recorded last); column-0 comment lines were left out. Local file renamed from 20261014231512. |

| Check | Result |
|---|---|
| The 296 `app`/`api` `duties_*`, `notifications_*`, `followups_*` and `identity_scoped*` functions | staging aggregate `9d1ddf5c...`; comparison with local pending the local verification run |
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

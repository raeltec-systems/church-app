# Story 4.8 - staging verification (tmurpotfluignacfueki, 2026-10-14)

Synthetic data only. Merged `800975d` after the independent review fixes (blocker 1 policy-check
cost on large publishes; should-fix 2 held leaders unrouted, 3 released/cancelled needs invisible,
4 accept with Q2 closed; deadline edges; client and test nits).

| Version | Name | How applied |
|---|---|---|
| 20261014171038 | duties_reminders | 139 KB, split at top-level statement boundaries into five parts (lines 1-519, 520-949, 950-1612, 1613-2117 by Supabase MCP `execute_sql`, then 2118-2709 by `apply_migration` so the version is recorded last); column-0 comment lines were left out. Local file renamed from 20261014153012. |

| Check | Result |
|---|---|
| The 204 `app`/`api` `duties_*` and `notifications_*` functions | staging aggregate `764f7d48...`; comparison with local pending the local verification run |
| Backslashes | none |
| Client grants | `anon` none on any `duties_*` / `notifications_*` function; no new client grant (the new command goes through `api.duties_command`) |
| After the apply | 0 assignments with `deadline_source <> 'creator'` or `short_notice`; 7 direct-contact routes for `duties_assignment` |
| Staging assertions of `tools/ci/verify-hosted.sql` (marker staging, private_access closed, alerting disabled, no recovery hold, Auth schema 20260831180000 with the reset gate trigger) | passed |
| Edge Functions | no change in 4.8 |

No owner SQL paste is needed for 4.8.

Pending:
- Rebuild the staging staff web and mobile APK before the owner's checks (batched at the end of
  the milestone).
- Owner: the story 4.8 manual checks in `docs/runbooks/duties.md`.
- Staging duties published before 4.8 get reminders only after their next change (no backfill).

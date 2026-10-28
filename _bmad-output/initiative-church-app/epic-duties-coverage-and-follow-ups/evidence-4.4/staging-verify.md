# Story 4.4 - staging verification (tmurpotfluignacfueki, 2026-10-14)

Synthetic data only. Merged `fbcd5aa` after the independent review fixes (two blockers: draft
cancel with a planned reason; override bypass on a re-asked declined assignee). Full local
verification on the merged branch: db:test 2566, all 21 E2Es including `duties-overlaps` 13/13,
Flutter client_core 496 / staff 35 / mobile 46. PR #6 CI green on `fbcd5aa`.

| Version | Name | How applied |
|---|---|---|
| 20261014052239 | duties_overlaps | Supabase MCP, in four parts because of the file size (125 KB): lines 1-1684 through `execute_sql` (three parts, split only between top-level statements), then lines 1690-2357 through `apply_migration`, which recorded the version. Local file renamed from 20261014024352. |

| Check | Result |
|---|---|
| The 89 `app`/`api` `duties_*` functions (purge stub excluded) | aggregate of per-function `md5(pg_get_functiondef)` identical to local (`01d22037...`, 89 rows) |
| `\u` escapes | none (no backslashes in the migration) |
| `alter column department_id drop not null` | applied without a connector prompt; relaxes a constraint only (allowed by `check-migrations`) |
| Client grants | `anon`: no duties function; `authenticated`: the 4.1-4.3 entry points plus `app/api.duties_candidates` only |
| After the apply | 0 cell-owned occurrences, 0 assignments with a recorded override |
| Staging assertions of `tools/ci/verify-hosted.sql` (marker, private_access closed, alerting disabled, no recovery hold, proven Auth schema and reset-gate trigger) | passed |
| Edge Functions | no change in 4.4 |

No owner SQL paste is needed for 4.4 (no new row deletions).

Follow-up recorded for the refactor sweep (entry 14): the reason-hiding uses the transaction
setting `app.duties_viewer`, set only by the board and rota reads; a future reader of those
projections that does not set it would show the reason (fail open). Make an unset viewer hide it.

Pending (owner): the story 4.4 manual checks in `docs/runbooks/duties.md`.

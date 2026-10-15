# Story 4.11 - staging verification (tmurpotfluignacfueki, 2026-10-15)

Synthetic data only. Merged `d65cd70` after the independent review fixes (S1 part-to-cell binding;
S2 older clients and the release gate; S3 member copy for cell parts; S4 cell-part withdraw test;
nits N1-N10). PR #6 CI green on `d65cd70` and `31b3408`. Local verification: db:test 41 files / 3554 tests, db:smoke, Flutter client_core 621 / staff 40 / mobile 55, all 28 E2Es exit 0 (`duties-owner-ops` 13/13).

| Version | Name | How applied |
|---|---|---|
| 20261015035112 | duties_owner_operations | 187 KB, split at top-level statement boundaries into six parts (lines 83-695, 716-1233, 1243-1910, 1912-2342, 2344-2876 by Supabase MCP `execute_sql`, then 2878-3580 by `apply_migration` so the version is recorded last); column-0 comment lines were left out. Local file renamed from 20261015120000. |

| Check | Result |
|---|---|
| The 50 functions the migration creates or replaces (40 `app.duties_*`, 10 `app.fixture_*`) | `md5(prosrc)` on staging equal to the local parts |
| The 362 `app`/`api` `duties_*`, `notifications_*`, `followups_*`, `identity_scoped*` and `fixture*` functions | per-function `md5(pg_get_functiondef)` identical to local: aggregate `816a6e3e...`, 362 rows each side |
| Backslashes | none |
| Client grants | unchanged: `anon` and `service_role` none; no function created by this migration is client-executable |
| After the apply | 0 rows in `duties_link_sources`, `duties_part_links`, `duties_review_flags`, `fixture_programme_parts`, `fixture_events` |
| Staging assertions of `tools/ci/verify-hosted.sql` (marker staging, private_access closed, alerting disabled, no recovery hold, Auth schema 20260831180000 with the reset gate trigger) | passed |
| Edge Functions | no change in 4.11 |

No owner SQL paste is needed for 4.11.

Pending:
- Release gate: rebuild the staging staff web and mobile APK before any cell part exists (clients
  older than 4.11 cannot read a cell part in My duties).
- Owner: the story 4.11 manual checks in `docs/runbooks/duties.md`.
- Owner acknowledgement: `duties.clear_review` answers `forbidden` (not `not_found`) to a
  non-manager. Open owner questions: may a cell show a linked duty's assignee (built: no); should
  a leader be notified of a mismatch (built: board only).

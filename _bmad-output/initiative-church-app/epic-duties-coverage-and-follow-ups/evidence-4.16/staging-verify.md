# Story 4.16 - staging verification (tmurpotfluignacfueki, 2026-10-15)

Synthetic data only. Merged `dc52adc` after the independent review and a focused re-check (S1
unlink records handovers, S2 notice currency, S3 G4 rate-limit doc, nits N1, N2, N4, N5).

| Version | Name | How applied |
|---|---|---|
| 20261015190139 | duties_owner_decisions | 81 KB, split at top-level statement boundaries into three parts (lines 60-427 and 431-1045 by Supabase MCP `execute_sql`, then 1049-1468 by `apply_migration` so the version is recorded last); column-0 comment lines were left out. Local file renamed from 20261015180000. |

| Check | Result |
|---|---|
| The 21 functions the migration creates or replaces (Duties, Identity, Follow-ups, fixture) | `md5(prosrc)` on staging equal to the local parts |
| The 690 `app`/`api` `duties_*`, `notifications_*`, `followups_*`, `identity*` and `fixture*` functions | 690 rows each side. Aggregates: staging `79902500...`, local `870b1f5c...`. Per-group comparison: Duties (180), Follow-ups (79), Notifications (94), fixture (42) and two of four Identity groups identical; the only two differing functions are `app.identity_application_name` (connector escape transcription) and `app.identity_reclaim_phone_username` (owner-pasted whitespace), the known epic 2 differences recorded in evidence-2.4, 2.5 and 2.11. Every 4.16 function is identical. |
| Backslashes | none; the only drop-like statement is `alter column lifecycle_event_id drop not null` |
| Client grants | unchanged: `anon` and `service_role` none; `authenticated` only the existing entry points; none of the 10 new functions is client-executable |
| Contracts | 1 `duty_review_flagged` reminder contract |
| `identity_handover_obligations.lifecycle_event_id` | nullable |
| `dormancy_days` | fixture row only (never approved on staging) |
| Staging assertions of `tools/ci/verify-hosted.sql` (marker staging, private_access closed, alerting disabled, no recovery hold, Auth schema 20260831180000 with the reset gate trigger) | passed |
| Edge Functions | no change in 4.16 |

No owner SQL paste. Rebuild the staging staff web and mobile APK before the owner's checks. At
production promotion the operator applies G3 (`app.identity_approve_setting`, 180 days), G4 and
G11 as documented in `production-promotion-identity.md`.

Local verification on the merged branch: db:test 45 files / 3845 tests, db:smoke, Flutter client_core 655 / staff 40 / mobile 55, all 31 E2Es exit 0 (`duties-decisions` 11/11). PR #6 CI green on `450579e`.

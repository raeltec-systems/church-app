# Story 4.16 - staging verification (tmurpotfluignacfueki, 2026-10-15)

Synthetic data only. Merged `dc52adc` after the independent review and a focused re-check (S1
unlink records handovers, S2 notice currency, S3 G4 rate-limit doc, nits N1, N2, N4, N5).

| Version | Name | How applied |
|---|---|---|
| 20261015190139 | duties_owner_decisions | 81 KB, split at top-level statement boundaries into three parts (lines 60-427 and 431-1045 by Supabase MCP `execute_sql`, then 1049-1468 by `apply_migration` so the version is recorded last); column-0 comment lines were left out. Local file renamed from 20261015180000. |

| Check | Result |
|---|---|
| The 21 functions the migration creates or replaces (Duties, Identity, Follow-ups, fixture) | `md5(prosrc)` on staging equal to the local parts |
| The 690 `app`/`api` `duties_*`, `notifications_*`, `followups_*`, `identity*` and `fixture*` functions | staging aggregate `79902500...`; comparison with local pending the local verification run |
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

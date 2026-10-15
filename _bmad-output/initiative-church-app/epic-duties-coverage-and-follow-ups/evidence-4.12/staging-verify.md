# Story 4.12 - staging verification (tmurpotfluignacfueki, 2026-10-15)

Synthetic data only. Merged `f5fc5d9` after three review rounds (round 1: S1 handover scale, S2
lifecycle/command deadlock, S3 unreachable owners, S4 last-leader screen and revoke-first limit,
N1-N8; round 2: B1 capped handover left authority with a revoked leader, S5 candidate being
deactivated, N9-N12; round 3: R1 held or dormant Pastors, R2 failing roster hook, R3 runbook).
PR #6 CI green on `8365b9f`.

| Version | Name | How applied |
|---|---|---|
| 20261015110202 | duties_lifecycle | 135 KB, split at top-level statement boundaries into five parts (lines 1-765, 766-1275, 1276-1764, 1765-2516 by Supabase MCP `execute_sql`, then 2517-2613 by `apply_migration` so the version is recorded last); column-0 comment lines were left out. Local file renamed from 20261015043644. |

| Check | Result |
|---|---|
| The 48 functions the migration creates or replaces | `md5(prosrc)` on staging equal to the local parts |
| The 392 `app`/`api` `duties_*`, `notifications_*`, `followups_*`, `identity_scoped*` and `fixture*` functions | staging aggregate `5fc1c65b...`; comparison with local pending the local verification run |
| Backslashes | none |
| Client grants | unchanged: `anon` and `service_role` none; `authenticated` only the existing Duties and Follow-ups entry points; no new function client-executable |
| Hooks | lifecycle: `duties` (access_hold_applied, deletion_requested, membership_deactivated, scope_revoked), `followups` (deletion_requested, membership_deactivated, scope_revoked); handover: `duties_report_handover`, `followups_report_handover` |
| Contracts | 1 `duty_vacated` reminder contract |
| Staging assertions of `tools/ci/verify-hosted.sql` (marker staging, private_access closed, alerting disabled, no recovery hold, Auth schema 20260831180000 with the reset gate trigger) | passed |
| Edge Functions | no change in 4.12 |

No owner SQL paste is needed for 4.12.

Pending:
- Deploy order: rebuild the staging staff web and mobile APK in the same rollout (older clients
  reject `leader` provenance in assignment history).
- Owner: the story 4.12 manual checks in `docs/runbooks/duties.md`.
- Owner acknowledgement: one vacancy notice per department per change (the frozen plan said per
  position). Follow-up item: an Identity grant-revocation handover hook (the revoke-first
  last-leader limit).

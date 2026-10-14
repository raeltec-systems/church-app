# Story 4.2 - staging verification (tmurpotfluignacfueki, 2026-10-14)

Synthetic data only. Merged `5a5b289` after the independent review fixes; full local verification
on the merged branch: db:test 2332, all 19 E2Es including `duties-revisions` 13/13, Flutter
client_core 467 / staff 34 / mobile 46.

| Version | Name | How applied |
|---|---|---|
| 20261014001142 | duties_revisions | Supabase MCP `apply_migration` (local file renamed from 20261013221115) |

| Check | Result |
|---|---|
| The 49 `app`/`api` `duties_*` functions (purge stub excluded), incl. the two new guard triggers | every per-function `md5(pg_get_functiondef)` identical to local |
| `\u` escapes | none in the migration (no backslashes at all), so no transport decoding to repair |
| Guard triggers `duties_slot_revisions_immutable`, `duties_assignments_history_immutable` | present |
| Reminder contracts | `duty_assigned`, `duty_changed`, `duty_released`, `duty_updated` registered |
| Slot revision backfill | staging had no published slots yet (0 slots, 0 revisions, 0 missing) |
| Edge Functions | no change in 4.2 |

No owner SQL paste is needed for 4.2 (no new row deletions; the 4.1 purge is reused).

Pending (owner): the 4.2 revise walkthrough in `docs/runbooks/duties.md`, "Owner manual checks".

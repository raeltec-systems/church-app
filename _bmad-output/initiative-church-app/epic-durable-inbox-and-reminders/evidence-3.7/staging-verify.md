# Story 3.7 — staging verification (tmurpotfluignacfueki, 2026-10-08)

Synthetic data only.

| Version | Name | How applied |
|---|---|---|
| 20261008183514 | notifications_inbox_screens | Supabase MCP `apply_migration` (local file renamed from 20261008181657) |

No rows file. No Edge Function change.

| Check | Result |
|---|---|
| `app.sys_execute`, `app.notifications_%` and `app.fixture_%` functions (purge stubs excluded; CR stripped) | 113 functions; aggregate identical to local (`c1b311030164d4698357174b10cb0f21`) |
| Realtime receive policy `notifications_account_refresh_receive` on `realtime.messages` | present (1), same as local |
| Local verification on the merged branch | db:test 2101 pass; all 17 E2Es incl. `inbox-screens` 12/12; flutter analyze/test clean for client_core (425), staff (29), mobile (31) |

Owner check still open: Realtime "Allow public access" for channels should stay off (Project Settings > Realtime);
an empty-payload public join would at most cause a spurious refresh.

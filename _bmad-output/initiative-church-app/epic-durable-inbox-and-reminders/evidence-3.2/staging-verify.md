# Story 3.2 — staging verification (tmurpotfluignacfueki, 2026-10-08)

Synthetic data only.

| Version | Name | How applied |
|---|---|---|
| 20261008090057 | notifications_source_contracts | Supabase MCP `apply_migration` (local file renamed from 20261008074412) |

| Check | Result |
|---|---|
| The 25 notification, fixture-reminder and reminder-contract functions | aggregate `md5(pg_get_functiondef)` identical to local (`e6d5d951...`) |
| Generic-text validator on staging (escape transcription check) | full-width digit title refused `not_generic`; plain title accepted |
| `notifications_open_item` with an unknown id (synthetic Admin) | 200 `{"state": "not_found"}`; without a session 401 |
| `notifications_my_inbox` | 200 |
| `fixture.reminder_create` with an unregistered kind | `validation_failed {"reminder_kind": "unregistered"}` |
| `fixture.reminder_create` then `fixture.reminder_change {change: expire}` | 200 pending; 200 with `expires_at` set |

Delivery and opening a delivered item on staging need the `notifications_worker` credential
(owner step in `../../milestone-2-owner-test.md`).

# Story 3.6 — staging verification (tmurpotfluignacfueki, 2026-10-08)

Synthetic data only. No Firebase or Apple credential is held by the agent; push stays off.

| Version | Name | How applied |
|---|---|---|
| 20261008155801 | notifications_push | Supabase MCP `apply_migration` (local file renamed from 20261008151500) |

No rows file.

| Check | Result |
|---|---|
| `app.sys_execute` plus the 80 `app.notifications_%` functions (purge stubs excluded) | 81 functions; aggregate `md5(pg_get_functiondef)` identical to local (`03e9a6ec241df5f6841aa43698a7a9da`) |
| `notifications_worker` command kinds | 8: attempt, claim, deliver_due, release, push_claim, push_prepare (`retain_result=false`), push_record, push_release |
| `app.notifications_scheduler_status() -> 'push'` | `{"enabled": false, "pending": 0, "leased": 0, ...}` |
| `notifications_worker` principals on staging | none yet: the owner's credential mint (milestone 2 owner step 1) creates it with all eight commands |
| Edge Function `notifications-worker` | redeployed as version 2 (`index.ts`, `logic.mjs`, `fcm.mjs`; `verify_jwt` false) |
| POST without the Edge secrets | `503 {"outcome":"unavailable"}` (fail closed, as before) |
| GET | `405 {"outcome":"invalid"}` |

Pending (owner): the worker credential and Edge secrets (3.4), then the Firebase project, the
`NOTIFICATIONS_FCM_SERVICE_ACCOUNT` secret, APNs, the client adapter follow-up and the real-device
check (`docs/runbooks/notifications.md`, story 3.6, Hosted staging steps 3 to 8).

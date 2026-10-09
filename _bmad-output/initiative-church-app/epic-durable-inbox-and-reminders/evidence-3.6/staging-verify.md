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

## Push live on staging (2026-10-09)

- Owner: Firebase project `kbicc-church-app`, Android app, service account `bic-push-sender`, Edge secret `NOTIFICATIONS_FCM_SERVICE_ACCOUNT`; the push-enabled APK (adapter merged 2026-10-08) registered one Android device for the synthetic member.
- `push_enabled` switched on. FCM first answered 403 PERMISSION_DENIED with only the role "Firebase Cloud Messaging Admin"; after adding "Firebase Cloud Messaging API Admin", the 05:25 UTC run answered `sent: {accepted: 4}`, `outcomes: {accepted: 4}` (provider acceptance, not delivery). The worker now reports `stop_detail` (provider status/code and the sender identity) when sending stops on configuration.

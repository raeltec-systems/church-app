# Story 3.4 — staging verification (tmurpotfluignacfueki, 2026-10-08)

Synthetic data only.

| Version | Name | How applied |
|---|---|---|
| 20261008121248 | notifications_worker | Supabase MCP `apply_migration` (local file renamed from 20261008121500) |

| Check | Result |
|---|---|
| Extensions | `pg_net 0.20.4`, `pg_cron 1.6.4` installed by the migration |
| All 65 notification, fixture-reminder and reminder-contract functions | aggregate `md5(pg_get_functiondef)` identical to local (`10f97e8f...`) |
| `ops_operator_actions` retired by rename and recreated | 11 rows = retired copy 11 |
| `app.notifications_scheduler_status()` after apply | `scheduler_jobs: 0`, `allowed: true`, staging |
| Edge Function `notifications-worker` | deployed with the connector (`verify_jwt: false`, `index.ts` + `logic.mjs`), version 1, ACTIVE |
| Worker URL and trigger (parent steps 3.1-3.2) | `worker_url_valid: true`, `trigger_set: true` (the value stays in Vault, never shown) |
| Function before the owner's Edge secrets | `POST {}` answers `503 {"outcome":"unavailable"}` (fails closed) |

Not done yet (owner steps in `../../milestone-2-owner-test.md`): mint and register the worker credential,
set the two Edge secrets; then the parent runs one manual tick and `app.notifications_scheduler_enable('israel')`.
The schedule stays off until then, so nothing calls the function every minute while it cannot work.

## Worker activation (2026-10-08, after the owner's steps)

- Owner minted the staging notifications-worker credential; the parent registered digest `88f9f20c...` (principal `notifications-worker`, purpose `notifications_worker`, credential `2d20a4d8-...`, expires 2026-11-07).
- Owner set the Edge secrets `NOTIFICATIONS_WORKER_SYSTEM_CREDENTIAL` and `NOTIFICATIONS_WORKER_TRIGGER` (values never seen by the agent).
- `app.notifications_scheduler_tick()` -> `{"tick":"sent"}`; pg_net response 200 `{"claimed":1,"outcomes":{"delivered":1},"push":{"state":"not_configured",...}}` (one waiting synthetic job delivered).
- `app.notifications_scheduler_enable('israel')` -> `active: true`, `schedule: "* * * * *"`, `scheduler_jobs: 1`.

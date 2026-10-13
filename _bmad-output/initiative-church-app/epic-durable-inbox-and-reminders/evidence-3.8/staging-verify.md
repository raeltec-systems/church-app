# Stories 3.8-3.9 (with review fixes) - staging rollout (tmurpotfluignacfueki, 2026-10-13)

Parent session, after the review-3.8-3.10 fixes merged (`b0c6f8d`) and the full local verification
passed (db:test 2145, all 17 E2Es, Flutter client_core 428 / staff 33 / mobile 45, ci:migrations
against both bases). Synthetic data only. Order as in `docs/runbooks/notifications.md`, Story 3.8,
Hosted staging.

| Step | Result |
|---|---|
| 0. Trial redeploy `notifications-worker` (MCP, files `index.ts`, `logic.mjs`, `fcm.mjs`, `../_shared/system_access.mjs`) | version 9 ACTIVE; POST `{}` without trigger -> 401 (boots, `_shared` resolved); scheduled runs 19:37 and 19:38 UTC -> 200 |
| 1a. `apply_migration notifications_health` | success; hosted version `20261013193932` (local file renamed from `20261013000000`) |
| 1b. `apply_migration notifications_health_repair` (owner-approved DROP CONSTRAINT) | success; hosted version `20261013194009` (renamed from `20261013190000`) |
| Checks | `ops_operators_auth_user_id_fkey` absent; 2 `ops_operators_auth_mapping_*` triggers on `auth.users` |
| 2. Gate | `app.policy_approve('outbound_sending', {"environment":"staging","scope":"synthetic push"}, 'israel', 'owner decision 2026-10-13 ...')`; `policy_is_open` = true |
| 3. Redeploy `identity-deletion` (MCP, `index.ts`, `logic.mjs`, `../_shared/system_access.mjs`) | version 6 ACTIVE; POST `{}` without credential -> 401 |
| Worker after migrations | 19:41 and 19:42 UTC runs -> 200, `push.enabled` true, no `gate_closed` |
| Parity | the 123 `app`/`api` notifications, fixture, `ops_operators_*` and `sys_execute` functions (purge stubs excluded): every per-function `md5(pg_get_functiondef)` identical to local (the order-sensitive aggregate differs only in overload ordering) |
| verify-hosted (staging) | pass: marker staging, private_access closed, alerting disabled, no recovery hold, Auth schema proven, reset-gate trigger present; outbound_sending open (allowed on staging) |

Still owner-side (unchanged by this rollout): map an operator account and run the health-view
demonstration on staff web, the real-device push re-check, and the Story 3.10 witness items.

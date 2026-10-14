# Story 3.3 — staging verification (tmurpotfluignacfueki, 2026-10-08)

Synthetic data only.

| Version | Name | How applied |
|---|---|---|
| 20261008102121 | notifications_scheduling | Supabase MCP `apply_migration` (local file renamed from 20261008120000) |

| Check | Result |
|---|---|
| All 45 notification, fixture-reminder and reminder-contract functions | aggregate `md5(pg_get_functiondef)` identical to local (`968699a7...`) |
| Q2 TEST FIXTURE value (`app.policy_gates.fixture_value`) | md5 identical to local (`bee10069...`) |
| `app.notifications_policy()` on staging | zone `Africa/Lusaka` (fixture) |
| Deadline, assigned 2026-10-01 10:00 Lusaka, starts 2026-12-27 09:00 Lusaka (lead >= 30 days) | band 1: 2026-12-13 09:00 Lusaka (14 days before), not short notice |
| Deadline, same assignment, starts 2026-10-04 09:00 Lusaka (lead about 71 h, under 72 h) | band 3: 2026-10-03 09:00 Lusaka (24 h before) |

Production stays closed until the owner approves `q2_church_time` (runbook, story 3.3 section) and runs
`app.notifications_replan_all('policy_changed')`.

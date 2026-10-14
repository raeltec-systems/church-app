# Story 3.1 — staging verification (tmurpotfluignacfueki, 2026-10-08)

Synthetic data only.

| Version | Name | How applied |
|---|---|---|
| 20261008073631 | notifications_inbox | Supabase MCP `apply_migration` (local file renamed from 20261008090000) |

| Check | Result |
|---|---|
| The 15 functions this migration creates (notifications_*, fixture_reminder*, fixture_authorize_command) | aggregate `md5(pg_get_functiondef)` identical to local (`dd6dc824...`) |
| `api.notifications_my_inbox` for anon | no EXECUTE; call without a session 401 |
| `notifications_my_inbox` as synthetic Admin +12025550150 | 200, `{"items": [], "next": null}` |
| `fixture.reminder_create` (due in 1 h) then `fixture.reminder_cancel` | 200 `job_created: true, job_state: pending`; then 200 `cancelled_jobs: 1`, revision 2 |

Delivery on staging needs the `notifications_worker` credential (owner step in
`../../milestone-2-owner-test.md`). One extra synthetic reminder created during this check stays
pending for the Admin until the worker runs.

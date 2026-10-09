# Story 3.5 — staging verification (tmurpotfluignacfueki, 2026-10-08)

Synthetic data only.

| Version | Name | How applied |
|---|---|---|
| 20261008135811 | notifications_routing | Supabase MCP `apply_migration` (local file renamed from 20261008143000) |
| 20261008135900 | notifications_routing_rows | owner pasted in the SQL editor on 2026-10-08; recorded in `schema_migrations` by the parent session |

| Check | Result |
|---|---|
| The 99 notification, fixture and reminder-contract/direct-contact functions (purge stubs excluded) | aggregate `md5(pg_get_functiondef)` identical to local (`bc37c852...`) |
| Deletion hooks registered | `cells, fixture, notifications` (same as local) |
| Notifications lifecycle hooks | 5 (`sessions_revoked`, `access_hold_applied`, `membership_deactivated`, `account_deactivated`, `deletion_requested`) |
| `notifications_deletion_purge_rows`, `fixture_deletion_purge_rows` | real bodies after the owner's paste: `md5(prosrc)` with CR removed identical to local (`f61b85cf...`, `8bb32d73...`); the SQL editor stored CRLF line endings; no execute for `authenticated` |

The Edge Function needs no redeploy for this story.

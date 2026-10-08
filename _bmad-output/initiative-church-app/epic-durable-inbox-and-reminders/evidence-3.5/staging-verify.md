# Story 3.5 — staging verification (tmurpotfluignacfueki, 2026-10-08)

Synthetic data only.

| Version | Name | How applied |
|---|---|---|
| 20261008135811 | notifications_routing | Supabase MCP `apply_migration` (local file renamed from 20261008143000) |
| 20261008135900 | notifications_routing_rows | **pending: owner paste** (renamed from 20261008143100 so it sorts after the main file) |

| Check | Result |
|---|---|
| The 99 notification, fixture and reminder-contract/direct-contact functions (purge stubs excluded) | aggregate `md5(pg_get_functiondef)` identical to local (`bc37c852...`) |
| Deletion hooks registered | `cells, fixture, notifications` (same as local) |
| Notifications lifecycle hooks | 5 (`sessions_revoked`, `access_hold_applied`, `membership_deactivated`, `account_deactivated`, `deletion_requested`) |
| `notifications_deletion_purge_rows`, `fixture_deletion_purge_rows` | fail-closed stubs until the owner pastes `20261008135900` (a staging deletion pauses at `erase_owners`, erasing nothing) |

The Edge Function needs no redeploy for this story.

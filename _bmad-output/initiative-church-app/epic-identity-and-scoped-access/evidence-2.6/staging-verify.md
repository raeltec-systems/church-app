# Story 2.6 — staging verification (tmurpotfluignacfueki, 2026-10-07)

Synthetic data only. No passwords or tokens recorded.

## Migration

| Version | Name | How applied |
|---|---|---|
| 20261007075946 | cell_membership | Supabase MCP `apply_migration` (local file renamed from 20261007140000 to the hosted version) |

## Function parity with a local reset

- 41 Cells functions compared by `md5(pg_get_functiondef)`: 40 identical.
- `app.cells_text`: the hosted text carries the format-character class as literal characters where the
  file has `\uXXXX` escapes (transcription by the connector). Same behaviour on 15 inputs (U+00AD,
  U+200B–U+200F, U+202A–U+202E, U+2060–U+2064, U+2066–U+206F, U+FEFF rejected; `A`, U+2010, U+202F,
  U+2065 accepted) on both databases.

## Functional checks (API as the synthetic Admin +12025550150)

| Check | Result |
|---|---|
| `cells_admin_overview` | 200; three SYNTHETIC cells, listed, no members yet |
| Request created from the approved 2.5 application | `join`, origin `application`, requested SYNTHETIC Market Cell, not a follow-up |
| `cells_leader_queue` for a member with no leader/assistant scope | 403 `not_granted` |
| `cells_private_fixture_read` for an Admin without membership | 403 (Admin role alone gives no cell-private access) |

Confirm, transfer and the leader screens are exercised on the local stack by `tools/identity-e2e/cells.mjs`
(13/13) and are part of the owner's consolidated staging test at the end of the identity epic.

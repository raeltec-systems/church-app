# Entry 19: staging verification (2026-10-28)

Project `tmurpotfluignacfueki` (staging). Production was not touched; no content was published, no
gate changed and no notification was sent.

- Before: staging's latest migration was `20261027192013` (entry 12). Entry 19 replaces no shared
  function, so nothing had to be rebuilt on the staging version.
- Applied `supabase/migrations/20261028064546_cells_my_meetings.sql` verbatim with
  `apply_migration`; staging recorded `20261028064546` and the local file was renamed from
  `20261027192306` to match.
- Function hashes, `md5(replace(pg_get_functiondef(oid), chr(13), ''))`, staging = fresh local reset:

| Function | Hash |
|---|---|
| `app.cells_my_meetings()` | `e5669cd0a82149dbeb4b2eb8aee119b3` |
| `api.cells_my_meetings()` | `779cba0650b270a0a54f933e660f9f5d` |
| `app.cells_my_cell()` (unchanged) | `df9b912af30afd2ed53a3ca8e0b16401` |
| `api.cells_my_cell()` (unchanged) | `2117ba59976fb99da4bf081bd2357680` |

- `app.contract_boundary_violations()` = 0, `app.contract_unowned_objects()` = 0.
- Privileges: anon has no EXECUTE on `api.cells_my_meetings()`; authenticated has.
- Signed-out reads: as `anon` the call fails with `42501` (HTTP 401 through PostgREST); as
  `authenticated` without a session it answers `PT401 unauthenticated`.

Local, before the apply (shared DB lock held as 6.19): fresh `supabase db reset`, full pgTAP suite
69 files / 5,627 tests, all passing except the known load-sensitive board-timing check
`duties_owner_decisions_test` 32, which passed when run alone; E2E
`tools/identity-e2e/calendar-overlays.mjs` 10/10 (`calendar-overlays-e2e.jsonl`).

# Story 5.1 on staging (`tmurpotfluignacfueki`, bic-kafue-platform-test)

Applied 2026-10-21 by the parent session through the Supabase connector (`apply_migration`).

- Before: staging's last migration was `20261015190139 duties_owner_decisions`, the branch base.
- Applied `cells_meetings`; staging recorded version `20261021073514`. The local file was renamed to
  `supabase/migrations/20261021073514_cells_meetings.sql` to match.
- `tools/ci/verify-hosted.sql` with `expected_env=staging` (the psql variable inlined, otherwise
  verbatim): passed. Marker `staging`, `private_access` closed, alerting disabled, no recovery
  hold, 2.7 reset gate present on the proven Auth schema.
- Contract registry on staging after the apply: 0 unowned objects, 0 unpinned functions,
  0 boundary violations. `api.cells_meetings()` executable by `authenticated`, not by `anon`.
- Function drift: `md5(pg_get_functiondef(...))` of all 23 functions this migration creates or
  replaces is identical on staging and on the local stack. The only Cells difference is the
  unchanged 2.6 wrapper `api.cells_my_cell()`, whose local body carries CRLF line endings from the
  Windows checkout; the definition text is otherwise identical.
- Transport note: the connector turns `\u` escapes in SQL text into characters, so the venue
  check's format-character class is written with `chr()` codes (ASCII, identical behaviour; pgTAP
  covers a soft-hyphen venue).
- No Edge Function change and no rows file. Owner manual checks: `docs/runbooks/cells-meetings.md`,
  story 5.1 (to be recorded in `owner-check.md`).

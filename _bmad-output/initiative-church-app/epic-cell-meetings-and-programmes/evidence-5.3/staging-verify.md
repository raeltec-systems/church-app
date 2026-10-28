# Story 5.3 on staging (`tmurpotfluignacfueki`, bic-kafue-platform-test)

Applied 2026-10-21 by the parent session through the Supabase connector (`apply_migration`), after
5.2 (`20261021081026`). The file has no backslashes and is ASCII only, so it travelled verbatim.

- Staging recorded `cells_programmes` as version `20261021084446`; the local file was renamed to
  `supabase/migrations/20261021084446_cells_programmes.sql` (it carries the 5.2 review fixes).
- Hosted checks after the apply (the `tools/ci/verify-hosted.sql` assertions, read as values):
  marker `staging`, `private_access` closed, alerting disabled, no recovery hold, Auth schema the
  proven one with the 2.7 reset gate enabled; every `cells*` function pins `search_path`; no
  programme function executable by `anon`; the three programme tables have RLS and no table
  privilege for `anon` or `authenticated`; `api.cells_programme(uuid)` granted to
  `authenticated`; `cells_reminder_specs('[]')` is `[]` (5.2 review fix 1 live).
- Function drift: `md5(pg_get_functiondef(...))` with carriage returns removed, for the 24
  functions 5.3 creates or replaces (programme helpers, commands and read, the dispatch,
  authorizer and in-scope check, the deletion hook, and the 5.2 fixes), compared staging and a
  fresh local reset: identical for every one.
- Owner manual checks: `docs/runbooks/cells-meetings.md`, story 5.3 (record in `owner-check.md`).

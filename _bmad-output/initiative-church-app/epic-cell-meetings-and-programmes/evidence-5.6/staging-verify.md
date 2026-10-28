# Story 5.6 on staging (`tmurpotfluignacfueki`, bic-kafue-platform-test)

Applied 2026-10-21 by the parent session through the Supabase connector (`apply_migration`), after
5.5, with the 5.6 review fixes in it. ASCII only, no backslashes; it travelled verbatim.

- Staging recorded `cells_programme_revisions` as `20261021104522`; the local file was renamed.
- Before applying, staging had no programmes (`app.cells_programmes` empty), so the backfill of the
  published snapshot (review finding 5) changed nothing there.
- Hosted checks after the apply: marker `staging`, `private_access` closed, alerting disabled, no
  recovery hold.
- Function drift: `md5(pg_get_functiondef(...))` (carriage returns removed) of every `app`/`api`
  `cells*` function except the pre-existing `app.cells_text` drift (2.6, owner finding): the 13
  functions 5.6 creates or replaces are identical to a fresh local reset, the others unchanged.
- Owner manual checks: `docs/runbooks/cells-meetings.md`, story 5.6 (record in `owner-check.md`).

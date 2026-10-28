# Story 5.4 on staging (`tmurpotfluignacfueki`, bic-kafue-platform-test)

Applied 2026-10-21 by the parent session through the Supabase connector (`apply_migration`), after
5.3 (`20261021084446`), once the owner confirmed the 4.11 release gate (`release-gate.md`). Both
files are ASCII only with no backslashes and travelled verbatim; the 5.4 review fixes were in them.

- Staging recorded `duties_owner_linkable` as `20261021093943` and `cells_programme_publish` as
  `20261021094249`; the local files were renamed to those versions.
- Hosted checks after the apply (the verify-hosted assertions, read as values): marker `staging`,
  `private_access` closed, alerting disabled, no recovery hold; every `cells*` and `duties_owner*`
  function pins `search_path`; no new function executable by `anon`; the projections table is not
  readable by `authenticated`; `api.cells_meeting_programme(uuid)` granted to `authenticated`; the
  `cells_programme_part` source is registered.
- Function drift: `md5(pg_get_functiondef(...))` with carriage returns removed for every `app`/`api`
  function named `cells*` plus `duties_owner_linkable`, staging against a fresh local reset:
  identical for all, except the pre-existing `app.cells_text` drift from story 2.6 already recorded
  as an owner finding (5.2 staging evidence); 5.4 does not touch it.
- Owner manual checks: `docs/runbooks/cells-meetings.md`, story 5.4 (record in `owner-check.md`).

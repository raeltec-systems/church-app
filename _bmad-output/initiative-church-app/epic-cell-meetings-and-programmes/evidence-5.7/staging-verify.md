# Story 5.7 on staging (`tmurpotfluignacfueki`, bic-kafue-platform-test)

Applied 2026-10-21 by the parent session through the Supabase connector (`apply_migration`), after
5.6, with the 5.7 review fixes in it. ASCII only, no backslashes; it travelled verbatim.

- Staging recorded `cells_absence_notices` as `20261021111547`; the local file was renamed.
- New tables `app.cells_absence_notices` and `app.cells_absence_audit`: RLS on, no grant to
  `anon`, `authenticated`, `service_role` or `PUBLIC`; empty after the apply.
- The nine new `app` functions are not executable by `anon` or `authenticated`.
- Notifications: source type `cells_absence_notice` and both reminder contracts
  (`cells_absence_sent`, `cells_absence_withdrawn`) registered.
- Function drift: `md5(pg_get_functiondef(...))` (carriage returns removed) of every `app`/`api`
  `cells*` function (105) matches a fresh local reset, except the pre-existing `app.cells_text`
  drift (2.6, owner finding).
- Owner manual checks: `docs/runbooks/cells-meetings.md`, story 5.7 (record in `owner-check.md`).

# Story 5.5 on staging (`tmurpotfluignacfueki`, bic-kafue-platform-test)

Applied 2026-10-21 by the parent session through the Supabase connector (`apply_migration`), after
5.4, with the 5.5 review fixes already in place (they were client-side and tests). Both files are
ASCII only with no backslashes and travelled verbatim.

- Staging recorded `duties_cell_confirmation` as `20261021101314` and `cells_youre_on` as
  `20261021101323`; the local files were renamed to those versions.
- Hosted checks after the apply: marker `staging`, `private_access` closed, alerting disabled, no
  recovery hold; `app.duties_lock_for_confirm` not executable by `authenticated`.
- Function drift: `md5(pg_get_functiondef(...))` (carriage returns removed) of
  `duties_lock_for_confirm`, `duties_confirm_by_leader`, `duties_in_scope`,
  `duties_authorize_command` and `app/api.cells_meeting_programme`: identical to a fresh local reset.
- Owner manual checks: `docs/runbooks/cells-meetings.md`, story 5.5 (the phone app must be rebuilt
  from this branch; record in `owner-check.md`).

# Story 5.8 on staging (`tmurpotfluignacfueki`, bic-kafue-platform-test)

Applied 2026-10-21 by the parent session through the Supabase connector (`apply_migration`), after
5.7, with the 5.8 review fixes in it. ASCII only, no backslashes; it travelled verbatim.

- Staging recorded `cells_meeting_records` as `20261021115855`; the local file was renamed.
- New tables `app.cells_meeting_records`, `app.cells_meeting_record_history`, `app.cells_actual_leaders`:
  RLS on, no grant to `anon`, `authenticated`, `service_role` or `PUBLIC`.
- Function drift: `md5(pg_get_functiondef(...))` (carriage returns removed) of the 14 functions 5.8
  creates or replaces (`cells_actual_leader_json`, `cells_correct_meeting_held`, `cells_erase_member`,
  `cells_in_scope`, `cells_lock_record`, `cells_meeting_record_json`, `cells_meeting_reference`,
  `cells_meeting_status`, `cells_meetings`, `cells_programme`, `cells_record_actual_leaders`,
  `cells_record_meeting`, `cells_record_meeting_held`, `cells_record_outcome`) match a fresh local
  reset. `cells_authorize_command` and `cells_command` differ from the local database only because the
  local one already carries story 5.9's `cells.resolve_handover`; the pre-existing `app.cells_text`
  drift (2.6) is unchanged.
- Owner manual checks: `docs/runbooks/cells-meetings.md`, story 5.8 (record in `owner-check.md`).

# Story 5.9 on staging (`tmurpotfluignacfueki`, bic-kafue-platform-test)

Applied 2026-10-21 by the parent session through the Supabase connector (`apply_migration`), after
5.8, with the 5.9 review fixes in it. ASCII only, no backslashes; it travelled verbatim.

- Staging recorded `cells_transfer_effects` as `20261021122802`; the local file was renamed.
- Function drift: `md5(pg_get_functiondef(...))` (carriage returns removed) of the 14 functions 5.9
  creates or replaces (Duties `duties_vacate_cell_member`, `duties_owner_vacate_member`; Cells
  `cells_programme_source_check`, `cells_programme_reminder_check`, `cells_transfer_effects`,
  `cells_has_reachable_leader`, `cells_programme_ahead`, `cells_report_handover`,
  `cells_handover_pending`, `cells_resolve_handover`, `cells_confirm_request`, `cells_cell_json`,
  `cells_authorize_command`, `cells_command`) match a fresh local reset.
- The Cells handover hook is registered on staging: deactivating or removing the last reachable
  leader or assistant of a cell with a published programme ahead is now refused there.
- Owner manual checks: `docs/runbooks/cells-meetings.md`, story 5.9 (record in `owner-check.md`); the
  epic's external check (an independent reviewer repeats the old-cell access loss on both clients)
  is due before story 5.12.
